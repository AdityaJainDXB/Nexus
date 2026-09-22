using System.Numerics;
using System.Text;

namespace Nexus.Core;

public class InsightsEngine(NexusStore store, RuleEngine rules)
{
    public void Scan(NexusSettings settings, SystemSnapshot snap)
    {
        Duplicates();
        SimilarScreenshots();
        StaleDownloads(settings);
        LargeDownloads(settings);
        LowDisk(settings, snap);
        Projects(settings);
        Habits();
        Conflicts();
        TimeSaved();
    }

    void Duplicates()
    {
        var groups = store.DuplicateHashes().Select(h => store.FilesWithHash(h).Where(f => File.Exists(f.Path)).ToList()).Where(g => g.Count > 1).ToList();
        if (groups.Count == 0) { store.RemoveInsight("duplicates"); return; }
        var wasted = groups.Sum(g => g.Skip(1).Sum(f => f.Size));
        store.UpsertInsight(new Insight
        {
            Key = "duplicates", Kind = InsightKind.duplicates, Title = $"{Text.Plural(groups.Count, "set")} of duplicate files wasting {Text.FormatBytes(wasted)}",
            Detail = string.Join("\n", groups.Take(6).Select(g => $"• {g[0].Name} ×{g.Count}")), Severity = Severity.suggestion, Command = "clean up duplicates",
            FilePaths = groups.SelectMany(g => g.Select(f => f.Path)).ToList(), Metric = wasted,
        });
    }

    void SimilarScreenshots()
    {
        var shots = store.Files(5000).Where(f => f.Kind == FileKind.screenshot && f.PerceptualHash != null && File.Exists(f.Path)).ToList();
        var used = new HashSet<string>(); var clusters = 0; var extra = 0;
        foreach (var s in shots)
        {
            if (used.Contains(s.Id)) continue;
            var cluster = shots.Where(o => !used.Contains(o.Id) && BitOperations.PopCount(o.PerceptualHash!.Value ^ s.PerceptualHash!.Value) <= 5).ToList();
            if (cluster.Count < 2) continue;
            cluster.ForEach(c => used.Add(c.Id));
            clusters++; extra += cluster.Count - 1;
        }
        if (extra < 3) { store.RemoveInsight("similarShots"); return; }
        store.UpsertInsight(new Insight
        {
            Key = "similarShots", Kind = InsightKind.similarScreenshots, Title = $"{Text.Plural(extra, "near-identical screenshot")} in {Text.Plural(clusters, "group")}",
            Detail = "Keep the newest of each group and send the rest to the Recycle Bin.", Severity = Severity.suggestion, Command = "clean up similar screenshots",
        });
    }

    void StaleDownloads(NexusSettings settings)
    {
        var dl = Paths.Expand("~/Downloads");
        if (!Directory.Exists(dl)) return;
        var old = new DirectoryInfo(dl).EnumerateFiles().Where(f => !f.Attributes.HasFlag(FileAttributes.Hidden) && (DateTime.Now - f.LastWriteTime).TotalDays > 30).ToList();
        if (old.Count < 10) { store.RemoveInsight("staleDownloads"); return; }
        store.UpsertInsight(new Insight
        {
            Key = "staleDownloads", Kind = InsightKind.staleDownloads, Title = $"{old.Count} downloads untouched for 30+ days ({Text.FormatBytes(old.Sum(f => f.Length))})",
            Detail = "Archive them to Documents\\Archive — you can always undo.", Severity = Severity.suggestion, Command = "archive files in Downloads older than 30 days",
            FilePaths = old.Take(50).Select(f => f.FullName).ToList(),
        });
    }

    void LargeDownloads(NexusSettings settings)
    {
        var dl = Paths.Expand("~/Downloads");
        if (!Directory.Exists(dl)) return;
        var big = new DirectoryInfo(dl).EnumerateFiles().Where(f => f.Length > 500_000_000).OrderByDescending(f => f.Length).ToList();
        if (big.Count == 0) { store.RemoveInsight("largeFiles"); return; }
        store.UpsertInsight(new Insight
        {
            Key = "largeFiles", Kind = InsightKind.largeFiles, Title = $"{Text.Plural(big.Count, "large download")} using {Text.FormatBytes(big.Sum(f => f.Length))}",
            Detail = string.Join("\n", big.Take(5).Select(f => $"• {f.Name} — {Text.FormatBytes(f.Length)}")), Severity = Severity.info, FilePaths = big.Select(f => f.FullName).ToList(),
        });
    }

    void LowDisk(NexusSettings settings, SystemSnapshot snap)
    {
        if (snap.DiskFreeGB <= 0 || snap.DiskFreeGB >= settings.LowDiskGB) { store.RemoveInsight("lowDisk"); return; }
        store.UpsertInsight(new Insight
        {
            Key = "lowDisk", Kind = InsightKind.lowDisk, Title = $"Only {snap.DiskFreeGB:0.#} GB free on your system drive",
            Detail = "Clean up duplicates and old downloads to reclaim space.", Severity = snap.DiskFreeGB < 10 ? Severity.critical : Severity.warning, Command = "clean up duplicates",
        });
    }

    void Projects(NexusSettings settings)
    {
        store.RemoveInsightsWithPrefix("inactive:");
        store.RemoveInsightsWithPrefix("deadline:");
        foreach (var p in store.Projects(false))
        {
            if ((DateTime.Now - p.LastActivityAt).TotalDays > settings.InactiveProjectDays)
                store.UpsertInsight(new Insight { Key = "inactive:" + p.Id, Kind = InsightKind.inactiveProject, Title = $"“{p.Name}” has been quiet for {(int)(DateTime.Now - p.LastActivityAt).TotalDays} days", Detail = "Archive it or pick it back up.", Severity = Severity.info });
            if (p.Deadline is { } d && d > DateTime.Now && (d - DateTime.Now).TotalDays < 7)
                store.UpsertInsight(new Insight { Key = "deadline:" + p.Id, Kind = InsightKind.deadlineSoon, Title = $"“{p.Name}” is due {Text.Relative(d)}", Detail = $"{store.ProjectStats(p.Id).count} files linked.", Severity = Severity.warning, Command = $"focus on {p.Name} for 2 hours" });
        }
    }

    /// Repeated manual moves become suggested rules ("you always move .stl files to 3D Printing").
    void Habits()
    {
        store.RemoveInsightsWithPrefix("habit:");
        var moves = store.ObservedMoves();
        foreach (var g in moves.Where(m => m.Ext.Length > 0).GroupBy(m => (m.Ext, to: m.ToFolder.ToLowerInvariant())).Where(g => g.Count() >= 3).Take(5))
        {
            var sample = g.First();
            var fromFolder = Paths.Abbreviate(sample.FromFolder);
            var rule = $"If a .{sample.Ext} file in {fromFolder} → move to {sample.ToFolder}";
            if (store.Rules().Any(r => r.Actions.Any(a => a.Kind == ActionKind.move && Paths.Same(a.Target, sample.ToFolder)))) continue;
            store.UpsertInsight(new Insight
            {
                Key = $"habit:{sample.Ext}:{g.Key.to}", Kind = InsightKind.habit, Title = $"You moved {g.Count()} .{sample.Ext} files to {Path.GetFileName(sample.ToFolder)} by hand",
                Detail = "Want Nexus to do that automatically?", Severity = Severity.suggestion, RuleText = rule, Command = "create rule: " + rule,
            });
        }
    }

    void Conflicts()
    {
        var c = rules.AnalyzeConflicts(store.Rules());
        if (c.Count == 0) { store.RemoveInsight("conflicts"); return; }
        store.UpsertInsight(new Insight { Key = "conflicts", Kind = InsightKind.conflicts, Title = $"{Text.Plural(c.Count, "rule conflict")} to review", Detail = string.Join("\n", c.Take(5).Select(x => "• " + x.Message)), Severity = Severity.warning, Command = "open rules" });
    }

    void TimeSaved()
    {
        var seconds = store.Rules().Sum(r => r.HitCount * r.EstimatedSecondsSaved) + store.EventCount(EventKind.fileMoved, DateTime.Now.AddDays(-30)) * 15;
        if (seconds < 120) { store.RemoveInsight("timeSaved"); return; }
        store.UpsertInsight(new Insight { Key = "timeSaved", Kind = InsightKind.timeSaved, Title = $"Nexus saved you about {TimeSpan.FromSeconds(seconds).TotalMinutes:0} minutes this month", Detail = "Filing, renaming and tidying you didn't have to do.", Severity = Severity.info, Metric = seconds });
    }

    public void SuggestProjectLinks(IEnumerable<(FileRecord file, Project project, double score)> items)
    {
        foreach (var g in items.GroupBy(i => i.project.Id))
        {
            var p = g.First().project;
            store.UpsertInsight(new Insight
            {
                Key = "projectLink:" + p.Id, Kind = InsightKind.projectLink, Title = $"{Text.Plural(g.Count(), "file")} may belong to “{p.Name}”",
                Detail = string.Join("\n", g.Take(6).Select(i => $"• {i.file.Name} ({(int)(i.score * 100)}%)")), Severity = Severity.suggestion,
                FilePaths = g.Select(i => i.file.Path).ToList(), Command = $"add {string.Join(", ", g.Take(1).Select(i => i.file.Name))} to project {p.Name}",
            });
        }
    }
}

public class ReportGenerator(NexusStore store)
{
    public string Markdown(string type)
    {
        var days = type switch { "daily" => 1, "monthly" => 30, _ => 7 };
        var since = DateTime.Now.AddDays(-days);
        var events = store.Events(5000).Where(e => e.Timestamp >= since).ToList();
        var sb = new StringBuilder();
        sb.AppendLine($"# Nexus {type} report — {DateTime.Now:MMMM d, yyyy}").AppendLine();
        sb.AppendLine("## Summary");
        sb.AppendLine($"- Files indexed: {events.Count(e => e.Kind == EventKind.fileIndexed)}");
        sb.AppendLine($"- Files filed: {events.Count(e => e.Kind == EventKind.fileMoved)}");
        sb.AppendLine($"- Renamed: {events.Count(e => e.Kind == EventKind.fileRenamed)} · Tagged: {events.Count(e => e.Kind == EventKind.fileTagged)} · Cleaned up: {events.Count(e => e.Kind == EventKind.fileTrashed)}");
        sb.AppendLine($"- Rules fired: {events.Count(e => e.Kind == EventKind.ruleFired)} · Commands: {events.Count(e => e.Kind == EventKind.command)}");
        sb.AppendLine($"- Waiting for review: {store.ReviewCount()}").AppendLine();
        var top = store.Rules().Where(r => r.HitCount > 0).OrderByDescending(r => r.HitCount).Take(5).ToList();
        if (top.Count > 0)
        {
            sb.AppendLine("## Busiest rules");
            foreach (var r in top) sb.AppendLine($"- **{r.Name}** — {r.HitCount} hits");
            sb.AppendLine();
        }
        var ins = store.Insights().Take(8).ToList();
        if (ins.Count > 0)
        {
            sb.AppendLine("## Insights");
            foreach (var i in ins) sb.AppendLine($"- {i.Title}{(i.Command != null ? $" — try “{i.Command}”" : "")}");
            sb.AppendLine();
        }
        if (type == "storage" || type == "weekly")
        {
            sb.AppendLine("## Storage");
            var snap = SystemMonitor.Sample();
            sb.AppendLine($"- Free: {snap.DiskFreeGB:0.#} GB of {snap.DiskTotalGB:0} GB");
            foreach (var folder in new[] { "~/Downloads", "~/Desktop", "~/Documents" })
            {
                var (size, count) = Scheduler.FolderStats(Paths.Expand(folder));
                sb.AppendLine($"- {folder}: {count} files, {Text.FormatBytes(size)}");
            }
        }
        return sb.ToString();
    }

    public string Save(string type)
    {
        var dir = Path.Combine(Paths.KnownFolder("documents"), "Nexus Reports");
        Directory.CreateDirectory(dir);
        var md = Markdown(type);
        var path = Paths.UniquePath(Path.Combine(dir, $"Nexus {type} report {DateTime.Now:yyyy-MM-dd}.md"));
        File.WriteAllText(path, md);
        var html = "<!doctype html><meta charset=utf-8><title>Nexus report</title><style>body{font:15px/1.6 'Segoe UI',system-ui;max-width:760px;margin:40px auto;padding:0 20px;color:#0d1220}h1{font-weight:650}h2{color:#0a7ea8;border-bottom:1px solid #e3e8ef}</style>"
            + System.Text.RegularExpressions.Regex.Replace(
                System.Text.RegularExpressions.Regex.Replace(System.Net.WebUtility.HtmlEncode(md), @"^# (.+)$", "<h1>$1</h1>", System.Text.RegularExpressions.RegexOptions.Multiline),
                @"^## (.+)$", "<h2>$1</h2>", System.Text.RegularExpressions.RegexOptions.Multiline)
                .Replace("\n- ", "\n<br>• ").Replace("**", "");
        File.WriteAllText(Path.ChangeExtension(path, ".html"), html);
        return path;
    }
}
