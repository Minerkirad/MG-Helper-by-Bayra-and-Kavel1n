// ============================================================
//  MgCore.cs - C# core decisions for MG Helper 3.0 (stage 4)
//  by Bayra & Kavel1n
//
//  Pure decisions only: no registry, no processes, no network. Same inputs -> same
//  outputs as MgHelper.Core.ps1; tools\parity.ps1 compares the two implementations
//  against tools\parity\expected.json, and that comparison is the gate for switching
//  the watcher to C# (docs/PLAN-3.0.md, stage 4).
//
//  Built by the installer / parity runner with Add-Type -OutputAssembly, i.e. the
//  CodeDom compiler: C# 5, no null-propagation, no string interpolation.
//
//  CLI: MgCore.exe --decide <request.json> <response.json>
//       MgCore.exe --version
// ============================================================
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Xml;

public static class MgCoreProgram
{
    public const string CoreVersion = "3.0.0";

    public static int Main(string[] args)
    {
        try
        {
            if (args == null || args.Length == 0)
            {
                Console.Error.WriteLine("usage: MgCore.exe --decide <request.json> <response.json> | --version");
                return 2;
            }
            if (args[0] == "--version")
            {
                Console.WriteLine(CoreVersion);
                return 0;
            }
            if (args[0] == "--decide")
            {
                if (args.Length < 3)
                {
                    Console.Error.WriteLine("--decide needs <request.json> <response.json>");
                    return 2;
                }
                Dictionary<string, object> request = MgJson.ReadObject(args[1]);
                Dictionary<string, object> actual = MgDecisions.Run(request);
                Dictionary<string, object> response = new Dictionary<string, object>();
                response["actual"] = actual;
                MgJson.WriteObject(args[2], response);
                return 0;
            }
            Console.Error.WriteLine("unknown argument: " + args[0]);
            return 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("MgCore: " + ex.Message);
            return 1;
        }
    }
}

internal static class MgJson
{
    public static Dictionary<string, object> ReadObject(string path)
    {
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        string text = File.ReadAllText(path, new UTF8Encoding(false));
        object parsed = serializer.DeserializeObject(text);
        Dictionary<string, object> map = parsed as Dictionary<string, object>;
        if (map == null) throw new InvalidDataException("not a JSON object: " + path);
        return map;
    }

    public static void WriteObject(string path, Dictionary<string, object> value)
    {
        StringBuilder sb = new StringBuilder();
        WriteValue(sb, value);
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
    }

    private static void WriteValue(StringBuilder sb, object value)
    {
        if (value == null) { sb.Append("null"); return; }
        if (value is bool) { sb.Append(((bool)value) ? "true" : "false"); return; }
        if (value is int) { sb.Append(((int)value).ToString(CultureInfo.InvariantCulture)); return; }
        if (value is long) { sb.Append(((long)value).ToString(CultureInfo.InvariantCulture)); return; }
        if (value is double) { sb.Append(((double)value).ToString("R", CultureInfo.InvariantCulture)); return; }
        if (value is string) { WriteString(sb, (string)value); return; }
        IDictionary dictionary = value as IDictionary;
        if (dictionary != null)
        {
            sb.Append('{');
            bool first = true;
            foreach (DictionaryEntry entry in dictionary)
            {
                if (!first) sb.Append(',');
                first = false;
                WriteString(sb, Convert.ToString(entry.Key, CultureInfo.InvariantCulture));
                sb.Append(':');
                WriteValue(sb, entry.Value);
            }
            sb.Append('}');
            return;
        }
        IEnumerable sequence = value as IEnumerable;
        if (sequence != null)
        {
            sb.Append('[');
            bool first = true;
            foreach (object item in sequence)
            {
                if (!first) sb.Append(',');
                first = false;
                WriteValue(sb, item);
            }
            sb.Append(']');
            return;
        }
        WriteString(sb, Convert.ToString(value, CultureInfo.InvariantCulture));
    }

    private static void WriteString(StringBuilder sb, string value)
    {
        sb.Append('"');
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '"' || c == '\\') { sb.Append('\\'); sb.Append(c); }
            else if (c == '\r') { sb.Append("\\r"); }
            else if (c == '\n') { sb.Append("\\n"); }
            else if (c == '\t') { sb.Append("\\t"); }
            else if (c < ' ') { sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); }
            else { sb.Append(c); }
        }
        sb.Append('"');
    }

    public static object Get(Dictionary<string, object> map, string key)
    {
        if (map == null) return null;
        object value;
        if (map.TryGetValue(key, out value)) return value;
        return null;
    }

    public static Dictionary<string, object> GetMap(Dictionary<string, object> map, string key)
    {
        return Get(map, key) as Dictionary<string, object>;
    }

    public static string GetString(Dictionary<string, object> map, string key)
    {
        object value = Get(map, key);
        if (value == null) return null;
        return Convert.ToString(value, CultureInfo.InvariantCulture);
    }

    public static bool GetBool(Dictionary<string, object> map, string key, bool fallback)
    {
        object value = Get(map, key);
        if (value == null) return fallback;
        if (value is bool) return (bool)value;
        string text = Convert.ToString(value, CultureInfo.InvariantCulture);
        if (string.Equals(text, "true", StringComparison.OrdinalIgnoreCase)) return true;
        if (string.Equals(text, "false", StringComparison.OrdinalIgnoreCase)) return false;
        return fallback;
    }

    public static int GetInt(Dictionary<string, object> map, string key, int fallback)
    {
        object value = Get(map, key);
        if (value == null) return fallback;
        return Convert.ToInt32(value, CultureInfo.InvariantCulture);
    }

    public static bool HasNonNull(Dictionary<string, object> map, string key)
    {
        return Get(map, key) != null;
    }
}

internal static class MgDecisions
{
    public static Dictionary<string, object> Run(Dictionary<string, object> request)
    {
        string kind = MgJson.GetString(request, "kind");
        Dictionary<string, object> inputs = MgJson.GetMap(request, "inputs");
        Dictionary<string, object> paths = MgJson.GetMap(request, "paths");
        if (inputs == null) inputs = new Dictionary<string, object>();
        if (paths == null) paths = new Dictionary<string, object>();
        switch (kind)
        {
            case "guard": return Guard(inputs);
            case "adopt": return Adopt(inputs);
            case "golden-source": return GoldenSource(inputs, paths);
            case "apply": return Apply(inputs, paths);
            case "compare": return Compare(inputs, paths);
            case "policy": return Policy(inputs);
            default: throw new ArgumentException("unknown scenario kind: " + kind);
        }
    }

    private static Dictionary<string, object> Guard(Dictionary<string, object> inputs)
    {
        Dictionary<string, object> result = new Dictionary<string, object>();
        string startText = MgJson.GetString(inputs, "sessionStart");
        int windowSec = MgJson.GetInt(inputs, "windowSec", 0);
        bool guardEnabled = MgJson.GetBool(inputs, "guardEnabled", true);
        bool gameRunning = MgJson.GetBool(inputs, "gameRunning", true);
        bool active = false;
        if (guardEnabled && gameRunning && !string.IsNullOrEmpty(startText))
        {
            DateTime start = ParseUtc(startText);
            if (windowSec <= 0) active = true;
            else active = (DateTime.UtcNow - start).TotalSeconds < windowSec;
        }
        result["active"] = active;
        return result;
    }

    private static Dictionary<string, object> Adopt(Dictionary<string, object> inputs)
    {
        Dictionary<string, object> result = new Dictionary<string, object>();
        bool changedAfterUs = MgJson.GetBool(inputs, "changedAfterUs", false);
        bool allowAdopt = MgJson.GetBool(inputs, "allowAdopt", false);
        bool appliedThisSession = MgJson.GetBool(inputs, "appliedThisSession", false);
        bool? same = TriState(inputs, "same");
        bool adopt = allowAdopt && appliedThisSession && changedAfterUs && (same.HasValue && same.Value == false);
        result["adopt"] = adopt;
        return result;
    }

    private static Dictionary<string, object> GoldenSource(Dictionary<string, object> inputs, Dictionary<string, object> paths)
    {
        bool allowLiveFallback = MgJson.GetBool(inputs, "allowLiveFallback", false);
        string live = MgJson.GetString(paths, "live");
        string first = MgJson.GetString(paths, "golden");
        List<string> chain = BuildChain(paths, allowLiveFallback);
        string source = null;
        bool healed = false;
        foreach (string candidate in chain)
        {
            if (GoldenValid(candidate))
            {
                source = candidate;
                healed = !SamePath(candidate, first);
                break;
            }
        }
        Dictionary<string, object> result = new Dictionary<string, object>();
        result["source"] = ClassifySource(source, paths);
        if (source == null) result["healed"] = null;
        else result["healed"] = healed;
        return result;
    }

    private static Dictionary<string, object> Apply(Dictionary<string, object> inputs, Dictionary<string, object> paths)
    {
        Dictionary<string, object> result = new Dictionary<string, object>();
        string golden = MgJson.GetString(paths, "golden");
        string live = MgJson.GetString(paths, "live");
        List<string> chain = BuildChain(paths, false);
        string source = null;
        bool healed = false;
        string first = golden;
        foreach (string candidate in chain)
        {
            if (GoldenValid(candidate)) { source = candidate; healed = !SamePath(candidate, first); break; }
        }
        bool applied = false;
        if (source != null)
        {
            byte[] bytes = File.ReadAllBytes(source);
            applied = true;
            if (healed)
            {
                if (!AtomicWrite(golden, bytes)) applied = false;
                else if (!GoldenValid(golden)) applied = false;
            }
            if (applied) applied = AtomicWrite(live, bytes);
        }
        result["applied"] = applied;
        result["liveTag"] = Tag(live);
        return result;
    }

    private static Dictionary<string, object> Compare(Dictionary<string, object> inputs, Dictionary<string, object> paths)
    {
        Dictionary<string, object> result = new Dictionary<string, object>();
        string a = MgJson.GetString(paths, "a");
        string b = MgJson.GetString(paths, "b");
        bool? same = SameSettings(a, b);
        result["same"] = same.HasValue ? (object)same.Value : null;
        return result;
    }

    private static Dictionary<string, object> Policy(Dictionary<string, object> inputs)
    {
        int version = MgJson.GetInt(inputs, "cfgVersion", 0);
        int windowSec = MgJson.GetInt(inputs, "guardWindowSec", 0);
        bool allowAdoptGiven = MgJson.HasNonNull(inputs, "allowAdopt");
        bool allowAdopt = MgJson.GetBool(inputs, "allowAdopt", false);
        if (version < 3)
        {
            if (!allowAdoptGiven) allowAdopt = false;
            if (windowSec == 120) windowSec = 0;
            version = 3;
        }
        Dictionary<string, object> result = new Dictionary<string, object>();
        result["cfgVersion"] = version;
        result["guardWindowSec"] = windowSec;
        result["allowAdopt"] = allowAdopt;
        return result;
    }

    // ---------- helpers ----------

    private static DateTime ParseUtc(string text)
    {
        DateTime parsed = DateTime.Parse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
        return parsed.ToUniversalTime();
    }

    private static bool? TriState(Dictionary<string, object> inputs, string key)
    {
        object value = MgJson.Get(inputs, key);
        if (value == null) return null;
        if (value is bool) return (bool)value;
        string text = Convert.ToString(value, CultureInfo.InvariantCulture);
        if (string.Equals(text, "true", StringComparison.OrdinalIgnoreCase)) return true;
        if (string.Equals(text, "false", StringComparison.OrdinalIgnoreCase)) return false;
        return null;
    }

    private static List<string> BuildChain(Dictionary<string, object> paths, bool allowLiveFallback)
    {
        List<string> chain = new List<string>();
        AddIfSet(chain, MgJson.GetString(paths, "golden"));
        AddIfSet(chain, MgJson.GetString(paths, "goldenBak"));
        if (allowLiveFallback)
        {
            AddIfSet(chain, MgJson.GetString(paths, "beforeApply"));
            AddIfSet(chain, MgJson.GetString(paths, "live"));
        }
        return chain;
    }

    private static void AddIfSet(List<string> list, string value)
    {
        if (!string.IsNullOrEmpty(value) && !list.Contains(value)) list.Add(value);
    }

    private static string ClassifySource(string source, Dictionary<string, object> paths)
    {
        if (source == null) return null;
        if (SamePath(source, MgJson.GetString(paths, "golden"))) return "golden";
        if (SamePath(source, MgJson.GetString(paths, "goldenBak"))) return "golden.bak";
        if (SamePath(source, MgJson.GetString(paths, "beforeApply"))) return "before_apply";
        if (SamePath(source, MgJson.GetString(paths, "live"))) return "live";
        return "other";
    }

    private static bool SamePath(string a, string b)
    {
        if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return false;
        return string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);
    }

    public static bool GoldenValid(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return false;
        try
        {
            FileInfo info = new FileInfo(path);
            if (info.Length <= 100) return false;
            return ValidSettingsXml(path);
        }
        catch { return false; }
    }

    public static bool ValidSettingsXml(string path)
    {
        try
        {
            XmlReaderSettings settings = new XmlReaderSettings();
            settings.DtdProcessing = DtdProcessing.Prohibit;
            settings.XmlResolver = null;
            settings.CheckCharacters = true;
            using (XmlReader reader = XmlReader.Create(path, settings))
            {
                XmlDocument document = new XmlDocument();
                document.XmlResolver = null;
                document.Load(reader);
                return document.DocumentElement != null && string.Equals(document.DocumentElement.Name, "Settings", StringComparison.Ordinal);
            }
        }
        catch { return false; }
    }

    private static string XmlSignature(string xmlText)
    {
        try
        {
            XmlDocument document = new XmlDocument();
            document.XmlResolver = null;
            document.LoadXml(xmlText);
            if (document.DocumentElement == null) return null;
            List<string> lines = new List<string>();
            Walk(document.DocumentElement, string.Empty, lines);
            lines.Sort(StringComparer.Ordinal);
            return string.Join("\n", lines.ToArray());
        }
        catch { return null; }
    }

    private static void Walk(XmlNode node, string path, List<string> lines)
    {
        foreach (XmlNode child in node.ChildNodes)
        {
            if (child.NodeType != XmlNodeType.Element) continue;
            List<string> attributes = new List<string>();
            if (child.Attributes != null)
            {
                foreach (XmlAttribute attribute in child.Attributes)
                {
                    attributes.Add(attribute.Name + "=" + attribute.Value);
                }
            }
            attributes.Sort(StringComparer.Ordinal);
            lines.Add(path + "/" + child.Name + " [" + string.Join(";", attributes.ToArray()) + "]");
            Walk(child, path + "/" + child.Name, lines);
        }
    }

    public static bool? SameSettings(string a, string b)
    {
        string textA;
        string textB;
        try
        {
            textA = File.ReadAllText(a);
            textB = File.ReadAllText(b);
        }
        catch { return null; }
        string signatureA = XmlSignature(textA);
        string signatureB = XmlSignature(textB);
        if (signatureA != null && signatureB != null) return string.Equals(signatureA, signatureB, StringComparison.Ordinal);
        return string.Equals(StripWhitespace(textA), StripWhitespace(textB), StringComparison.Ordinal);
    }

    private static string StripWhitespace(string text)
    {
        StringBuilder sb = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (!char.IsWhiteSpace(c)) sb.Append(c);
        }
        return sb.ToString();
    }

    private static bool AtomicWrite(string path, byte[] bytes)
    {
        string tmp = path + "." + System.Diagnostics.Process.GetCurrentProcess().Id + ".mgtmp";
        for (int attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                File.WriteAllBytes(tmp, bytes);
                if (File.Exists(path))
                {
                    FileInfo info = new FileInfo(path);
                    if ((info.Attributes & FileAttributes.ReadOnly) != 0) info.Attributes = info.Attributes & ~FileAttributes.ReadOnly;
                    File.Replace(tmp, path, null);
                }
                else
                {
                    File.Move(tmp, path);
                }
                return true;
            }
            catch
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                System.Threading.Thread.Sleep(1000);
            }
        }
        return false;
    }

    private static string Tag(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return "MISSING";
        string text;
        try { text = File.ReadAllText(path); } catch { return "MISSING"; }
        string[] markers = new string[] { "GOLDEN-BAK", "MAJESTIC-OVERWRITE", "USER-LIVE", "OLD-LIVE", "GOLDEN" };
        foreach (string marker in markers)
        {
            if (text.Contains(marker)) return marker;
        }
        return "UNKNOWN";
    }
}