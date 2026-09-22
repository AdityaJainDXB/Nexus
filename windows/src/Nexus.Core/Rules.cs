using System.Globalization;
using System.Text.RegularExpressions;

namespace Nexus.Core;

public class RuleContext
{
    public FileRecord? File { get; set; }
    public string Content { get; set; } = "";
    public string? ProjectName { get; set; }
    public TriggerKind Trigger { get; set; }
    public Dictionary<string, string> Info { get; set; } = [];
    public DateTime Now { get; set; } = DateTime.Now;
}

public record ConditionResult(Condition Condition, bool Passed, string Actual);
public record RuleEvaluation(Rule Rule, bool TriggerMatched, List<ConditionResult> ConditionResults, bool Fired, bool SkippedByStop, List<string> PlannedActions);
public record SimulationReport(FileRecord File, List<RuleEvaluation> Evaluations, List<string> Conflicts);
public record RuleConflict(string Kind, string RuleA, string RuleB, string Message);

public class RuleEngine
{
    public bool TriggerMatches(Rule rule, RuleContext ctx)
    {
        var t = rule.Trigger;
        if (t.Kind == TriggerKind.manual) return true;
        if (ctx.Trigger == TriggerKind.manual) return t.Kind.IsFileTrigger();
        var kindOk = t.Kind == ctx.Trigger || (t.Kind == TriggerKind.fileAdded && ctx.Trigger == TriggerKind.downloadCompleted);
        if (!kindOk) return false;
        switch (t.Kind)
        {
            case TriggerKind.fileAdded or TriggerKind.fileModified or TriggerKind.downloadCompleted:
                if (ctx.File == null) return false;
                return t.Folders.Count == 0 || t.Folders.Any(f => Paths.IsInside(ctx.File.Path, Paths.Expand(f), t.Recursive));
            case TriggerKind.appLaunched or TriggerKind.appQuit:
                if (string.IsNullOrEmpty(t.AppName)) return true;
                var want = t.AppName.ToLowerInvariant();
                var app = ctx.Info.GetValueOrDefault("appName", "").ToLowerInvariant();
                return app == want || ctx.Info.GetValueOrDefault("process", "").ToLowerInvariant() == want || app.Contains(want);
            case TriggerKind.volumeMounted or TriggerKind.volumeUnmounted:
                return string.IsNullOrEmpty(t.VolumeName) || ctx.Info.GetValueOrDefault("volumeName", "").Equals(t.VolumeName, StringComparison.OrdinalIgnoreCase);
            case TriggerKind.diskSpaceBelow:
                return (double.TryParse(ctx.Info.GetValueOrDefault("freeGB"), CultureInfo.InvariantCulture, out var free) ? free : double.MaxValue) < (t.Threshold ?? 25);
            case TriggerKind.connectorEvent:
                return t.ConnectorEvent == null || t.ConnectorEvent == ctx.Info.GetValueOrDefault("connectorEvent");
            case TriggerKind.idle:
                return (double.TryParse(ctx.Info.GetValueOrDefault("idleMinutes"), CultureInfo.InvariantCulture, out var idle) ? idle : 0) >= (t.Threshold ?? 15);
            default: return true;
        }
    }

    public ConditionResult Evaluate(Condition c, RuleContext ctx)
    {
        var f = ctx.File;
        var v = c.Value.Trim();
        ConditionResult Str(string? s) { var a = s ?? ""; return new(c, Compare(a, c.Op, v), a.Length > 80 ? a[..80] : a); }
        ConditionResult List(IEnumerable<string> itemsE)
        {
            var items = itemsE.ToList();
            var passed = c.Op switch
            {
                ConditionOp.notContains => !items.Any(i => Compare(i, ConditionOp.contains, v)),
                ConditionOp.notEquals => !items.Any(i => Compare(i, ConditionOp.equals, v)),
                ConditionOp.exists => items.Count > 0,
                _ => items.Any(i => Compare(i, c.Op, v))
            };
            return new(c, passed, string.Join(", ", items.Take(5)));
        }
        ConditionResult Num(double? n)
        {
            if (n is not { } x) return new(c, false, "—");
            var target = double.TryParse(v, CultureInfo.InvariantCulture, out var t) ? t : 0;
            var passed = c.Op switch
            {
                ConditionOp.greaterThan => x > target, ConditionOp.lessThan => x < target, ConditionOp.equals => Math.Abs(x - target) < 1e-4,
                ConditionOp.notEquals => Math.Abs(x - target) >= 1e-4,
                ConditionOp.isAnyOf => v.Split(',').Select(p => double.TryParse(p.Trim(), CultureInfo.InvariantCulture, out var d) ? d : double.NaN).Contains(x),
                _ => Compare(x.ToString(CultureInfo.InvariantCulture), c.Op, v)
            };
            return new(c, passed, x.ToString("0.0", CultureInfo.InvariantCulture));
        }
        switch (c.Field)
        {
            case ConditionField.name: return Str(f?.Name);
            case ConditionField.ext: { var a = f?.Ext ?? ""; return new(c, Compare(a, c.Op, v.Replace(".", "")), a); }
            case ConditionField.kind:
                {
                    var k = f?.Kind.ToString() ?? "";
                    var kinds = new List<string> { k };
                    if (k == "screenshot") kinds.Add("image");
                    if (k is "pdf" or "document" or "text" or "spreadsheet" or "presentation") kinds.Add("document");
                    return List(kinds);
                }
            case ConditionField.content: return Str(ctx.Content);
            case ConditionField.anyText: return Str((f?.Name ?? "") + "\n" + ctx.Content);
            case ConditionField.sizeMB: return Num(f == null ? null : f.Size / 1048576.0);
            case ConditionField.ageDays: return Num(f == null ? null : (ctx.Now - (f.CreatedAt < f.ModifiedAt ? f.CreatedAt : f.ModifiedAt)).TotalDays);
            case ConditionField.folder:
                {
                    var folder = f?.Folder ?? "";
                    var passed = c.Op switch
                    {
                        ConditionOp.equals => Paths.Same(folder, Paths.Expand(v)),
                        ConditionOp.notEquals => !Paths.Same(folder, Paths.Expand(v)),
                        ConditionOp.contains when v.Contains('/') || v.Contains('\\') || v.StartsWith('~') => Paths.IsInside(folder, Paths.Expand(v)) || Paths.Same(folder, Paths.Expand(v)),
                        _ => Compare(folder, c.Op, v)
                    };
                    return new(c, passed, Paths.Abbreviate(folder));
                }
            case ConditionField.docType: return Str(f?.DocType);
            case ConditionField.language: return Str(f?.Language);
            case ConditionField.tag: return List(f?.Tags ?? ctx.Info.GetValueOrDefault("tag", "").Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList());
            case ConditionField.project: return Str(ctx.ProjectName);
            case ConditionField.topic: return List(f?.Topics ?? []);
            case ConditionField.entity: return List((f?.Entities ?? []).Select(e => e.Value));
            case ConditionField.sourceURL: return Str(f?.SourceUrl);
            case ConditionField.hour: return Num(ctx.Now.Hour);
            default: return Num((int)ctx.Now.DayOfWeek + 1);
        }
    }

    public static bool Compare(string actual, ConditionOp op, string expected)
    {
        var a = actual.ToLowerInvariant(); var e = expected.ToLowerInvariant();
        switch (op)
        {
            case ConditionOp.contains: return e.Split('|').Any(x => a.Contains(x.Trim()));
            case ConditionOp.notContains: return !e.Split('|').Any(x => a.Contains(x.Trim()));
            case ConditionOp.equals: return a == e || (e.Contains('*') && a.Glob(e));
            case ConditionOp.notEquals: return a != e;
            case ConditionOp.startsWith: return a.StartsWith(e);
            case ConditionOp.endsWith: return a.EndsWith(e);
            case ConditionOp.matches: try { return Regex.IsMatch(actual, expected, RegexOptions.None, TimeSpan.FromMilliseconds(200)); } catch { return false; }
            case ConditionOp.isAnyOf: return e.Split(',').Select(x => x.Trim()).Contains(a);
            case ConditionOp.exists: return a.Length > 0;
            case ConditionOp.greaterThan: return (double.TryParse(a, CultureInfo.InvariantCulture, out var x1) ? x1 : 0) > (double.TryParse(e, CultureInfo.InvariantCulture, out var y1) ? y1 : 0);
            default: return (double.TryParse(a, CultureInfo.InvariantCulture, out var x2) ? x2 : 0) < (double.TryParse(e, CultureInfo.InvariantCulture, out var y2) ? y2 : 0);
        }
    }

    public (bool ok, List<ConditionResult> results) ConditionsPass(ConditionGroup group, RuleContext ctx)
    {
        var results = group.Conditions.Select(c => Evaluate(c, ctx)).ToList();
        if (results.Count == 0) return (true, results);
        return (group.Match == MatchMode.all ? results.All(r => r.Passed) : results.Any(r => r.Passed), results);
    }

    public List<RuleEvaluation> Evaluate(IEnumerable<Rule> rules, RuleContext ctx, bool includeDisabled = false)
    {
        var outList = new List<RuleEvaluation>();
        var stopped = false;
        foreach (var rule in rules.OrderByDescending(r => r.Priority).ThenBy(r => r.CreatedAt).Where(r => r.Enabled || includeDisabled))
        {
            var trig = TriggerMatches(rule, ctx);
            var (ok, results) = trig ? ConditionsPass(rule.Conditions, ctx) : (false, []);
            var fired = trig && ok && !stopped && rule.Enabled;
            outList.Add(new RuleEvaluation(rule, trig, results, fired, trig && ok && stopped, rule.Actions.Select(a => Templates.Describe(a, ctx.File, ctx.ProjectName)).ToList()));
            if (fired && rule.StopProcessing) stopped = true;
        }
        return outList;
    }

    public List<Rule> FiringRules(IEnumerable<Rule> rules, RuleContext ctx) => Evaluate(rules, ctx).Where(e => e.Fired).Select(e => e.Rule).ToList();

    public SimulationReport Simulate(IEnumerable<Rule> rules, FileRecord file, string content, string? projectName)
    {
        var ctx = new RuleContext { File = file, Content = content, ProjectName = projectName, Trigger = TriggerKind.manual };
        var evals = Evaluate(rules, ctx, includeDisabled: true);
        var conflicts = new List<string>();
        var moves = evals.Where(e => e.Fired).SelectMany(e => e.Rule.Actions.Where(a => a.Kind == ActionKind.move).Select(a => (e.Rule.Name, Templates.Expand(a.Target, file, projectName)))).ToList();
        if (moves.Select(m => m.Item2).Distinct(Paths.Comparer).Count() > 1)
            conflicts.Add("Conflicting moves: " + string.Join("; ", moves.Select(m => $"{m.Name} → {Paths.Abbreviate(m.Item2)}")) + ". Only the first move applies; later file actions follow the file.");
        var adds = evals.Where(e => e.Fired).SelectMany(e => e.Rule.Actions.Where(a => a.Kind == ActionKind.tag).SelectMany(a => a.Tags)).ToHashSet();
        var removes = evals.Where(e => e.Fired).SelectMany(e => e.Rule.Actions.Where(a => a.Kind == ActionKind.removeTag).SelectMany(a => a.Tags)).ToHashSet();
        if (adds.Intersect(removes).Any()) conflicts.Add("Tags both added and removed: " + string.Join(", ", adds.Intersect(removes)));
        conflicts.AddRange(evals.Where(e => e.SkippedByStop).Select(e => $"“{e.Rule.Name}” would match but is blocked by a higher-priority rule that stops processing."));
        return new SimulationReport(file, evals, conflicts);
    }

    public List<RuleConflict> AnalyzeConflicts(IEnumerable<Rule> rulesE)
    {
        var enabled = rulesE.Where(r => r.Enabled).OrderByDescending(r => r.Priority).ToList();
        var outList = new List<RuleConflict>();
        for (var i = 0; i < enabled.Count; i++)
            for (var j = i + 1; j < enabled.Count; j++)
            {
                var a = enabled[i]; var b = enabled[j];
                if (!(a.Trigger.Kind == b.Trigger.Kind || (a.Trigger.Kind.IsFileTrigger() && b.Trigger.Kind.IsFileTrigger()))) continue;
                if (!FoldersOverlap(a.Trigger, b.Trigger)) continue;
                var condA = a.Conditions.Conditions.Select(Key).ToHashSet(); var condB = b.Conditions.Conditions.Select(Key).ToHashSet();
                var actA = a.Actions.Select(ActKey).ToHashSet(); var actB = b.Actions.Select(ActKey).ToHashSet();
                if (condA.SetEquals(condB) && actA.SetEquals(actB)) { outList.Add(new("redundant", a.Id, b.Id, $"“{a.Name}” and “{b.Name}” are identical.")); continue; }
                if (a.StopProcessing && a.Conditions.Match == MatchMode.all && condA.IsSubsetOf(condB)) { outList.Add(new("shadowed", a.Id, b.Id, $"“{b.Name}” can never run: “{a.Name}” matches first and stops processing.")); continue; }
                var ma = a.Actions.FirstOrDefault(x => x.Kind == ActionKind.move)?.Target; var mb = b.Actions.FirstOrDefault(x => x.Kind == ActionKind.move)?.Target;
                if (ma != null && mb != null && !Paths.Same(Paths.Expand(ma), Paths.Expand(mb)) && !MutuallyExclusive(a.Conditions, b.Conditions))
                    outList.Add(new("contradictory", a.Id, b.Id, $"“{a.Name}” and “{b.Name}” can match the same file but move it to different folders ({Paths.Abbreviate(ma)} vs {Paths.Abbreviate(mb)})."));
            }
        return outList;
    }

    static string Key(Condition c) => $"{c.Field}|{c.Op}|{c.Value.ToLowerInvariant()}";
    static string ActKey(RuleAction a) => $"{a.Kind}|{a.Target.ToLowerInvariant()}|{string.Join(",", a.Tags.OrderBy(t => t))}";

    static bool FoldersOverlap(Trigger a, Trigger b)
    {
        if (!a.Kind.IsFileTrigger() || !b.Kind.IsFileTrigger()) return true;
        if (a.Folders.Count == 0 || b.Folders.Count == 0) return true;
        return a.Folders.Any(fa => b.Folders.Any(fb =>
        {
            var x = Paths.Expand(fa); var y = Paths.Expand(fb);
            return Paths.Same(x, y) || (a.Recursive && Paths.IsInside(y, x)) || (b.Recursive && Paths.IsInside(x, y));
        }));
    }

    static bool MutuallyExclusive(ConditionGroup a, ConditionGroup b)
    {
        if (a.Match != MatchMode.all || b.Match != MatchMode.all) return false;
        foreach (var field in new[] { ConditionField.ext, ConditionField.kind, ConditionField.docType, ConditionField.language })
        {
            HashSet<string> Values(ConditionGroup g) => g.Conditions.Where(c => c.Field == field && c.Op is ConditionOp.equals or ConditionOp.isAnyOf)
                .SelectMany(c => c.Value.ToLowerInvariant().Split(',').Select(x => x.Trim().Replace(".", ""))).ToHashSet();
            var va = Values(a); var vb = Values(b);
            if (va.Count > 0 && vb.Count > 0 && !va.Overlaps(vb)) return true;
        }
        return false;
    }
}

public static class Templates
{
    public static string Expand(string template, FileRecord? file, string? projectName, Dictionary<string, string>? info = null, DateTime? nowOpt = null)
    {
        var now = nowOpt ?? DateTime.Now;
        static string Finish(string s) => s.StartsWith('~') || s.StartsWith('/') || Regex.IsMatch(s, @"^[A-Za-z]:[\\/]") ? Paths.Expand(s) : s;
        if (!template.Contains('{')) return Finish(template);
        var date = file?.CreatedAt ?? now;
        var vars = new Dictionary<string, string>
        {
            ["name"] = file?.Name ?? "", ["basename"] = file == null ? "" : Path.GetFileNameWithoutExtension(file.Name), ["ext"] = file?.Ext ?? "",
            ["year"] = date.Year.ToString(), ["month"] = date.Month.ToString("00"), ["day"] = date.Day.ToString("00"), ["date"] = date.ToString("yyyy-MM-dd"),
            ["today"] = now.ToString("yyyy-MM-dd"), ["project"] = projectName ?? "Unsorted", ["docType"] = (file?.DocType ?? "Other").Capitalized(),
            ["category"] = file?.Category ?? "Other", ["kind"] = (file?.Kind.ToString() ?? "other").Capitalized(), ["language"] = file?.Language ?? "Other",
            ["topic"] = file?.Topics.FirstOrDefault()?.Capitalized() ?? "General",
        };
        var s = template;
        if (info != null) foreach (var (k, v) in info) s = s.Replace("{" + k + "}", Safe(v));
        foreach (var (k, v) in vars) s = s.Replace("{" + k + "}", Safe(v));
        return Finish(s);
    }

    static string Safe(string v) => Regex.Replace(v, @"[\\/:*?""<>|]", "-");

    public static string Describe(RuleAction a, FileRecord? file, string? projectName)
    {
        switch (a.Kind)
        {
            case ActionKind.move or ActionKind.copy or ActionKind.syncFolder:
                return $"{a.Kind.Label()} {Paths.Abbreviate(Expand(a.Target, file, projectName))}";
            case ActionKind.rename:
                var n = Expand(a.Target, file, projectName);
                return $"Rename to “{(Path.HasExtension(n) || string.IsNullOrEmpty(file?.Ext) ? n : n + "." + file!.Ext)}”";
            default: return a.Summary;
        }
    }
}
