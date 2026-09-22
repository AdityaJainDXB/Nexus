using System.Collections.Concurrent;
using System.Numerics;

namespace Nexus.Core;

public record Suggestion(string Folder, double Score, string Reason);
public record CleanupGroup(FileRecord Keep, List<FileRecord> Trash);

public class PlannedStep
{
    public required CommandStep Step { get; init; }
    public List<FileRecord> Files { get; set; } = [];
    public List<string> Preview { get; set; } = [];
    public string? Note { get; set; }
    public RuleCompileResult? RuleResult { get; set; }
}

public class CommandPlan
{
    public string Input { get; init; } = "";
    public List<PlannedStep> Steps { get; init; } = [];
    public bool Understood { get; init; }
    public bool RequiresConfirmation { get; init; }
    public bool UsedLlm { get; init; }
}

public class CommandResult
{
    public string Message { get; set; } = "";
    public List<string> Details { get; set; } = [];
    public List<FileRecord> Files { get; set; } = [];
    public string? Navigate { get; set; }
    public string BatchId { get; set; } = "";
    public Rule? CreatedRule { get; set; }
}

/// The agent: watches folders, understands files, runs rules and autopilot, executes commands.
public class NexusEngine : IActionHost
{
    public NexusStore Store { get; }
    public NexusSettings Settings { get; private set; }
    public ContentExtractor Extractor { get; } = new();
    public Classifier Classifier { get; } = new();
    public TaxonomyLearner Taxonomy { get; }
    public ProjectMatcher ProjectMatcher { get; } = new();
    public Embedder Embedder { get; } = new();
    public RuleEngine RuleEngine { get; } = new();
    public ActionExecutor Executor { get; }
    public TaskQueue Queue { get; }
    public Scheduler Scheduler { get; }
    public SystemMonitor Monitor { get; } = new();
    public InsightsEngine Insights { get; }
    public ReportGenerator Reports { get; }
    public LlmRouter Llm { get; } = new();
    public FileWatcher Watcher { get; } = new();
    public FileStabilizer Stabilizer { get; } = new();

    public event Action<string>? StoreChanged;
    public event Action<EngineStatus>? StatusChanged;
    public Action<string, string, bool>? Notifier { get; set; }
    public Func<IReadOnlyList<string>>? ContextSelection { get; set; }

    public bool Paused { get; private set; }
    public FocusSession? Focus { get; private set; }
    public EngineStatus Status { get; private set; } = EngineStatus.idle;

    readonly SemaphoreSlim ingestGate = new(2, 2);
    int ingesting;
    readonly ConcurrentDictionary<string, (string path, long size, DateTime at, FileRecord? rec)> recentRemovals = new(StringComparer.OrdinalIgnoreCase);
    readonly ConcurrentDictionary<string, DateTime> lastEventRuleFire = new();
    readonly List<(FileRecord, Project, double)> pendingProjectLinks = [];
    Dictionary<string, float[]> projectVectors = [];
    List<string> lastCommandResults = [];
    (int filed, int review) digest;
    readonly object stateLock = new();

    public NexusEngine(NexusStore store)
    {
        Store = store;
        Settings = store.LoadSettings();
        Taxonomy = new TaxonomyLearner(store);
        Executor = new ActionExecutor(store, new RunawayGuard(Settings.MaxOpsPerMinute)) { Host = this };
        Queue = new TaskQueue(store);
        Scheduler = new Scheduler(store, Queue);
        Insights = new InsightsEngine(store, RuleEngine);
        Reports = new ReportGenerator(store);
        Focus = Json.Parse<FocusSession>(store.Kv("focus"));
        Paused = store.Kv("paused") == "1";
        ApplySettings();
        store.OnChange = e => StoreChanged?.Invoke(e);
    }

    bool SetupComplete => Settings.OnboardingComplete;

    // MARK: Lifecycle

    public void Start()
    {
        SeedIfNeeded();
        Watcher.OnChange = HandleFileChanges;
        Watcher.OnOverflow = root => Task.Run(() => CatchUp(root, DateTime.Now.AddMinutes(-10)));
        Stabilizer.OnStable = path => EnqueueIngest(path, TriggerFor(path));
        RestartWatcher();

        Queue.Runner = RunJob;
        Queue.IsPaused = () => Paused;
        Queue.IsThrottled = () => Settings.BatteryAware && Monitor.Snapshot.ShouldThrottle;
        Queue.IsUnderPressure = () => Settings.BatteryAware && Monitor.Snapshot.UnderPressure;
        Queue.OnActivityChange = RefreshStatus;
        Queue.Start();

        Scheduler.Snapshot = () => Monitor.Snapshot;
        Scheduler.Maintenance.AddRange([
            ("insights", TimeSpan.FromHours(3), () => EnqueueOnce(JobOperation.scanInsights, "Scan for insights", JobKind.ai, JobPriority.low)),
            ("snapshots", TimeSpan.FromHours(24), TakeSnapshots),
            ("taxonomy", TimeSpan.FromHours(24), () => EnqueueOnce(JobOperation.learnTaxonomy, "Learn folder structure", JobKind.ai, JobPriority.low)),
            ("libraryIndex", TimeSpan.FromHours(24), () =>
            {
                foreach (var root in Settings.LibraryRootsExpanded.Concat(Settings.WatchedFoldersExpanded).Distinct(Paths.Comparer))
                    EnqueueOnce(JobOperation.classifyFolder, $"Index {Paths.Abbreviate(root)}", JobKind.ai, JobPriority.low, new JobSpec { Operation = JobOperation.classifyFolder, Path = root });
            }),
            ("ageSweep", TimeSpan.FromHours(1), SweepAgeRules),
            ("focus", TimeSpan.FromMinutes(2), CheckFocus),
            ("prune", TimeSpan.FromHours(24), Store.PruneJobs),
            ("digest", TimeSpan.FromMinutes(1), () => { FlushDigest(); MarkAlive(); }),
            ("projectLinks", TimeSpan.FromMinutes(10), FlushProjectLinks),
        ]);
        Scheduler.Start();
        Monitor.OnEvent = (kind, info) => FireEventRules(kind, info);
        Monitor.Start();
        LocalModelServer.Shared.CleanupStale();
        RebuildProjectVectors();
        Store.Log(new ActivityEvent { Kind = EventKind.system, Message = $"Nexus started · watching {Watcher.WatchedPaths.Count} folders" });
        CatchUpWhileClosed();
    }

    public void Stop()
    {
        Watcher.Stop(); Monitor.Stop(); Scheduler.Stop(); Queue.Stop();
        LocalModelServer.Shared.Stop();
        MarkAlive();
    }

    void MarkAlive() => Store.SetKv("lastAlive", Time.Epoch(DateTime.Now).ToString(System.Globalization.CultureInfo.InvariantCulture));

    /// Files that landed in watched folders while Nexus wasn't running are processed on launch.
    void CatchUpWhileClosed()
    {
        var last = double.TryParse(Store.Kv("lastAlive"), System.Globalization.CultureInfo.InvariantCulture, out var l) ? Time.FromEpoch(l) : (DateTime?)null;
        MarkAlive();
        if (last == null) return;   // first launch: existing files are organized only when the user asks
        Task.Run(async () =>
        {
            await Task.Delay(2000);
            foreach (var folder in Settings.WatchedFoldersExpanded) CatchUp(folder, last.Value.AddMinutes(-2));
        });
    }

    void CatchUp(string folder, DateTime since)
    {
        foreach (var path in ListFiles(folder, false))
        {
            if (Store.FileByPath(path) != null) continue;
            try
            {
                var fi = new FileInfo(path);
                var changed = fi.CreationTime > fi.LastWriteTime ? fi.CreationTime : fi.LastWriteTime;
                if (changed > since) EnqueueIngest(path, TriggerFor(path));
            }
            catch { }
        }
    }

    public void UpdateSettings(NexusSettings s)
    {
        var foldersChanged = !s.WatchedFolders.SequenceEqual(Settings.WatchedFolders) || !s.LibraryRoots.SequenceEqual(Settings.LibraryRoots);
        Settings = s;
        Store.SaveSettings(s);
        ApplySettings();
        if (foldersChanged) RestartWatcher();
    }

    void ApplySettings()
    {
        Extractor.EnableOcr = Settings.EnableOcr;
        Extractor.MaxChars = Settings.MaxExtractKB * 1024;
        Llm.Settings = Settings;
        Llm.Invalidate();
        Executor.Guardrail.LimitPerMinute = Settings.MaxOpsPerMinute;
    }

    public void RestartWatcher()
    {
        var paths = Settings.WatchedFoldersExpanded.Concat(Settings.LibraryRootsExpanded).Append(Path.Combine(Paths.AppSupport, "Inbox")).ToList();
        foreach (var r in Store.Rules().Where(r => r.Enabled && r.Trigger.Kind.IsFileTrigger())) paths.AddRange(r.Trigger.Folders.Select(Paths.Expand));
        if (Settings.ObsidianVault.Length > 0) paths.Add(Paths.Expand(Settings.ObsidianVault));
        Directory.CreateDirectory(Path.Combine(Paths.AppSupport, "Inbox", "Mail"));
        var unique = paths.Select(Paths.Canonical).Distinct(Paths.Comparer).ToList();
        var roots = unique.Where(p => !unique.Any(o => !Paths.Same(o, p) && Paths.IsInside(p, o))).Where(Directory.Exists).ToList();
        if (roots.OrderBy(x => x).SequenceEqual(Watcher.WatchedPaths.OrderBy(x => x), Paths.Comparer)) return;
        Watcher.Start(roots);
    }

    public void SetPaused(bool p)
    {
        Paused = p;
        Store.SetKv("paused", p ? "1" : "0");
        Store.Log(new ActivityEvent { Kind = EventKind.system, Message = p ? "Automations paused" : "Automations resumed" });
        RefreshStatus();
        if (!p) Queue.Tick();
    }

    public void Pause(string reason) { SetPaused(true); Notify("Nexus paused automations", reason, true); }

    public void RefreshStatus()
    {
        var busy = Volatile.Read(ref ingesting) > 0 || Queue.RunningCount > 0;
        var s = Paused ? EngineStatus.paused : busy ? EngineStatus.working : Store.ReviewCount() > 0 ? EngineStatus.attention : EngineStatus.idle;
        if (s != Status) { Status = s; StatusChanged?.Invoke(s); }
    }

    // MARK: Seeding

    void SeedIfNeeded()
    {
        if (Store.Kv("seeded") != null) return;
        if (Store.Kv("settings") == null)
        {
            var found = FolderDiscovery.Candidates().Where(c => c.Recommended).Select(c => Paths.Abbreviate(c.Path)).ToList();
            if (found.Count > 0) { Settings.LibraryRoots = found; Store.SaveSettings(Settings); }
        }
        var root = Settings.LibraryRoots.FirstOrDefault(r => r.EndsWith("Documents")) ?? Settings.LibraryRoots.FirstOrDefault() ?? "~/Documents";
        var roots = Settings.LibraryRootsExpanded;
        string Dest(string s) => s.StartsWith('~') ? s : root.TrimEnd('/') + "/" + s;
        (string name, string dest, string[] types, string[] keys)[] defaults =
        [
            ("Invoices", "Finance/Invoices/{year}", ["invoice"], ["invoice", "amount due"]), ("Receipts", "Finance/Receipts/{year}", ["receipt"], ["receipt", "order total"]),
            ("Bank statements", "Finance/Statements", ["bank statement"], []), ("Tax documents", "Finance/Taxes/{year}", ["tax document"], ["1099", "w-2"]),
            ("Lab reports", "School/Lab Reports", ["lab report"], ["hypothesis", "lab report"]), ("Syllabi", "School/Syllabi", ["syllabus"], ["syllabus"]),
            ("Assignments", "School/Assignments", ["assignment"], ["rubric", "worksheet"]), ("Essays", "School/Essays", ["essay"], []),
            ("Resumes", "Career", ["resume"], []), ("Contracts", "Legal", ["contract"], ["agreement"]), ("Research papers", "Library/Papers", ["research paper"], ["arxiv", "doi"]),
            ("Manuals", "Library/Manuals", ["manual"], []), ("Tickets", "Travel", ["ticket"], ["boarding pass"]), ("Meeting notes", "Notes/Meetings", ["meeting notes"], []),
            ("Specs", "Dev/Specs", ["spec"], []), ("Code snippets", "Dev/Snippets/{language}", ["code"], []), ("3D models", "3D Printing/Models", ["3d model"], []),
            ("Screenshots", "~/Pictures/Screenshots/{year}-{month}", ["screenshot"], []), ("Installers", "~/Downloads/Installers", ["installer"], []),
        ];
        foreach (var (name, d, types, keys) in defaults)
        {
            var existing = FolderDiscovery.ExistingFolder(name, roots);
            Store.SaveCategory(new Category { Name = name, Destination = existing != null ? Paths.Abbreviate(existing) : Dest(d), Keywords = [.. keys], DocTypes = [.. types], Learned = existing != null });
        }
        Store.SaveSchedule(new Schedule
        {
            Name = "Weekly report", Mode = ScheduleMode.recurring, Cron = $"0 {Settings.DigestHour} * * {Settings.DigestWeekday - 1}", JobKind = JobKind.ai,
            Job = new JobSpec { Operation = JobOperation.generateReport, Params = new() { ["type"] = "weekly" } }, Priority = JobPriority.low, NaturalLanguage = "Every Sunday at 9 AM generate weekly report",
        });
        Store.SaveSchedule(new Schedule
        {
            Name = "Evening Downloads tidy", Mode = ScheduleMode.conditional, Enabled = false, CooldownMinutes = 720,
            Conditions = [new SystemCondition(SystemConditionKind.folderCountAbove, "~/Downloads", 50), new SystemCondition(SystemConditionKind.hourAtLeast, null, 20)],
            Job = new JobSpec { Operation = JobOperation.sortFolder, Path = "~/Downloads" }, NaturalLanguage = "When Downloads has > 50 files and it's after 8 PM → auto-sort",
        });
        Store.SetKv("seeded", "1");
    }

    // MARK: File events

    public TriggerKind TriggerFor(string path)
    {
        if (Paths.IsInside(path, Path.Combine(Paths.AppSupport, "Inbox", "Mail"))) return TriggerKind.connectorEvent;
        if (Paths.IsInside(path, Paths.Expand("~/Downloads"))) return TriggerKind.downloadCompleted;
        return TriggerKind.fileAdded;
    }

    public bool ShouldProcess(string path)
    {
        var name = Path.GetFileName(path);
        if (name.StartsWith('.') || name.StartsWith("~$")) return false;
        if (Settings.IgnoredPatterns.Any(p => name.Glob(p))) return false;
        var parts = path.Split(Paths.Sep);
        if (parts.Any(p => p is ".git" or "node_modules" or "$RECYCLE.BIN" or ".Trash")) return false;
        if (Paths.IsInside(path, Paths.AppSupport) && !Paths.IsInside(path, Path.Combine(Paths.AppSupport, "Inbox"))) return false;
        return true;
    }

    bool IsAutomationFolder(string path) => Settings.WatchedFoldersExpanded.Any(f => Paths.IsInside(path, f, recursive: false));

    void HandleFileChanges(List<FileChange> changes)
    {
        foreach (var (k, v) in recentRemovals) if ((DateTime.Now - v.at).TotalSeconds > 20) recentRemovals.TryRemove(k, out _);
        foreach (var c in changes.Where(c => ShouldProcess(c.Path)))
        {
            switch (c.Kind)
            {
                case ChangeKind.removed:
                    {
                        var rec = Store.FileByPath(c.Path);
                        recentRemovals[Path.GetFileName(c.Path)] = (c.Path, rec?.Size ?? -1, DateTime.Now, rec);
                        _ = Task.Delay(5000).ContinueWith(_ => { if (!File.Exists(c.Path) && Store.FileByPath(c.Path) != null) Store.MarkMissing(c.Path); });
                        break;
                    }
                case ChangeKind.renamed when c.OldPath != null && !c.IsDirectory:
                    if (Store.FileByPath(c.OldPath) is { } renamed)
                    {
                        HandleUserMove(c.OldPath, c.Path, renamed);
                        if (IsAutomationFolder(c.Path) && !IsAutomationFolder(c.OldPath)) Stabilizer.Submit(c.Path);
                    }
                    else Stabilizer.Submit(c.Path);   // e.g. browser renames .crdownload → final name
                    break;
                case ChangeKind.created or ChangeKind.renamed:
                    {
                        if (c.IsDirectory) break;
                        if (recentRemovals.TryRemove(Path.GetFileName(c.Path), out var moved) && !Paths.Same(moved.path, c.Path)
                            && (moved.size < 0 || SafeSize(c.Path) == moved.size))
                        {
                            HandleUserMove(moved.path, c.Path, moved.rec);
                            if (IsAutomationFolder(c.Path) && !IsAutomationFolder(moved.path)) Stabilizer.Submit(c.Path);
                            break;
                        }
                        Stabilizer.Submit(c.Path);
                        break;
                    }
                case ChangeKind.modified:
                    {
                        if (c.IsDirectory || !File.Exists(c.Path)) break;
                        if (Store.FileByPath(c.Path) is { } rec && Math.Abs((File.GetLastWriteTime(c.Path) - rec.ModifiedAt).TotalSeconds) < 1) break;
                        if (Store.FileByPath(c.Path) == null) { Stabilizer.Submit(c.Path); break; }
                        if (Store.Rules().Any(r => r.Enabled && r.Trigger.Kind == TriggerKind.fileModified)) EnqueueIngest(c.Path, TriggerKind.fileModified);
                        break;
                    }
            }
        }
    }

    static long SafeSize(string p) { try { return new FileInfo(p).Length; } catch { return -2; } }

    /// The user moved a file by hand: keep the index in sync and learn from it.
    void HandleUserMove(string from, string to, FileRecord? record)
    {
        var fromFolder = Paths.FolderOf(from); var toFolder = Paths.FolderOf(to);
        if ((record ?? Store.FileByPath(from)) is { } rec)
        {
            rec.Path = to; Store.UpsertFile(rec);
            if (!Paths.Same(fromFolder, toFolder))
            {
                var keywords = Classifier.Tokens(Path.GetFileNameWithoutExtension(rec.Name)).Concat(rec.Topics.Select(t => t.ToLowerInvariant())).Distinct().Take(12).ToList();
                Store.RecordObservedMove(new ObservedMove(fromFolder, toFolder, rec.Ext, keywords, DateTime.Now));
                Taxonomy.Reinforce(toFolder, rec.DocType, keywords);
                if (Store.PendingReview(rec.Id) is { } item)
                {
                    item.Status = item.SuggestedDestination != null && Paths.Same(Paths.Expand(item.SuggestedDestination), toFolder) ? ReviewStatus.approved : ReviewStatus.rejected;
                    item.ResolvedAt = DateTime.Now; Store.SaveReview(item);
                }
            }
        }
        else if (!Paths.Same(fromFolder, toFolder))
            Store.RecordObservedMove(new ObservedMove(fromFolder, toFolder, Path.GetExtension(to).TrimStart('.').ToLowerInvariant(), Classifier.Tokens(Path.GetFileNameWithoutExtension(to)), DateTime.Now));
    }

    public void EnqueueIngest(string path, TriggerKind trigger, Dictionary<string, string>? info = null)
    {
        Interlocked.Increment(ref ingesting);
        RefreshStatus();
        Task.Run(async () =>
        {
            await ingestGate.WaitAsync();
            try { await Ingest(path, trigger, info ?? []); }
            catch (Exception ex) { Store.Log(new ActivityEvent { Kind = EventKind.error, Message = $"Couldn't process {Path.GetFileName(path)}: {ex.Message}" }); }
            finally { ingestGate.Release(); Interlocked.Decrement(ref ingesting); RefreshStatus(); }
        });
    }

    // MARK: Ingest pipeline

    public async Task Ingest(string rawPath, TriggerKind trigger, Dictionary<string, string>? infoIn = null)
    {
        var path = Paths.Canonical(rawPath);
        if (!ShouldProcess(path) || !File.Exists(path)) return;
        if (Index(path) is not var (rec, content)) return;
        var info = infoIn ?? [];
        if (trigger == TriggerKind.connectorEvent) { info["connectorEvent"] = "mail.attachment"; info["source"] = "Mail"; }
        if (Paused) return;

        // A new download whose exact content is already filed elsewhere is just clutter: Recycle Bin (undoable)
        if (Settings.AutoRemoveDuplicates && SetupComplete && IsAutomationFolder(path) && rec.ContentHash != null && rec.Size > 0
            && Store.FilesWithHash(rec.ContentHash).FirstOrDefault(f => f.Id != rec.Id && !IsAutomationFolder(f.Path) && File.Exists(f.Path)) is { } original)
        {
            var batch = Ids.New();
            var (_, outc) = await Executor.Run([new RuleAction(ActionKind.trash)], rec, batchId: batch, dryRun: Settings.DryRun);
            if (outc.FirstOrDefault()?.Success == true)
            {
                Store.Log(new ActivityEvent { Kind = EventKind.fileTrashed, Message = $"Removed duplicate {rec.Name} — already filed at {Paths.Abbreviate(original.Path)}", FileId = rec.Id, BatchId = batch });
                lock (stateLock) digest.filed++;
                return;
            }
        }
        var fired = await RunRules(rec, content, trigger, info);
        if (fired > 0 || !(IsAutomationFolder(path) || trigger == TriggerKind.connectorEvent)) return;
        var current = Store.File(rec.Id) ?? rec;
        if (await RouteForFocus(current)) return;
        if (Settings.AutopilotEnabled) await Autopilot(current, content);
    }

    /// Extract → classify → match project → persist (FTS, embeddings, knowledge graph). No side effects on disk.
    public (FileRecord rec, string content)? Index(string rawPath)
    {
        var path = Paths.Canonical(rawPath);
        if (Extractor.Extract(path) is not { } x || x.Kind == FileKind.folder) return null;
        var prev = Store.FileByPath(path);
        var cls = Classifier.Classify(path, x, ProjectTerms().Concat(Taxonomy.KnownTerms));
        var rec = prev ?? new FileRecord { Path = path };
        rec.Path = path; rec.Kind = x.Kind; rec.Size = x.Size; rec.CreatedAt = x.CreatedAt; rec.ModifiedAt = x.ModifiedAt;
        rec.IndexedAt = prev?.IndexedAt ?? DateTime.Now; rec.ContentHash = x.ContentHash; rec.PerceptualHash = x.PerceptualHash;
        rec.SourceUrl = x.SourceUrl; rec.DocType = cls.DocType; rec.Confidence = cls.DocTypeConfidence; rec.Language = cls.Language;
        rec.Topics = cls.Topics; rec.Entities = cls.Entities;
        var snippet = x.Text.Collapse();
        rec.Snippet = snippet.Length > 400 ? snippet[..400] : snippet;
        if (rec.Status == FileStatus.missing) rec.Status = FileStatus.indexed;

        var vector = Embedder.Vector(Path.GetFileNameWithoutExtension(rec.Name) + ". " + string.Join(", ", rec.Topics) + ". " + (x.Text.Length > 1200 ? x.Text[..1200] : x.Text));
        if (rec.ProjectId == null)
        {
            Dictionary<string, float[]> pv; lock (stateLock) pv = projectVectors;
            if (ProjectMatcher.Match(rec, x.Text, Store.Projects(false), vector, pv).FirstOrDefault() is { } best)
            {
                if (best.Score >= Settings.AutoThreshold) { rec.ProjectId = best.Project.Id; best.Project.LastActivityAt = DateTime.Now; Store.SaveProject(best.Project); }
                else if (best.Score >= Settings.ReviewThreshold) lock (stateLock) pendingProjectLinks.Add((rec, best.Project, best.Score));
            }
        }
        Store.UpsertFile(rec, x.Text);
        if (vector != null) Store.SaveEmbedding(rec.Id, vector);
        Store.RemoveEdges(NodeType.file, rec.Id);
        var edges = rec.Topics.Select(t => new GraphEdge(NodeType.file, rec.Id, NodeType.topic, t.ToLowerInvariant(), "about")).ToList();
        foreach (var e in rec.Entities)
        {
            NodeType? t = e.Kind switch { EntityKind.person => NodeType.person, EntityKind.organization => NodeType.organization, EntityKind.place => NodeType.place, EntityKind.date => NodeType.date, EntityKind.course => NodeType.topic, _ => null };
            if (t is { } nt) edges.Add(new GraphEdge(NodeType.file, rec.Id, nt, e.Value.ToLowerInvariant(), "mentions"));
        }
        edges.AddRange(rec.Tags.Select(t => new GraphEdge(NodeType.file, rec.Id, NodeType.tag, t.ToLowerInvariant(), "taggedWith")));
        if (rec.ProjectId != null) edges.Add(new GraphEdge(NodeType.file, rec.Id, NodeType.project, rec.ProjectId, "belongsTo"));
        Store.AddEdges(edges);
        if (prev == null) Store.Log(new ActivityEvent { Kind = EventKind.fileIndexed, Message = $"Indexed {rec.Name}{(rec.DocType != null ? " · " + rec.DocType : "")}", FileId = rec.Id });
        return (rec, x.Text);
    }

    IEnumerable<string> ProjectTerms() => Store.Projects(false).SelectMany(p => p.Keywords.Prepend(p.Name));

    public void RebuildProjectVectors()
    {
        var v = new Dictionary<string, float[]>();
        foreach (var p in Store.Projects(false))
            if (Embedder.Vector(string.Join(", ", p.Keywords.Concat(p.Tags).Prepend(p.Name)) + ". " + p.Notes) is { } vec) v[p.Id] = vec;
        lock (stateLock) projectVectors = v;
    }

    // MARK: Rules

    public async Task<int> RunRules(FileRecord file, string content, TriggerKind trigger, Dictionary<string, string> info, string? batchId = null)
    {
        batchId ??= Ids.New();
        var rules = Store.Rules().Where(r => r.Enabled && (r.Trigger.Kind.IsFileTrigger() || r.Trigger.Kind == TriggerKind.connectorEvent)).ToList();
        if (rules.Count == 0) return 0;
        var projectName = file.ProjectId is { } pid ? Store.Project(pid)?.Name : null;
        var ctx = new RuleContext { File = file, Content = content, ProjectName = projectName, Trigger = trigger, Info = info };
        var current = file; var fired = 0;
        foreach (var rule in RuleEngine.FiringRules(rules, ctx))
        {
            if (rule.Trigger.Kind == TriggerKind.connectorEvent && trigger != TriggerKind.connectorEvent) continue;
            fired++;
            if (rule.RequireConfirmation)
            {
                var move = rule.Actions.FirstOrDefault(a => a.Kind == ActionKind.move);
                Store.SaveReview(new ReviewItem
                {
                    FileId = current.Id, Path = current.Path, SuggestedDestination = move == null ? null : Templates.Expand(move.Target, current, projectName),
                    SuggestedTags = rule.Actions.Where(a => a.Kind == ActionKind.tag).SelectMany(a => a.Tags).ToList(), Confidence = 1,
                    Reasons = [$"Rule “{rule.Name}” requires confirmation", rule.Summary], RuleId = rule.Id,
                });
                current.Status = FileStatus.review; Store.UpsertFile(current);
                continue;
            }
            var actions = Paths.IsProtected(current.Path)
                ? rule.Actions.Select(a => a.Kind == ActionKind.move ? new RuleAction(ActionKind.copy, a.Target, a.Tags, a.Project, a.Params) : a).Where(a => a.Kind is not (ActionKind.rename or ActionKind.trash or ActionKind.compress)).ToList()
                : rule.Actions;
            var (after, outcomes) = await Executor.Run(actions, current, info, rule.Id, null, batchId, Settings.DryRun);
            if (after != null) current = after;
            Store.RecordRuleHit(rule.Id);
            Store.Log(new ActivityEvent { Kind = EventKind.ruleFired, Message = $"“{rule.Name}” on {file.Name}: {string.Join(" · ", outcomes.Select(o => o.Message))}", FileId = file.Id, RuleId = rule.Id, BatchId = batchId });
            if (outcomes.Any(o => o.Success)) lock (stateLock) digest.filed++;
        }
        return fired;
    }

    public void FireEventRules(TriggerKind kind, Dictionary<string, string> info)
    {
        if (Paused) return;
        var ctx = new RuleContext { Trigger = kind, Info = info };
        foreach (var rule in Store.Rules().Where(r => r.Enabled && r.Trigger.Kind == kind && RuleEngine.TriggerMatches(r, ctx)))
        {
            if (rule.Trigger.Kind == TriggerKind.connectorEvent && rule.Trigger.Folders.Count > 0) continue;
            if (!RuleEngine.ConditionsPass(rule.Conditions, ctx).ok) continue;
            var cooling = lastEventRuleFire.TryGetValue(rule.Id, out var last) && (DateTime.Now - last).TotalMinutes < Math.Max(rule.CooldownMinutes, 1);
            if (cooling) continue;
            lastEventRuleFire[rule.Id] = DateTime.Now;
            EnqueueRuleJob(rule, info);
        }
    }

    void EnqueueRuleJob(Rule rule, Dictionary<string, string> info)
    {
        var kind = rule.Actions.Any(a => a.Kind is ActionKind.runShell or ActionKind.runPlugin) ? JobKind.script
            : rule.Actions.Any(a => a.Kind is ActionKind.githubIssue or ActionKind.slackMessage or ActionKind.webhook or ActionKind.obsidianNote) ? JobKind.integration
            : rule.Actions.Any(a => a.Kind is ActionKind.summarize or ActionKind.generateReport) ? JobKind.ai : JobKind.file;
        Queue.Enqueue(new Job
        {
            Name = rule.Name, Kind = kind, Priority = Focus != null && rule.ProjectId == Focus.ProjectId ? JobPriority.focus : JobPriority.high,
            Spec = new JobSpec { Operation = JobOperation.runActions, RuleId = rule.Id, Actions = rule.Actions, Params = info }, MaxAttempts = 2,
        });
    }

    public async Task<string> RunRuleNow(Rule rule, JobContext? jobCtx = null)
    {
        if (!rule.Trigger.Kind.IsFileTrigger())
        {
            var (_, outc) = await Executor.Run(rule.Actions, null, new() { ["manual"] = "1" }, rule.Id, jobCtx?.JobId, dryRun: Settings.DryRun);
            Store.RecordRuleHit(rule.Id);
            return string.Join(" · ", outc.Select(o => o.Message));
        }
        var folders = (rule.Trigger.Folders.Count == 0 ? Settings.WatchedFolders : rule.Trigger.Folders).Select(Paths.Expand);
        var batch = Ids.New(); int matched = 0, total = 0;
        foreach (var folder in folders)
            foreach (var path in ListFiles(folder, rule.Trigger.Recursive))
            {
                if (jobCtx?.IsCancelled == true) break;
                total++;
                if (Index(path) is not var (rec, content)) continue;
                var ctx = new RuleContext { File = rec, Content = content, ProjectName = rec.ProjectId is { } p ? Store.Project(p)?.Name : null, Trigger = TriggerKind.manual };
                if (!RuleEngine.ConditionsPass(rule.Conditions, ctx).ok) continue;
                matched++;
                var (_, outc) = await Executor.Run(rule.Actions, rec, null, rule.Id, jobCtx?.JobId, batch, Settings.DryRun);
                jobCtx?.Log($"{rec.Name}: {string.Join(" · ", outc.Select(o => o.Message))}");
                Store.RecordRuleHit(rule.Id);
            }
        return $"Matched {matched} of {total} files";
    }

    public SimulationReport? Simulate(string path, IEnumerable<Rule>? rules = null) =>
        Index(path) is var (rec, content) ? RuleEngine.Simulate(rules ?? Store.Rules(), rec, content, rec.ProjectId is { } p ? Store.Project(p)?.Name : null) : null;

    public List<(FileRecord file, RuleEvaluation eval)> TestRule(Rule rule, string folder, int limit = 300)
    {
        var outList = new List<(FileRecord, RuleEvaluation)>();
        foreach (var path in ListFiles(Paths.Expand(folder), false).Take(limit))
        {
            if (Index(path) is not var (rec, content)) continue;
            var ctx = new RuleContext { File = rec, Content = content, Trigger = TriggerKind.manual };
            var copy = Json.Parse<Rule>(Json.Str(rule))!; copy.Enabled = true; copy.StopProcessing = false;
            if (RuleEngine.Evaluate([copy], ctx).FirstOrDefault() is { } e) outList.Add((rec, e));
        }
        return outList.OrderByDescending(x => x.Item2.Fired).ToList();
    }

    NLRuleCompiler NewCompiler() => new(Settings.LibraryRoots.FirstOrDefault() ?? "~/Documents", Store.Projects().Select(p => p.Name));

    class RuleRewrite { public string Rule { get; set; } = ""; }
    class CommandRewrite { public List<string> Commands { get; set; } = []; }

    /// Deterministic compiler first, local LLM as a fallback that rewrites into the supported grammar.
    public async Task<RuleCompileResult> CompileRule(string text)
    {
        var compiler = NewCompiler();
        var first = compiler.Compile(text);
        if (first.Rule != null && !first.Warnings.Any(w => w.StartsWith("Didn’t understand"))) return first;
        const string system = """
        Rewrite the user's automation request as ONE sentence in this exact grammar:
        "<If|When> <trigger and conditions> → <action>, <action>, ..."
        Triggers: a <type> in <Folder>; download finishes; drive '<name>' is connected; <App> app opens; disk < N GB; <Folder> has > N files; Every <day> <time>:
        Conditions: contains '<text>'; filename contains '<text>'; older than N days; larger than N MB; tagged <tag>; language is <lang>; after N PM.
        Actions: move to <Folder/Path>; copy to <path>; tag <t1> <t2>; add to project <name>; rename to <pattern with {date} {basename}>; notify <message>;
        create a reminder; add deadline to calendar; compress; run script <cmd>; sync <Folder> to <path>; archive old files; auto-sort; generate weekly report.
        Return JSON {"rule": "<sentence>"}.
        """;
        if (await Llm.JsonAsk<RuleRewrite>(system, text) is { Rule.Length: > 0 } r)
        {
            var second = compiler.Compile(r.Rule);
            if (second.Rule != null)
            {
                second.Rule.NaturalLanguage = text;
                second.Explanation.Insert(0, $"Interpreted by the local model as: “{r.Rule}”");
                return second;
            }
        }
        return first;
    }

    // MARK: Autopilot

    public List<Suggestion> Suggestions(FileRecord file)
    {
        var outList = new List<Suggestion>();
        var projectName = file.ProjectId is { } pid ? Store.Project(pid)?.Name : null;
        foreach (var c in Store.Categories())
        {
            if (file.DocType == null || !c.DocTypes.Contains(file.DocType)) continue;
            var keyHit = c.Keywords.Any(k => file.Snippet.Contains(k, StringComparison.OrdinalIgnoreCase) || file.Name.Contains(k, StringComparison.OrdinalIgnoreCase));
            var score = 0.5 + 0.3 * file.Confidence + (keyHit ? 0.04 : 0);
            var folder = Paths.Canonical(Templates.Expand(c.Destination, file, projectName));
            var exists = Directory.Exists(folder) || Directory.Exists(Paths.FolderOf(folder));
            if (!exists) score *= 0.85;
            var noun = file.DocType;
            var article = "aeiou".Contains(char.ToLowerInvariant(noun[0])) ? "an" : "a";
            outList.Add(new Suggestion(folder, Math.Min(0.84, score), $"Looks like {article} {noun} → {c.Name}{(exists ? "" : " (new folder)")}"));
        }
        var generic = new HashSet<string>(Settings.LibraryRootsExpanded.Concat(Settings.WatchedFoldersExpanded).Append(Paths.Home), Paths.Comparer);
        foreach (var s in Taxonomy.Suggest(file, Classifier.Tokens(file.Name + " " + file.Snippet), generic))
        {
            var folder = Paths.Canonical(s.Folder);
            var i = outList.FindIndex(o => Paths.Same(o.Folder, folder));
            if (i >= 0) { var o = outList[i]; outList[i] = o with { Score = 1 - (1 - o.Score) * (1 - s.Score), Reason = o.Reason + " · " + s.Reason }; continue; }
            var pi = outList.FindIndex(o => Paths.IsInside(folder, o.Folder));
            if (pi >= 0 && s.Score >= 0.5 && NameOverlap(file, folder, outList[pi].Folder))
            {
                var o = outList[pi];
                outList[pi] = new Suggestion(folder, 1 - (1 - o.Score) * (1 - s.Score), s.Reason + " · " + o.Reason);
                continue;
            }
            outList.Add(new Suggestion(folder, s.Score, s.Reason));
        }
        return outList.Where(o => !Paths.Same(o.Folder, file.Folder)).OrderByDescending(o => o.Score).ToList();
    }

    static bool NameOverlap(FileRecord file, string sub, string parent)
    {
        var extra = sub[Math.Min(parent.Length, sub.Length)..].Split(Paths.Sep, StringSplitOptions.RemoveEmptyEntries).SelectMany(Classifier.Tokens).ToList();
        var terms = Classifier.Tokens(file.Name).Concat(file.Topics.SelectMany(Classifier.Tokens)).Concat(file.Entities.Where(e => e.Kind == EntityKind.course).SelectMany(e => Classifier.Tokens(e.Value))).ToHashSet();
        return extra.Any(t => terms.Contains(t) || terms.Any(x => x.StartsWith(t) || t.StartsWith(x)));
    }

    public List<string> SuggestedTags(FileRecord file)
    {
        var tags = file.Entities.Where(e => e.Kind == EntityKind.course).Select(e => e.Value).ToList();
        if (file.ProjectId is { } pid && Store.Project(pid) is { } p) tags.AddRange(p.Tags);
        if (file.DocType != null && !new[] { "photo", "archive", "code", "screenshot", "installer" }.Contains(file.DocType)) tags.Add(file.DocType.Replace(' ', '-'));
        if (file.Kind == FileKind.code && file.Language != null) tags.Add(file.Language.ToLowerInvariant());
        return tags.Distinct(StringComparer.OrdinalIgnoreCase).Where(t => !file.Tags.Contains(t, StringComparer.OrdinalIgnoreCase)).Take(4).ToList();
    }

    async Task Autopilot(FileRecord file, string content)
    {
        var sugg = Suggestions(file);
        var tags = SuggestedTags(file);
        if (sugg.Count == 0)
        {
            if (tags.Count > 0 && file.Confidence >= Settings.AutoThreshold && SetupComplete) await Executor.Run([new RuleAction(ActionKind.tag, tags: tags)], file, dryRun: Settings.DryRun);
            else { file.Status = FileStatus.ignored; Store.UpsertFile(file); }
            return;
        }
        var best = sugg[0];
        if (best.Score >= Settings.AutoThreshold && SetupComplete)
        {
            var actions = new List<RuleAction> { new(ActionKind.move, best.Folder) };
            if (tags.Count > 0) actions.Add(new RuleAction(ActionKind.tag, tags: tags));
            var batch = Ids.New();
            var (_, outc) = await Executor.Run(actions, file, batchId: batch, dryRun: Settings.DryRun);
            Store.Log(new ActivityEvent { Kind = EventKind.fileMoved, Message = $"Autopilot ({(int)(best.Score * 100)}%): {file.Name} — {best.Reason}", FileId = file.Id, BatchId = batch });
            if (outc.Any(o => o.Success)) lock (stateLock) digest.filed++;
        }
        else if (best.Score >= Settings.ReviewThreshold || (best.Score >= Settings.AutoThreshold && !SetupComplete))
        {
            if (Store.PendingReview(file.Id) != null) return;
            Store.SaveReview(new ReviewItem
            {
                FileId = file.Id, Path = file.Path, SuggestedDestination = best.Folder, SuggestedTags = tags, SuggestedProjectId = file.ProjectId, SuggestedCategory = file.DocType,
                Confidence = best.Score, Reasons = [best.Reason], Alternatives = sugg.Skip(1).Take(3).Select(s => s.Folder).ToList(),
            });
            file.Status = FileStatus.review; Store.UpsertFile(file);
            lock (stateLock) digest.review++;
        }
        else
        {
            file.Status = FileStatus.ignored; Store.UpsertFile(file);
            Store.Log(new ActivityEvent { Kind = EventKind.fileIndexed, Message = $"Low confidence ({(int)(best.Score * 100)}%) for {file.Name} — left in place", FileId = file.Id });
        }
    }

    public async Task<string> SortFolder(string path, string batchId)
    {
        int filed = 0, review = 0, untouched = 0;
        foreach (var p in ListFiles(path, false))
        {
            if (Index(p) is not var (rec, content)) continue;
            if (await RunRules(rec, content, TriggerKind.fileAdded, [], batchId) > 0) { filed++; continue; }
            await Autopilot(rec, content);
            switch (Store.File(rec.Id)?.Status)
            {
                case FileStatus.filed: filed++; break;
                case FileStatus.review: review++; break;
                default: untouched++; break;
            }
        }
        return $"Sorted {Paths.Abbreviate(path)}: filed {filed}, {review} to review, {untouched} left in place";
    }

    public List<CleanupGroup> DuplicateCleanupPlan()
    {
        var groups = new List<CleanupGroup>();
        foreach (var h in Store.DuplicateHashes())
        {
            var files = Store.FilesWithHash(h).Where(f => File.Exists(f.Path)).ToList();
            if (files.Count < 2) continue;
            var ranked = files.OrderBy(f => IsAutomationFolder(f.Path) ? 1 : 0).ThenBy(f => f.CreatedAt).ThenBy(f => f.Name.Length).ToList();
            var trash = ranked.Skip(1).Where(f => !Paths.IsProtected(f.Path)).ToList();
            if (trash.Count > 0) groups.Add(new CleanupGroup(ranked[0], trash));
        }
        return groups;
    }

    public List<CleanupGroup> SimilarScreenshotPlan()
    {
        var shots = Store.Files(5000).Where(f => f.Kind == FileKind.screenshot && f.PerceptualHash != null && File.Exists(f.Path) && !Paths.IsProtected(f.Path)).OrderByDescending(f => f.CreatedAt).ToList();
        var used = new HashSet<string>(); var groups = new List<CleanupGroup>();
        foreach (var s in shots)
        {
            if (used.Contains(s.Id)) continue;
            var cluster = shots.Where(o => !used.Contains(o.Id) && BitOperations.PopCount(o.PerceptualHash!.Value ^ s.PerceptualHash!.Value) <= 5).ToList();
            if (cluster.Count < 2) continue;
            cluster.ForEach(c => used.Add(c.Id));
            groups.Add(new CleanupGroup(cluster[0], cluster.Skip(1).ToList()));
        }
        return groups;
    }

    public List<string> DebugSuggestions(FileRecord file) => Suggestions(file).Take(4).Select(s => $"{(int)(s.Score * 100)}% {Paths.Abbreviate(s.Folder)} — {s.Reason}").ToList();

    // MARK: Review queue

    public async Task Approve(ReviewItem item, string? destination = null, List<string>? tags = null, string? projectId = null)
    {
        if ((Store.File(item.FileId) ?? Store.FileByPath(item.Path)) is not { } file) return;
        var actions = new List<RuleAction>();
        if (item.RuleId != null && Store.Rule(item.RuleId) is { } rule && destination == null && tags == null) { actions = rule.Actions; Store.RecordRuleHit(rule.Id); }
        else
        {
            if ((destination ?? item.SuggestedDestination) is { } d) actions.Add(new RuleAction(ActionKind.move, d));
            var t = tags ?? item.SuggestedTags;
            if (t.Count > 0) actions.Add(new RuleAction(ActionKind.tag, tags: t));
            if ((projectId ?? item.SuggestedProjectId) is { } pid && Store.Project(pid) is { } p) actions.Add(new RuleAction(ActionKind.addToProject, p.Name, project: p.Name));
        }
        var batch = Ids.New();
        var (after, _) = await Executor.Run(actions, file, ruleId: item.RuleId, batchId: batch, dryRun: Settings.DryRun);
        item.Status = ReviewStatus.approved; item.ResolvedAt = DateTime.Now;
        if (destination != null) item.SuggestedDestination = destination;
        Store.SaveReview(item);
        if ((destination ?? item.SuggestedDestination) is { } dest)
            Taxonomy.Reinforce(Templates.Expand(dest, file, null), file.DocType, Classifier.Tokens(file.Name), destination == null ? 1 : 2);
        if ((after ?? Store.File(file.Id)) is { Status: FileStatus.review } f) { f.Status = FileStatus.filed; Store.UpsertFile(f); }
        Store.Log(new ActivityEvent { Kind = EventKind.review, Message = $"Approved {file.Name}", FileId = file.Id, BatchId = batch });
        RefreshStatus();
    }

    public void Reject(ReviewItem item)
    {
        item.Status = ReviewStatus.rejected; item.ResolvedAt = DateTime.Now;
        Store.SaveReview(item);
        if (Store.File(item.FileId) is { } file)
        {
            if (item.SuggestedDestination is { } d) Taxonomy.Penalize(Templates.Expand(d, file, null), file.DocType);
            file.Status = FileStatus.indexed; Store.UpsertFile(file);
        }
        Store.Log(new ActivityEvent { Kind = EventKind.review, Message = $"Rejected suggestion for {Path.GetFileName(item.Path)}", FileId = item.FileId });
        RefreshStatus();
    }

    public int UndoLast() => Store.LastUndoableBatch() is { } b ? Executor.Undo(b) : 0;

    // MARK: Focus

    public void StartFocus(string projectId, int minutes, string source = "manual")
    {
        Focus = new FocusSession { ProjectId = projectId, StartedAt = DateTime.Now, EndsAt = DateTime.Now.AddMinutes(minutes), Source = source };
        Store.SetKv("focus", Json.Str(Focus));
        var name = Store.Project(projectId)?.Name ?? "project";
        Store.Log(new ActivityEvent { Kind = EventKind.focus, Message = $"Focus started: {name} for {minutes} min" });
        FireEventRules(TriggerKind.focusStarted, new() { ["project"] = name });
        Queue.Enqueue(new Job { Name = $"Pre-warm {name}", Kind = JobKind.ai, Priority = JobPriority.focus, Spec = new JobSpec { Operation = JobOperation.prewarmProject, Params = new() { ["projectId"] = projectId } } });
        StoreChanged?.Invoke("focus");
    }

    public void EndFocus()
    {
        if (Focus is not { } f) return;
        Focus = null; Store.SetKv("focus", null);
        var name = Store.Project(f.ProjectId)?.Name ?? "project";
        Store.Log(new ActivityEvent { Kind = EventKind.focus, Message = $"Focus ended: {name}" });
        FireEventRules(TriggerKind.focusEnded, new() { ["project"] = name });
        if (f.Suppressed > 0) Notify("Focus session complete", $"{Text.Plural(f.Suppressed, "non-urgent notification")} held back. Check Insights & Review.", true);
        StoreChanged?.Invoke("focus");
    }

    void CheckFocus() { if (Focus is { } f && f.EndsAt <= DateTime.Now) EndFocus(); }

    async Task<bool> RouteForFocus(FileRecord file)
    {
        if (Focus is not { } f || Store.Project(f.ProjectId) is not { } p || p.Folders.FirstOrDefault() is not { } folder) return false;
        Dictionary<string, float[]> pv; lock (stateLock) pv = projectVectors;
        var score = ProjectMatcher.Match(file, Store.FileContent(file.Id) ?? file.Snippet, [p], Embedder.Vector(file.Name + " " + file.Snippet), pv).FirstOrDefault()?.Score ?? 0;
        if (score < Settings.ReviewThreshold || !SetupComplete) return false;
        var batch = Ids.New();
        await Executor.Run([new RuleAction(ActionKind.move, Paths.Expand(folder)), new RuleAction(ActionKind.addToProject, p.Name, project: p.Name)], file, batchId: batch, dryRun: Settings.DryRun);
        Store.Log(new ActivityEvent { Kind = EventKind.focus, Message = $"Focus routing: {file.Name} → {p.Name}", FileId = file.Id, BatchId = batch });
        return true;
    }

    // MARK: Commands

    public async Task<CommandPlan> Plan(string input)
    {
        var parser = new CommandParser(NewCompiler());
        var steps = parser.Parse(input);
        var usedLlm = false;
        if (steps.Any(s => s.Intent is Intent.Unknown)
            && await Llm.JsonAsk<CommandRewrite>($"Rewrite the user's request for a Windows file assistant into one or more commands using ONLY this grammar:\n{CommandParser.GrammarHelp}\nReturn JSON {{\"commands\": [\"...\"]}}.", input) is { Commands.Count: > 0 } rw)
        {
            var rewritten = rw.Commands.SelectMany(parser.Parse).ToList();
            if (rewritten.Count > 0 && !rewritten.Any(s => s.Intent is Intent.Unknown)) { steps = rewritten; usedLlm = true; }
        }
        var planned = new List<PlannedStep>();
        List<FileRecord> previous; lock (stateLock) previous = lastCommandResults.Select(Store.File).Where(f => f != null).Select(f => f!).ToList();
        foreach (var s in steps)
        {
            var ps = new PlannedStep { Step = s };
            switch (s.Intent)
            {
                case Intent.Find f:
                    ps.Files = Resolve(f.Query, previous);
                    ps.Preview = ps.Files.Take(8).Select(x => $"{x.Name} — {Paths.Abbreviate(x.Folder)}").ToList();
                    ps.Note = $"{Text.Plural(ps.Files.Count, "file")} found";
                    previous = ps.Files; break;
                case Intent.FileActions fa:
                    ps.Files = Resolve(fa.Query, previous);
                    ps.Preview = ps.Files.Take(8).Select(x => $"{x.Name}: " + string.Join(", ", fa.Actions.Select(a => Templates.Describe(a, x, null)))).ToList();
                    ps.Note = ps.Files.Count == 0 ? "No matching files" : $"{Text.Plural(ps.Files.Count, "file")} will be changed";
                    previous = ps.Files; break;
                case Intent.SummarizeQuery sq:
                    ps.Files = Resolve(sq.Query, previous); ps.Note = $"Summarize {ps.Files.Count} files"; break;
                case Intent.CreateRule cr:
                    var r = await CompileRule(cr.Text);
                    ps.RuleResult = r;
                    ps.Preview = r.Explanation.Concat(r.Warnings.Select(w => "⚠ " + w)).ToList();
                    ps.Note = r.Rule != null ? $"Rule: {r.Rule.Name}" : "Couldn’t build a rule from that"; break;
                case Intent.ScheduleIt sc:
                    ps.Note = sc.When is TimeResult.Once o ? $"Run “{sc.Command}” {o.At:ddd MMM d, h:mm tt}" : $"Run “{sc.Command}” — {CronExpression.Describe(((TimeResult.CronAt)sc.When).Cron)}"; break;
                case Intent.Organize org:
                    ps.Note = $"Sort {ListFiles(org.Folder, false).Count} files in {Paths.Abbreviate(org.Folder)} using rules + learned folders"; break;
                case Intent.Archive ar:
                    ps.Note = $"Move {ar.Kind ?? "file"}s older than {ar.Days} days from {Paths.Abbreviate(ar.Folder)} into the archive"; break;
                case Intent.Focus fo:
                    ps.Note = Store.ProjectNamed(fo.Project) is { } proj ? $"Focus on {proj.Name} for {fo.Minutes} min" : $"No project named “{fo.Project}” — it will be created"; break;
                case Intent.SmartFile sf:
                    ps.Files = Resolve(sf.Query, previous);
                    ps.Preview = ps.Files.Take(8).Select(x => $"{x.Name} " + (Suggestions(x).FirstOrDefault() is { } b ? $"→ {Paths.Abbreviate(b.Folder)} ({(int)(b.Score * 100)}%)" : "→ rules / review")).ToList();
                    ps.Note = ps.Files.Count == 0 ? "Nothing selected — select files in File Explorer first" : $"File {Text.Plural(ps.Files.Count, "selected item")}";
                    previous = ps.Files; break;
                case Intent.CleanDuplicates:
                    {
                        var groups = DuplicateCleanupPlan();
                        ps.Files = groups.SelectMany(g => g.Trash).ToList();
                        ps.Preview = groups.Take(8).Select(g => $"keep {Paths.Abbreviate(g.Keep.Path)} · remove {Text.Plural(g.Trash.Count, "copy")}").ToList();
                        ps.Note = groups.Count == 0 ? "No duplicates found" : $"Move {Text.Plural(ps.Files.Count, "duplicate")} to the Recycle Bin · frees {Text.FormatBytes(ps.Files.Sum(f => f.Size))}";
                        break;
                    }
                case Intent.CleanSimilarScreenshots:
                    {
                        var groups = SimilarScreenshotPlan();
                        ps.Files = groups.SelectMany(g => g.Trash).ToList();
                        ps.Preview = groups.Take(8).Select(g => $"keep {g.Keep.Name} · remove {g.Trash.Count} similar").ToList();
                        ps.Note = groups.Count == 0 ? "No near-identical screenshots" : $"Move {Text.Plural(ps.Files.Count, "near-identical screenshot")} to the Recycle Bin";
                        break;
                    }
                case Intent.Ask a: ps.Note = $"Searching your files for: {a.Question}"; break;
                case Intent.Briefing: ps.Note = "Today’s briefing"; break;
                case Intent.Unknown u: ps.Note = $"Not sure how to do “{u.Text}”. Try: organize Downloads · find invoices from last month · create rule: …"; break;
                default: ps.Note = s.Intent.Label; break;
            }
            planned.Add(ps);
        }
        return new CommandPlan
        {
            Input = input, Steps = planned, Understood = planned.Count > 0 && !planned.Any(p => p.Step.Intent is Intent.Unknown),
            RequiresConfirmation = planned.Any(p => p.Step.Intent.IsMutating), UsedLlm = usedLlm,
        };
    }

    public async Task<CommandResult> Execute(CommandPlan plan)
    {
        Store.AddCommandHistory(plan.Input);
        Store.Log(new ActivityEvent { Kind = EventKind.command, Message = "› " + plan.Input });
        var batch = Ids.New();
        var result = new CommandResult { BatchId = batch };
        List<FileRecord> previous; lock (stateLock) previous = lastCommandResults.Select(Store.File).Where(f => f != null).Select(f => f!).ToList();
        var messages = new List<string>();
        foreach (var ps in plan.Steps)
        {
            switch (ps.Step.Intent)
            {
                case Intent.Find f:
                    previous = ps.Files.Count == 0 ? Resolve(f.Query, previous) : ps.Files;
                    result.Files = previous; messages.Add($"Found {Text.Plural(previous.Count, "file")}"); break;
                case Intent.FileActions fa:
                    {
                        var targets = fa.Query.UseLastResults ? previous.Select(p => Store.File(p.Id) ?? p).ToList() : ps.Files.Count == 0 ? Resolve(fa.Query, previous) : ps.Files;
                        var ok = 0; var updated = new List<FileRecord>();
                        foreach (var t in targets)
                        {
                            var (after, outc) = await Executor.Run(fa.Actions, Store.File(t.Id) ?? t, batchId: batch, dryRun: Settings.DryRun);
                            if (outc.All(o => o.Success)) ok++;
                            result.Details.AddRange(outc.Where(o => !o.Success).Select(o => $"{t.Name}: {o.Message}"));
                            updated.Add(after ?? t);
                        }
                        previous = updated; result.Files = updated;
                        messages.Add($"{string.Join(" + ", fa.Actions.Select(a => a.Kind.Label()))}: {ok}/{targets.Count} files");
                        break;
                    }
                case Intent.SummarizeFolder sf: messages.Add(await SummarizeFolder(sf.Folder)); break;
                case Intent.SummarizeQuery sq:
                    {
                        var files = ps.Files.Count == 0 ? Resolve(sq.Query, previous) : ps.Files;
                        messages.Add(await Llm.Summarize(string.Join("\n", files.Take(25).Select(x => $"{x.Name}: {x.Summary ?? x.Snippet}")), "set of files"));
                        result.Files = files; break;
                    }
                case Intent.SummarizeProject sp:
                    {
                        if (Store.ProjectNamed(sp.Name) is not { } p) { messages.Add($"No project “{sp.Name}”"); break; }
                        var files = Store.Files(40, p.Id);
                        messages.Add(await Llm.Summarize($"Project {p.Name}. Notes: {p.Notes}\n" + string.Join("\n", files.Select(x => $"{x.Name} ({x.DocType ?? x.Kind.ToString()}): {x.Summary ?? x.Snippet}")), "project"));
                        result.Files = files; break;
                    }
                case Intent.CreateRule:
                    {
                        if (ps.RuleResult?.Rule is not { } rule) { messages.Add("Rule not created"); break; }
                        if (rule.Actions.FirstOrDefault(a => a.Kind == ActionKind.addToProject)?.Project is { } pname && ResolveProject(pname, true) is { } proj) rule.ProjectId = proj.Id;
                        Store.SaveRule(rule); RestartWatcher();
                        result.CreatedRule = rule; messages.Add($"Created rule “{rule.Name}”. Want to test it?"); break;
                    }
                case Intent.ScheduleIt sc:
                    {
                        var s = new Schedule { Name = sc.Command, Mode = ScheduleMode.once, Job = new JobSpec { Operation = JobOperation.runCommand, Command = sc.Command }, NaturalLanguage = plan.Input };
                        if (sc.When is TimeResult.Once o) { s.RunAt = o.At; s.NextRunAt = o.At; }
                        else if (sc.When is TimeResult.CronAt c) { s.Mode = ScheduleMode.recurring; s.Cron = c.Cron; s.NextRunAt = CronExpression.Parse(c.Cron)?.Next(DateTime.Now); }
                        Store.SaveSchedule(s);
                        messages.Add($"Scheduled “{sc.Command}” · {(s.Cron != null ? CronExpression.Describe(s.Cron) : $"{s.RunAt:ddd MMM d, h:mm tt}")}");
                        break;
                    }
                case Intent.Organize org: messages.Add(await SortFolder(org.Folder, batch)); break;
                case Intent.FindDuplicates: messages.Add(FindDuplicates(false)); result.Navigate = "insights"; break;
                case Intent.Report rep: messages.Add(await GenerateReport(rep.Type)); break;
                case Intent.CreateProject cp:
                    {
                        var p = Store.ProjectNamed(cp.Name) is { } ex && ex.Name.Equals(cp.Name, StringComparison.OrdinalIgnoreCase) ? ex : new Project { Name = cp.Name, Color = Palette[Random.Shared.Next(Palette.Length)] };
                        p.Keywords = p.Keywords.Union(cp.Keywords).ToList();
                        if (cp.Folder != null) { p.Folders = p.Folders.Union([cp.Folder]).ToList(); Directory.CreateDirectory(cp.Folder); }
                        if (cp.Deadline != null) p.Deadline = cp.Deadline;
                        Store.SaveProject(p); RebuildProjectVectors();
                        messages.Add($"Project “{p.Name}” is ready"); result.Navigate = "projects"; break;
                    }
                case Intent.Focus fo:
                    if (ResolveProject(fo.Project, true) is { } fp) { StartFocus(fp.Id, fo.Minutes); messages.Add($"Focusing on {fp.Name} for {fo.Minutes} min. Non-critical notifications are silenced."); }
                    break;
                case Intent.EndFocus: EndFocus(); messages.Add("Focus ended"); break;
                case Intent.Undo: { var n = UndoLast(); messages.Add(n > 0 ? $"Undid {Text.Plural(n, "operation")}" : "Nothing to undo"); break; }
                case Intent.Archive ar:
                    {
                        var ps2 = new Dictionary<string, string> { ["folder"] = ar.Folder, ["days"] = ar.Days.ToString() };
                        if (ar.Kind != null) ps2["kind"] = ar.Kind;
                        var dest = ar.Kind == "screenshot" ? "~/Documents/Archive/Screenshots/{year}" : "~/Documents/Archive/{year}";
                        var (_, outc) = await Executor.Run([new RuleAction(ActionKind.archiveOld, Paths.Expand(dest), p: ps2)], null, batchId: batch, dryRun: Settings.DryRun);
                        messages.Add(string.Join(" ", outc.Select(o => o.Message))); break;
                    }
                case Intent.Pause: SetPaused(true); messages.Add("Automations paused"); break;
                case Intent.Resume: SetPaused(false); messages.Add("Automations resumed"); break;
                case Intent.Navigate nav: result.Navigate = nav.View; messages.Add($"Opening {nav.View}"); break;
                case Intent.LearnTaxonomy: EnqueueOnce(JobOperation.learnTaxonomy, "Learn folder structure", JobKind.ai, JobPriority.high); messages.Add("Learning your folder structure in the background"); break;
                case Intent.RunRule rr:
                    {
                        if (Store.Rules().FirstOrDefault(r => r.Name.Contains(rr.Name, StringComparison.OrdinalIgnoreCase)) is not { } r) { messages.Add($"No rule matching “{rr.Name}”"); break; }
                        Queue.Enqueue(new Job { Name = $"Run rule: {r.Name}", Kind = JobKind.file, Priority = JobPriority.high, Spec = new JobSpec { Operation = JobOperation.runRule, RuleId = r.Id } });
                        messages.Add($"Running “{r.Name}”"); break;
                    }
                case Intent.Classify cl:
                    Queue.Enqueue(new Job { Name = $"Classify {Paths.Abbreviate(cl.Folder)}", Kind = JobKind.ai, Priority = JobPriority.normal, Spec = new JobSpec { Operation = JobOperation.classifyFolder, Path = cl.Folder } });
                    messages.Add($"Classifying {Paths.Abbreviate(cl.Folder)} in the background"); break;
                case Intent.SmartFile sm:
                    {
                        var files = ps.Files.Count == 0 ? Resolve(sm.Query, previous) : ps.Files;
                        int filed = 0, review = 0;
                        foreach (var f in files)
                        {
                            if (Index(f.Path) is not var (rec, content)) continue;
                            if (await RunRules(rec, content, TriggerKind.manual, [], batch) > 0) { filed++; continue; }
                            if (Suggestions(rec).FirstOrDefault() is { } best && best.Score >= Settings.ReviewThreshold)
                            {
                                var tags = SuggestedTags(rec);
                                var acts = new List<RuleAction> { new(ActionKind.move, best.Folder) };
                                if (tags.Count > 0) acts.Add(new RuleAction(ActionKind.tag, tags: tags));
                                var (_, outc) = await Executor.Run(acts, rec, batchId: batch, dryRun: Settings.DryRun);
                                if (outc.Any(o => o.Success)) filed++;
                                Taxonomy.Reinforce(best.Folder, rec.DocType, Classifier.Tokens(rec.Name));
                            }
                            else { await Autopilot(rec, content); if (Store.File(rec.Id)?.Status == FileStatus.review) review++; }
                        }
                        previous = files.Select(x => Store.File(x.Id)).Where(x => x != null).Select(x => x!).ToList();
                        result.Files = previous;
                        messages.Add($"Filed {filed} of {files.Count}{(review > 0 ? $", {review} need a quick review" : "")}");
                        break;
                    }
                case Intent.CleanDuplicates or Intent.CleanSimilarScreenshots:
                    {
                        var isDup = ps.Step.Intent is Intent.CleanDuplicates;
                        var groups = isDup ? DuplicateCleanupPlan() : SimilarScreenshotPlan();
                        var trashed = 0; long freed = 0;
                        foreach (var g in groups)
                            foreach (var f in g.Trash.Where(f => File.Exists(f.Path)))
                            {
                                var (_, outc) = await Executor.Run([new RuleAction(ActionKind.trash)], f, batchId: batch, dryRun: Settings.DryRun);
                                if (outc.FirstOrDefault()?.Success == true) { trashed++; freed += f.Size; }
                            }
                        Store.RemoveInsight(isDup ? "duplicates" : "similarShots");
                        messages.Add(trashed == 0 ? "Nothing to clean up" : $"Moved {Text.Plural(trashed, isDup ? "duplicate" : "similar screenshot")} to the Recycle Bin · freed {Text.FormatBytes(freed)}. Undo anytime.");
                        break;
                    }
                case Intent.Ask a:
                    {
                        var (answer, sources) = await Answer(a.Question);
                        messages.Add(answer); result.Files = sources; previous = sources; break;
                    }
                case Intent.Briefing: messages.Add(await Briefing()); break;
                case Intent.Unknown u:
                    {
                        if (await Llm.Provider() is { } p)
                        {
                            string answer;
                            try { answer = await p.Complete($"You are Nexus, a concise Windows file assistant. Answer briefly. If the user wants an action, suggest a command from: {CommandParser.GrammarHelp}", u.Text); }
                            catch { answer = ""; }
                            messages.Add(answer.Length == 0 ? "I couldn't do that." : answer);
                        }
                        else messages.Add($"I didn’t understand “{u.Text}”. Try “organize Downloads” or “find PDFs about hydroponics”.");
                        break;
                    }
            }
        }
        lock (stateLock) lastCommandResults = previous.Select(p => p.Id).ToList();
        result.Message = string.Join("\n", messages);
        return result;
    }

    /// Resolves a file query against disk (folder scopes) and the index (FTS + vectors).
    public List<FileRecord> Resolve(FileQuery q, List<FileRecord> previous)
    {
        if (q.UseLastResults) return previous.Select(p => Store.File(p.Id) ?? p).ToList();
        if (q.UseContext)
            return (ContextSelection?.Invoke() ?? []).SelectMany(p => Directory.Exists(p) ? ListFiles(p, false) : [p])
                .Select(p => Store.FileByPath(p) ?? Index(p)?.rec).Where(f => f != null).Select(f => f!).ToList();
        var candidates = new List<FileRecord>();
        var ftsMatched = new HashSet<string>();
        if (q.Folders.Count > 0)
        {
            foreach (var folder in q.Folders)
            {
                var recursive = !Settings.WatchedFoldersExpanded.Contains(folder, Paths.Comparer);
                foreach (var path in ListFiles(folder, recursive).Take(3000))
                    if ((Store.FileByPath(path) ?? Index(path)?.rec) is { } rec) candidates.Add(rec);
            }
        }
        else if (q.SearchTerms.Count > 0)
        {
            var seen = new HashSet<string>();
            foreach (var term in q.SearchTerms)
            {
                foreach (var f in Store.SearchFiles(term.Replace('|', ' '), 400)) if (seen.Add(f.Id)) { candidates.Add(f); ftsMatched.Add(f.Id); }
                if (Embedder.Vector(term) is { } v)
                    foreach (var (id, _) in Store.AllEmbeddings().Select(e => (e.id, s: Embedder.Cosine(v, e.vec))).Where(x => x.s > 0.35).OrderByDescending(x => x.s).Take(60))
                        if (seen.Add(id) && Store.File(id) is { } f) { candidates.Add(f); ftsMatched.Add(id); }
            }
        }
        else candidates = Store.Files(5000);
        var conds = q.Conditions.Where(c => !(ftsMatched.Count > 0 && c.Field is ConditionField.anyText or ConditionField.content && c.Op == ConditionOp.contains)).ToList();
        var needsText = conds.Any(c => c.Field is ConditionField.content or ConditionField.anyText);
        return candidates.Where(f =>
        {
            if (!File.Exists(f.Path)) return false;
            var ctx = new RuleContext { File = f, Content = needsText ? Store.FileContent(f.Id) ?? f.Snippet : "", ProjectName = f.ProjectId is { } p ? Store.Project(p)?.Name : null, Trigger = TriggerKind.manual };
            return RuleEngine.ConditionsPass(new ConditionGroup { Conditions = conds }, ctx).ok;
        }).OrderByDescending(f => f.ModifiedAt).Take(q.Limit).ToList();
    }

    public async Task<string> SummarizeFolder(string folder)
    {
        var files = ListFiles(folder, true).Take(60).ToList();
        if (files.Count == 0) return $"{Paths.Abbreviate(folder)} is empty or not found.";
        var kinds = new Dictionary<string, int>(); var lines = new List<string>();
        foreach (var p in files)
        {
            if ((Store.FileByPath(p) ?? Index(p)?.rec) is not { } r) continue;
            var k = r.DocType ?? r.Kind.ToString();
            kinds[k] = kinds.GetValueOrDefault(k) + 1;
            if (lines.Count < 30) lines.Add($"{r.Name} [{k}]: {r.Summary ?? (r.Snippet.Length > 200 ? r.Snippet[..200] : r.Snippet)}");
        }
        var overview = string.Join(", ", kinds.OrderByDescending(k => k.Value).Take(5).Select(k => $"{k.Value} {k.Key}"));
        var summary = await Llm.Summarize($"Folder {Paths.Abbreviate(folder)} contains: {overview}\n" + string.Join("\n", lines), "folder");
        return $"{Paths.Abbreviate(folder)} — {files.Count}{(files.Count == 60 ? "+" : "")} files ({overview}).\n{summary}";
    }

    public List<(FileRecord file, double score, List<string> why)> Related(FileRecord file, int limit = 12)
    {
        var scores = new Dictionary<string, (double s, HashSet<string> why)>();
        foreach (var e in Store.EdgesFrom(NodeType.file, file.Id))
        {
            double w = e.DstType == NodeType.project ? 3 : e.DstType is NodeType.person or NodeType.organization ? 2 : e.DstType == NodeType.date ? 0.3 : 1;
            foreach (var o in Store.EdgesTo(e.DstType, e.DstId).Where(o => o.SrcId != file.Id && o.SrcType == NodeType.file))
            {
                var cur = scores.GetValueOrDefault(o.SrcId, (0, []));
                cur.why.Add($"{e.DstType}: {e.DstId}");
                scores[o.SrcId] = (cur.s + w, cur.why);
            }
        }
        return scores.OrderByDescending(s => s.Value.s).Take(limit).Select(s => (Store.File(s.Key), s.Value.s, s.Value.why.OrderBy(x => x).ToList()))
            .Where(x => x.Item1 != null).Select(x => (x.Item1!, x.Item2, x.Item3)).ToList();
    }

    /// Answers a question from the contents of your files: hybrid retrieval → on-device model with citations.
    public async Task<(string answer, List<FileRecord> sources)> Answer(string question)
    {
        var terms = Classifier.Tokens(question).Where(t => t is not ("file" or "files" or "document" or "documents" or "due" or "when" or "what")).ToList();
        var scored = new Dictionary<string, double>();
        foreach (var (t, i) in terms.Take(6).Select((t, i) => (t, i)))
            foreach (var (f, rank) in Store.SearchFiles(t, 40).Select((f, r) => (f, r))) scored[f.Id] = scored.GetValueOrDefault(f.Id) + 1.0 / (rank + 2) + (i == 0 ? 0.1 : 0);
        if (terms.Count > 0)
            foreach (var (f, rank) in Store.SearchFiles(string.Join(' ', terms), 20).Select((f, r) => (f, r))) scored[f.Id] = scored.GetValueOrDefault(f.Id) + 2.0 / (rank + 1);
        if (Embedder.Vector(question) is { } v)
            foreach (var (id, vec) in Store.AllEmbeddings()) { var s = Embedder.Cosine(v, vec); if (s > 0.4) scored[id] = scored.GetValueOrDefault(id) + s; }
        var top = scored.OrderByDescending(s => s.Value).Take(6).Select(s => Store.File(s.Key)).Where(f => f != null && File.Exists(f.Path)).Select(f => f!).ToList();
        if (top.Count == 0) return ("I couldn’t find anything about that in your indexed files.", []);
        var sources = top.Select((f, i) => $"[{i + 1}] {f.Name}\n{Passage(Store.FileContent(f.Id) ?? f.Snippet, terms)}").ToList();
        if (await Llm.Provider() is { } p)
        {
            try
            {
                var ans = await p.Complete("You answer questions using ONLY the provided excerpts from the user's own files. Be concise (1-3 sentences). Cite sources like [1]. If the excerpts don't contain the answer, say so.",
                    $"Question: {question}\n\nExcerpts:\n{string.Join("\n\n", sources)}", 200);
                if (ans.Trim().Length > 0) return (ans.Trim(), top);
            }
            catch { }
        }
        return ($"From {top[0].Name}: “{Passage(Store.FileContent(top[0].Id) ?? top[0].Snippet, terms, 280)}”", top);
    }

    static string Passage(string text, List<string> terms, int length = 700)
    {
        var lower = text.ToLowerInvariant();
        var hits = terms.Select(t => lower.IndexOf(t, StringComparison.Ordinal)).Where(i => i >= 0).ToList();
        var start = Math.Max(0, (hits.Count > 0 ? hits.Min() : 0) - length / 3);
        start = Math.Min(start, text.Length);
        return text.Substring(start, Math.Min(length, text.Length - start)).Collapse();
    }

    public async Task<string> Briefing()
    {
        var now = DateTime.Now;
        var lines = new List<string>();
        var due = Store.Projects(false).Where(p => p.Deadline is { } d && d > now && (d - now).TotalDays < 7).ToList();
        if (due.Count > 0) lines.Add("Due this week: " + string.Join(", ", due.Select(p => $"{p.Name} {Text.Relative(p.Deadline!.Value)}")) + ".");
        var newFiles = Store.Files(2000).Count(f => (now - f.IndexedAt).TotalHours < 24);
        var filed = Store.EventCount(EventKind.fileMoved, now.AddDays(-1));
        lines.Add($"{Text.Plural(newFiles, "new file")} in the last day; I filed {filed}.");
        var review = Store.ReviewCount();
        if (review > 0) lines.Add($"{Text.Plural(review, "suggestion")} {(review == 1 ? "needs" : "need")} your OK.");
        if (Store.Insights().FirstOrDefault() is { } top) lines.Add($"Worth a look: {top.Title}.");
        if (Focus is { } f && Store.Project(f.ProjectId) is { } fp) lines.Add($"You’re in focus on {fp.Name} until {f.EndsAt:h:mm tt}.");
        var upcoming = Scheduler.Upcoming(3, 1);
        if (upcoming.Count > 0) lines.Add("Coming up: " + string.Join("; ", upcoming.Select(u => $"{u.name} at {u.at:h:mm tt}")) + ".");
        var raw = string.Join(" ", lines);
        if (await Llm.Provider() is { } p)
        {
            try { var s = await p.Complete("Rewrite this status into a warm, crisp spoken briefing of at most 4 sentences. Keep every fact. No preamble.", raw, 180); if (s.Trim().Length > 0) return s.Trim(); } catch { }
        }
        return raw;
    }

    // MARK: Jobs

    void EnqueueOnce(JobOperation op, string name, JobKind kind, JobPriority priority, JobSpec? spec = null)
    {
        if (Store.JobsWithStatus([JobStatus.queued, JobStatus.running, JobStatus.scheduled]).Any(j => j.Spec.Operation == op && j.Name == name)) return;
        Queue.Enqueue(new Job { Name = name, Kind = kind, Priority = priority, Spec = spec ?? new JobSpec { Operation = op } });
    }

    async Task<string> RunJob(Job job, JobContext ctx)
    {
        var spec = job.Spec;
        switch (spec.Operation)
        {
            case JobOperation.ingestFile:
                await Ingest(Paths.Expand(spec.Path ?? throw new Exception("no path")), TriggerKind.manual);
                return $"Processed {Path.GetFileName(spec.Path)}";
            case JobOperation.classifyFolder:
                {
                    var folder = Paths.Expand(spec.Path ?? throw new Exception("no folder"));
                    var n = 0;
                    foreach (var p in ListFiles(folder, true))
                    {
                        if (ctx.IsCancelled) break;
                        if (Store.FileByPath(p) is { Status: not FileStatus.missing } rec && Math.Abs((File.GetLastWriteTime(p) - rec.ModifiedAt).TotalSeconds) < 1) continue;
                        Index(p);
                        if (++n % 50 == 0) ctx.Log($"Indexed {n} files…");
                        if (Settings.BatteryAware && Monitor.Snapshot.ShouldThrottle) await Task.Delay(150);
                    }
                    return $"Indexed {n} new or changed files in {Paths.Abbreviate(folder)}";
                }
            case JobOperation.runRule:
                return await RunRuleNow(Store.Rule(spec.RuleId ?? "") ?? throw new Exception("rule not found"), ctx);
            case JobOperation.runActions:
                {
                    var rule = spec.RuleId != null ? Store.Rule(spec.RuleId) : null;
                    var actions = spec.Actions.Count == 0 ? rule?.Actions ?? [] : spec.Actions;
                    var batch = Ids.New();
                    var files = spec.Paths.Select(p => Store.FileByPath(Paths.Expand(p)) ?? Index(Paths.Expand(p))?.rec).Where(f => f != null).Select(f => f!).ToList();
                    List<string> msgs;
                    if (files.Count == 0)
                    {
                        var (_, outc) = await Executor.Run(actions, null, spec.Params, rule?.Id, job.Id, batch, Settings.DryRun);
                        msgs = outc.Select(o => o.Message).ToList();
                        if (outc.Count > 0 && outc.All(o => !o.Success)) throw new Exception(string.Join(" · ", msgs));
                    }
                    else
                    {
                        foreach (var f in files) { var (_, outc) = await Executor.Run(actions, f, spec.Params, rule?.Id, job.Id, batch, Settings.DryRun); ctx.Log($"{f.Name}: {string.Join(" · ", outc.Select(o => o.Message))}"); }
                        msgs = [$"Processed {files.Count} files"];
                    }
                    if (rule != null)
                    {
                        Store.RecordRuleHit(rule.Id);
                        Store.Log(new ActivityEvent { Kind = EventKind.ruleFired, Message = $"“{rule.Name}”: {string.Join(" · ", msgs)}", RuleId = rule.Id, JobId = job.Id, BatchId = batch });
                    }
                    msgs.ForEach(ctx.Log);
                    return string.Join(" · ", msgs);
                }
            case JobOperation.runCommand:
                {
                    var p = await Plan(spec.Command ?? throw new Exception("no command"));
                    if (!p.Understood) throw new Exception($"Couldn’t understand “{spec.Command}”");
                    var r = await Execute(p);
                    ctx.Log(r.Message);
                    Notify("Scheduled task finished", r.Message.Length > 140 ? r.Message[..140] : r.Message, false);
                    return r.Message;
                }
            case JobOperation.summarizeFolder: return await SummarizeFolder(Paths.Expand(spec.Path ?? "~/Downloads"));
            case JobOperation.generateReport: return await GenerateReport(spec.Params.GetValueOrDefault("type", "weekly"));
            case JobOperation.findDuplicates: return FindDuplicates(spec.Params.GetValueOrDefault("large") == "1");
            case JobOperation.archiveOld:
                {
                    var (_, outc) = await Executor.Run([new RuleAction(ActionKind.archiveOld, spec.Params.GetValueOrDefault("target", "~/Documents/Archive/{year}"), p: spec.Params)], null, jobId: job.Id, dryRun: Settings.DryRun);
                    return string.Join("", outc.Select(o => o.Message));
                }
            case JobOperation.sortFolder: return await SortFolder(Paths.Expand(spec.Path ?? "~/Downloads"), Ids.New());
            case JobOperation.scanInsights:
                Insights.Scan(Settings, Monitor.Snapshot);
                FlushProjectLinks();
                var ins = Store.Insights();
                if (ins.FirstOrDefault(i => i.Severity == Severity.critical) is { } critical) Notify(critical.Title, critical.Detail, true);
                return $"{Text.Plural(ins.Count, "active insight")}";
            case JobOperation.syncFolder:
                {
                    var (_, outc) = await Executor.Run([new RuleAction(ActionKind.syncFolder, spec.Params.GetValueOrDefault("target", ""), p: new() { ["source"] = spec.Path ?? "" })], null, jobId: job.Id);
                    if (outc.FirstOrDefault(o => !o.Success) is { } fail) throw new Exception(fail.Message);
                    return string.Join("", outc.Select(o => o.Message));
                }
            case JobOperation.runShell:
                {
                    if (!Settings.AllowScripts) throw new Exception("Scripts are off");
                    var (code, output) = Shell.PowerShell(spec.Command ?? "", false, []);
                    ctx.Log(output);
                    if (code != 0) throw new Exception($"exit {code}: {output[..Math.Min(200, output.Length)]}");
                    return output.Length == 0 ? "Done" : output[..Math.Min(200, output.Length)];
                }
            case JobOperation.learnTaxonomy:
                Taxonomy.Learn(Settings.LibraryRootsExpanded, cancelled: () => ctx.IsCancelled);
                return $"Learned {Taxonomy.Profiles.Count} folders";
            case JobOperation.prewarmProject:
                {
                    var pid = spec.Params.GetValueOrDefault("projectId") ?? throw new Exception("project not found");
                    var p = Store.Project(pid) ?? throw new Exception("project not found");
                    var n = 0;
                    foreach (var folder in p.Folders.Select(Paths.Expand))
                        foreach (var path in ListFiles(folder, true).Take(2000)) if (Store.FileByPath(path) == null) { Index(path); n++; }
                    var recent = Store.Files(15, pid);
                    foreach (var f in recent.Take(5).Where(f => f.Summary == null && f.Snippet.Length > 0)) { f.Summary = await Summarize(f); Store.UpsertFile(f); }
                    return $"Indexed {n} files, summarized {Math.Min(5, recent.Count)} recent files for {p.Name}";
                }
            default: throw new Exception($"Unsupported job {spec.Operation}");
        }
    }

    void SweepAgeRules()
    {
        if (Paused) return;
        foreach (var r in Store.Rules().Where(r => r.Enabled && r.Trigger.Kind.IsFileTrigger() && r.Conditions.Conditions.Any(c => c.Field == ConditionField.ageDays && c.Op == ConditionOp.greaterThan)))
            Queue.Enqueue(new Job { Name = $"Sweep: {r.Name}", Kind = JobKind.file, Priority = JobPriority.low, Spec = new JobSpec { Operation = JobOperation.runRule, RuleId = r.Id }, MaxAttempts = 1 });
    }

    void TakeSnapshots() => Task.Run(() =>
    {
        foreach (var folder in Settings.WatchedFoldersExpanded.Concat(Settings.LibraryRootsExpanded).Distinct(Paths.Comparer))
        {
            var (size, count) = Scheduler.FolderStats(folder);
            Store.SaveSnapshot(folder, size, count);
        }
    });

    void FlushProjectLinks()
    {
        List<(FileRecord, Project, double)> items;
        lock (stateLock) { items = [.. pendingProjectLinks]; pendingProjectLinks.Clear(); }
        if (items.Count > 0) Insights.SuggestProjectLinks(items);
    }

    void FlushDigest()
    {
        (int filed, int review) d;
        lock (stateLock) { d = digest; digest = (0, 0); }
        if (d.filed + d.review == 0) return;
        var parts = new List<string>();
        if (d.filed > 0) parts.Add($"Filed {Text.Plural(d.filed, "new file")}");
        if (d.review > 0) parts.Add($"{d.review} need{(d.review == 1 ? "s" : "")} a quick review");
        Notify("Nexus", string.Join(" · ", parts), false);
    }

    public List<string> ListFiles(string folder, bool recursive)
    {
        var outList = new List<string>();
        if (!Directory.Exists(folder)) return outList;
        try
        {
            if (!recursive)
            {
                foreach (var p in Directory.EnumerateFiles(folder))
                    if (ShouldProcess(p) && !new FileInfo(p).Attributes.HasFlag(FileAttributes.Hidden)) outList.Add(Paths.Canonical(p));
                return outList;
            }
            var stack = new Stack<string>([folder]);
            while (stack.Count > 0 && outList.Count < 20_000)
            {
                var dir = stack.Pop();
                try
                {
                    foreach (var p in Directory.EnumerateFiles(dir)) if (ShouldProcess(p) && !new FileInfo(p).Attributes.HasFlag(FileAttributes.Hidden)) outList.Add(Paths.Canonical(p));
                    foreach (var d in Directory.EnumerateDirectories(dir))
                    {
                        var n = Path.GetFileName(d);
                        if (n.StartsWith('.') || TaxonomyLearner.SkipDirs.Contains(n)) continue;
                        try { if (new DirectoryInfo(d).Attributes.HasFlag(FileAttributes.ReparsePoint)) continue; } catch { continue; }
                        stack.Push(d);
                    }
                }
                catch { }
            }
        }
        catch { }
        return outList;
    }

    public static readonly string[] Palette = ["#FF6B6B", "#FFA94D", "#FFD43B", "#69DB7C", "#38D9A9", "#4DABF7", "#748FFC", "#DA77F2", "#F783AC"];

    // MARK: IActionHost

    public void Notify(string title, string body, bool important)
    {
        if (!Settings.NotificationsEnabled) return;
        if (!important)
        {
            if (Focus is { } f) { f.Suppressed++; Store.SetKv("focus", Json.Str(f)); return; }
            var h = DateTime.Now.Hour;
            var quiet = Settings.QuietHoursStart > Settings.QuietHoursEnd ? h >= Settings.QuietHoursStart || h < Settings.QuietHoursEnd : h >= Settings.QuietHoursStart && h < Settings.QuietHoursEnd;
            if (quiet) return;
        }
        Notifier?.Invoke(title, body, important);
    }

    public Task<string> Summarize(FileRecord file)
    {
        var text = Store.FileContent(file.Id) ?? file.Snippet;
        return Llm.Summarize(text.Length == 0 ? file.Name : text, file.DocType ?? "file");
    }

    public void IndexCopy(string path) => Task.Run(() => Index(path));

    public string FindDuplicates(bool largeOnly)
    {
        var groups = Store.DuplicateHashes(largeOnly ? 50_000_000 : 1).Select(h => Store.FilesWithHash(h).Where(f => File.Exists(f.Path)).ToList()).Where(g => g.Count > 1).ToList();
        var wasted = groups.Sum(g => g.Skip(1).Sum(f => f.Size));
        if (groups.Count > 0)
            Store.UpsertInsight(new Insight
            {
                Key = "duplicates", Kind = InsightKind.duplicates, Title = $"{Text.Plural(groups.Count, "set")} of duplicate files wasting {Text.FormatBytes(wasted)}",
                Detail = string.Join("\n", groups.Take(6).Select(g => $"• {g[0].Name} ×{g.Count}")), Severity = Severity.suggestion, Command = "clean up duplicates",
                FilePaths = groups.SelectMany(g => g.Select(f => f.Path)).ToList(), Metric = wasted,
            });
        foreach (var root in Settings.LibraryRootsExpanded)
            EnqueueOnce(JobOperation.classifyFolder, $"Classify {Paths.Abbreviate(root)}", JobKind.ai, JobPriority.low, new JobSpec { Operation = JobOperation.classifyFolder, Path = root });
        return groups.Count == 0 ? "No duplicates found among indexed files (indexing your library in the background)"
            : $"Found {Text.Plural(groups.Count, "duplicate set")} ({Text.FormatBytes(wasted)} reclaimable). Say “clean up duplicates” to move the extra copies to the Recycle Bin.";
    }

    public Task<string> GenerateReport(string type)
    {
        var path = Reports.Save(type);
        Store.Log(new ActivityEvent { Kind = EventKind.system, Message = $"Generated {type} report → {Paths.Abbreviate(path)}" });
        Notify($"Your {type} report is ready", Path.GetFileName(path), false);
        return Task.FromResult($"Report saved: {Paths.Abbreviate(path)}");
    }

    public Project? ResolveProject(string name, bool create)
    {
        if (Store.ProjectNamed(name) is { } p && (p.Name.Equals(name, StringComparison.OrdinalIgnoreCase) || !create)) return p;
        if (!create || name.Trim().Length == 0) return null;
        var np = new Project { Name = name.Trim(), Color = Palette[Random.Shared.Next(Palette.Length)] };
        Store.SaveProject(np);
        Store.Log(new ActivityEvent { Kind = EventKind.system, Message = $"Created project {np.Name}" });
        RebuildProjectVectors();
        return np;
    }

    public void ScheduleReminder(string title, DateTime at) =>
        Store.SaveSchedule(new Schedule { Name = "Reminder: " + title, Mode = ScheduleMode.once, RunAt = at, NextRunAt = at, Job = new JobSpec { Operation = JobOperation.runActions, Actions = [new RuleAction(ActionKind.notify, "Reminder: " + title, p: new() { ["important"] = "1" })] }, NaturalLanguage = title });
}
