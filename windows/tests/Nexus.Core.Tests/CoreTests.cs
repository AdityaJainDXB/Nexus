using System.Text;
using System.IO.Compression;
using System.Text.Json.Nodes;
using Nexus.Core;
using Xunit;

namespace Nexus.Core.Tests;

public class CompilerTests
{
    readonly NLRuleCompiler compiler = new("~/Documents", ["Science Fair"]);

    [Fact]
    public void LabReportRule()
    {
        var rule = compiler.Compile("If a PDF in Downloads contains 'lab report' → move to School/Science/Reports, tag MYP3, add to project Science Fair.").Rule!;
        Assert.Equal(TriggerKind.fileAdded, rule.Trigger.Kind);
        Assert.Equal([Paths.Expand("~/Downloads")], rule.Trigger.Folders);
        Assert.Contains(rule.Conditions.Conditions, c => c.Field == ConditionField.ext && c.Value == "pdf");
        Assert.Contains(rule.Conditions.Conditions, c => c.Field == ConditionField.anyText && c.Value == "lab report");
        Assert.Equal([ActionKind.move, ActionKind.tag, ActionKind.addToProject], rule.Actions.Select(a => a.Kind));
        Assert.Equal(Paths.Expand("~/Documents/School/Science/Reports"), rule.Actions[0].Target);
        Assert.Equal(["MYP3"], rule.Actions[1].Tags);
        Assert.Equal("Science Fair", rule.Actions[2].Project);
    }

    [Fact]
    public void PythonRule()
    {
        var rule = compiler.Compile("If code file language is Python and folder is Downloads → move to Dev/Python, tag snippet.").Rule!;
        Assert.Contains(rule.Conditions.Conditions, c => c.Field == ConditionField.language && c.Value == "Python");
        Assert.Equal(ActionKind.move, rule.Actions[0].Kind);
    }

    [Fact]
    public void GoesToPhrasing()
    {
        var rule = compiler.Compile("Invoices from Downloads go to Finance/Invoices").Rule!;
        Assert.Contains(rule.Conditions.Conditions, c => c.Field == ConditionField.docType && c.Value == "invoice");
        Assert.Equal(Paths.Expand("~/Documents/Finance/Invoices"), rule.Actions[0].Target);
    }

    [Fact]
    public void EventTriggers()
    {
        var drive = compiler.Compile("When drive 'Backup' is connected → sync Projects and School folders").Rule!;
        Assert.Equal(TriggerKind.volumeMounted, drive.Trigger.Kind);
        Assert.Equal("Backup", drive.Trigger.VolumeName);
        Assert.Equal(2, drive.Actions.Count(a => a.Kind == ActionKind.syncFolder));
        Assert.StartsWith("vol:Backup", drive.Actions[0].Target);
        var app = compiler.Compile("When Figma opens → notify me 'design time'").Rule!;
        Assert.Equal(TriggerKind.appLaunched, app.Trigger.Kind);
        Assert.Equal("Figma", app.Trigger.AppName);
        var disk = compiler.Compile("When disk space drops below 20 GB → find duplicates, notify me").Rule!;
        Assert.Equal(TriggerKind.diskSpaceBelow, disk.Trigger.Kind);
        Assert.Equal(20, disk.Trigger.Threshold);
    }

    [Fact]
    public void QuotedAlternatives()
    {
        var rule = compiler.Compile("If a file in Downloads contains 'MYP3' or 'Grade 9' → tag school").Rule!;
        Assert.Equal(MatchMode.all, rule.Conditions.Match);
        Assert.Contains(rule.Conditions.Conditions, c => c.Value == "MYP3|Grade 9");
    }

    [Fact]
    public void ScheduleRule()
    {
        var rule = compiler.Compile("Every Sunday at 9 AM: archive old screenshots, generate storage report").Rule!;
        Assert.Equal(TriggerKind.schedule, rule.Trigger.Kind);
        Assert.Equal("0 9 * * 0", rule.Trigger.Cron);
        Assert.Contains(rule.Actions, a => a.Kind == ActionKind.archiveOld && a.Params["kind"] == "screenshot");
        Assert.Contains(rule.Actions, a => a.Kind == ActionKind.generateReport && a.Params["type"] == "storage");
    }

    [Fact]
    public void TrashRequiresConfirmation()
    {
        var r = compiler.Compile("If an installer in Downloads is older than 7 days → delete it");
        Assert.True(r.Rule!.RequireConfirmation);
        Assert.Contains(r.Rule.Conditions.Conditions, c => c.Field == ConditionField.ageDays && c.Value == "7");
    }

    [Fact]
    public void WindowsPathsCompile()
    {
        var r = compiler.Compile(@"If a PDF in Downloads contains 'tax' → move to C:\Users\me\Documents\Taxes, tag tax");
        Assert.NotNull(r.Rule);
        Assert.Contains("Taxes", r.Rule!.Actions[0].Target);
    }

    [Fact]
    public void AbsolutePathsWithSpaces()
    {
        var folder = Paths.IsWindows ? @"C:\Users\John Smith\Downloads" : "/Users/John Smith/Downloads";
        var rule = compiler.Compile($"If a file in {folder} contains 'hypothesis' → move to School, tag science").Rule!;
        Assert.Equal([Paths.Expand(folder)], rule.Trigger.Folders);
        Assert.Contains(rule.Conditions.Conditions, c => c.Value == "hypothesis");
    }

    [Fact]
    public void ShippedExamplesCompile()
    {
        string[] examples =
        [
            "If a PDF in Downloads contains 'invoice' → move to Finance/Invoices/{year}, tag invoice",
            "When a download finishes and it's an installer → move to Downloads/Installers",
            "If a screenshot lands on the Desktop → move to Pictures/Screenshots/{year}-{month}",
            "When drive 'Backup' is connected → sync Documents",
            "Every day at 6pm: generate daily report",
            "If a file in Downloads is larger than 1 GB → notify me 'big download'",
            "When Downloads has more than 50 files → auto-sort Downloads",
            "If a python script in Downloads → move to Dev/Snippets, tag python",
            "If a file in Downloads contains 'syllabus' → move to School/Syllabi, remind me to add deadlines",
            "If an image in Downloads is tagged wallpaper → move to Pictures/Wallpapers",
            "If a PDF in Downloads named receipt* → rename to {date} {basename}, move to Finance/Receipts",
            "When I open Word → notify me 'Focus: finish the essay'",
        ];
        foreach (var e in examples) Assert.True(compiler.Compile(e).Rule != null, e);
    }
}

public class TimeTests
{
    [Fact]
    public void CronNext()
    {
        var c = CronExpression.Parse("0 9 * * 1")!;
        var next = c.Next(new DateTime(2026, 9, 17, 10, 0, 0))!.Value;   // Thursday
        Assert.Equal(new DateTime(2026, 9, 21, 9, 0, 0), next);
        Assert.Equal("Every Monday at 9:00 AM", CronExpression.Describe("0 9 * * 1"));
        Assert.Equal("Every 15 minutes", CronExpression.Describe("*/15 * * * *"));
    }

    [Fact]
    public void NaturalTime()
    {
        var now = new DateTime(2026, 9, 17, 14, 0, 0);
        Assert.Equal("0 9 * * 0", ((TimeResult.CronAt)NLTime.Parse("every Sunday at 9am", now)!).Cron);
        Assert.Equal(new DateTime(2026, 9, 17, 22, 0, 0), ((TimeResult.Once)NLTime.Parse("tonight", now)!).At);
        Assert.Equal(now.AddMinutes(5), ((TimeResult.Once)NLTime.Parse("in 5 minutes", now)!).At);
        Assert.Equal("30 7 * * 1-5", ((TimeResult.CronAt)NLTime.Parse("every weekday at 7:30 am", now)!).Cron);
        Assert.Equal(new DateTime(2026, 9, 18, 8, 0, 0), ((TimeResult.Once)NLTime.Parse("tomorrow at 8am", now)!).At);
    }
}

public class ParserTests
{
    readonly CommandParser parser = new(new NLRuleCompiler());

    [Fact]
    public void MultiStep()
    {
        var steps = parser.Parse("find invoices from Downloads, then move them to Finance and tag them tax");
        Assert.Equal(3, steps.Count);
        Assert.IsType<Intent.Find>(steps[0].Intent);
        Assert.True(((Intent.FileActions)steps[1].Intent).Query.UseLastResults);
    }

    [Fact]
    public void MoveAndTag()
    {
        var i = (Intent.FileActions)parser.Parse("move all screenshots from Desktop to ~/Pictures/Screenshots")[0].Intent;
        Assert.Contains(i.Query.Conditions, c => c.Field == ConditionField.kind && c.Value == "screenshot");
        Assert.Equal(Paths.Expand("~/Pictures/Screenshots"), i.Actions[0].Target);
    }

    [Fact]
    public void OtherIntents()
    {
        Assert.IsType<Intent.CleanDuplicates>(parser.Parse("clean up duplicates")[0].Intent);
        Assert.IsType<Intent.Briefing>(parser.Parse("brief me")[0].Intent);
        Assert.IsType<Intent.Ask>(parser.Parse("when is the brightsparks invoice due?")[0].Intent);
        Assert.IsType<Intent.Organize>(parser.Parse("organize Downloads")[0].Intent);
        Assert.IsType<Intent.Undo>(parser.Parse("undo")[0].Intent);
        Assert.IsType<Intent.SmartFile>(parser.Parse("file this")[0].Intent);
        Assert.IsType<Intent.CreateRule>(parser.Parse("If a PDF in Downloads contains 'x' → tag x")[0].Intent);
        var sched = (Intent.ScheduleIt)parser.Parse("generate weekly report in 1 minute")[0].Intent;
        Assert.Equal("generate weekly report", sched.Command);
        Assert.IsType<TimeResult.Once>(sched.When);
        var focus = (Intent.Focus)parser.Parse("focus on Science Fair for 90 minutes")[0].Intent;
        Assert.Equal(90, focus.Minutes);
    }
}

public class EngineTests : IDisposable
{
    // Not %TEMP%: on Windows that is inside AppData, which Nexus deliberately refuses to touch
    readonly string tmp = Path.Combine(AppContext.BaseDirectory, "testdata-" + Guid.NewGuid().ToString("N")[..8]);

    public EngineTests()
    {
        Directory.CreateDirectory(tmp);
        Environment.SetEnvironmentVariable("NEXUS_HOME", Path.Combine(tmp, "support"));
        Environment.SetEnvironmentVariable("NEXUS_HOME_ROOT", Path.Combine(tmp, "home"));
        Environment.SetEnvironmentVariable("NEXUS_TRASH_DIR", Path.Combine(tmp, "trash"));
    }

    public void Dispose() { try { Directory.Delete(tmp, true); } catch { } }

    (NexusStore store, NexusEngine engine, string inbox) Setup(bool onboarded = true)
    {
        var inbox = Path.Combine(tmp, "home", "Inbox");
        Directory.CreateDirectory(inbox);
        var store = new NexusStore(Path.Combine(tmp, Guid.NewGuid().ToString("N")[..6] + ".sqlite"));
        var s = new NexusSettings { WatchedFolders = [inbox], LibraryRoots = [Path.Combine(tmp, "home", "Docs")], LlmProvider = LlmProvider.off, OnboardingComplete = onboarded };
        store.SaveSettings(s);
        store.SetKv("seeded", "1");
        return (store, new NexusEngine(store), inbox);
    }

    [Fact]
    public async Task IngestRuleMoveTagAndUndo()
    {
        var (store, engine, inbox) = Setup();
        var file = Path.Combine(inbox, "lab-notes.txt");
        File.WriteAllText(file, "Lab report: hypothesis, procedure, materials and conclusion for the hydroponics experiment.");
        var dest = Path.Combine(tmp, "home", "Docs", "School", "Reports");
        var rule = new NLRuleCompiler(Path.Combine(tmp, "home", "Docs")).Compile($"If a file in {inbox} contains 'hypothesis' → move to {dest}, tag science").Rule!;
        store.SaveRule(rule);

        await engine.Ingest(file, TriggerKind.fileAdded);
        var moved = Path.Combine(dest, "lab-notes.txt");
        Assert.True(File.Exists(moved));
        var rec = store.FileByPath(moved)!;
        Assert.Equal(["science"], rec.Tags);
        Assert.Equal("lab report", rec.DocType);
        Assert.Equal(1, store.Rule(rule.Id)!.HitCount);
        Assert.Equal(rec.Id, store.SearchFiles("hydroponics").FirstOrDefault()?.Id);

        Assert.Equal(2, engine.UndoLast());
        Assert.True(File.Exists(file));
        Assert.Empty(store.File(rec.Id)!.Tags);
    }

    [Fact]
    public async Task NoAutomaticChangesBeforeSetup()
    {
        var (store, engine, inbox) = Setup(onboarded: false);
        var lib = Path.Combine(tmp, "home", "Docs", "Finance");
        Directory.CreateDirectory(lib);
        File.WriteAllText(Path.Combine(lib, "old.txt"), "INVOICE #1 amount due $10 invoice");
        engine.Index(Path.Combine(lib, "old.txt"));
        var dup = Path.Combine(inbox, "old copy.txt");
        File.Copy(Path.Combine(lib, "old.txt"), dup);

        await engine.Ingest(dup, TriggerKind.fileAdded);
        Assert.True(File.Exists(dup));

        var s = engine.Settings; s.OnboardingComplete = true; engine.UpdateSettings(s);
        await engine.Ingest(dup, TriggerKind.fileAdded);
        Assert.False(File.Exists(dup));
        Assert.Single(Directory.GetFiles(Path.Combine(tmp, "trash")));
        Assert.Equal(1, engine.UndoLast());
        Assert.True(File.Exists(dup));
    }

    [Fact]
    public async Task CleanDuplicatesCommandAndProtectedPaths()
    {
        var (store, engine, _) = Setup();
        var lib = Path.Combine(tmp, "home", "Docs", "English");
        Directory.CreateDirectory(lib);
        foreach (var n in new[] { "essay.txt", "essay-2.txt", "essay-3.txt" }) File.WriteAllText(Path.Combine(lib, n), "Macbeth essay about ambition");
        foreach (var f in Directory.GetFiles(lib)) engine.Index(f);
        var r = await engine.Execute(await engine.Plan("clean up duplicates"));
        Assert.Contains("Moved 2 duplicates", r.Message);
        Assert.Single(Directory.GetFiles(lib));
        engine.UndoLast();
        Assert.Equal(3, Directory.GetFiles(lib).Length);

        var rec = store.FileByPath(Path.Combine(lib, "essay.txt"))!;
        var protectedDest = Paths.IsWindows ? Environment.GetFolderPath(Environment.SpecialFolder.Windows) : "/System/Nexus";
        var (_, outc) = await engine.Executor.Run([new RuleAction(ActionKind.move, protectedDest)], rec);
        Assert.False(outc[0].Success);
        Assert.Contains("protected", outc[0].Message);
    }

    [Fact]
    public async Task BatteryRunsJobsSerially()
    {
        var (store, _, _) = Setup();
        var queue = new TaskQueue(store) { IsThrottled = () => true };
        int active = 0, peak = 0;
        queue.Runner = async (_, _) =>
        {
            var a = Interlocked.Increment(ref active); lock (queue) peak = Math.Max(peak, a);
            await Task.Delay(150);
            Interlocked.Decrement(ref active);
            return "ok";
        };
        var jobs = Enumerable.Range(0, 3).Select(i => queue.Enqueue(new Job { Name = $"index {i}", Priority = JobPriority.low, Spec = new JobSpec { Operation = JobOperation.scanInsights } })).ToList();
        queue.Start();
        for (var i = 0; i < 100 && !jobs.All(j => store.Job(j.Id)?.Status == JobStatus.completed); i++) await Task.Delay(100);
        Assert.All(jobs, j => Assert.Equal(JobStatus.completed, store.Job(j.Id)!.Status));
        Assert.Equal(1, peak);
    }

    [Fact]
    public void RecycleBinRoundTrip()
    {
        if (!OperatingSystem.IsWindows()) return;   // real Recycle Bin only exists on Windows
        var dir = Path.Combine(tmp, "bin test"); Directory.CreateDirectory(dir);
        var f = Path.Combine(dir, $"recycle-me-{Guid.NewGuid():N}.txt");
        File.WriteAllText(f, "bye");
        RecycleBin.Send(f);
        Assert.False(File.Exists(f));
        Assert.True(RecycleBin.Restore(f));
        Assert.Equal("bye", File.ReadAllText(f));
    }

    [Fact]
    public void Plurals()
    {
        Assert.Equal("2 copies", Text.Plural(2, "copy"));
        Assert.Equal("1 copy", Text.Plural(1, "copy"));
        Assert.Equal("3 days", Text.Plural(3, "day"));
        Assert.Equal("2 files", Text.Plural(2, "file"));
        Assert.Equal("2 matches", Text.Plural(2, "match"));
    }

    /// Battery and Energy Saver slow background work down; they must never stop it (otherwise search never gets indexed).
    [Theory]
    [InlineData(true, false, false)]   // on AC, normal
    [InlineData(false, false, true)]   // on battery
    [InlineData(true, true, true)]     // Energy Saver on AC
    [InlineData(false, true, true)]
    public void EnergySaverThrottlesButNeverPauses(bool ac, bool saver, bool throttled)
    {
        var snap = new SystemSnapshot { OnAcPower = ac, LowPowerMode = saver };
        Assert.Equal(throttled, snap.ShouldThrottle);
        Assert.False(snap.UnderPressure);
    }

    [Fact]
    public async Task LowPriorityJobsStillRunInEnergySaver()
    {
        var (store, _, _) = Setup();
        var queue = new TaskQueue(store) { IsThrottled = () => true, IsUnderPressure = () => false };
        var ran = 0;
        queue.Runner = (_, _) => { Interlocked.Increment(ref ran); return Task.FromResult("ok"); };
        var job = queue.Enqueue(new Job { Name = "index", Priority = JobPriority.low, Spec = new JobSpec { Operation = JobOperation.scanInsights } });
        queue.Start();
        for (var i = 0; i < 50 && store.Job(job.Id)?.Status != JobStatus.completed; i++) await Task.Delay(100);
        Assert.Equal(JobStatus.completed, store.Job(job.Id)!.Status);
        Assert.Equal(1, ran);
    }

    [Fact]
    public void RunawayGuard()
    {
        var g = new RunawayGuard(3);
        Assert.True(g.Allow()); Assert.True(g.Allow()); Assert.True(g.Allow());
        Assert.False(g.Allow());
    }

    [Fact]
    public void ExtractsOfficeText()
    {
        var docx = Path.Combine(tmp, "report.docx");
        using (var z = ZipFile.Open(docx, ZipArchiveMode.Create))
        using (var w = new StreamWriter(z.CreateEntry("word/document.xml").Open()))
            w.Write("<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>Syllabus for Physics</w:t></w:r></w:p><w:p><w:r><w:t>Office hours: Monday</w:t></w:r></w:p></w:body></w:document>");
        var x = new ContentExtractor().Extract(docx)!;
        Assert.Contains("Syllabus for Physics", x.Text);
        var cls = new Classifier().Classify(docx, x);
        Assert.Equal("syllabus", cls.DocType);
    }

    [Fact]
    public void ClassifiesInvoiceEntities()
    {
        var p = Path.Combine(tmp, "brightsparks.txt");
        File.WriteAllText(p, "INVOICE #3345\nBrightSparks Electronics\nBill to: Aditya\nAmount due: $64.50\nDue date: Dec 12 2026\nPayment terms net 30");
        var x = new ContentExtractor().Extract(p)!;
        var c = new Classifier().Classify(p, x);
        Assert.Equal("invoice", c.DocType);
        Assert.Contains(c.Entities, e => e.Kind == EntityKind.money && e.Value == "$64.50");
        Assert.Contains(c.Entities, e => e.Kind == EntityKind.date && e.Value == "2026-12-12");
        Assert.Contains(c.Entities, e => e.Kind == EntityKind.organization && e.Value.Contains("BrightSparks"));
    }
}

public class UpdaterTests : IDisposable
{
    readonly string tmp = Path.Combine(AppContext.BaseDirectory, "upd-" + Guid.NewGuid().ToString("N")[..8]);
    readonly NexusStore store;

    public UpdaterTests()
    {
        Directory.CreateDirectory(tmp);
        store = new NexusStore(Path.Combine(tmp, "u.sqlite"));
    }
    public void Dispose() { store.Dispose(); try { Directory.Delete(tmp, true); } catch { } }

    Updater Make(string current) => new(store, current) { ApiOverride = Path.Combine(AppContext.BaseDirectory, "fixtures", "release-latest.json") };

    [Theory]
    [InlineData("1.0.1", "1.0.0", 1)]
    [InlineData("1.2.0", "1.10.0", -1)]
    [InlineData("1.2.10", "1.2.9", 1)]
    [InlineData("1.0.0", "1.0.0", 0)]
    [InlineData("v1.1.0", "1.1", 0)]
    [InlineData("1.0.0", "1.0.0-beta", 1)]
    public void ComparesVersions(string a, string b, int expected) => Assert.Equal(expected, Math.Sign(Updater.Compare(a, b)));

    [Fact]
    public async Task OffersNewerReleaseWithTheRightAsset()
    {
        var u = Make("1.0.0");
        var release = await u.Check();
        Assert.NotNull(release);
        Assert.Equal("1.2.0", release!.Version);
        Assert.Equal("Nexus-Setup-1.2.0-x64.exe", release.AssetName);          // the Windows installer, not the .dmg
        Assert.EndsWith("SHA256SUMS-windows.txt", release.ChecksumsUrl);
        Assert.Equal(UpdateStage.Available, u.State.Stage);
        Assert.NotNull(u.LastChecked);
    }

    [Fact]
    public async Task SaysUpToDateOnTheLatestVersion()
    {
        var u = Make("1.2.0");
        Assert.Null(await u.Check());
        Assert.Equal(UpdateStage.UpToDate, u.State.Stage);
    }

    [Fact]
    public async Task SkippedVersionIsNotOfferedAutomaticallyButStillOnDemand()
    {
        var u = Make("1.0.0");
        u.Skip("1.2.0");
        Assert.Null(await u.Check(automatic: true));
        Assert.NotNull(await u.Check());                                        // asking by hand still offers it
        u.Unskip();
        Assert.NotNull(await u.Check(automatic: true, enabled: true));
    }

    [Fact]
    public async Task TurningChecksOffContactsNothing()
    {
        var u = Make("1.0.0");
        u.ApiOverride = Path.Combine(AppContext.BaseDirectory, "does-not-exist.json");
        Assert.Null(await u.Check(automatic: true, enabled: false));
        Assert.Equal(UpdateStage.Idle, u.State.Stage);
        Assert.Null(u.LastChecked);
    }

    [Fact]
    public async Task ReportsAFailedCheckWithoutCrashing()
    {
        var u = Make("1.0.0");
        u.ApiOverride = Path.Combine(AppContext.BaseDirectory, "missing.json");
        Assert.Null(await u.Check());
        Assert.Equal(UpdateStage.Failed, u.State.Stage);
        Assert.Contains("Couldn't check", u.State.Message);
    }
}

public class UpdaterDownloadTests : IDisposable
{
    readonly string tmp = Path.Combine(AppContext.BaseDirectory, "updl-" + Guid.NewGuid().ToString("N")[..8]);
    readonly NexusStore store;
    readonly string? previousHome = Environment.GetEnvironmentVariable("NEXUS_HOME");

    public UpdaterDownloadTests()
    {
        Directory.CreateDirectory(tmp);
        Environment.SetEnvironmentVariable("NEXUS_HOME", Path.Combine(tmp, "support"));
        store = new NexusStore(Path.Combine(tmp, "d.sqlite"));
    }
    public void Dispose() { store.Dispose(); Environment.SetEnvironmentVariable("NEXUS_HOME", previousHome); try { Directory.Delete(tmp, true); } catch { } }

    /// Serves an "installer" and its checksums over real HTTP on a free local port.
    static (MiniHttpServer server, ReleaseInfo release, byte[] payload) Serve(string name, bool honestChecksum)
    {
        var payload = System.Security.Cryptography.RandomNumberGenerator.GetBytes(400_000);
        var sha = honestChecksum ? Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(payload)).ToLowerInvariant() : new string('0', 64);
        var sums = Encoding.UTF8.GetBytes($"{sha}  {name}\n");
        var server = new MiniHttpServer(System.Net.IPAddress.Loopback, 0, async (req, stream) =>
        {
            if (req.Path.EndsWith(name)) await HttpRequest.Reply(stream, 200, payload, "application/octet-stream");
            else if (req.Path.EndsWith("SHA256SUMS-windows.txt")) await HttpRequest.Reply(stream, 200, sums, "text/plain");
            else await HttpRequest.Reply(stream, 404, [], "text/plain");
        });
        Assert.True(server.Start());
        var root = $"http://127.0.0.1:{server.Port}/";
        return (server, new ReleaseInfo("9.9.9", "Nexus 9.9.9", "- test", root, root + name, name, payload.Length, root + "SHA256SUMS-windows.txt", DateTime.UtcNow), payload);
    }

    [Fact]
    public async Task DownloadsAndVerifiesTheInstaller()
    {
        var (server, release, payload) = Serve("Nexus-Setup-9.9.9-x64.exe", honestChecksum: true);
        try
        {
            var updater = new Updater(store, "1.0.0");
            var path = await updater.Download(release);
            Assert.NotNull(path);
            Assert.Equal(UpdateStage.Ready, updater.State.Stage);
            Assert.Equal(payload, File.ReadAllBytes(path!));
        }
        finally { server.Stop(); }
    }

    [Fact]
    public async Task RejectsAndDeletesATamperedInstaller()
    {
        var (server, release, _) = Serve("Nexus-Setup-bad.exe", honestChecksum: false);
        try
        {
            var updater = new Updater(store, "1.0.0");
            Assert.Null(await updater.Download(release));
            Assert.Equal(UpdateStage.Failed, updater.State.Stage);
            Assert.Contains("checksum", updater.State.Message);
            Assert.False(File.Exists(Path.Combine(Paths.AppSupport, "Updates", "Nexus-Setup-bad.exe")));
        }
        finally { server.Stop(); }
    }

    [Fact]
    public async Task ReportsAMissingInstallerWithoutCrashing()
    {
        var updater = new Updater(store, "1.0.0");
        var none = new ReleaseInfo("9.9.9", "x", "", "https://example.invalid", null, null, 0, null, DateTime.UtcNow);
        Assert.Null(await updater.Download(none));
        Assert.Equal(UpdateStage.Failed, updater.State.Stage);
        Assert.Contains("no download", updater.State.Message);
    }
}

public class F1Tests
{
    static F1Service Service() => new() { BaseOverride = Path.Combine(AppContext.BaseDirectory, "fixtures", "f1"), Now = () => new DateTime(2026, 9, 26, 12, 30, 0, DateTimeKind.Utc) };

    [Fact]
    public async Task ReadsLiveTiming()
    {
        var f1 = Service();
        var session = await f1.LatestSession();
        Assert.NotNull(session);
        Assert.Equal("Race", session!.Type);
        Assert.Equal("Baku", session.Circuit);
        Assert.True(session.IsLive(new DateTime(2026, 9, 26, 12, 30, 0, DateTimeKind.Utc)));
        Assert.False(session.IsLive(new DateTime(2026, 9, 27, 12, 30, 0, DateTimeKind.Utc)));

        var live = await f1.Live();
        Assert.NotNull(live);
        Assert.NotEmpty(live!.Rows);
        Assert.Equal(live.Rows.OrderBy(r => r.Position).Select(r => r.Position), live.Rows.Select(r => r.Position));
        var leader = live.Rows[0];
        Assert.Equal("LEADER", leader.Gap);
        Assert.NotEqual("", leader.Driver.Acronym);
        Assert.All(live.Rows, r => Assert.False(string.IsNullOrWhiteSpace(r.Driver.Team)));
        Assert.Contains(live.Rows, r => r.LastLap > 0);
        Assert.Contains(live.Rows, r => r.Compound is "SOFT" or "MEDIUM" or "HARD");
        Assert.NotNull(live.Weather);
        Assert.NotEmpty(live.Messages);

        var text = F1Service.LiveText(live, leader.Driver.Acronym);
        Assert.Contains("Baku", text);
        Assert.Contains("P1 " + leader.Driver.Acronym, text);
    }

    [Fact]
    public void FormatsLapTimes()
    {
        Assert.Equal("1:48.488", F1Row.Format(108.488));
        Assert.Equal("58.900", F1Row.Format(58.9));
    }

    [Fact]
    public async Task ReadsScheduleAndStandings()
    {
        var f1 = Service();
        var next = await f1.NextRace();
        Assert.NotNull(next);
        Assert.Contains("Grand Prix", next!.Name);
        Assert.NotEmpty(next.Sessions);
        Assert.Equal("Race", next.Sessions[^1].name);
        // recorded data ages, so test the countdown against fixed clocks instead of "now"
        Assert.Equal("in 2d 3h", next.CountdownAt(next.StartUtc.AddDays(-2).AddHours(-3).AddMinutes(-10)));
        Assert.Equal("in 5h 30m", next.CountdownAt(next.StartUtc.AddHours(-5).AddMinutes(-30)));
        Assert.Equal("in 12m", next.CountdownAt(next.StartUtc.AddMinutes(-12)));
        Assert.Equal("under way", next.CountdownAt(next.StartUtc.AddMinutes(1)));

        var drivers = await f1.DriverStandings();
        var teams = await f1.ConstructorStandings();
        Assert.NotEmpty(drivers);
        Assert.Equal(1, drivers[0].Position);
        Assert.True(drivers[0].Points >= drivers[1].Points);
        Assert.NotEmpty(teams);
        Assert.Contains(drivers[0].Code, F1Service.StandingsText(drivers, teams));

        var (race, order) = await f1.LastResults();
        Assert.NotEmpty(order);
        Assert.Contains("P1", F1Service.ResultsText(race, order));
    }

    [Theory]
    [InlineData("f1", "auto")]
    [InlineData("f1 live", "auto")]
    [InlineData("f1 live timing", "auto")]
    [InlineData("formula 1 standings", "standings")]
    [InlineData("f1 championship", "standings")]
    [InlineData("next race", "next")]
    [InlineData("when is the next grand prix", "next")]
    [InlineData("f1 results", "results")]
    [InlineData("who won the last f1 race", "results")]
    [InlineData("who is leading the race", "auto")]
    public void ParsesF1Commands(string input, string kind)
    {
        var intent = new CommandParser(new NLRuleCompiler()).Parse(input)[0].Intent;
        var f1 = Assert.IsType<Intent.F1>(intent);
        Assert.Equal(kind, f1.Kind);
    }

    [Fact]
    public void LeavesOtherCommandsAlone()
    {
        var parser = new CommandParser(new NLRuleCompiler());
        Assert.IsNotType<Intent.F1>(parser.Parse("organize Downloads")[0].Intent);
        Assert.IsNotType<Intent.F1>(parser.Parse("find my f1 telemetry notes")[0].Intent);
        Assert.IsNotType<Intent.F1>(parser.Parse("when is the brightsparks invoice due?")[0].Intent);
    }
}

public class RemoteCryptoTests
{
    [Fact]
    public void SealOpenRoundTripAndTamper()
    {
        var key = RemoteCrypto.PairingKey("123456", new byte[16]);
        Assert.Equal(32, key.Length);
        var sealedData = RemoteCrypto.Seal(new JsonObject { ["hello"] = "world" }, key);
        Assert.Equal("world", RemoteCrypto.Open(sealedData, key)["hello"]!.GetValue<string>());
        var raw = Convert.FromBase64String(System.Text.Encoding.ASCII.GetString(sealedData)); raw[14] ^= 1;
        Assert.ThrowsAny<Exception>(() => RemoteCrypto.Open(System.Text.Encoding.ASCII.GetBytes(Convert.ToBase64String(raw)), key));
        Assert.ThrowsAny<Exception>(() => RemoteCrypto.Open(sealedData, RemoteCrypto.PairingKey("654321", new byte[16])));
    }

    /// HKDF-SHA256 vector computed with Apple CryptoKit (Nexus for Mac / iOS) for the same inputs.
    [Fact]
    public void HkdfMatchesCryptoKit()
    {
        var key = RemoteCrypto.PairingKey("123456", Enumerable.Range(0, 16).Select(i => (byte)i).ToArray());
        Assert.Equal(Environment.GetEnvironmentVariable("NEXUS_HKDF_VECTOR") ?? HkdfVector, Convert.ToHexString(key).ToLowerInvariant());
    }

    const string HkdfVector = "29305f2f209f4e09ae6254cef78400fcb8017de83f02b45d91024f730d600c13";
}
