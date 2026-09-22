namespace Nexus.Core;

public enum FileKind { pdf, document, spreadsheet, presentation, text, code, image, screenshot, audio, video, archive, installer, cad, folder, other }
public enum FileStatus { indexed, filed, review, ignored, missing }
public enum EntityKind { person, organization, place, date, email, url, course, money }

public record Entity(EntityKind Kind, string Value);

public class FileRecord
{
    public string Id { get; set; } = Ids.New();
    public string Path { get; set; } = "";
    public FileKind Kind { get; set; } = FileKind.other;
    public long Size { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public DateTime ModifiedAt { get; set; } = DateTime.Now;
    public DateTime IndexedAt { get; set; } = DateTime.Now;
    public string? ContentHash { get; set; }
    public ulong? PerceptualHash { get; set; }
    public string? SourceUrl { get; set; }
    public string? DocType { get; set; }
    public double Confidence { get; set; }
    public string? Language { get; set; }
    public List<string> Topics { get; set; } = [];
    public List<Entity> Entities { get; set; } = [];
    public List<string> Tags { get; set; } = [];
    public string? ProjectId { get; set; }
    public string? Category { get; set; }
    public string Snippet { get; set; } = "";
    public string? Summary { get; set; }
    public FileStatus Status { get; set; } = FileStatus.indexed;

    public string Name => System.IO.Path.GetFileName(Path);
    public string Ext => System.IO.Path.GetExtension(Path).TrimStart('.').ToLowerInvariant();
    public string Folder => Paths.FolderOf(Path);
}

public class Project
{
    public string Id { get; set; } = Ids.New();
    public string Name { get; set; } = "";
    public List<string> Folders { get; set; } = [];
    public List<string> Keywords { get; set; } = [];
    public List<string> Tags { get; set; } = [];
    public string Color { get; set; } = "#39E2FF";
    public DateTime? Deadline { get; set; }
    public string Notes { get; set; } = "";
    public bool Archived { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public DateTime LastActivityAt { get; set; } = DateTime.Now;
}

public class Category
{
    public string Id { get; set; } = Ids.New();
    public string Name { get; set; } = "";
    public string Destination { get; set; } = "";
    public List<string> Keywords { get; set; } = [];
    public List<string> DocTypes { get; set; } = [];
    public bool Learned { get; set; }
}

// MARK: Jobs

public enum JobKind { file, ai, script, integration, system }
public enum JobStatus { scheduled, queued, running, completed, failed, cancelled }
public enum JobPriority { low = 0, normal = 1, high = 2, focus = 3 }
public enum JobOperation
{
    ingestFile, classifyFolder, runRule, runActions, runCommand, summarizeFolder, generateReport, findDuplicates,
    archiveOld, sortFolder, scanInsights, syncFolder, runShell, learnTaxonomy, prewarmProject
}

public class JobSpec
{
    public JobOperation Operation { get; set; }
    public string? Path { get; set; }
    public List<string> Paths { get; set; } = [];
    public string? RuleId { get; set; }
    public List<RuleAction> Actions { get; set; } = [];
    public string? Command { get; set; }
    public Dictionary<string, string> Params { get; set; } = [];
}

public class Job
{
    public string Id { get; set; } = Ids.New();
    public string Name { get; set; } = "";
    public JobKind Kind { get; set; } = JobKind.system;
    public JobPriority Priority { get; set; } = JobPriority.normal;
    public JobStatus Status { get; set; } = JobStatus.queued;
    public JobSpec Spec { get; set; } = new();
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public DateTime ScheduledFor { get; set; } = DateTime.Now;
    public DateTime? StartedAt { get; set; }
    public DateTime? FinishedAt { get; set; }
    public int Attempts { get; set; }
    public int MaxAttempts { get; set; } = 3;
    public double Progress { get; set; }
    public string? ResultSummary { get; set; }
    public string? Error { get; set; }
    public List<string> Log { get; set; } = [];
    public string? ScheduleId { get; set; }
}

public enum ScheduleMode { once, recurring, conditional }
public enum SystemConditionKind { folderCountAbove, folderSizeAboveGB, diskFreeBelowGB, hourAtLeast, idleMinutes, onACPower }
public record SystemCondition(SystemConditionKind Kind, string? Folder = null, double Number = 0);

public class Schedule
{
    public string Id { get; set; } = Ids.New();
    public string Name { get; set; } = "";
    public ScheduleMode Mode { get; set; } = ScheduleMode.once;
    public string? Cron { get; set; }
    public DateTime? RunAt { get; set; }
    public List<SystemCondition> Conditions { get; set; } = [];
    public JobKind JobKind { get; set; } = JobKind.system;
    public JobSpec Job { get; set; } = new();
    public JobPriority Priority { get; set; } = JobPriority.normal;
    public bool Enabled { get; set; } = true;
    public DateTime? LastRunAt { get; set; }
    public DateTime? NextRunAt { get; set; }
    public int CooldownMinutes { get; set; } = 60;
    public string? NaturalLanguage { get; set; }
}

// MARK: Activity & undo

public enum EventKind
{
    fileIndexed, fileMoved, fileCopied, fileRenamed, fileTagged, fileTrashed, ruleFired, jobStarted, jobCompleted, jobFailed,
    command, review, insight, focus, connector, system, error, guardTripped, undo
}
public enum UndoOp { move, copy, rename, tag, trash, createFolder, compress, projectLink }

public class UndoRecord
{
    public UndoOp Op { get; set; }
    public string? From { get; set; }
    public string? To { get; set; }
    public string? FileId { get; set; }
    public List<string> Tags { get; set; } = [];
    public string? ProjectId { get; set; }
    public string? Token { get; set; }
}

public class ActivityEvent
{
    public string Id { get; set; } = Ids.New();
    public EventKind Kind { get; set; }
    public string Message { get; set; } = "";
    public DateTime Timestamp { get; set; } = DateTime.Now;
    public string? FileId { get; set; }
    public string? RuleId { get; set; }
    public string? JobId { get; set; }
    public string? BatchId { get; set; }
    public UndoRecord? Undo { get; set; }
    public bool Undone { get; set; }
}

// MARK: Insights & review

public enum InsightKind { duplicates, similarScreenshots, staleDownloads, largeFiles, lowDisk, inactiveProject, deadlineSoon, habit, conflicts, projectLink, timeSaved, folderGrowth }
public enum Severity { info, suggestion, warning, critical }

public class Insight
{
    public string Id { get; set; } = Ids.New();
    public string Key { get; set; } = "";
    public InsightKind Kind { get; set; }
    public string Title { get; set; } = "";
    public string Detail { get; set; } = "";
    public Severity Severity { get; set; } = Severity.info;
    public string? Command { get; set; }
    public string? RuleText { get; set; }
    public List<string> FilePaths { get; set; } = [];
    public double Metric { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public bool Dismissed { get; set; }
}

public enum ReviewStatus { pending, approved, rejected }

public class ReviewItem
{
    public string Id { get; set; } = Ids.New();
    public string FileId { get; set; } = "";
    public string Path { get; set; } = "";
    public string? SuggestedDestination { get; set; }
    public List<string> SuggestedTags { get; set; } = [];
    public string? SuggestedProjectId { get; set; }
    public string? SuggestedCategory { get; set; }
    public double Confidence { get; set; }
    public List<string> Reasons { get; set; } = [];
    public List<string> Alternatives { get; set; } = [];
    public string? RuleId { get; set; }
    public ReviewStatus Status { get; set; } = ReviewStatus.pending;
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public DateTime? ResolvedAt { get; set; }
}

public record ObservedMove(string FromFolder, string ToFolder, string Ext, List<string> Keywords, DateTime At);

public class FocusSession
{
    public string ProjectId { get; set; } = "";
    public DateTime StartedAt { get; set; } = DateTime.Now;
    public DateTime EndsAt { get; set; } = DateTime.Now;
    public string Source { get; set; } = "manual";
    public int Suppressed { get; set; }
}

public enum EngineStatus { idle, working, attention, paused }

// MARK: Rules

public enum TriggerKind
{
    fileAdded, fileModified, downloadCompleted, schedule, manual, appLaunched, appQuit, volumeMounted, volumeUnmounted,
    diskSpaceBelow, folderCountAbove, folderSizeAbove, idle, wake, focusStarted, focusEnded, connectorEvent
}

public static class TriggerKindExt
{
    public static bool IsFileTrigger(this TriggerKind k) => k is TriggerKind.fileAdded or TriggerKind.fileModified or TriggerKind.downloadCompleted;
    public static string Label(this TriggerKind k) => k switch
    {
        TriggerKind.fileAdded => "New file in folder", TriggerKind.fileModified => "File changed", TriggerKind.downloadCompleted => "Download finished",
        TriggerKind.schedule => "Time / schedule", TriggerKind.manual => "Manually / on demand", TriggerKind.appLaunched => "App opened",
        TriggerKind.appQuit => "App closed", TriggerKind.volumeMounted => "Drive connected", TriggerKind.volumeUnmounted => "Drive ejected",
        TriggerKind.diskSpaceBelow => "Disk space low", TriggerKind.folderCountAbove => "Folder file count above", TriggerKind.folderSizeAbove => "Folder size above",
        TriggerKind.idle => "PC idle", TriggerKind.wake => "PC woke up", TriggerKind.focusStarted => "Focus started", TriggerKind.focusEnded => "Focus ended",
        _ => "Connector event"
    };
}

public class Trigger
{
    public TriggerKind Kind { get; set; } = TriggerKind.fileAdded;
    public List<string> Folders { get; set; } = [];
    public bool Recursive { get; set; }
    public string? Cron { get; set; }
    public string? AppName { get; set; }
    public string? VolumeName { get; set; }
    public double? Threshold { get; set; }
    public string? ConnectorEvent { get; set; }

    public Trigger() { }
    public Trigger(TriggerKind kind) { Kind = kind; }

    public string Summary => Kind switch
    {
        _ when Kind.IsFileTrigger() => $"{Kind.Label()}: {(Folders.Count == 0 ? "any watched folder" : string.Join(", ", Folders.Select(Paths.Abbreviate)))}",
        TriggerKind.schedule => $"Schedule: {(Cron != null ? CronExpression.Describe(Cron) : "—")}",
        TriggerKind.appLaunched or TriggerKind.appQuit => $"{Kind.Label()}: {AppName ?? "any"}",
        TriggerKind.volumeMounted or TriggerKind.volumeUnmounted => $"{Kind.Label()}: {VolumeName ?? "any"}",
        TriggerKind.diskSpaceBelow => $"Disk free < {(int)(Threshold ?? 25)} GB",
        TriggerKind.folderCountAbove => $"{(Folders.Count > 0 ? Paths.Abbreviate(Folders[0]) : "folder")} has > {(int)(Threshold ?? 50)} files",
        TriggerKind.folderSizeAbove => $"{(Folders.Count > 0 ? Paths.Abbreviate(Folders[0]) : "folder")} > {(int)(Threshold ?? 10)} GB",
        TriggerKind.idle => $"Idle for {(int)(Threshold ?? 15)} min",
        TriggerKind.connectorEvent => $"Connector: {ConnectorEvent ?? "—"}",
        _ => Kind.Label()
    };
}

public enum ConditionField { name, ext, kind, content, anyText, sizeMB, ageDays, folder, docType, language, tag, project, topic, entity, sourceURL, hour, weekday }
public enum ConditionOp { contains, notContains, equals, notEquals, startsWith, endsWith, matches, greaterThan, lessThan, isAnyOf, exists }

public static class ConditionLabels
{
    public static string Label(this ConditionField f) => f switch
    {
        ConditionField.name => "Filename", ConditionField.ext => "Extension", ConditionField.kind => "File type", ConditionField.content => "Content",
        ConditionField.anyText => "Name or content", ConditionField.sizeMB => "Size (MB)", ConditionField.ageDays => "Age (days)", ConditionField.folder => "Folder",
        ConditionField.docType => "Document type", ConditionField.language => "Code language", ConditionField.tag => "Tag", ConditionField.project => "Project",
        ConditionField.topic => "Topic", ConditionField.entity => "Mentions", ConditionField.sourceURL => "Downloaded from", ConditionField.hour => "Hour of day",
        _ => "Weekday (1=Sun)"
    };
    public static string Label(this ConditionOp o) => o switch
    {
        ConditionOp.contains => "contains", ConditionOp.notContains => "does not contain", ConditionOp.equals => "is", ConditionOp.notEquals => "is not",
        ConditionOp.startsWith => "starts with", ConditionOp.endsWith => "ends with", ConditionOp.matches => "matches regex", ConditionOp.greaterThan => ">",
        ConditionOp.lessThan => "<", ConditionOp.isAnyOf => "is any of", _ => "is set"
    };
}

public class Condition
{
    public string Id { get; set; } = Ids.New();
    public ConditionField Field { get; set; }
    public ConditionOp Op { get; set; }
    public string Value { get; set; } = "";
    public Condition() { }
    public Condition(ConditionField field, ConditionOp op, string value) { Field = field; Op = op; Value = value; }
    public string Summary => Op == ConditionOp.exists ? $"{Field.Label()} is set" : $"{Field.Label()} {Op.Label()} “{Value}”";
}

public enum MatchMode { all, any }

public class ConditionGroup
{
    public MatchMode Match { get; set; } = MatchMode.all;
    public List<Condition> Conditions { get; set; } = [];
}

public enum ActionKind
{
    move, copy, rename, tag, removeTag, addToProject, createProject, setCategory, trash, compress, createFolder,
    notify, createTask, createReminder, createCalendarEvent, summarize, openFile, revealInFinder,
    runShell, runAppleScript, runShortcut, runPlugin, webhook, syncFolder, archiveOld, sortFolder, findDuplicates, generateReport,
    githubIssue, obsidianNote, slackMessage, notionPage
}

public static class ActionKindExt
{
    public static string Label(this ActionKind k) => k switch
    {
        ActionKind.move => "Move to", ActionKind.copy => "Copy to", ActionKind.rename => "Rename", ActionKind.tag => "Add tags", ActionKind.removeTag => "Remove tags",
        ActionKind.addToProject => "Add to project", ActionKind.createProject => "Create / update project", ActionKind.setCategory => "Set category",
        ActionKind.trash => "Move to Recycle Bin", ActionKind.compress => "Compress (zip)", ActionKind.createFolder => "Create folder", ActionKind.notify => "Send notification",
        ActionKind.createTask => "Create Nexus task", ActionKind.createReminder => "Create reminder", ActionKind.createCalendarEvent => "Create calendar event",
        ActionKind.summarize => "Summarize (AI)", ActionKind.openFile => "Open file", ActionKind.revealInFinder => "Show in File Explorer",
        ActionKind.runShell => "Run PowerShell script", ActionKind.runAppleScript => "Run script", ActionKind.runShortcut => "Run shortcut", ActionKind.runPlugin => "Run plugin",
        ActionKind.webhook => "Call webhook", ActionKind.syncFolder => "Sync folder to", ActionKind.archiveOld => "Archive old files", ActionKind.sortFolder => "Auto-sort folder",
        ActionKind.findDuplicates => "Find duplicates", ActionKind.generateReport => "Generate report", ActionKind.githubIssue => "Create GitHub issue",
        ActionKind.obsidianNote => "Append Obsidian note", ActionKind.slackMessage => "Post to Slack", _ => "Create Notion page"
    };
    public static bool IsFileScoped(this ActionKind k) => k is ActionKind.move or ActionKind.copy or ActionKind.rename or ActionKind.tag or ActionKind.removeTag
        or ActionKind.addToProject or ActionKind.setCategory or ActionKind.trash or ActionKind.compress or ActionKind.summarize or ActionKind.openFile or ActionKind.revealInFinder;
    public static bool IsMutating(this ActionKind k) => k is ActionKind.move or ActionKind.copy or ActionKind.rename or ActionKind.trash or ActionKind.compress
        or ActionKind.syncFolder or ActionKind.archiveOld or ActionKind.sortFolder;
}

public class RuleAction
{
    public string Id { get; set; } = Ids.New();
    public ActionKind Kind { get; set; }
    public string Target { get; set; } = "";
    public List<string> Tags { get; set; } = [];
    public string? Project { get; set; }
    public Dictionary<string, string> Params { get; set; } = [];
    public RuleAction() { }
    public RuleAction(ActionKind kind, string target = "", List<string>? tags = null, string? project = null, Dictionary<string, string>? p = null)
    { Kind = kind; Target = target; Tags = tags ?? []; Project = project; Params = p ?? []; }

    public string Summary => Kind switch
    {
        ActionKind.tag or ActionKind.removeTag => $"{Kind.Label()}: {string.Join(' ', Tags.Select(t => "#" + t))}",
        ActionKind.addToProject => $"Add to project “{Project ?? Target}”",
        ActionKind.move or ActionKind.copy or ActionKind.syncFolder => $"{Kind.Label()} {Paths.Abbreviate(Target)}",
        ActionKind.archiveOld => $"Archive files older than {Params.GetValueOrDefault("days", "30")} days → {Paths.Abbreviate(Target)}",
        ActionKind.rename => $"Rename to {Target}",
        _ => string.IsNullOrEmpty(Target) ? Kind.Label() : $"{Kind.Label()}: {Target}"
    };
}

public class Rule
{
    public string Id { get; set; } = Ids.New();
    public string Name { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public Trigger Trigger { get; set; } = new();
    public ConditionGroup Conditions { get; set; } = new();
    public List<RuleAction> Actions { get; set; } = [];
    public int Priority { get; set; } = 50;
    public bool StopProcessing { get; set; }
    public bool RequireConfirmation { get; set; }
    public int CooldownMinutes { get; set; }
    public string? NaturalLanguage { get; set; }
    public string? ProjectId { get; set; }
    public int HitCount { get; set; }
    public DateTime? LastTriggeredAt { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public int EstimatedSecondsSaved { get; set; } = 20;

    public string Summary
    {
        get
        {
            var conds = string.Join(Conditions.Match == MatchMode.all ? " AND " : " OR ", Conditions.Conditions.Select(c => c.Summary));
            var acts = string.Join(" → ", Actions.Select(a => a.Summary));
            return $"{Trigger.Summary}{(conds.Length == 0 ? "" : " · if " + conds)} → {acts}";
        }
    }
}

// MARK: Settings

public enum LlmProvider { auto, bundled, ollama, off }

public class NexusSettings
{
    public List<string> WatchedFolders { get; set; } = ["~/Downloads", "~/Desktop", "~/Pictures/Screenshots"];
    public List<string> LibraryRoots { get; set; } = ["~/Documents"];
    public bool AutopilotEnabled { get; set; } = true;
    public double AutoThreshold { get; set; } = 0.85;
    public double ReviewThreshold { get; set; } = 0.55;
    public bool AutoRemoveDuplicates { get; set; } = true;
    public bool DryRun { get; set; }
    public bool EnableOcr { get; set; } = true;
    public int MaxExtractKB { get; set; } = 512;
    public int MaxOpsPerMinute { get; set; } = 120;
    public bool BatteryAware { get; set; } = true;
    public bool NotificationsEnabled { get; set; } = true;
    public int QuietHoursStart { get; set; } = 22;
    public int QuietHoursEnd { get; set; } = 7;
    public int DigestHour { get; set; } = 9;
    public int DigestWeekday { get; set; } = 1;
    public bool ApiEnabled { get; set; } = true;
    public int ApiPort { get; set; } = 7788;
    public bool RemoteEnabled { get; set; }
    public LlmProvider LlmProvider { get; set; } = LlmProvider.auto;
    public string OllamaModel { get; set; } = "llama3.2";
    public string OllamaUrl { get; set; } = "http://127.0.0.1:11434";
    public string LocalModelPath { get; set; } = "";
    public string PaletteHotkey { get; set; } = "Ctrl+Alt+N";
    public string VoiceHotkey { get; set; } = "Ctrl+Alt+Space";
    public bool VoiceAutoSubmit { get; set; } = true;
    public bool SpeakResponses { get; set; } = true;
    public string Hotbar { get; set; } = "floating";   // floating | hidden
    public string Appearance { get; set; } = "system";  // system | dark | light
    public bool OnboardingComplete { get; set; }
    public bool LaunchAtLogin { get; set; } = true;
    public List<string> IgnoredPatterns { get; set; } = ["desktop.ini", "Thumbs.db", "*.crdownload", "*.part", "*.tmp", "~$*", "*.partial", "*.download", ".~lock*"];
    public int InactiveProjectDays { get; set; } = 30;
    public int LowDiskGB { get; set; } = 25;
    public string GithubRepo { get; set; } = "";
    public string ObsidianVault { get; set; } = "";
    public string SlackWebhook { get; set; } = "";
    public bool AllowScripts { get; set; }

    public List<string> WatchedFoldersExpanded => WatchedFolders.Select(Paths.Expand).ToList();
    public List<string> LibraryRootsExpanded => LibraryRoots.Select(Paths.Expand).ToList();
}
