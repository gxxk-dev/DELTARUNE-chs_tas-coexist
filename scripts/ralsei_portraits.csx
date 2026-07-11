using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using ImageMagick;
using Newtonsoft.Json.Linq;
using UndertaleModLib;
using UndertaleModLib.Models;
using UndertaleModLib.Util;

EnsureDataLoaded();

string action = RequireEnvironment("RALSEI_PORTRAITS_ACTION");
string chapter = RequireEnvironment("RALSEI_PORTRAITS_CHAPTER");
string manifestPath = RequireEnvironment("RALSEI_PORTRAITS_MANIFEST");
string assetRoot = Path.GetFullPath(RequireEnvironment("RALSEI_PORTRAITS_ROOT"));

if (action != "import" && action != "verify")
    throw new ScriptException($"Unsupported Ralsei portrait action: {action}");
if (!System.Text.RegularExpressions.Regex.IsMatch(chapter, "^ch[1-5]$"))
    throw new ScriptException($"Invalid Ralsei portrait chapter: {chapter}");
if (!Directory.Exists(assetRoot))
    throw new ScriptException($"Ralsei portrait asset root does not exist: {assetRoot}");

JObject manifest = JObject.Parse(File.ReadAllText(manifestPath));
List<PortraitFrame> frames = manifest["files"]!.Values<JObject>()
    .Where(item => (string)item["chapter"]! == chapter)
    .Select(item => new PortraitFrame(
        (string)item["rel"]!,
        (string)item["sprite"]!,
        (int)item["frame"]!,
        (int)item["width"]!,
        (int)item["height"]!))
    .OrderBy(item => item.Sprite, StringComparer.Ordinal)
    .ThenBy(item => item.Frame)
    .ToList();

if (frames.Count == 0)
    throw new ScriptException($"No Ralsei portrait frames are defined for {chapter}");

Dictionary<string, SpriteSnapshot> snapshots = new(StringComparer.Ordinal);
UndertaleTextureGroupInfo commonGroup = null;
foreach (IGrouping<string, PortraitFrame> spriteFrames in frames.GroupBy(item => item.Sprite))
{
    List<PortraitFrame> ordered = spriteFrames.OrderBy(item => item.Frame).ToList();
    UndertaleSprite sprite = Data.Sprites.ByName(spriteFrames.Key)
        ?? throw new ScriptException($"Missing target sprite: {spriteFrames.Key}");
    if (sprite.IsSpineSprite || sprite.IsYYSWFSprite)
        throw new ScriptException($"Unsupported special sprite type: {spriteFrames.Key}");
    if (sprite.Textures.Count != ordered.Count)
        throw new ScriptException($"Unexpected frame count for {spriteFrames.Key}: {sprite.Textures.Count}");
    for (int index = 0; index < ordered.Count; index++)
    {
        PortraitFrame frame = ordered[index];
        if (frame.Frame != index)
            throw new ScriptException($"Non-contiguous frame mapping for {spriteFrames.Key}");
        if (frame.Width != sprite.Width || frame.Height != sprite.Height)
            throw new ScriptException($"Manifest canvas mismatch for {spriteFrames.Key}_{index}");
        if (sprite.Textures[index]?.Texture is null)
            throw new ScriptException($"Target sprite frame is null: {spriteFrames.Key}_{index}");
        string sourcePath = ResolveAssetPath(assetRoot, frame.Rel);
        using MagickImage source = TextureWorker.ReadBGRAImageFromFile(sourcePath);
        if (source.Width != frame.Width || source.Height != frame.Height)
            throw new ScriptException($"PNG dimensions do not match the manifest: {frame.Rel}");
    }

    List<UndertaleTextureGroupInfo> groups = new();
    if (Data.TextureGroupInfo is not null)
    {
        foreach (UndertaleTextureGroupInfo group in Data.TextureGroupInfo)
        {
            foreach (UndertaleResourceById<UndertaleSprite, UndertaleChunkSPRT> reference in group.Sprites)
            {
                if (reference.Resource == sprite)
                {
                    groups.Add(group);
                    break;
                }
            }
        }
    }
    if (groups.Count != 1)
        throw new ScriptException($"Expected one texture group for {spriteFrames.Key}, found {groups.Count}");
    if (commonGroup is null)
        commonGroup = groups[0];
    else if (commonGroup != groups[0])
        throw new ScriptException("Ralsei portrait sprites do not share one texture group");

    snapshots.Add(spriteFrames.Key, SpriteSnapshot.Capture(sprite));
}

if (action == "import")
{
    int embeddedBefore = Data.EmbeddedTextures.Count;
    int pageItemsBefore = Data.TexturePageItems.Count;
    TextureGroupPacker packer = new(1024, 0, false, GMImage.ImageFormat.Png);
    Dictionary<(string Sprite, int Frame), UndertaleTexturePageItem> replacements = new();
    foreach (PortraitFrame frame in frames)
    {
        MagickImage source = TextureWorker.ReadBGRAImageFromFile(ResolveAssetPath(assetRoot, frame.Rel));
        UndertaleTexturePageItem item = packer.AddImage(
            source,
            TextureGroupPacker.BorderFlags.None,
            false);
        replacements.Add((frame.Sprite, frame.Frame), item);
    }
    packer.PackPages();
    packer.ImportToData(Data);

    int addedPages = Data.EmbeddedTextures.Count - embeddedBefore;
    int addedItems = Data.TexturePageItems.Count - pageItemsBefore;
    if (addedPages != 1 || addedItems != frames.Count)
        throw new ScriptException($"Unexpected atlas result: {addedPages} pages, {addedItems} items");
    for (int index = embeddedBefore; index < Data.EmbeddedTextures.Count; index++)
    {
        // Magick.NET adds wall-clock PNG text chunks; remove only those before serialization.
        Data.EmbeddedTextures[index].TextureData.Image = CanonicalizeAtlasPng(
            Data.EmbeddedTextures[index].TextureData.Image);
        commonGroup.TexturePages.Add(
            new UndertaleResourceById<UndertaleEmbeddedTexture, UndertaleChunkTXTR>(
                Data.EmbeddedTextures[index]));
    }
    foreach (PortraitFrame frame in frames)
        Data.Sprites.ByName(frame.Sprite).Textures[frame.Frame].Texture = replacements[(frame.Sprite, frame.Frame)];
}

foreach ((string spriteName, SpriteSnapshot snapshot) in snapshots)
    snapshot.AssertUnchanged(Data.Sprites.ByName(spriteName));

using (TextureWorker worker = new())
{
    foreach (PortraitFrame frame in frames)
    {
        UndertaleSprite sprite = Data.Sprites.ByName(frame.Sprite);
        UndertaleTexturePageItem item = sprite.Textures[frame.Frame].Texture;
        using IMagickImage<byte> actual = worker.GetTextureFor(
            item,
            $"{frame.Sprite}_{frame.Frame}",
            true);
        using MagickImage expected = TextureWorker.ReadBGRAImageFromFile(
            ResolveAssetPath(assetRoot, frame.Rel));
        byte[] actualPixels = actual.GetPixels().ToByteArray(PixelMapping.RGBA);
        byte[] expectedPixels = expected.GetPixels().ToByteArray(PixelMapping.RGBA);
        if (!actualPixels.AsSpan().SequenceEqual(expectedPixels))
            throw new ScriptException($"Pixel verification failed: {frame.Rel}");
    }
}

Console.WriteLine($"Ralsei portrait {action} verified: {chapter} ({frames.Count} frames)");

GMImage CanonicalizeAtlasPng(GMImage image)
{
    using MemoryStream encoded = new();
    image.SavePng(encoded);
    byte[] source = encoded.ToArray();
    if (source.Length < 20 || !source.AsSpan(0, 8).SequenceEqual(GMImage.MagicPng))
        throw new ScriptException("Generated Ralsei atlas is not a PNG");

    using MemoryStream canonical = new(source.Length);
    canonical.Write(source, 0, 8);
    int offset = 8;
    int removedDateChunks = 0;
    bool foundEnd = false;
    while (offset < source.Length)
    {
        if (source.Length - offset < 12)
            throw new ScriptException("Generated Ralsei atlas has a truncated PNG chunk");
        uint dataLength = ReadBigEndianUInt32(source, offset);
        long chunkLength = 12L + dataLength;
        if (chunkLength > source.Length - offset)
            throw new ScriptException("Generated Ralsei atlas has an invalid PNG chunk length");

        bool isText = source[offset + 4] == (byte)'t' && source[offset + 5] == (byte)'E' &&
            source[offset + 6] == (byte)'X' && source[offset + 7] == (byte)'t';
        bool isDate = dataLength >= 5 && source[offset + 8] == (byte)'d' &&
            source[offset + 9] == (byte)'a' && source[offset + 10] == (byte)'t' &&
            source[offset + 11] == (byte)'e' && source[offset + 12] == (byte)':';
        if (isText && isDate)
        {
            removedDateChunks++;
        }
        else
        {
            canonical.Write(source, offset, checked((int)chunkLength));
        }

        bool isEnd = source[offset + 4] == (byte)'I' && source[offset + 5] == (byte)'E' &&
            source[offset + 6] == (byte)'N' && source[offset + 7] == (byte)'D';
        offset += checked((int)chunkLength);
        if (isEnd)
        {
            foundEnd = true;
            break;
        }
    }
    if (!foundEnd || offset != source.Length || removedDateChunks != 3)
        throw new ScriptException($"Unexpected generated Ralsei atlas metadata ({removedDateChunks} date chunks)");
    return GMImage.FromPng(canonical.ToArray(), true);
}

uint ReadBigEndianUInt32(byte[] bytes, int offset) =>
    ((uint)bytes[offset] << 24) |
    ((uint)bytes[offset + 1] << 16) |
    ((uint)bytes[offset + 2] << 8) |
    bytes[offset + 3];

string RequireEnvironment(string name)
{
    string value = Environment.GetEnvironmentVariable(name);
    if (string.IsNullOrWhiteSpace(value))
        throw new ScriptException($"Required environment variable is missing: {name}");
    return value;
}

string ResolveAssetPath(string root, string relative)
{
    if (string.IsNullOrEmpty(relative) || Path.IsPathRooted(relative) || relative.Contains('\\'))
        throw new ScriptException($"Unsafe Ralsei portrait path: {relative}");
    string fullPath = Path.GetFullPath(Path.Combine(root, relative));
    string prefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
    if (!fullPath.StartsWith(prefix, StringComparison.Ordinal))
        throw new ScriptException($"Ralsei portrait path escapes the asset root: {relative}");
    if (!File.Exists(fullPath))
        throw new ScriptException($"Ralsei portrait PNG is missing: {relative}");
    return fullPath;
}

sealed class PortraitFrame
{
    public string Rel { get; }
    public string Sprite { get; }
    public int Frame { get; }
    public int Width { get; }
    public int Height { get; }

    public PortraitFrame(string rel, string sprite, int frame, int width, int height)
    {
        Rel = rel;
        Sprite = sprite;
        Frame = frame;
        Width = width;
        Height = height;
    }
}

sealed class SpriteSnapshot
{
    private readonly uint width;
    private readonly uint height;
    private readonly int marginLeft;
    private readonly int marginRight;
    private readonly int marginTop;
    private readonly int marginBottom;
    private readonly uint bboxMode;
    private readonly UndertaleSprite.SepMaskType sepMasks;
    private readonly int originX;
    private readonly int originY;
    private readonly bool transparent;
    private readonly bool smooth;
    private readonly bool preload;
    private readonly int textureCount;
    private readonly int collisionMaskCount;
    private readonly string collisionMaskHash;

    private SpriteSnapshot(UndertaleSprite sprite)
    {
        width = sprite.Width;
        height = sprite.Height;
        marginLeft = sprite.MarginLeft;
        marginRight = sprite.MarginRight;
        marginTop = sprite.MarginTop;
        marginBottom = sprite.MarginBottom;
        bboxMode = sprite.BBoxMode;
        sepMasks = sprite.SepMasks;
        originX = sprite.OriginX;
        originY = sprite.OriginY;
        transparent = sprite.Transparent;
        smooth = sprite.Smooth;
        preload = sprite.Preload;
        textureCount = sprite.Textures.Count;
        collisionMaskCount = sprite.CollisionMasks.Count;
        collisionMaskHash = HashMasks(sprite);
    }

    public static SpriteSnapshot Capture(UndertaleSprite sprite) => new(sprite);

    public void AssertUnchanged(UndertaleSprite sprite)
    {
        if (sprite.Width != width || sprite.Height != height ||
            sprite.MarginLeft != marginLeft || sprite.MarginRight != marginRight ||
            sprite.MarginTop != marginTop || sprite.MarginBottom != marginBottom ||
            sprite.BBoxMode != bboxMode || sprite.SepMasks != sepMasks ||
            sprite.OriginX != originX || sprite.OriginY != originY ||
            sprite.Transparent != transparent || sprite.Smooth != smooth ||
            sprite.Preload != preload || sprite.Textures.Count != textureCount ||
            sprite.CollisionMasks.Count != collisionMaskCount || HashMasks(sprite) != collisionMaskHash)
            throw new ScriptException($"Sprite metadata changed unexpectedly: {sprite.Name.Content}");
    }

    private static string HashMasks(UndertaleSprite sprite)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (UndertaleSprite.MaskEntry mask in sprite.CollisionMasks)
            hash.AppendData(mask.Data ?? Array.Empty<byte>());
        return Convert.ToHexString(hash.GetHashAndReset());
    }
}
