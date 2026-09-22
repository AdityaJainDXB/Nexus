using System.Collections.Concurrent;
using System.Diagnostics;

namespace Nexus.Core;

public enum ChangeKind { created, modified, removed, renamed }
public record FileChange(string Path, ChangeKind Kind, string? OldPath = null, bool IsDirectory = false);

/// Recursive FileSystemWatcher per root with batching; buffer overflows trigger a rescan callback.
public class FileWatcher : IDisposable
{
    readonly List<FileSystemWatcher> watchers = [];
    readonly ConcurrentQueue<FileChange> pending = new();
    Timer? flush;
    public List<string> WatchedPaths { get; private set; } = [];
    public Action<List<FileChange>>? OnChange;
    public Action<string>? OnOverflow;

    public void Start(IEnumerable<string> roots)
    {
        Stop();
        WatchedPaths = roots.Where(Directory.Exists).Select(Paths.Canonical).Distinct(Paths.Comparer).ToList();
        foreach (var root in WatchedPaths)
        {
            try
            {
                var w = new FileSystemWatcher(root)
                {
                    IncludeSubdirectories = true, InternalBufferSize = 64 * 1024,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
                };
                w.Created += (_, e) => Push(new FileChange(e.FullPath, ChangeKind.created, null, Directory.Exists(e.FullPath)));
                w.Changed += (_, e) => Push(new FileChange(e.FullPath, ChangeKind.modified, null, Directory.Exists(e.FullPath)));
                w.Deleted += (_, e) => Push(new FileChange(e.FullPath, ChangeKind.removed));
                w.Renamed += (_, e) => Push(new FileChange(e.FullPath, ChangeKind.renamed, e.OldFullPath, Directory.Exists(e.FullPath)));
                w.Error += (_, _) => OnOverflow?.Invoke(root);
                w.EnableRaisingEvents = true;
                watchers.Add(w);
            }
            catch { }
        }
        flush = new Timer(_ => Flush(), null, 400, 400);
    }

    void Push(FileChange c) => pending.Enqueue(c with { Path = Paths.Canonical(c.Path), OldPath = c.OldPath == null ? null : Paths.Canonical(c.OldPath) });

    void Flush()
    {
        if (pending.IsEmpty) return;
        var batch = new List<FileChange>();
        while (pending.TryDequeue(out var c)) batch.Add(c);
        // collapse duplicate modified events
        var collapsed = batch.GroupBy(c => (c.Path.ToLowerInvariant(), c.Kind)).Select(g => g.Last()).ToList();
        try { OnChange?.Invoke(collapsed); } catch { }
    }

    public void Stop()
    {
        flush?.Dispose(); flush = null;
        foreach (var w in watchers) { try { w.EnableRaisingEvents = false; w.Dispose(); } catch { } }
        watchers.Clear();
    }

    public void Dispose() => Stop();
}

/// Waits until a file stops growing and can be opened (downloads, copies in progress) before processing it.
public class FileStabilizer
{
    readonly ConcurrentDictionary<string, (long size, int checks, int stable)> pending = new(StringComparer.OrdinalIgnoreCase);
    public Action<string>? OnStable;
    public int IntervalMs { get; set; } = 700;

    public void Submit(string path)
    {
        if (pending.TryAdd(path, (-1, 0, 0))) _ = Check(path);
    }

    async Task Check(string path)
    {
        while (true)
        {
            await Task.Delay(IntervalMs);
            if (!pending.TryGetValue(path, out var st)) return;
            long size;
            try
            {
                var fi = new FileInfo(path);
                if (!fi.Exists) { pending.TryRemove(path, out _); return; }
                size = fi.Length;
            }
            catch { pending.TryRemove(path, out _); return; }
            var stable = size == st.size ? st.stable + 1 : 0;
            if (stable >= 1 && CanOpen(path))
            {
                pending.TryRemove(path, out _);
                try { OnStable?.Invoke(path); } catch { }
                return;
            }
            if (st.checks > 400) { pending.TryRemove(path, out _); return; }
            pending[path] = (size, st.checks + 1, stable);
        }
    }

    static bool CanOpen(string path)
    {
        try { using var _ = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); return true; } catch { return false; }
    }
}

/// Polls disk space, power, idle time, drives and running apps; raises events on changes.
public class SystemMonitor
{
    public SystemSnapshot Snapshot { get; private set; } = Sample();
    public Action<TriggerKind, Dictionary<string, string>>? OnEvent;
    Timer? timer;
    Dictionary<string, string> volumes = new(StringComparer.OrdinalIgnoreCase);
    HashSet<string> apps = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, string> friendly = new(StringComparer.OrdinalIgnoreCase);
    bool wasIdle;
    bool first = true;

    public void Start() => timer = new Timer(_ => Poll(), null, 500, 5000);
    public void Stop() { timer?.Dispose(); timer = null; }

    public static SystemSnapshot Sample()
    {
        var s = new SystemSnapshot { OnAcPower = Platform.Current.OnAcPower, LowPowerMode = Platform.Current.LowPowerMode, IdleSeconds = Platform.Current.IdleSeconds };
        try
        {
            var root = Path.GetPathRoot(Paths.Home) ?? "/";
            var d = new DriveInfo(root);
            s.DiskFreeGB = d.AvailableFreeSpace / 1e9; s.DiskTotalGB = d.TotalSize / 1e9;
        }
        catch { }
        return s;
    }

    void Poll()
    {
        try
        {
            var snap = Sample();
            // Drives
            var now = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var d in DriveInfo.GetDrives())
            {
                try { if (d.IsReady && d.DriveType is DriveType.Removable or DriveType.Fixed or DriveType.Network) now[d.RootDirectory.FullName] = string.IsNullOrEmpty(d.VolumeLabel) ? d.Name : d.VolumeLabel; }
                catch { }
            }
            snap.Volumes = now.Values.ToList();
            if (!first)
            {
                foreach (var (root, label) in now.Where(v => !volumes.ContainsKey(v.Key)))
                    OnEvent?.Invoke(TriggerKind.volumeMounted, new() { ["volumeName"] = label, ["volumePath"] = root });
                foreach (var (root, label) in volumes.Where(v => !now.ContainsKey(v.Key)))
                    OnEvent?.Invoke(TriggerKind.volumeUnmounted, new() { ["volumeName"] = label, ["volumePath"] = root });
            }
            volumes = now;

            // Apps with a window
            var running = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in Process.GetProcesses())
            {
                try { if (p.MainWindowHandle != IntPtr.Zero || !Paths.IsWindows) running.Add(p.ProcessName); } catch { }
                finally { p.Dispose(); }
            }
            if (!first && Paths.IsWindows)
            {
                foreach (var a in running.Where(a => !apps.Contains(a))) OnEvent?.Invoke(TriggerKind.appLaunched, new() { ["appName"] = Friendly(a), ["process"] = a });
                foreach (var a in apps.Where(a => !running.Contains(a))) OnEvent?.Invoke(TriggerKind.appQuit, new() { ["appName"] = friendly.GetValueOrDefault(a, a), ["process"] = a });
            }
            apps = running;

            // Idle / wake
            var idle = snap.IdleSeconds >= 15 * 60;
            if (idle && !wasIdle) OnEvent?.Invoke(TriggerKind.idle, new() { ["idleMinutes"] = ((int)(snap.IdleSeconds / 60)).ToString() });
            if (!idle && wasIdle) OnEvent?.Invoke(TriggerKind.wake, []);
            wasIdle = idle;
            if (snap.DiskFreeGB > 0 && snap.DiskFreeGB < 25) OnEvent?.Invoke(TriggerKind.diskSpaceBelow, new() { ["freeGB"] = snap.DiskFreeGB.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) });
            Snapshot = snap;
            first = false;
        }
        catch { }
    }

    string Friendly(string process)
    {
        if (friendly.TryGetValue(process, out var f)) return f;
        var name = process;
        try
        {
            var p = Process.GetProcessesByName(process).FirstOrDefault();
            var desc = p?.MainModule?.FileVersionInfo.FileDescription;
            if (!string.IsNullOrWhiteSpace(desc)) name = desc.Trim();
        }
        catch { }
        friendly[process] = name;
        return name;
    }
}
