using System.Text.RegularExpressions;

namespace Nexus.Core;

public class FileQuery
{
    public List<string> Folders { get; set; } = [];
    public bool Recursive { get; set; } = true;
    public List<Condition> Conditions { get; set; } = [];
    public bool UseLastResults { get; set; }
    public bool UseContext { get; set; }
    public int Limit { get; set; } = 500;
    public string Text { get; set; } = "";
    public List<string> SearchTerms => Conditions.Where(c => c.Field is ConditionField.anyText or ConditionField.content or ConditionField.topic or ConditionField.entity && c.Op == ConditionOp.contains).Select(c => c.Value).ToList();
}

public abstract record Intent
{
    public sealed record Find(FileQuery Query) : Intent;
    public sealed record FileActions(FileQuery Query, List<RuleAction> Actions) : Intent;
    public sealed record SummarizeFolder(string Folder) : Intent;
    public sealed record SummarizeQuery(FileQuery Query) : Intent;
    public sealed record SummarizeProject(string Name) : Intent;
    public sealed record CreateRule(string Text) : Intent;
    public sealed record ScheduleIt(string Command, TimeResult When) : Intent;
    public sealed record Organize(string Folder) : Intent;
    public sealed record FindDuplicates : Intent;
    public sealed record Report(string Type) : Intent;
    public sealed record CreateProject(string Name, List<string> Keywords, string? Folder, DateTime? Deadline) : Intent;
    public sealed record Focus(string Project, int Minutes) : Intent;
    public sealed record EndFocus : Intent;
    public sealed record Undo : Intent;
    public sealed record Archive(string Folder, int Days, string? Kind) : Intent;
    public sealed record Pause : Intent;
    public sealed record Resume : Intent;
    public sealed record Navigate(string View) : Intent;
    public sealed record LearnTaxonomy : Intent;
    public sealed record RunRule(string Name) : Intent;
    public sealed record Classify(string Folder) : Intent;
    public sealed record Ask(string Question) : Intent;
    public sealed record Briefing : Intent;
    public sealed record SmartFile(FileQuery Query) : Intent;
    public sealed record CleanDuplicates : Intent;
    public sealed record CleanSimilarScreenshots : Intent;
    public sealed record Unknown(string Text) : Intent;

    public string Label => this switch
    {
        Find => "Search", FileActions fa => string.Join(" + ", fa.Actions.Select(a => a.Kind.Label())), SummarizeFolder or SummarizeQuery or SummarizeProject => "Summarize",
        CreateRule => "Create rule", ScheduleIt => "Schedule", Organize => "Organize", FindDuplicates => "Find duplicates", Report => "Report", CreateProject => "Create project",
        Focus => "Start focus", EndFocus => "End focus", Undo => "Undo", Archive => "Archive", Pause => "Pause automations", Resume => "Resume automations", Navigate => "Open",
        LearnTaxonomy => "Learn folders", RunRule => "Run rule", Classify => "Classify", Ask => "Answer from your files", Briefing => "Briefing", SmartFile => "File it",
        CleanDuplicates => "Clean up duplicates", CleanSimilarScreenshots => "Clean up similar screenshots", _ => "Ask"
    };

    public bool IsMutating => this switch
    {
        Find or SummarizeFolder or SummarizeQuery or SummarizeProject or Navigate or Unknown or Ask or Briefing => false,
        FileActions fa => fa.Actions.Any(a => a.Kind is not (ActionKind.summarize or ActionKind.revealInFinder or ActionKind.openFile)),
        _ => true
    };
}

public record CommandStep(string Text, Intent Intent);

/// Natural-language command → ordered steps. Pure & deterministic (same grammar as Nexus for Mac).
public class CommandParser(NLRuleCompiler compiler)
{
    public NLRuleCompiler Compiler { get; } = compiler;

    static readonly HashSet<string> ContextSubjects = ["this", "this file", "these", "these files", "the selection", "selected files", "the selected files", "my selection",
        "this document", "the current file", "current file", "the current document", "what i'm looking at", "this pdf", "this image"];

    public const string GrammarHelp = """
    move|copy <files> to <folder> · tag <files> as <tags> · add <files> to project <name> · rename <files> to <pattern>
    find|show <files> · summarize <folder> folder · summarize project <name> · organize <folder> · archive screenshots older than N days
    find duplicates · clean up duplicates · generate weekly|storage report · create project <name> with keywords a, b · focus on <project> for N hours · end focus
    create rule: <if/when … → actions> · <command> tonight at 10pm / every Sunday at 9am · undo · pause · resume
    <files> examples: "all invoices from Downloads", "PDFs containing 'MYP3'", "everything about hydroponics in the last 3 months", "them"
    """;

    public List<CommandStep> Parse(string input)
    {
        var text = input.Trim().TrimEnd('.', '!');
        if (text.TrimEnd('?').Length == 0) return [];
        if (LooksLikeRule(text)) return [new CommandStep(text, new Intent.CreateRule(text))];
        return SplitSteps(text).Select(s => new CommandStep(s, ParseStep(s))).ToList();
    }

    public static bool LooksLikeRule(string t)
    {
        var l = t.ToLowerInvariant();
        if (l.EndsWith('?') || Regex.IsMatch(l, @"^(?:when|if)\s+(?:is|are|was|were|does|do|did|will|am|can|should|'s)\b")) return false;
        if (Regex.IsMatch(l, @"^(?:create|make|add|new)\s+(?:a\s+)?(?:rule|automation)")) return true;
        if (t.Contains('→') || t.Contains("->")) return true;
        if (l.StartsWith("if ") || l.StartsWith("when ") || l.StartsWith("whenever ")) return true;
        if ((l.StartsWith("every ") || l.StartsWith("each ")) && l.Contains(':')) return true;
        return l.Contains(" goes to ") || l.Contains(" should go to ");
    }

    const string StepVerbs = "move|copy|tag|label|add|link|rename|summarize|summarise|compress|zip|archive|trash|delete|find|show|search|list|organize|organise|sort|generate|create|open|reveal|focus|undo";

    static List<string> SplitSteps(string text)
    {
        var pattern = @"\s*(?:,\s*then\s+|\s+then\s+|;\s*|,\s*and\s+(?=(?:" + StepVerbs + @")\b)|\s+and\s+(?=(?:then\s+)?(?:" + StepVerbs + @")\s+(?:them|those|these|it|all|every|the|my)\b)|,\s*(?=(?:" + StepVerbs + @")\s+(?:them|those|these|it)\b))";
        return Regex.Split(text, pattern, RegexOptions.IgnoreCase).Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
    }

    public Intent ParseStep(string sRaw)
    {
        var s = sRaw.Trim();
        var l = s.ToLowerInvariant().TrimEnd('?');

        if (ScheduledPhrase(s) is { } when)
        {
            var stripped = Regex.Replace(s, @"\s*(?:tonight|tomorrow|this evening|(?:next|on|this)\s+(?:mon|tues|wednes|thurs|fri|satur|sun)day|in\s+\d+\s*(?:minutes?|mins?|hours?|hrs?|days?)|every\s+\w+(?:\s+\w+)?|daily|weekly|nightly)?\s*(?:at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?|at\s+noon|at\s+midnight)?\s*$", "", RegexOptions.IgnoreCase).Trim();
            if (stripped.Length > 0 && !stripped.Equals(s, StringComparison.OrdinalIgnoreCase))
            {
                var phrase = s[stripped.Length..].Trim();
                return new Intent.ScheduleIt(stripped, NLTime.Parse(phrase) ?? when);
            }
        }

        switch (l)
        {
            case "undo" or "undo that" or "undo last" or "undo last command" or "revert": return new Intent.Undo();
            case "pause" or "pause nexus" or "pause automations": return new Intent.Pause();
            case "resume" or "resume nexus" or "resume automations" or "unpause": return new Intent.Resume();
            case "find duplicates" or "find duplicate files" or "show duplicates" or "find large duplicate files": return new Intent.FindDuplicates();
            case "end focus" or "stop focus" or "exit focus" or "stop focusing": return new Intent.EndFocus();
            case "learn my folders" or "learn folders" or "learn my folder structure" or "relearn taxonomy": return new Intent.LearnTaxonomy();
        }
        if (Regex.IsMatch(l, @"^(?:brief me|briefing|daily briefing|morning briefing|good morning|what'?s (?:up|new|on my plate)|catch me up|what did i miss)\b")) return new Intent.Briefing();
        if (s.Captures(@"^(?:file|put away|tidy|organi[sz]e|sort)\s+(this|these|this file|these files|the selection|selected files|the selected files|this document)$") is { } sf) return new Intent.SmartFile(Query(sf[1]));
        if (s.Captures(@"^summari[sz]e\s+(this|these|this file|these files|this document|the selection|selected files)$") is { } sq) return new Intent.SummarizeQuery(Query(sq[1]));
        if (IsQuestion(s)) return new Intent.Ask(s);
        if (l.Captures(@"^(?:open|show|go to)\s+(?:the\s+)?(review queue|review|insights|rules|projects|tasks|schedule|activity|settings|connectors|files|today)$") is { } nav) return new Intent.Navigate(nav[1]);
        if (l.Captures(@"^run\s+(?:the\s+)?rule\s+(.+)$") is { } rr) return new Intent.RunRule(s.Substring(l.IndexOf(rr[1], StringComparison.Ordinal), rr[1].Length));
        if (s.Captures(@"^(?:run\s+)?(?:classification|classify|index|scan|re-?index)\s+(?:on\s+|of\s+)?(?:my\s+|the\s+)?(.+?)(?:\s+folder)?$") is { } cl) return new Intent.Classify(Compiler.ResolveFolder(cl[1]));
        if (Regex.IsMatch(l, @"^(?:clean(?: up)?|delete|remove|trash|get rid of|dedupe|deduplicate)\b.*(?:duplicate|dupes|copies)") || l == "dedupe") return new Intent.CleanDuplicates();
        if (Regex.IsMatch(l, @"^(?:clean(?: up)?|delete|remove|trash|tidy)\b.*(?:similar|identical|duplicate) screenshots")) return new Intent.CleanSimilarScreenshots();
        if (l.Contains("duplicate") && (l.StartsWith("find") || l.StartsWith("show"))) return new Intent.FindDuplicates();
        if (l.Captures(@"^(?:generate|run|create|make|build|show)\s+(?:a\s+|the\s+|my\s+)?(weekly|monthly|daily|storage)?\s*(?:storage\s+)?(?:report|digest)") is { } rep)
            return new Intent.Report(rep[1].Length == 0 ? (l.Contains("storage") ? "storage" : "weekly") : rep[1]);
        if (s.Captures(@"^(?:create|make|start|new)\s+(?:a\s+)?project\s+(?:called\s+|named\s+)?(.+?)(?:\s+with\s+keywords?\s+(.+?))?(?:\s+(?:in|at)\s+folder\s+(.+?))?(?:\s+due\s+(.+))?$") is { } cp)
        {
            var keywords = cp[2].Split(',').Select(k => k.Trim().Trim('\'', '"')).Where(k => k.Length > 0).ToList();
            DateTime? deadline = null;
            if (cp[4].Length > 0)
            {
                if (NLTime.Parse(cp[4]) is TimeResult.Once o) deadline = o.At;
                else if (DateTime.TryParse(cp[4], out var d)) deadline = d;
            }
            return new Intent.CreateProject(cp[1].Trim('\'', '"'), keywords, cp[3].Length == 0 ? null : Compiler.ResolveFolder(cp[3]), deadline);
        }
        if (s.Captures(@"^(?:start\s+)?focus(?:ing)?\s+(?:on\s+)?(?:project\s+)?(.+?)(?:\s+for\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m))?$") is { } fo)
        {
            var n = fo[2].Length > 0 ? double.Parse(fo[2], System.Globalization.CultureInfo.InvariantCulture) : 2;
            var minutes = fo[3].Length == 0 ? 120 : fo[3].StartsWith('h') ? (int)(n * 60) : (int)n;
            return new Intent.Focus(fo[1].Trim('\'', '"'), minutes);
        }
        if (s.Captures(@"^summari[sz]e\s+(?:the\s+)?project\s+(.+)$") is { } spj) return new Intent.SummarizeProject(spj[1]);
        if ((s.Captures(@"^summari[sz]e\s+(?:what(?:'s| is) in\s+)?(?:my\s+|the\s+)?(.+?)\s+folder$") ?? s.Captures(@"^summari[sz]e\s+(?:what(?:'s| is) in\s+)?(?:my\s+|the\s+)?(~?[/\\]\S+|[A-Za-z]:\\\S+|downloads|desktop|documents)$")) is { } sfo)
            return new Intent.SummarizeFolder(Compiler.ResolveFolder(sfo[1].Trim('`', '\'', '"')));
        if (l.StartsWith("summarize") || l.StartsWith("summarise")) return new Intent.SummarizeQuery(Query(s["summarize".Length..].Trim()));
        if (s.Captures(@"^(?:organi[sz]e|sort|auto-sort|clean up|tidy(?: up)?)\s*(?:my\s+|the\s+)?(.*?)(?:\s+folder)?$") is { } org && !l.Contains(" older than"))
            return new Intent.Organize(Compiler.ResolveFolder(org[1].Length == 0 ? "Downloads" : org[1]));
        if (l.StartsWith("archive"))
        {
            var days = 30;
            if (l.Captures(@"(\d+)\s*(day|week|month)s?") is { } dm) days = (int)(double.Parse(dm[1]) * Compiler.UnitDays(dm[2]));
            var shots = l.Contains("screenshot");
            var folder = shots ? "~/Pictures/Screenshots" : "~/Downloads";
            if (s.Captures(@"\b(?:in|from)\s+(?:my\s+|the\s+)?(~?[\w/\\:\- ]+?)(?:\s+folder)?(?:\s+older|\s*$)") is { } af) folder = af[1];
            return new Intent.Archive(Compiler.ResolveFolder(folder), days, shots ? "screenshot" : null);
        }
        if (s.Captures(@"^(move|copy|put|file)\s+(.+?)\s+(?:in)?to\s+(?!project\b)(.+)$") is { } mv)
            return FileActions(mv[2], $"{(mv[1].Equals("copy", StringComparison.OrdinalIgnoreCase) ? "copy" : "move")} to {mv[3]}");
        if ((s.Captures(@"^(?:tag|label)\s+(.+?)\s+(?:as|with)\s+(.+)$") ?? s.Captures(@"^(?:tag|label)\s+(them|those|these|it)\s+(.+)$")) is { } tg) return FileActions(tg[1], "tag " + tg[2]);
        if ((s.Captures(@"^(?:add|link|put|move)\s+(.+?)\s+(?:to|into|with)\s+(?:the\s+)?project\s+(.+)$") ?? s.Captures(@"^(?:add|link)\s+(.+?)\s+to\s+(?:the\s+)?(.+?)\s+project$")) is { } ap)
            return FileActions(ap[1], "add to project " + ap[2]);
        if (s.Captures(@"^(?:add|link|attach)\s+(?:them\s+|those\s+|it\s+)?to\s+(?:the\s+)?project\s+(.+)$") is { } ap2) return FileActions("them", "add to project " + ap2[1]);
        if (s.Captures(@"^(?:and\s+)?(?:tag|label)\s+(?!them\b|those\b|it\b)([#\w\-']+)$") is { } tg2) return FileActions("them", "tag " + tg2[1]);
        if (s.Captures(@"^rename\s+(.+?)\s+(?:to|as)\s+(.+)$") is { } rn) return FileActions(rn[1], "rename to " + rn[2]);
        if (s.Captures(@"^(trash|delete|remove|compress|zip|reveal|open)\s+(.+)$") is { } tr)
        {
            var verb = tr[1].ToLowerInvariant() is "delete" or "remove" ? "trash" : tr[1].ToLowerInvariant();
            return FileActions(tr[2], verb);
        }
        if (s.Captures(@"^(?:find|show|list|search(?: for)?|get|where (?:are|is))\s+(?:me\s+)?(.+)$") is { } fi) return new Intent.Find(Query(fi[1]));
        var q = Query(s);
        if (q.Conditions.Count >= 1 && s.Split(' ').Length <= 8) return new Intent.Find(q);
        return new Intent.Unknown(s);
    }

    Intent FileActions(string subject, string body)
    {
        var q = Query(subject);
        var (text, quotes) = Compiler.ExtractQuotes(Compiler.Normalize(body));
        var actions = Compiler.ParseActions(text, new Trigger(TriggerKind.manual) { Folders = q.Folders }, quotes, [], []);
        return actions.Count == 0 ? new Intent.Unknown(subject + " " + body) : new Intent.FileActions(q, actions);
    }

    public FileQuery Query(string subjectRaw)
    {
        var q = new FileQuery { Text = subjectRaw };
        var subject = subjectRaw.Trim();
        var l = subject.ToLowerInvariant();
        if (ContextSubjects.Contains(l)) { q.UseContext = true; return q; }
        if (l is "them" or "those" or "it" or "those files" or "the files" or "the results" or "that") { q.UseLastResults = true; return q; }
        var (text, quotes) = Compiler.ExtractQuotes(Compiler.Normalize(subject));
        var trigger = Compiler.ParseTrigger(text, quotes, []);
        if (!trigger.Kind.IsFileTrigger()) trigger = new Trigger(TriggerKind.fileAdded);
        q.Folders = trigger.Folders.Select(Paths.Expand).ToList();
        q.Conditions = Compiler.ParseConditions(text, trigger, quotes, []);

        var now = DateTime.Now;
        void Since(DateTime d) => q.Conditions.Add(new Condition(ConditionField.ageDays, ConditionOp.lessThan, ((now - d).TotalDays).ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)));
        if (l.Contains("this year")) Since(new DateTime(now.Year, 1, 1));
        else if (l.Contains("this month")) Since(new DateTime(now.Year, now.Month, 1));
        else if (l.Contains("this week")) Since(now.Date.AddDays(-(int)now.DayOfWeek));
        else if (l.Contains("today")) Since(now.Date);
        else if (l.Contains("yesterday")) Since(now.Date.AddDays(-1));
        else if (l.Contains("last month") && !l.Contains("in the last")) Since(now.AddMonths(-1));
        else if (l.Contains("last week") && !l.Contains("in the last")) Since(now.AddDays(-7));

        if (q.Conditions.Count == 0 && q.Folders.Count == 0)
        {
            string[] filler = ["all", "my", "the", "files", "file", "everything", "stuff", "things", "documents", "every", "any", "in", "from", "of", "to", "me"];
            var words = subject.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => !filler.Contains(w.ToLowerInvariant())).ToList();
            if (words.Count > 0) q.Conditions.Add(new Condition(ConditionField.anyText, ConditionOp.contains, Compiler.Restore(string.Join(' ', words), quotes)));
        }
        if (l.StartsWith("the latest") || l.StartsWith("latest") || l.StartsWith("newest") || (l.StartsWith("last ") && !l.Contains("last month"))) q.Limit = 10;
        return q;
    }

    static bool IsQuestion(string s)
    {
        var l = s.ToLowerInvariant().Trim();
        string[] starters = ["what ", "when ", "who ", "which ", "how much", "how many", "how do", "why ", "is there", "does ", "do i ", "did ", "tell me", "explain", "according to", "remind me what"];
        if (!starters.Any(l.StartsWith) && !l.EndsWith('?')) return false;
        return !Regex.IsMatch(l, @"^(?:what|which|where)\s+(?:files|documents|pdfs|images|screenshots)\b");
    }

    static TimeResult? ScheduledPhrase(string s)
    {
        var l = " " + s.ToLowerInvariant() + " ";
        string[] markers = [" tonight", " tomorrow", " at ", " every ", " in ", " daily", " weekly", " nightly", " on monday", " on tuesday", " on wednesday", " on thursday", " on friday", " on saturday", " on sunday", " next "];
        if (!markers.Any(l.Contains)) return null;
        var timeish = Regex.IsMatch(l, @"(tonight|tomorrow|\d{1,2}(:\d{2})?\s*(am|pm)|noon|midnight|every\s+(day|night|morning|week|month|hour|\d+|mon|tue|wed|thu|fri|sat|sun)|in\s+\d+\s*(min|hour|hr|day)|daily|weekly|nightly|next\s+(mon|tue|wed|thu|fri|sat|sun))");
        return timeish ? NLTime.Parse(s) : null;
    }
}
