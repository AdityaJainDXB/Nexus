using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Json;
using System.Text;

namespace Nexus.Core;

/// Services the executor needs from the engine (keeps it testable).
public interface IActionHost
{
    NexusSettings Settings { get; }
    void Notify(string title, string body, bool important);
    Task<string> Summarize(FileRecord file);
    void IndexCopy(string path);
    Task<string> SortFolder(string path, string batchId);
    string FindDuplicates(bool largeOnly);
    Task<string> GenerateReport(string type);
    Project? ResolveProject(string name, bool create);
    void Pause(string reason);
    void ScheduleReminder(string title, DateTime at);
}

public record ActionOutcome(RuleAction Action, bool Success, string Message);

/// Sliding-window circuit breaker: a buggy rule can't move 10,000 files in a loop.
public class RunawayGuard(int limitPerMinute)
{
    readonly List<DateTime> stamps = [];
    public int LimitPerMinute { get; set; } = limitPerMinute;
    public bool Allow(int n = 1)
    {
        lock (stamps)
        {
            var cutoff = DateTime.Now.AddMinutes(-1);
            stamps.RemoveAll(s => s < cutoff);
            if (stamps.Count + n > LimitPerMinute) return false;
            for (var i = 0; i < n; i++) stamps.Add(DateTime.Now);
            return true;
        }
    }
}

public class ActionExecutor(NexusStore store, RunawayGuard guardrail)
{
    public IActionHost? Host { get; set; }
    public RunawayGuard Guardrail { get; } = guardrail;
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    class Failure(string message) : Exception(message);

    /// Runs actions sequentially; file-scoped actions follow the file (a move then a tag tags the moved file).
    public async Task<(FileRecord? file, List<ActionOutcome> outcomes)> Run(IEnumerable<RuleAction> actions, FileRecord? initial, Dictionary<string, string>? info = null,
        string? ruleId = null, string? jobId = null, string? batchId = null, bool dryRun = false)
    {
        batchId ??= Ids.New();
        info ??= [];
        var file = initial;
        var outcomes = new List<ActionOutcome>();
        foreach (var action in actions)
        {
            if (action.Kind.IsFileScoped() && file == null && action.Kind is not (ActionKind.openFile or ActionKind.revealInFinder))
            {
                outcomes.Add(new(action, false, "Skipped: no file in context")); continue;
            }
            var projectName = file?.ProjectId is { } pid ? store.Project(pid)?.Name : null;
            if (dryRun) { outcomes.Add(new(action, true, "Would " + Templates.Describe(action, file, projectName).ToLowerInvariant())); continue; }
            if (action.Kind.IsMutating() && !Guardrail.Allow())
            {
                var msg = $"Runaway guard: more than {Guardrail.LimitPerMinute} file operations in a minute. Automations paused.";
                Host?.Pause(msg);
                store.Log(new ActivityEvent { Kind = EventKind.guardTripped, Message = msg, RuleId = ruleId, JobId = jobId, BatchId = batchId });
                outcomes.Add(new(action, false, msg));
                break;
            }
            try
            {
                var (msg, after) = await Perform(action, file, projectName, info, ruleId, jobId, batchId);
                file = after;
                outcomes.Add(new(action, true, msg));
            }
            catch (Exception ex)
            {
                var message = ex is Failure ? ex.Message : ex.Message.Replace(Paths.Home, "~");
                outcomes.Add(new(action, false, message));
                store.Log(new ActivityEvent { Kind = EventKind.error, Message = $"{action.Kind.Label()} failed: {message}", FileId = file?.Id, RuleId = ruleId, JobId = jobId, BatchId = batchId });
                if (action.Kind.IsMutating()) break;
            }
        }
        return (file, outcomes);
    }

    static void CheckWritable(params string[] paths)
    {
        foreach (var p in paths)
            if (Paths.IsProtected(p) && !Paths.IsInside(p, Paths.AppSupport)) throw new Failure($"{Paths.Abbreviate(p)} is a protected location");
    }

    /// "vol:Backup\Nexus Sync\Docs" → "E:\Nexus Sync\Docs" when a drive labelled Backup is connected.
    public static string ResolveVolume(string target)
    {
        if (!target.StartsWith("vol:")) return target;
        var rest = target[4..];
        var sep = rest.IndexOfAny(['\\', '/']);
        var label = sep < 0 ? rest : rest[..sep];
        var tail = sep < 0 ? "" : rest[(sep + 1)..];
        var drive = DriveInfo.GetDrives().FirstOrDefault(d => { try { return d.IsReady && d.VolumeLabel.Equals(label, StringComparison.OrdinalIgnoreCase); } catch { return false; } })
            ?? throw new Failure($"The drive “{label}” isn't connected");
        return Path.Combine(drive.RootDirectory.FullName, tail);
    }

    async Task<(string, FileRecord?)> Perform(RuleAction a, FileRecord? file, string? projectName, Dictionary<string, string> info, string? ruleId, string? jobId, string batchId)
    {
        string Expand(string s) => Templates.Expand(s, file, projectName, info);
        void Log(EventKind kind, string msg, UndoRecord? undo = null) =>
            store.Log(new ActivityEvent { Kind = kind, Message = msg, FileId = file?.Id, RuleId = ruleId, JobId = jobId, BatchId = batchId, Undo = undo });

        switch (a.Kind)
        {
            case ActionKind.move or ActionKind.copy:
                {
                    var f = file ?? throw new Failure("no file");
                    var destFolder = ResolveVolume(Expand(a.Target));
                    if (string.IsNullOrWhiteSpace(destFolder)) throw new Failure("no destination");
                    destFolder = Paths.Canonical(destFolder);
                    if (a.Kind == ActionKind.move) CheckWritable(f.Path, destFolder); else CheckWritable(destFolder);
                    if (!File.Exists(f.Path) && !Directory.Exists(f.Path)) throw new Failure($"{f.Name} no longer exists");
                    if (a.Kind == ActionKind.move && Paths.Same(f.Folder, destFolder)) return ($"Already in {Paths.Abbreviate(destFolder)}", f);
                    Directory.CreateDirectory(destFolder);
                    var dest = Paths.UniquePath(Path.Combine(destFolder, f.Name));
                    if (a.Kind == ActionKind.move)
                    {
                        var from = f.Path;
                        if (Directory.Exists(from)) Directory.Move(from, dest); else File.Move(from, dest);
                        f.Path = dest; f.Status = FileStatus.filed;
                        store.UpsertFile(f);
                        Log(EventKind.fileMoved, $"Moved {f.Name} → {Paths.Abbreviate(destFolder)}", new UndoRecord { Op = UndoOp.move, From = from, To = dest, FileId = f.Id });
                        return ($"Moved to {Paths.Abbreviate(destFolder)}", f);
                    }
                    File.Copy(f.Path, dest);
                    Host?.IndexCopy(dest);
                    Log(EventKind.fileCopied, $"Copied {f.Name} → {Paths.Abbreviate(destFolder)}", new UndoRecord { Op = UndoOp.copy, To = dest });
                    return ($"Copied to {Paths.Abbreviate(destFolder)}", f);
                }
            case ActionKind.rename:
                {
                    var f = file ?? throw new Failure("no file");
                    CheckWritable(f.Path);
                    var newName = System.Text.RegularExpressions.Regex.Replace(Expand(a.Target), @"[\\/:*?""<>|]", "-").Trim();
                    if (newName.Length == 0) throw new Failure("empty name");
                    if (!Path.HasExtension(newName) && f.Ext.Length > 0) newName += "." + f.Ext;
                    if (newName == f.Name) return ("Name unchanged", f);
                    var dest = Paths.UniquePath(Path.Combine(f.Folder, newName));
                    var from = f.Path;
                    File.Move(from, dest);
                    f.Path = dest; store.UpsertFile(f);
                    Log(EventKind.fileRenamed, $"Renamed {Path.GetFileName(from)} → {f.Name}", new UndoRecord { Op = UndoOp.rename, From = from, To = dest, FileId = f.Id });
                    return ($"Renamed to {f.Name}", f);
                }
            case ActionKind.tag or ActionKind.removeTag:
                {
                    var f = file ?? throw new Failure("no file");
                    var tags = a.Tags.Select(Expand).Where(t => t.Length > 0).ToList();
                    List<string> changed;
                    if (a.Kind == ActionKind.tag)
                    {
                        changed = tags.Where(t => !f.Tags.Contains(t, StringComparer.OrdinalIgnoreCase)).ToList();
                        f.Tags.AddRange(changed);
                    }
                    else
                    {
                        changed = f.Tags.Where(t => tags.Contains(t, StringComparer.OrdinalIgnoreCase)).ToList();
                        f.Tags.RemoveAll(t => changed.Contains(t));
                    }
                    store.UpsertFile(f);
                    if (changed.Count > 0)
                        Log(EventKind.fileTagged, $"{(a.Kind == ActionKind.tag ? "Tagged" : "Untagged")} {f.Name}: {string.Join(' ', changed.Select(t => "#" + t))}",
                            new UndoRecord { Op = UndoOp.tag, FileId = f.Id, Tags = changed, From = a.Kind == ActionKind.tag ? "add" : "remove" });
                    return (changed.Count == 0 ? "Tags unchanged" : $"Tags: {string.Join(' ', changed.Select(t => "#" + t))}", f);
                }
            case ActionKind.addToProject or ActionKind.createProject:
                {
                    var name = Expand(a.Project ?? a.Target).Trim();
                    if (name.Length == 0 || name == "{title}") name = info.GetValueOrDefault("title", file?.Name ?? "New project");
                    var p = Host?.ResolveProject(name, true) ?? throw new Failure("project unavailable");
                    if (a.Kind == ActionKind.createProject && a.Params.TryGetValue("tags", out var tagT))
                    {
                        var t = Expand(tagT); if (t.Length > 0 && !t.Contains('{') && !p.Tags.Contains(t)) { p.Tags.Add(t); store.SaveProject(p); }
                    }
                    if (file == null) return ($"Project “{p.Name}” ready", file);
                    var previous = file.ProjectId;
                    file.ProjectId = p.Id; store.UpsertFile(file);
                    p.LastActivityAt = DateTime.Now; store.SaveProject(p);
                    Log(EventKind.fileTagged, $"Added {file.Name} to {p.Name}", new UndoRecord { Op = UndoOp.projectLink, FileId = file.Id, ProjectId = previous });
                    return ($"Added to {p.Name}", file);
                }
            case ActionKind.setCategory:
                {
                    var f = file ?? throw new Failure("no file");
                    f.Category = Expand(a.Target); store.UpsertFile(f);
                    return ($"Category: {f.Category}", f);
                }
            case ActionKind.trash:
                {
                    var f = file ?? throw new Failure("no file");
                    CheckWritable(f.Path);
                    if (!File.Exists(f.Path)) throw new Failure($"{f.Name} no longer exists");
                    var original = f.Path;
                    var token = Platform.Current.Trash(original);
                    f.Status = FileStatus.missing; store.UpsertFile(f);
                    Log(EventKind.fileTrashed, $"Moved {f.Name} to the Recycle Bin", new UndoRecord { Op = UndoOp.trash, From = original, Token = token, FileId = f.Id });
                    return ("Moved to the Recycle Bin", f);
                }
            case ActionKind.compress:
                {
                    var f = file ?? throw new Failure("no file");
                    CheckWritable(f.Folder);
                    var zip = Paths.UniquePath(Path.Combine(f.Folder, Path.GetFileNameWithoutExtension(f.Name) + ".zip"));
                    using (var z = ZipFile.Open(zip, ZipArchiveMode.Create)) z.CreateEntryFromFile(f.Path, f.Name, CompressionLevel.Optimal);
                    Log(EventKind.fileCopied, $"Compressed {f.Name}", new UndoRecord { Op = UndoOp.compress, To = zip });
                    Host?.IndexCopy(zip);
                    return ($"Created {Path.GetFileName(zip)}", f);
                }
            case ActionKind.createFolder:
                {
                    var folder = ResolveVolume(Expand(a.Target));
                    CheckWritable(folder);
                    if (Directory.Exists(folder)) return ($"{Paths.Abbreviate(folder)} exists", file);
                    Directory.CreateDirectory(folder);
                    Log(EventKind.system, $"Created folder {Paths.Abbreviate(folder)}", new UndoRecord { Op = UndoOp.createFolder, To = folder });
                    return ($"Created {Paths.Abbreviate(folder)}", file);
                }
            case ActionKind.notify:
                Host?.Notify("Nexus", Expand(string.IsNullOrEmpty(a.Target) ? "{name} was processed" : a.Target), a.Params.ContainsKey("important"));
                return ("Notified", file);
            case ActionKind.createTask or ActionKind.createReminder:
                {
                    var title = Expand(string.IsNullOrEmpty(a.Target) ? "Review {name}" : a.Target).Replace("{title}", info.GetValueOrDefault("title", ""));
                    var due = a.Params.GetValueOrDefault("due", "1d");
                    var days = int.TryParse(due.TrimEnd('d'), out var dd) ? dd : 1;
                    var at = DateTime.Today.AddDays(days).AddHours(9);
                    Host?.ScheduleReminder(title, at);
                    return ($"Reminder “{title}” {at:ddd h tt}", file);
                }
            case ActionKind.createCalendarEvent:
                {
                    var title = Expand(a.Target);
                    var date = file?.Entities.Where(e => e.Kind == EntityKind.date).Select(e => DateTime.TryParse(e.Value, out var d) ? d : (DateTime?)null)
                        .Where(d => d > DateTime.Now).Min() ?? DateTime.Today.AddDays(1);
                    var dir = Path.Combine(Paths.AppSupport, "Calendar"); Directory.CreateDirectory(dir);
                    var ics = Path.Combine(dir, $"{Ids.New()[..8]}.ics");
                    await File.WriteAllTextAsync(ics, $"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Nexus//EN\r\nBEGIN:VEVENT\r\nUID:{Ids.New()}\r\nDTSTAMP:{DateTime.UtcNow:yyyyMMdd'T'HHmmss'Z'}\r\nDTSTART;VALUE=DATE:{date:yyyyMMdd}\r\nSUMMARY:{title.Replace(",", "\\,")}\r\nDESCRIPTION:{(file?.Path ?? "").Replace("\\", "\\\\")}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n");
                    Platform.Current.Open(ics);
                    return ($"Calendar event “{title}” on {date:MMM d}", file);
                }
            case ActionKind.summarize:
                {
                    var f = file ?? throw new Failure("no file");
                    f.Summary = Host == null ? null : await Host.Summarize(f);
                    store.UpsertFile(f);
                    return ("Summarized", f);
                }
            case ActionKind.openFile:
                Platform.Current.Open(string.IsNullOrEmpty(a.Target) ? file?.Path ?? "" : Expand(a.Target));
                return ("Opened", file);
            case ActionKind.revealInFinder:
                Platform.Current.Reveal(string.IsNullOrEmpty(a.Target) ? file?.Path ?? "" : Expand(a.Target));
                return ("Shown in File Explorer", file);
            case ActionKind.runShell or ActionKind.runAppleScript or ActionKind.runShortcut or ActionKind.runPlugin:
                {
                    if (Host?.Settings.AllowScripts != true) throw new Failure("Scripts are off — enable them in Settings → Automation");
                    var script = a.Kind == ActionKind.runPlugin ? Path.Combine(Paths.AppSupport, "Plugins", a.Target.EndsWith(".ps1") ? a.Target : a.Target + ".ps1") : Expand(a.Target);
                    var (code, output) = Shell.PowerShell(script, a.Kind == ActionKind.runPlugin, new Dictionary<string, string>
                    {
                        ["NEXUS_FILE"] = file?.Path ?? "", ["NEXUS_NAME"] = file?.Name ?? "", ["NEXUS_TAGS"] = string.Join(",", file?.Tags ?? []),
                    });
                    Log(EventKind.system, $"Script finished ({code}): {output[..Math.Min(120, output.Length)]}");
                    if (code != 0) throw new Failure($"exit {code}: {output[..Math.Min(200, output.Length)]}");
                    return (output.Length == 0 ? "Script finished" : output[..Math.Min(200, output.Length)], file);
                }
            case ActionKind.webhook or ActionKind.slackMessage:
                {
                    var url = a.Kind == ActionKind.slackMessage ? Host?.Settings.SlackWebhook ?? "" : Expand(a.Target);
                    if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https" && uri.Host != "127.0.0.1" && uri.Host != "localhost") throw new Failure("A valid https webhook URL is required");
                    object payload = a.Kind == ActionKind.slackMessage ? new { text = Expand(a.Target) } : new { file = file?.Path, name = file?.Name, tags = file?.Tags, docType = file?.DocType, rule = ruleId, info };
                    var r = await Http.PostAsJsonAsync(uri, payload, Json.Options);
                    if (!r.IsSuccessStatusCode) throw new Failure($"Webhook returned {(int)r.StatusCode}");
                    return ("Webhook called", file);
                }
            case ActionKind.githubIssue:
                {
                    var repo = Host?.Settings.GithubRepo ?? "";
                    var token = Secrets.Get("github.token");
                    if (repo.Length == 0 || token == null) throw new Failure("Connect GitHub in Connectors first");
                    using var req = new HttpRequestMessage(HttpMethod.Post, $"https://api.github.com/repos/{repo}/issues")
                    { Content = JsonContent.Create(new { title = Expand(a.Target), body = $"Created by Nexus from {file?.Name}" }) };
                    req.Headers.Add("Authorization", "Bearer " + token); req.Headers.Add("User-Agent", "Nexus");
                    var r = await Http.SendAsync(req);
                    if (!r.IsSuccessStatusCode) throw new Failure($"GitHub returned {(int)r.StatusCode}");
                    return ("GitHub issue created", file);
                }
            case ActionKind.obsidianNote:
                {
                    var vault = Host?.Settings.ObsidianVault ?? "";
                    if (vault.Length == 0) throw new Failure("Choose your Obsidian vault in Connectors first");
                    var note = Path.Combine(Paths.Expand(vault), Expand(string.IsNullOrEmpty(a.Target) ? "Nexus/Inbox.md" : a.Target));
                    Directory.CreateDirectory(Path.GetDirectoryName(note)!);
                    await File.AppendAllTextAsync(note, $"\n- {DateTime.Now:yyyy-MM-dd HH:mm} [[{file?.Name}]] {string.Join(' ', (file?.Tags ?? []).Select(t => "#" + t))}\n");
                    return ("Appended to Obsidian", file);
                }
            case ActionKind.notionPage:
                throw new Failure("Notion isn't available in Nexus for Windows yet");
            case ActionKind.syncFolder:
                {
                    var source = Paths.Expand(a.Params.GetValueOrDefault("source", ""));
                    var target = ResolveVolume(a.Target);
                    if (!Directory.Exists(source)) throw new Failure($"{Paths.Abbreviate(source)} not found");
                    CheckWritable(target);
                    var (copied, bytes) = SyncFolder(source, target);
                    Log(EventKind.fileCopied, $"Synced {Paths.Abbreviate(source)} → {target}: {copied} files ({Text.FormatBytes(bytes)})");
                    return ($"Synced {copied} changed file{(copied == 1 ? "" : "s")} to {target}", file);
                }
            case ActionKind.archiveOld:
                {
                    var folder = Paths.Expand(a.Params.GetValueOrDefault("folder", "~/Downloads"));
                    var days = int.TryParse(a.Params.GetValueOrDefault("days", "30"), out var d) ? d : 30;
                    var onlyShots = a.Params.GetValueOrDefault("kind") == "screenshot";
                    var moved = 0;
                    if (Directory.Exists(folder))
                        foreach (var p in Directory.EnumerateFiles(folder).ToList())
                        {
                            var fi = new FileInfo(p);
                            if (fi.Name.StartsWith('.') || fi.Attributes.HasFlag(FileAttributes.Hidden)) continue;
                            if ((DateTime.Now - (fi.LastWriteTime < fi.CreationTime ? fi.LastWriteTime : fi.CreationTime)).TotalDays < days) continue;
                            if (onlyShots && !(ContentExtractor.KindFor(p) == FileKind.image && ContentExtractor.LooksLikeScreenshot(p))) continue;
                            var rec = store.FileByPath(p) ?? new FileRecord { Path = p, Size = fi.Length, CreatedAt = fi.CreationTime, ModifiedAt = fi.LastWriteTime };
                            var (_, outc) = await Run([new RuleAction(ActionKind.move, a.Target)], rec, info, ruleId, jobId, batchId);
                            if (outc.FirstOrDefault()?.Success == true) moved++;
                        }
                    return ($"Archived {moved} file{(moved == 1 ? "" : "s")} older than {days} days from {Paths.Abbreviate(folder)}", file);
                }
            case ActionKind.sortFolder:
                return (Host == null ? "No host" : await Host.SortFolder(Paths.Expand(string.IsNullOrEmpty(a.Target) ? "~/Downloads" : a.Target), batchId), file);
            case ActionKind.findDuplicates:
                return (Host?.FindDuplicates(a.Params.GetValueOrDefault("large") == "1") ?? "", file);
            case ActionKind.generateReport:
                return (Host == null ? "" : await Host.GenerateReport(a.Params.GetValueOrDefault("type", "weekly")), file);
            default:
                throw new Failure($"{a.Kind.Label()} isn't supported on Windows");
        }
    }

    /// One-way mirror: copies new/changed files, never deletes at the destination.
    static (int copied, long bytes) SyncFolder(string source, string target)
    {
        int copied = 0; long bytes = 0;
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(source, file);
            if (rel.Split(Path.DirectorySeparatorChar).Any(p => p.StartsWith('.') || TaxonomyLearner.SkipDirs.Contains(p))) continue;
            var dest = Path.Combine(target, rel);
            var fi = new FileInfo(file);
            var di = new FileInfo(dest);
            if (di.Exists && di.Length == fi.Length && di.LastWriteTimeUtc >= fi.LastWriteTimeUtc) continue;
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            File.Copy(file, dest, true);
            copied++; bytes += fi.Length;
        }
        return (copied, bytes);
    }

    // MARK: Undo

    public int Undo(string batchId)
    {
        var n = 0;
        foreach (var e in store.BatchEvents(batchId))
        {
            if (e.Undo is not { } u) continue;
            try
            {
                switch (u.Op)
                {
                    case UndoOp.move or UndoOp.rename when u.From != null && u.To != null && (File.Exists(u.To) || Directory.Exists(u.To)):
                        Directory.CreateDirectory(Path.GetDirectoryName(u.From)!);
                        var back = File.Exists(u.From) ? Paths.UniquePath(u.From) : u.From;
                        if (Directory.Exists(u.To)) Directory.Move(u.To, back); else File.Move(u.To, back);
                        if (u.FileId != null && store.File(u.FileId) is { } f) { f.Path = back; f.Status = FileStatus.indexed; store.UpsertFile(f); }
                        break;
                    case UndoOp.copy or UndoOp.compress when u.To != null && File.Exists(u.To):
                        File.Delete(u.To);
                        store.MarkMissing(u.To);
                        break;
                    case UndoOp.trash when u.Token != null && u.From != null:
                        if (!Platform.Current.Restore(u.Token, u.From)) continue;
                        if (u.FileId != null && store.File(u.FileId) is { } tf) { tf.Path = u.From; tf.Status = FileStatus.indexed; store.UpsertFile(tf); }
                        break;
                    case UndoOp.tag when u.FileId != null && store.File(u.FileId) is { } tg:
                        if (u.From == "remove") tg.Tags.AddRange(u.Tags); else tg.Tags.RemoveAll(t => u.Tags.Contains(t));
                        store.UpsertFile(tg);
                        break;
                    case UndoOp.projectLink when u.FileId != null && store.File(u.FileId) is { } pf:
                        pf.ProjectId = u.ProjectId; store.UpsertFile(pf);
                        break;
                    case UndoOp.createFolder when u.To != null && Directory.Exists(u.To) && !Directory.EnumerateFileSystemEntries(u.To).Any():
                        Directory.Delete(u.To);
                        break;
                    default: continue;
                }
                store.MarkUndone(e);
                n++;
            }
            catch (Exception ex)
            {
                store.Log(new ActivityEvent { Kind = EventKind.error, Message = $"Undo failed: {ex.Message}" });
            }
        }
        if (n > 0) store.Log(new ActivityEvent { Kind = EventKind.undo, Message = $"Undid {Text.Plural(n, "operation")}" });
        return n;
    }
}

public static class Shell
{
    public static (int code, string output) PowerShell(string scriptOrFile, bool isFile, Dictionary<string, string> env, int timeoutSeconds = 120)
    {
        var exe = Paths.IsWindows ? "powershell.exe" : "pwsh";
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        psi.ArgumentList.Add("-NoProfile"); psi.ArgumentList.Add("-NonInteractive"); psi.ArgumentList.Add("-ExecutionPolicy"); psi.ArgumentList.Add("Bypass");
        if (isFile) { psi.ArgumentList.Add("-File"); psi.ArgumentList.Add(scriptOrFile); }
        else { psi.ArgumentList.Add("-Command"); psi.ArgumentList.Add(scriptOrFile); }
        foreach (var (k, v) in env) psi.Environment[k] = v;
        try
        {
            using var p = Process.Start(psi)!;
            var output = new StringBuilder();
            p.OutputDataReceived += (_, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            if (!p.WaitForExit(timeoutSeconds * 1000)) { try { p.Kill(true); } catch { } return (-1, "timed out"); }
            p.WaitForExit();
            return (p.ExitCode, output.ToString().Trim());
        }
        catch (Exception ex) { return (-1, ex.Message); }
    }
}
