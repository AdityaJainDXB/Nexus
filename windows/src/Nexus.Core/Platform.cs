using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace Nexus.Core;

/// OS services the engine uses. The Windows app replaces the defaults with WinRT/Win32 implementations
/// (OCR, image decoding, toasts); the defaults keep the core fully testable on any OS.
public class Platform
{
    public static Platform Current { get; set; } = new();

    /// OCR an image; null when unavailable.
    public virtual string? Ocr(string path) => null;
    /// 64-bit perceptual difference hash of an image; null when unavailable.
    public virtual ulong? ImageHash(string path) => null;
    public virtual bool OnAcPower => true;
    public virtual bool LowPowerMode => false;
    public virtual double IdleSeconds => 0;
    public virtual void Notify(string title, string body, bool important) { }
    public virtual void Open(string path) { try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { } }
    public virtual void Reveal(string path)
    {
        try
        {
            if (Paths.IsWindows) Process.Start("explorer.exe", $"/select,\"{path}\"");
            else Process.Start("open", ["-R", path]);
        }
        catch { }
    }
    public virtual string MachineName => Environment.MachineName;

    // MARK: Recycle Bin

    /// Moves a file to the Recycle Bin (Windows) or Nexus's trash folder. Returns an undo token.
    public virtual string Trash(string path)
    {
        var overrideDir = Environment.GetEnvironmentVariable("NEXUS_TRASH_DIR");
        if (!string.IsNullOrEmpty(overrideDir) || !Paths.IsWindows)
        {
            var dir = !string.IsNullOrEmpty(overrideDir) ? overrideDir : Path.Combine(Paths.AppSupport, "Trash");
            Directory.CreateDirectory(dir);
            var dest = Paths.UniquePath(Path.Combine(dir, Path.GetFileName(path)));
            if (Directory.Exists(path)) Directory.Move(path, dest); else File.Move(path, dest);
            return "file:" + dest;
        }
        RecycleBin.Send(path);
        return "recycle:" + path;
    }

    /// Restores a trashed file to its original location.
    public virtual bool Restore(string token, string originalPath)
    {
        if (token.StartsWith("file:"))
        {
            var from = token[5..];
            if (!File.Exists(from) && !Directory.Exists(from)) return false;
            Directory.CreateDirectory(Path.GetDirectoryName(originalPath)!);
            var dest = File.Exists(originalPath) ? Paths.UniquePath(originalPath) : originalPath;
            if (Directory.Exists(from)) Directory.Move(from, dest); else File.Move(from, dest);
            return true;
        }
        if (token.StartsWith("recycle:")) return RecycleBin.Restore(token[8..]);
        return false;
    }
}

/// Windows Recycle Bin: send via SHFileOperation (FOF_ALLOWUNDO), restore by reading the $I metadata files
/// in <drive>\$Recycle.Bin\<SID> and moving the matching $R item back.
public static class RecycleBin
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd; public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string? pTo;
        public ushort fFlags; [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings; [MarshalAs(UnmanagedType.LPWStr)] public string? lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
    const uint FO_DELETE = 3;
    const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;

    public static void Send(string path)
    {
        var op = new SHFILEOPSTRUCT { wFunc = FO_DELETE, pFrom = path + "\0\0", fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI };
        var rc = SHFileOperation(ref op);
        if (rc != 0 || op.fAnyOperationsAborted) throw new IOException($"Couldn't move {Path.GetFileName(path)} to the Recycle Bin (0x{rc:X})");
    }

    public static bool Restore(string originalPath)
    {
        try
        {
            var root = Path.GetPathRoot(originalPath);
            var sid = WindowsIdentity.GetCurrent().User?.Value;
            if (root == null || sid == null) return false;
            var bin = Path.Combine(root, "$Recycle.Bin", sid);
            if (!Directory.Exists(bin)) return false;
            (string info, DateTime deleted)? best = null;
            foreach (var info in Directory.EnumerateFiles(bin, "$I*"))
            {
                var (orig, when) = ReadInfo(info);
                if (orig != null && orig.Equals(originalPath, StringComparison.OrdinalIgnoreCase) && (best == null || when > best.Value.deleted)) best = (info, when);
            }
            if (best == null) return false;
            var data = Path.Combine(bin, "$R" + Path.GetFileName(best.Value.info)[2..]);
            var dest = File.Exists(originalPath) || Directory.Exists(originalPath) ? Paths.UniquePath(originalPath) : originalPath;
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            if (Directory.Exists(data)) Directory.Move(data, dest); else File.Move(data, dest);
            File.Delete(best.Value.info);
            return true;
        }
        catch { return false; }
    }

    /// $I file: version (8) · size (8) · deletion FILETIME (8) · [v2: path length (4)] · UTF-16 path
    static (string? path, DateTime when) ReadInfo(string file)
    {
        try
        {
            var b = File.ReadAllBytes(file);
            if (b.Length < 24) return (null, default);
            var version = BitConverter.ToInt64(b, 0);
            var when = DateTime.FromFileTime(BitConverter.ToInt64(b, 16));
            string path;
            if (version >= 2 && b.Length >= 28)
            {
                var len = BitConverter.ToInt32(b, 24);
                path = Encoding.Unicode.GetString(b, 28, Math.Min(len * 2, b.Length - 28));
            }
            else path = Encoding.Unicode.GetString(b, 24, Math.Min(520, b.Length - 24));
            return (path.TrimEnd('\0'), when);
        }
        catch { return (null, default); }
    }
}

/// Secrets (API tokens, iPhone device keys) encrypted with Windows DPAPI for the current user.
/// Other OSes (tests) fall back to a user-only file.
public static class Secrets
{
    static readonly object Gate = new();
    static string FilePath => Path.Combine(Paths.AppSupport, "secrets.dat");

    static Dictionary<string, string> Load()
    {
        try { return Json.Parse<Dictionary<string, string>>(File.ReadAllText(FilePath)) ?? []; } catch { return []; }
    }

    public static string? Get(string key)
    {
        lock (Gate)
        {
            if (!Load().TryGetValue(key, out var blob)) return null;
            try
            {
                var bytes = Convert.FromBase64String(blob);
                if (OperatingSystem.IsWindows()) bytes = System.Security.Cryptography.ProtectedData.Unprotect(bytes, Encoding.UTF8.GetBytes("nexus:" + key), System.Security.Cryptography.DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(bytes);
            }
            catch { return null; }
        }
    }

    public static void Set(string key, string? value)
    {
        lock (Gate)
        {
            var all = Load();
            if (value == null) all.Remove(key);
            else
            {
                var bytes = Encoding.UTF8.GetBytes(value);
                if (OperatingSystem.IsWindows()) bytes = System.Security.Cryptography.ProtectedData.Protect(bytes, Encoding.UTF8.GetBytes("nexus:" + key), System.Security.Cryptography.DataProtectionScope.CurrentUser);
                all[key] = Convert.ToBase64String(bytes);
            }
            File.WriteAllText(FilePath, Json.Str(all));
            if (!OperatingSystem.IsWindows()) try { File.SetUnixFileMode(FilePath, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
        }
    }
}
