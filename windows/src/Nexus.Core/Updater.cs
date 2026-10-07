using System.Diagnostics;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;

namespace Nexus.Core;

public record ReleaseInfo(string Version, string Name, string Notes, string Url, string? AssetUrl, string? AssetName, long AssetSize, string? ChecksumsUrl, DateTime PublishedAt)
{
    public string SizeText => AssetSize > 0 ? Text.FormatBytes(AssetSize) : "";
}

public enum UpdateStage { Idle, Checking, Available, Downloading, Verifying, Ready, Installing, UpToDate, Failed }

public record UpdateState(UpdateStage Stage, ReleaseInfo? Release = null, double Progress = 0, string? Message = null, string? InstallerPath = null);

/// Checks GitHub Releases for a newer Nexus, downloads it with a checksum check, and runs the installer.
/// Entirely opt-out: when AutomaticUpdateChecks is off nothing is contacted, and any version can be skipped.
public class Updater
{
    public const string DefaultRepo = "AdityaJainDXB/Nexus";

    readonly NexusStore store;
    readonly HttpClient http;
    public string Repo { get; set; } = DefaultRepo;
    public string CurrentVersion { get; set; }
    /// Asset picker for this platform — Windows installer by default.
    public Func<IEnumerable<(string name, string url, long size)>, (string name, string url, long size)?> PickAsset { get; set; }
    public Func<DateTime> Now { get; set; } = () => DateTime.UtcNow;
    public Action<UpdateState>? OnState;
    public UpdateState State { get; private set; } = new(UpdateStage.Idle);
    public string? ApiOverride { get; set; }      // tests point this at a local file

    public Updater(NexusStore store, string? currentVersion = null, HttpClient? client = null)
    {
        this.store = store;
        CurrentVersion = currentVersion ?? System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "1.0.0";
        http = client ?? new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        http.DefaultRequestHeaders.UserAgent.TryParseAdd("Nexus-Updater/1.0");
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        PickAsset = assets => assets.FirstOrDefault(a => a.name.StartsWith("Nexus-Setup", StringComparison.OrdinalIgnoreCase) && a.name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) is { name: not null } hit ? hit : null;
    }

    public DateTime? LastChecked => double.TryParse(store.Kv("update.lastCheck"), CultureInfo.InvariantCulture, out var t) ? Time.FromEpoch(t) : null;
    public string? SkippedVersion => store.Kv("update.skipped");
    public void Skip(string version) { store.SetKv("update.skipped", version); Set(new UpdateState(UpdateStage.Idle, Message: $"Skipping {version}")); }
    public void Unskip() => store.SetKv("update.skipped", null);

    void Set(UpdateState s) { State = s; OnState?.Invoke(s); }

    /// Newest release, or null when up to date / skipped / checks are off.
    public async Task<ReleaseInfo?> Check(bool automatic = false, bool enabled = true)
    {
        if (automatic && !enabled) return null;
        if (automatic && LastChecked is { } last && Now() - last < TimeSpan.FromHours(6)) return State.Release;
        Set(new UpdateState(UpdateStage.Checking, State.Release));
        try
        {
            JsonNode? node;
            if (ApiOverride is { Length: > 0 } file) node = JsonNode.Parse(await File.ReadAllTextAsync(file));
            else
            {
                using var r = await http.GetAsync($"https://api.github.com/repos/{Repo}/releases/latest", HttpCompletionOption.ResponseHeadersRead);
                if (!r.IsSuccessStatusCode) throw new HttpRequestException($"GitHub returned {(int)r.StatusCode}");
                node = JsonNode.Parse(await r.Content.ReadAsStringAsync());
            }
            store.SetKv("update.lastCheck", Time.Epoch(Now()).ToString(CultureInfo.InvariantCulture));
            if (node == null) throw new InvalidOperationException("empty response");

            var tag = node["tag_name"]?.GetValue<string>() ?? "";
            var version = tag.TrimStart('v', 'V');
            var assets = (node["assets"]?.AsArray() ?? [])
                .Select(a => (name: a?["name"]?.GetValue<string>() ?? "", url: a?["browser_download_url"]?.GetValue<string>() ?? "", size: (long)(a?["size"]?.GetValue<double>() ?? 0)))
                .Where(a => a.name.Length > 0).ToList();
            var pick = PickAsset(assets);
            var checksums = assets.FirstOrDefault(a => a.name.StartsWith("SHA256SUMS", StringComparison.OrdinalIgnoreCase) && (pick == null || a.name.Contains("windows", StringComparison.OrdinalIgnoreCase) == pick.Value.name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)));
            var release = new ReleaseInfo(version, node["name"]?.GetValue<string>() ?? tag, node["body"]?.GetValue<string>() ?? "",
                node["html_url"]?.GetValue<string>() ?? $"https://github.com/{Repo}/releases/latest",
                pick?.url, pick?.name, pick?.size ?? 0, checksums.url is { Length: > 0 } ? checksums.url : null,
                DateTime.TryParse(node["published_at"]?.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var p) ? p : Now());

            if (Compare(release.Version, CurrentVersion) <= 0) { Set(new UpdateState(UpdateStage.UpToDate, null, 0, $"Nexus {CurrentVersion} is the latest version")); return null; }
            if (automatic && SkippedVersion == release.Version) { Set(new UpdateState(UpdateStage.Idle)); return null; }
            Set(new UpdateState(UpdateStage.Available, release));
            return release;
        }
        catch (Exception ex)
        {
            Set(new UpdateState(UpdateStage.Failed, State.Release, 0, "Couldn't check for updates: " + ex.Message));
            return null;
        }
    }

    /// Downloads the asset, verifies its SHA-256 when the release publishes checksums, and returns the file.
    public async Task<string?> Download(ReleaseInfo release, CancellationToken ct = default)
    {
        if (release.AssetUrl is not { Length: > 0 } url || release.AssetName is not { Length: > 0 } name)
        { Set(new UpdateState(UpdateStage.Failed, release, 0, "This release has no download for your platform")); return null; }
        try
        {
            var dir = Path.Combine(Paths.AppSupport, "Updates");
            Directory.CreateDirectory(dir);
            foreach (var old in Directory.EnumerateFiles(dir).Where(f => !f.EndsWith(name))) { try { File.Delete(old); } catch { } }
            var dest = Path.Combine(dir, name);

            if (!File.Exists(dest) || new FileInfo(dest).Length != release.AssetSize)
            {
                Set(new UpdateState(UpdateStage.Downloading, release, 0));
                using var r = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
                r.EnsureSuccessStatusCode();
                var total = r.Content.Headers.ContentLength ?? release.AssetSize;
                await using var body = await r.Content.ReadAsStreamAsync(ct);
                await using (var file = File.Create(dest))
                {
                    var buffer = new byte[1 << 20];
                    long done = 0;
                    int n;
                    var lastReport = Now();
                    while ((n = await body.ReadAsync(buffer, ct)) > 0)
                    {
                        await file.WriteAsync(buffer.AsMemory(0, n), ct);
                        done += n;
                        if (Now() - lastReport > TimeSpan.FromMilliseconds(250))
                        {
                            lastReport = Now();
                            Set(new UpdateState(UpdateStage.Downloading, release, total > 0 ? (double)done / total : 0, $"{Text.FormatBytes(done)} of {Text.FormatBytes(total)}"));
                        }
                    }
                }
            }

            if (release.ChecksumsUrl is { Length: > 0 } sums)
            {
                Set(new UpdateState(UpdateStage.Verifying, release, 1));
                try
                {
                    var text = await http.GetStringAsync(sums, ct);
                    var expected = text.Split('\n').Select(l => l.Trim().Split("  ")).FirstOrDefault(p => p.Length == 2 && p[1].Trim() == name)?[0];
                    if (expected is { Length: 64 })
                    {
                        var actual = Text.Sha256File(dest);
                        if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
                        {
                            try { File.Delete(dest); } catch { }
                            Set(new UpdateState(UpdateStage.Failed, release, 0, "The download didn't match its checksum — update cancelled"));
                            return null;
                        }
                    }
                }
                catch (HttpRequestException) { /* no checksums published — continue */ }
            }
            Set(new UpdateState(UpdateStage.Ready, release, 1, "Ready to install", dest));
            return dest;
        }
        catch (OperationCanceledException) { Set(new UpdateState(UpdateStage.Idle, release)); return null; }
        catch (Exception ex) { Set(new UpdateState(UpdateStage.Failed, release, 0, "Download failed: " + ex.Message)); return null; }
    }

    /// Runs the downloaded installer and asks the caller to quit. Windows: silent install, then Nexus restarts itself.
    public bool Install(string installerPath, bool silent = true)
    {
        try
        {
            Set(new UpdateState(UpdateStage.Installing, State.Release, 1, "Installing…", installerPath));
            if (!Paths.IsWindows) { Platform.Current.Open(installerPath); return true; }
            var args = silent
                ? "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
                : "/CLOSEAPPLICATIONS /RESTARTAPPLICATIONS";
            Process.Start(new ProcessStartInfo(installerPath, args) { UseShellExecute = true });
            return true;
        }
        catch (Exception ex)
        {
            Set(new UpdateState(UpdateStage.Failed, State.Release, 0, "Couldn't start the installer: " + ex.Message, installerPath));
            return false;
        }
    }

    /// Semantic-ish compare: 1.2.10 > 1.2.9 > 1.2 > 1.2.0-beta.
    public static int Compare(string a, string b)
    {
        static (int[] nums, string pre) Parse(string v)
        {
            v = v.Trim().TrimStart('v', 'V');
            var dash = v.IndexOfAny(['-', '+']);
            var pre = dash >= 0 ? v[(dash + 1)..] : "";
            var core = dash >= 0 ? v[..dash] : v;
            var nums = core.Split('.').Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0).ToArray();
            return (nums, pre);
        }
        var (an, ap) = Parse(a);
        var (bn, bp) = Parse(b);
        for (var i = 0; i < Math.Max(an.Length, bn.Length); i++)
        {
            var x = i < an.Length ? an[i] : 0;
            var y = i < bn.Length ? bn[i] : 0;
            if (x != y) return x.CompareTo(y);
        }
        if (ap == bp) return 0;
        if (ap.Length == 0) return 1;      // 1.0.0 beats 1.0.0-beta
        if (bp.Length == 0) return -1;
        return string.CompareOrdinal(ap, bp);
    }
}
