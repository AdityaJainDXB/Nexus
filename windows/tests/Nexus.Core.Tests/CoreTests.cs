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
    readonly string tmp = Path.Combine(Path.GetTempPath(), "nexus-win-tests-" + Guid.NewGuid().ToString("N")[..8]);

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
