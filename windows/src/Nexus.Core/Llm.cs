using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Nexus.Core;

public interface ILlmProvider
{
    string Name { get; }
    Task<string> Complete(string system, string prompt, int maxTokens = 400, CancellationToken ct = default);
}

/// OpenAI-compatible chat against a local llama.cpp server or Ollama.
class ChatProvider(string name, Func<Task<Uri?>> endpoint, string? model) : ILlmProvider
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(180) };
    public string Name { get; } = name;

    public async Task<string> Complete(string system, string prompt, int maxTokens = 400, CancellationToken ct = default)
    {
        var baseUri = await endpoint() ?? throw new InvalidOperationException("model unavailable");
        var body = new JsonObject
        {
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "system", ["content"] = system }, new JsonObject { ["role"] = "user", ["content"] = prompt.Length > 12_000 ? prompt[..12_000] : prompt }),
            ["temperature"] = 0.2, ["max_tokens"] = maxTokens, ["stream"] = false,
        };
        if (model != null) body["model"] = model;
        using var r = await Http.PostAsync(new Uri(baseUri, "v1/chat/completions"), new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json"), ct);
        r.EnsureSuccessStatusCode();
        var json = JsonNode.Parse(await r.Content.ReadAsStringAsync(ct));
        return json?["choices"]?[0]?["message"]?["content"]?.GetValue<string>()?.Trim() ?? "";
    }
}

/// Runs the bundled llama.cpp server on demand; it shuts down when idle and always dies with Nexus.
public sealed class LocalModelServer
{
    public static LocalModelServer Shared { get; } = new();
    Process? process;
    int port;
    DateTime lastUse = DateTime.Now;
    readonly SemaphoreSlim gate = new(1, 1);
    Timer? idleTimer;
    public string? ModelOverride { get; set; }

    static string ExeName => Paths.IsWindows ? "llama-server.exe" : "llama-server";

    public static string? RuntimePath()
    {
        var candidates = new List<string>();
        if (Environment.GetEnvironmentVariable("NEXUS_LLAMA_DIR") is { Length: > 0 } dir) candidates.Add(Path.Combine(dir, ExeName));
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "llama", ExeName));
        return candidates.FirstOrDefault(File.Exists);
    }

    public string? ModelPath()
    {
        if (!string.IsNullOrEmpty(ModelOverride) && File.Exists(Paths.Expand(ModelOverride))) return Paths.Expand(ModelOverride);
        var dirs = new List<string> { Path.Combine(AppContext.BaseDirectory, "Models"), Path.Combine(Paths.AppSupport, "Models") };
        if (Environment.GetEnvironmentVariable("NEXUS_MODELS_DIR") is { Length: > 0 } md) dirs.Insert(0, md);
        return dirs.Where(Directory.Exists).SelectMany(d => Directory.EnumerateFiles(d, "*.gguf")).OrderByDescending(f => new FileInfo(f).Length).FirstOrDefault();
    }

    public bool IsAvailable => RuntimePath() != null && ModelPath() != null;
    public bool IsRunning => process is { HasExited: false };
    public string ModelName => ModelPath() is { } m ? Path.GetFileNameWithoutExtension(m) : "none";

    public async Task<Uri?> Endpoint()
    {
        lastUse = DateTime.Now;
        if (IsRunning && await Healthy(port)) return new Uri($"http://127.0.0.1:{port}/");
        await gate.WaitAsync();
        try
        {
            if (IsRunning && await Healthy(port)) return new Uri($"http://127.0.0.1:{port}/");
            var exe = RuntimePath(); var model = ModelPath();
            if (exe == null || model == null) return null;
            Stop();
            port = FreePort();
            var threads = Math.Max(2, Environment.ProcessorCount / 2);
            var psi = new ProcessStartInfo(exe)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                WorkingDirectory = Path.GetDirectoryName(exe)!,
            };
            foreach (var a in new[] { "-m", model, "--host", "127.0.0.1", "--port", port.ToString(), "-c", "4096", "-t", threads.ToString(), "--no-webui" }) psi.ArgumentList.Add(a);
            var p = Process.Start(psi)!;
            p.OutputDataReceived += (_, _) => { }; p.ErrorDataReceived += (_, _) => { };
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            ChildProcessGuard.Attach(p);
            process = p;
            File.WriteAllText(Path.Combine(Paths.AppSupport, "llama-server.pid"), p.Id.ToString());
            for (var i = 0; i < 240; i++)
            {
                if (p.HasExited) return null;
                if (await Healthy(port)) break;
                await Task.Delay(250);
            }
            idleTimer ??= new Timer(_ => { if (IsRunning && DateTime.Now - lastUse > TimeSpan.FromMinutes(10)) Stop(); }, null, 60_000, 60_000);
            return new Uri($"http://127.0.0.1:{port}/");
        }
        finally { gate.Release(); }
    }

    static async Task<bool> Healthy(int port)
    {
        if (port == 0) return false;
        try
        {
            using var c = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            var r = await c.GetAsync($"http://127.0.0.1:{port}/health");
            return r.IsSuccessStatusCode;
        }
        catch { return false; }
    }

    static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start(); var p = ((IPEndPoint)l.LocalEndpoint).Port; l.Stop();
        return p;
    }

    public void Stop()
    {
        try { if (process is { HasExited: false }) process.Kill(true); } catch { }
        process = null;
        try { File.Delete(Path.Combine(Paths.AppSupport, "llama-server.pid")); } catch { }
    }

    /// Kills a server left behind by a previous crash.
    public void CleanupStale()
    {
        var pidFile = Path.Combine(Paths.AppSupport, "llama-server.pid");
        try
        {
            if (File.Exists(pidFile) && int.TryParse(File.ReadAllText(pidFile), out var pid))
            {
                var p = Process.GetProcessById(pid);
                if (p.ProcessName.Contains("llama", StringComparison.OrdinalIgnoreCase)) p.Kill(true);
            }
        }
        catch { }
        try { File.Delete(pidFile); } catch { }
    }
}

/// Windows Job Object with KILL_ON_JOB_CLOSE: child processes die with Nexus, even after a crash.
static class ChildProcessGuard
{
    static IntPtr job;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string? name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoType, IntPtr info, uint length);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }

    public static void Attach(Process p)
    {
        if (!Paths.IsWindows) return;
        try
        {
            if (job == IntPtr.Zero)
            {
                job = CreateJobObject(IntPtr.Zero, null);
                var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION { Basic = new JOBOBJECT_BASIC_LIMIT_INFORMATION { LimitFlags = 0x2000 } };
                var len = Marshal.SizeOf(info);
                var ptr = Marshal.AllocHGlobal(len);
                Marshal.StructureToPtr(info, ptr, false);
                SetInformationJobObject(job, 9, ptr, (uint)len);
                Marshal.FreeHGlobal(ptr);
            }
            AssignProcessToJobObject(job, p.Handle);
        }
        catch { }
    }
}

public class LlmRouter
{
    public NexusSettings Settings { get; set; } = new();
    ILlmProvider? cached;
    DateTime cachedAt = DateTime.MinValue;
    static readonly HttpClient Probe = new() { Timeout = TimeSpan.FromSeconds(1.5) };

    public void Invalidate() => cachedAt = DateTime.MinValue;

    public async Task<ILlmProvider?> Provider()
    {
        if (DateTime.Now - cachedAt < TimeSpan.FromMinutes(2)) return cached;
        cached = await Resolve();
        cachedAt = DateTime.Now;
        return cached;
    }

    async Task<ILlmProvider?> Resolve()
    {
        LocalModelServer.Shared.ModelOverride = Settings.LocalModelPath;
        var bundled = new ChatProvider($"On-device · {LocalModelServer.Shared.ModelName}", LocalModelServer.Shared.Endpoint, null);
        switch (Settings.LlmProvider)
        {
            case LlmProvider.off: return null;
            case LlmProvider.bundled: return LocalModelServer.Shared.IsAvailable ? bundled : null;
            case LlmProvider.ollama: return await OllamaUp() ? Ollama() : null;
            default:
                if (LocalModelServer.Shared.IsAvailable) return bundled;
                return await OllamaUp() ? Ollama() : null;
        }
    }

    ChatProvider Ollama() => new($"Ollama · {Settings.OllamaModel}", () => Task.FromResult<Uri?>(new Uri(Settings.OllamaUrl.TrimEnd('/') + "/")), Settings.OllamaModel);

    async Task<bool> OllamaUp()
    {
        try { return (await Probe.GetAsync(Settings.OllamaUrl.TrimEnd('/') + "/api/tags")).IsSuccessStatusCode; } catch { return false; }
    }

    public async Task<string> ProviderName() => (await Provider())?.Name ?? "Built-in heuristics (no model)";

    public async Task<string> Summarize(string text, string context)
    {
        if (await Provider() is { } p)
        {
            try
            {
                var s = await p.Complete($"Summarize this {context} in 2-3 crisp sentences. Plain text, no preamble.", text.Length > 8000 ? text[..8000] : text, 220);
                if (s.Length > 0) return s;
            }
            catch { }
        }
        return ExtractiveSummarizer.Summarize(text);
    }

    public async Task<T?> JsonAsk<T>(string system, string prompt)
    {
        if (await Provider() is not { } p) return default;
        try
        {
            var raw = await p.Complete(system + "\nRespond with JSON only.", prompt, 300);
            var start = raw.IndexOf('{'); var end = raw.LastIndexOf('}');
            return start >= 0 && end > start ? JsonSerializer.Deserialize<T>(raw[start..(end + 1)], Json.Options) : default;
        }
        catch { return default; }
    }
}
