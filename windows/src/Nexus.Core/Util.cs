using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Nexus.Core;

public static class Ids
{
    public static string New() => Guid.NewGuid().ToString();
}

/// Path helpers. Paths are stored with native separators; "~" means the user profile.
/// NEXUS_HOME_ROOT (fake home) and NEXUS_HOME (support folder) make every test hermetic.
public static class Paths
{
    public static bool IsWindows => OperatingSystem.IsWindows();
    public static StringComparison Cmp => IsWindows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
    public static StringComparer Comparer => IsWindows ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
    public static char Sep => Path.DirectorySeparatorChar;

    static string? FakeHome => Environment.GetEnvironmentVariable("NEXUS_HOME_ROOT") is { Length: > 0 } h ? h : null;

    public static string Home => Canonical(FakeHome ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    public static string AppSupport
    {
        get
        {
            var custom = Environment.GetEnvironmentVariable("NEXUS_HOME");
            var dir = custom is { Length: > 0 } ? custom
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Nexus");
            Directory.CreateDirectory(dir);
            return Canonical(dir);
        }
    }

    /// Well-known folders, honoring OneDrive "Known Folder Move" redirection on real Windows installs.
    public static string KnownFolder(string name)
    {
        var n = name.ToLowerInvariant();
        if (FakeHome == null && IsWindows)
        {
            string? real = n switch
            {
                "documents" => Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                "desktop" => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                "pictures" => Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
                "music" => Environment.GetFolderPath(Environment.SpecialFolder.MyMusic),
                "videos" or "movies" => Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
                "downloads" => KnownFolders.Downloads(),
                _ => null
            };
            if (!string.IsNullOrEmpty(real)) return Canonical(real);
        }
        var folder = n switch
        {
            "documents" => "Documents", "desktop" => "Desktop", "pictures" => "Pictures", "music" => "Music",
            "videos" or "movies" => IsWindows || FakeHome != null ? "Videos" : "Movies", "downloads" => "Downloads", _ => name
        };
        return Canonical(Path.Combine(Home, folder));
    }

    static readonly string[] Known = ["Documents", "Desktop", "Downloads", "Pictures", "Music", "Videos", "Movies"];

    public static string Expand(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return raw;
        var s = raw.Trim().Replace('\\', '/');
        if (s == "~") return Home;
        if (s.StartsWith("~/"))
        {
            var rest = s[2..];
            var first = rest.Split('/')[0];
            var tail = rest.Length > first.Length ? rest[(first.Length + 1)..] : "";
            string root;
            if (Known.Any(k => k.Equals(first, StringComparison.OrdinalIgnoreCase))) root = KnownFolder(first);
            else { root = Home; tail = rest; }
            return Canonical(tail.Length == 0 ? root : Path.Combine(root, tail.Replace('/', Sep)));
        }
        if (IsWindows && s.StartsWith('/') && !s.StartsWith("//")) return s.Replace('/', Sep); // not a Windows path; leave for protection checks
        return Canonical(s.Replace('/', Sep));
    }

    /// Normalizes separators, drops trailing separators, resolves "..". Case is preserved.
    public static string Canonical(string raw)
    {
        if (string.IsNullOrEmpty(raw)) return raw;
        var p = raw;
        if (IsWindows) p = p.Replace('/', '\\');
        try { p = Path.GetFullPath(p); } catch { }
        if (!IsWindows)
        {
            foreach (var prefix in new[] { "/private/tmp", "/private/var", "/private/etc" })
                if (p == prefix || p.StartsWith(prefix + "/")) p = p[8..];
        }
        var root = Path.GetPathRoot(p) ?? "";
        while (p.Length > root.Length && (p.EndsWith(Sep) || p.EndsWith('/'))) p = p[..^1];
        return p;
    }

    public static bool Same(string a, string b) => string.Equals(Canonical(a), Canonical(b), Cmp);

    public static bool IsInside(string path, string folder, bool recursive = true)
    {
        var p = Canonical(path); var f = Canonical(folder);
        if (string.IsNullOrEmpty(f)) return false;
        var prefix = f.EndsWith(Sep) ? f : f + Sep;
        if (!p.StartsWith(prefix, Cmp)) return false;
        if (recursive) return true;
        return !p[prefix.Length..].Contains(Sep);
    }

    public static string Abbreviate(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;
        var p = Canonical(path);
        var h = Home;
        if (p.Equals(h, Cmp)) return "~";
        if (IsInside(p, h)) return "~" + "/" + p[(h.Length + 1)..].Replace('\\', '/');
        return p;
    }

    public static string FolderOf(string path) => Path.GetDirectoryName(Canonical(path)) ?? "";

    /// System folders, app data and the home folder itself are never touched by automations.
    public static IEnumerable<string> ProtectedPrefixes()
    {
        var home = Home;
        var list = new List<string> { Path.Combine(home, ".ssh"), Path.Combine(home, ".gnupg"), Path.Combine(home, ".config") };
        if (IsWindows)
        {
            var win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            list.AddRange([win, Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                Path.Combine(home, "AppData"), Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)]);
            foreach (var d in SafeDrives()) { list.Add(Path.Combine(d, "$Recycle.Bin")); list.Add(Path.Combine(d, "System Volume Information")); }
        }
        else
        {
            list.AddRange(["/System", "/Library", "/bin", "/sbin", "/usr", "/Applications", "/etc", "/var/db", "/var/root", Path.Combine(home, "Library")]);
        }
        return list.Where(x => !string.IsNullOrEmpty(x)).Select(Canonical);
    }

    static IEnumerable<string> SafeDrives()
    {
        try { return DriveInfo.GetDrives().Select(d => d.RootDirectory.FullName); } catch { return []; }
    }

    public static bool IsProtected(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return true;
        var path = Canonical(raw);
        if (path.Equals(Home, Cmp)) return true;
        var root = Path.GetPathRoot(path);
        if (!string.IsNullOrEmpty(root) && path.Equals(Canonical(root), Cmp)) return true;   // C:\ or /
        // Nexus's own inbox (connector drops) is writable
        if (IsInside(path, Path.Combine(AppSupport, "Inbox"))) return false;
        return ProtectedPrefixes().Any(p => path.Equals(p, Cmp) || IsInside(path, p));
    }

    public static string UniquePath(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path) ?? "";
        var name = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path);
        for (var i = 2; i < 10_000; i++)
        {
            var candidate = Path.Combine(dir, $"{name} ({i}){ext}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
        return Path.Combine(dir, $"{name} {Ids.New()[..6]}{ext}");
    }
}

static class KnownFolders
{
    static readonly Guid DownloadsId = new("374DE290-123F-4565-9164-39C4925E467B");

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint flags, IntPtr token, out IntPtr path);

    public static string? Downloads()
    {
        try
        {
            if (SHGetKnownFolderPath(DownloadsId, 0, IntPtr.Zero, out var p) == 0)
            {
                var s = Marshal.PtrToStringUni(p);
                Marshal.FreeCoTaskMem(p);
                return s;
            }
        }
        catch { }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        WriteIndented = false,
    };
    public static readonly JsonSerializerOptions Pretty = new(Options) { WriteIndented = true };

    public static string Str<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T? Parse<T>(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return default;
        try { return JsonSerializer.Deserialize<T>(json, Options); } catch { return default; }
    }
}

public static class Text
{
    public static string Trimmed(this string s) => s.Trim();

    /// Regex captures (group 0..n, missing groups as ""), case-insensitive; null when no match.
    public static string[]? Captures(this string s, string pattern, RegexOptions extra = RegexOptions.None)
    {
        var m = Regex.Match(s, pattern, RegexOptions.IgnoreCase | RegexOptions.Singleline | extra);
        if (!m.Success) return null;
        var arr = new string[m.Groups.Count];
        for (var i = 0; i < m.Groups.Count; i++) arr[i] = m.Groups[i].Success ? m.Groups[i].Value : "";
        return arr;
    }

    public static string Re(this string s, string pattern, string replacement, bool ignoreCase = true) =>
        Regex.Replace(s, pattern, replacement, ignoreCase ? RegexOptions.IgnoreCase : RegexOptions.None);

    public static bool Has(this string s, string pattern) => Regex.IsMatch(s, pattern, RegexOptions.IgnoreCase);

    public static bool Glob(this string text, string pattern)
    {
        var re = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
        return Regex.IsMatch(text, re, RegexOptions.IgnoreCase);
    }

    public static string Capitalized(this string s) =>
        string.Join(' ', s.Split(' ').Select(w => w.Length == 0 ? w : char.ToUpperInvariant(w[0]) + w[1..].ToLowerInvariant()));

    public static string FormatBytes(long bytes)
    {
        double b = bytes;
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        var i = 0;
        while (b >= 1000 && i < units.Length - 1) { b /= 1000; i++; }
        return i == 0 ? $"{bytes} bytes" : $"{b:0.#} {units[i]}";
    }

    public static string Relative(DateTime when)
    {
        var d = when - DateTime.Now;
        var future = d.TotalSeconds > 0;
        var a = d.Duration();
        string s = a.TotalMinutes < 1 ? "moments" : a.TotalHours < 1 ? $"{(int)a.TotalMinutes} min" : a.TotalDays < 1 ? $"{(int)a.TotalHours} h" : $"{(int)a.TotalDays} days";
        return future ? $"in {s}" : $"{s} ago";
    }

    public static string Plural(int n, string word) =>
        $"{n} {(n == 1 ? word : word.EndsWith('y') && word.Length > 1 && !"aeiou".Contains(word[^2]) ? word[..^1] + "ies" : word.EndsWith('s') || word.EndsWith("sh") || word.EndsWith("ch") || word.EndsWith('x') ? word + "es" : word + "s")}";

    public static string Collapse(this string s) => Regex.Replace(s, "\\s+", " ").Trim();

    public static string Sha256File(string path)
    {
        using var sha = System.Security.Cryptography.SHA256.Create();
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16);
        return Convert.ToHexString(sha.ComputeHash(fs)).ToLowerInvariant();
    }

    public static string Utf8(byte[] b) => Encoding.UTF8.GetString(b);
}

public static class Time
{
    public static double Epoch(DateTime d) => (d.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds;
    public static DateTime FromEpoch(double s) => DateTime.UnixEpoch.AddSeconds(s).ToLocalTime();
    public static string Iso(DateTime d) => d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
}
