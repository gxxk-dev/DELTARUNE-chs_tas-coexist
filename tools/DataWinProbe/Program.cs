using Underanalyzer.Decompiler;
using UndertaleModLib;
using UndertaleModLib.Decompiler;
using System.Security.Cryptography;
using System.Text;

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

if (args.Length < 2)
{
    Console.Error.WriteLine("Usage: DataWinProbe <command> <data.win> [args...]");
    Console.Error.WriteLine("Commands: summary, list-code, grep-strings <term>, decompile <codeName>, compare-code <keucher.win> <merged.win> <code-list>");
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
    case "grep-strings":
        if (args.Length < 3) throw new Exception("grep-strings requires a term");
        string term = args[2];
        foreach (var item in data.Strings.Select(x => x.Content).Where(x => x.Contains(term, StringComparison.OrdinalIgnoreCase)).Order())
            Console.WriteLine(item);
        break;
    case "decompile":
        if (args.Length < 3) throw new Exception("decompile requires a code name");
        Console.Write(Decompile(data, args[2]));
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
    default:
        throw new Exception($"Unknown command: {command}");
}

return 0;
