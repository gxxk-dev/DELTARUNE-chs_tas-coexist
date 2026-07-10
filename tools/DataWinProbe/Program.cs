using Underanalyzer.Decompiler;
using UndertaleModLib;
using UndertaleModLib.Compiler;
using UndertaleModLib.Decompiler;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

static UndertaleData Load(string path)
{
    using FileStream input = new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    return UndertaleIO.Read(input, (warning, important) =>
    {
        if (important) Console.Error.WriteLine($"warning: {warning}");
    });
}

static string Decompile(UndertaleData data, string codeName)
{
    var code = data.Code.ByName(codeName);
    if (code == null) throw new Exception($"Code not found: {codeName}");
    GlobalDecompileContext globalContext = new(data);
    IDecompileSettings settings = data.ToolInfo.DecompilerSettings;
    DecompileContext context = new(globalContext, code, settings);
    return context.DecompileToString();
}

static string Hash(string content)
{
    byte[] bytes = SHA256.HashData(Encoding.UTF8.GetBytes(content));
    return Convert.ToHexString(bytes).ToLowerInvariant();
}

static bool NeedsSavestateLoadingGuard(string codeName)
{
    if (!codeName.StartsWith("gml_Object_", StringComparison.Ordinal)) return false;
    return codeName.EndsWith("_Create_0", StringComparison.Ordinal)
        || codeName.EndsWith("_Step_1", StringComparison.Ordinal)
        || codeName.EndsWith("_Other_4", StringComparison.Ordinal)
        || codeName.EndsWith("_PreCreate_0", StringComparison.Ordinal)
        || codeName.EndsWith("_PreCreate", StringComparison.Ordinal);
}

static string ReinstrumentSavestateV2(string codeName, string content, out int replacements, out bool guardAdded)
{
    string[] loggedFunctions =
    [
        "audio_play_sound", "audio_stop_sound", "audio_play_sound_at", "audio_play_sound_on",
        "audio_sound_gain", "audio_emitter_create", "audio_create_stream", "audio_destroy_stream",
        "audio_listener_orientation", "audio_listener_position", "ds_list_create", "ds_map_create",
        "ds_priority_create", "sprite_get_texture", "sprite_create_from_surface", "sprite_add",
        "path_start", "json_decode", "call_later"
    ];

    replacements = 0;
    foreach (string function in loggedFunctions)
    {
        string source = function + "(";
        string target = function + "_logged(";
        if (!content.Contains(source, StringComparison.Ordinal)) continue;
        content = content.Replace(source, target, StringComparison.Ordinal);
        replacements++;
    }

    if (content.Contains("path_delete(", StringComparison.Ordinal))
    {
        content = content.Replace("path_delete(", "path_delete_safe(", StringComparison.Ordinal);
        replacements++;
    }

    guardAdded = false;
    const string guardPattern = @"\A\s*if\s*\(\s*(?:instance_exists\([^)]*\)\s*&&\s*)?(?:obj_savestate_manager|\d+)\.loading\s*\)";
    if (NeedsSavestateLoadingGuard(codeName)
        && !Regex.IsMatch(content, guardPattern, RegexOptions.CultureInvariant))
    {
        content = "if (obj_savestate_manager.loading) exit;" + Environment.NewLine + content;
        guardAdded = true;
    }

    return content;
}

static void AssertNoRawSavestateV2Calls(string codeName, string content)
{
    string[] rawFunctions =
    [
        "audio_play_sound", "audio_stop_sound", "audio_play_sound_at", "audio_play_sound_on",
        "audio_sound_gain", "audio_emitter_create", "audio_create_stream", "audio_destroy_stream",
        "audio_listener_orientation", "audio_listener_position", "ds_list_create", "ds_map_create",
        "ds_priority_create", "sprite_get_texture", "sprite_create_from_surface", "sprite_add",
        "path_start", "json_decode", "call_later", "path_delete"
    ];
    foreach (string function in rawFunctions)
    {
        if (content.Contains(function + "(", StringComparison.Ordinal))
            throw new Exception($"Raw savestate-sensitive call remains in {codeName}: {function}(");
    }

    if (!NeedsSavestateLoadingGuard(codeName)) return;
    const string guardPattern = @"\A\s*if\s*\(\s*(?:instance_exists\([^)]*\)\s*&&\s*)?(?:obj_savestate_manager|\d+)\.loading\s*\)";
    if (!Regex.IsMatch(content, guardPattern, RegexOptions.CultureInvariant))
        throw new Exception($"Savestate loading guard is missing from {codeName}");
}

if (args.Length < 2)
{
    Console.Error.WriteLine("Usage: DataWinProbe <command> <data.win> [args...]");
    Console.Error.WriteLine("Commands: summary, list-code, changed-code-list <modified.win>, grep-strings <term>, grep-code <term>, decompile <codeName>, object-index <objectName>, replace-code <codeName> <gml> <output.win>, compare-code <keucher.win> <merged.win> <code-list>, reinstrument-savestate-v2 <imports-code-dir> <output.win>");
    return 2;
}

string command = args[0];
string dataPath = args[1];
UndertaleData data = Load(dataPath);

switch (command)
{
    case "summary":
        Console.WriteLine($"Code={data.Code.Count}");
        Console.WriteLine($"GameObjects={data.GameObjects.Count}");
        Console.WriteLine($"Sprites={data.Sprites.Count}");
        Console.WriteLine($"Fonts={data.Fonts.Count}");
        Console.WriteLine($"Strings={data.Strings.Count}");
        break;
    case "list-code":
        foreach (var code in data.Code.Where(x => x != null).Select(x => x.Name.Content).Order())
            Console.WriteLine(code);
        break;
    case "changed-code-list":
        if (args.Length < 3) throw new Exception("changed-code-list requires <modified.win>");
        UndertaleData modifiedData = Load(args[2]);
        foreach (var code in data.Code.Where(x => x?.ParentEntry is null).OrderBy(x => x.Name.Content))
        {
            string codeName = code.Name.Content;
            if (modifiedData.Code.ByName(codeName) == null) continue;
            try
            {
                if (Hash(Decompile(data, codeName)) != Hash(Decompile(modifiedData, codeName)))
                    Console.WriteLine(codeName);
            }
            catch
            {
                // Ignore malformed or compiler-generated roots that cannot be decompiled consistently.
            }
        }
        break;
    case "grep-strings":
        if (args.Length < 3) throw new Exception("grep-strings requires a term");
        string term = args[2];
        foreach (var item in data.Strings.Select(x => x.Content).Where(x => x.Contains(term, StringComparison.OrdinalIgnoreCase)).Order())
            Console.WriteLine(item);
        break;
    case "grep-code":
        if (args.Length < 3) throw new Exception("grep-code requires a term");
        string codeTerm = args[2];
        foreach (var code in data.Code.Where(x => x != null).Select(x => x.Name.Content).Order())
        {
            try
            {
                if (Decompile(data, code).Contains(codeTerm, StringComparison.OrdinalIgnoreCase))
                    Console.WriteLine(code);
            }
            catch
            {
                // Some entries are compiler-generated child code and cannot be decompiled as roots.
            }
        }
        break;
    case "decompile":
        if (args.Length < 3) throw new Exception("decompile requires a code name");
        Console.Write(Decompile(data, args[2]));
        break;
    case "object-index":
        if (args.Length < 3) throw new Exception("object-index requires an object name");
        int objectIndex = -1;
        for (int i = 0; i < data.GameObjects.Count; i++)
        {
            if (data.GameObjects[i]?.Name?.Content != args[2]) continue;
            objectIndex = i;
            break;
        }
        if (objectIndex < 0) throw new Exception($"Object not found: {args[2]}");
        Console.WriteLine(objectIndex);
        break;
    case "replace-code":
        if (args.Length < 5) throw new Exception("replace-code requires <codeName> <gml> <output.win>");
        string replaceCodeName = args[2];
        string gmlPath = args[3];
        string outputPath = args[4];
        if (data.Code.ByName(replaceCodeName) == null) throw new Exception($"Code not found: {replaceCodeName}");
        CodeImportGroup importGroup = new(data);
        importGroup.QueueReplace(replaceCodeName, File.ReadAllText(gmlPath, Encoding.UTF8));
        CompileResult compileResult = importGroup.Import();
        if (!compileResult.Successful)
            throw new Exception(compileResult.PrintAllErrors(true));
        using (FileStream output = new(outputPath, FileMode.Create, FileAccess.Write))
            UndertaleIO.Write(output, data);
        break;
    case "compare-code":
        if (args.Length < 5) throw new Exception("compare-code requires <keucher.win> <merged.win> <code-list>");
        UndertaleData keucher = Load(args[2]);
        UndertaleData merged = Load(args[3]);
        foreach (string rawCode in File.ReadLines(args[4]))
        {
            string codeName = rawCode.Trim();
            if (codeName.Length == 0) continue;

            string vanillaCode = Decompile(data, codeName);
            string keucherCode = Decompile(keucher, codeName);
            string mergedCode = Decompile(merged, codeName);

            string vanillaHash = Hash(vanillaCode);
            string keucherHash = Hash(keucherCode);
            string mergedHash = Hash(mergedCode);
            if (vanillaHash == keucherHash) continue;

            string status = mergedHash == keucherHash
                ? "merged_matches_keucher"
                : mergedHash == vanillaHash
                    ? "merged_lost_keucher"
                    : "merged_differs_from_both";
            Console.WriteLine($"{status}\t{codeName}\t{vanillaHash}\t{keucherHash}\t{mergedHash}");
        }
        break;
    case "reinstrument-savestate-v2":
        if (args.Length < 4) throw new Exception("reinstrument-savestate-v2 requires <imports-code-dir> <output.win>");
        string importsCodeDir = args[2];
        string reinstrumentedOutput = args[3];
        if (!Directory.Exists(importsCodeDir)) throw new Exception($"Imports directory not found: {importsCodeDir}");

        string managerCreate = Decompile(data, "gml_Object_obj_savestate_manager_Create_0");
        if (!managerCreate.Contains("function decode_data_type(", StringComparison.Ordinal)
            || !managerCreate.Contains("game_display_name", StringComparison.Ordinal))
            throw new Exception("Expected Keucher savestate v2 manager was not found");

        CodeImportGroup reinstrumentGroup = new(data);
        int changedCodes = 0;
        int guardedCodes = 0;
        int callReplacementGroups = 0;
        foreach (string importPath in Directory.GetFiles(importsCodeDir, "*.gml").Order())
        {
            string codeName = Path.GetFileNameWithoutExtension(importPath);
            if (data.Code.ByName(codeName) == null)
            {
                Console.Error.WriteLine($"warning: imported code not found in data.win: {codeName}");
                continue;
            }

            string original = Decompile(data, codeName);
            string instrumented = ReinstrumentSavestateV2(codeName, original, out int callGroups, out bool guardAdded);
            if (instrumented == original) continue;
            reinstrumentGroup.QueueReplace(codeName, instrumented);
            changedCodes++;
            callReplacementGroups += callGroups;
            if (guardAdded) guardedCodes++;
        }

        if (changedCodes > 0)
        {
            CompileResult reinstrumentResult = reinstrumentGroup.Import();
            if (!reinstrumentResult.Successful)
                throw new Exception(reinstrumentResult.PrintAllErrors(true));
        }
        foreach (string importPath in Directory.GetFiles(importsCodeDir, "*.gml").Order())
        {
            string codeName = Path.GetFileNameWithoutExtension(importPath);
            if (data.Code.ByName(codeName) == null) continue;
            AssertNoRawSavestateV2Calls(codeName, Decompile(data, codeName));
        }
        using (FileStream output = new(reinstrumentedOutput, FileMode.Create, FileAccess.Write))
            UndertaleIO.Write(output, data);
        Console.WriteLine($"reinstrumented {changedCodes} code entries ({guardedCodes} guards, {callReplacementGroups} call groups)");
        break;
    default:
        throw new Exception($"Unknown command: {command}");
}

return 0;
