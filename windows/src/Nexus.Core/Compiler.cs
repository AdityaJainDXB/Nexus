using System.Text.RegularExpressions;

namespace Nexus.Core;

public class RuleCompileResult
{
    public Rule? Rule { get; set; }
    public List<string> Warnings { get; set; } = [];
    public double Confidence { get; set; }
    public List<string> Explanation { get; set; } = [];
}

/// Deterministic natural-language → Rule compiler (same grammar as Nexus for Mac).
///   "If a PDF in Downloads contains 'lab report' → move to School/Science/Reports, tag MYP3, add to project Science Fair"
///   "When drive 'Backup' is connected → sync Projects and School folders"
///   "Every Sunday 9 AM: archive old screenshots, generate storage report"
public class NLRuleCompiler
{
    public string LibraryRoot { get; set; }
    public List<string> KnownProjects { get; set; }

    public NLRuleCompiler(string libraryRoot = "~/Documents", IEnumerable<string>? knownProjects = null)
    {
        LibraryRoot = libraryRoot;
        KnownProjects = knownProjects?.ToList() ?? [];
    }

    static readonly string[] ActionVerbs = ["move", "put", "file", "send", "copy", "duplicate", "tag", "label", "mark", "rename", "add", "link", "archive", "sync", "back up", "backup",
        "notify", "alert", "tell", "remind", "create", "make", "prepare", "open", "reveal", "show", "run", "compress", "zip", "summarize", "summarise", "trash", "delete",
        "remove", "find", "suggest", "generate", "save", "post", "append", "call", "sort", "auto-sort", "organize", "organise", "clean", "gets", "get", "goes", "go", "set", "mirror", "then"];

    static Dictionary<string, string> WellKnownFolders => new(StringComparer.OrdinalIgnoreCase)
    {
        ["downloads"] = "~/Downloads", ["desktop"] = "~/Desktop", ["documents"] = "~/Documents", ["pictures"] = "~/Pictures", ["videos"] = "~/Videos",
        ["movies"] = "~/Videos", ["music"] = "~/Music", ["home"] = "~", ["icloud drive"] = "~/iCloudDrive", ["screenshots"] = "~/Pictures/Screenshots",
        ["onedrive"] = Environment.GetEnvironmentVariable("OneDrive") is { Length: > 0 } od && Environment.GetEnvironmentVariable("NEXUS_HOME_ROOT") == null ? od : "~/OneDrive",
    };

    static readonly (string noun, string type)[] DocTypeNouns = [("invoices", "invoice"), ("invoice", "invoice"), ("receipts", "receipt"), ("receipt", "receipt"),
        ("lab reports", "lab report"), ("lab report", "lab report"), ("syllabi", "syllabus"), ("syllabus", "syllabus"), ("resumes", "resume"), ("resume", "resume"),
        ("contracts", "contract"), ("contract", "contract"), ("bank statements", "bank statement"), ("statements", "bank statement"), ("tax documents", "tax document"),
        ("research papers", "research paper"), ("papers", "research paper"), ("meeting notes", "meeting notes"), ("specs", "spec"), ("assignments", "assignment"),
        ("homework", "assignment"), ("tickets", "ticket"), ("essays", "essay"), ("manuals", "manual"), ("3d models", "3d model"), ("screen recordings", "screen recording")];

    internal static readonly (string noun, ConditionField field, string value)[] KindNouns = [
        ("screenshots", ConditionField.kind, "screenshot"), ("screenshot", ConditionField.kind, "screenshot"), ("pdfs", ConditionField.ext, "pdf"), ("pdf", ConditionField.ext, "pdf"),
        ("images", ConditionField.kind, "image"), ("image", ConditionField.kind, "image"), ("photos", ConditionField.kind, "image"), ("pictures", ConditionField.kind, "image"),
        ("videos", ConditionField.kind, "video"), ("video", ConditionField.kind, "video"), ("code files", ConditionField.kind, "code"), ("code file", ConditionField.kind, "code"), ("scripts", ConditionField.kind, "code"),
        ("spreadsheets", ConditionField.kind, "spreadsheet"), ("presentations", ConditionField.kind, "presentation"), ("slides", ConditionField.kind, "presentation"),
        ("installers", ConditionField.kind, "installer"), ("exes", ConditionField.ext, "exe,msi"), ("msis", ConditionField.ext, "msi"), ("zips", ConditionField.ext, "zip"), ("zip files", ConditionField.ext, "zip"), ("archives", ConditionField.kind, "archive"),
        ("audio files", ConditionField.kind, "audio"), ("recordings", ConditionField.kind, "audio"), ("word documents", ConditionField.ext, "doc,docx"), ("documents", ConditionField.kind, "document"), ("docs", ConditionField.kind, "document"),
        ("stl files", ConditionField.ext, "stl,3mf,obj"), ("stls", ConditionField.ext, "stl,3mf,obj"), ("gcode", ConditionField.ext, "gcode"), ("csvs", ConditionField.ext, "csv"), ("csv files", ConditionField.ext, "csv")];

    static readonly Dictionary<string, string> Languages = new() { ["python"] = "Python", ["swift"] = "Swift", ["javascript"] = "JavaScript", ["typescript"] = "TypeScript", ["rust"] = "Rust", ["go"] = "Go",
        ["java"] = "Java", ["c++"] = "C++", ["c#"] = "C#", ["ruby"] = "Ruby", ["shell"] = "Shell", ["powershell"] = "PowerShell", ["kotlin"] = "Kotlin", ["arduino"] = "Arduino" };

    // MARK: Entry

    public RuleCompileResult Compile(string input)
    {
        var warnings = new List<string>(); var explanation = new List<string>();
        var (text, quotes) = ExtractQuotes(Normalize(input));
        if (text.Captures(@"^\s*(?:please\s+)?(?:create|make|add|new)?\s*(?:a\s+)?(?:rule|automation)\s*(?:that|to|:|,)?\s*(.*)$") is { } wrap) text = wrap[1];

        if (SplitHeadBody(text) is not { } hb)
            return new RuleCompileResult { Warnings = ["Couldn't find an action (e.g. “→ move to …”, “tag …”)."] };
        var head = hb.head.Trim(); var body = hb.body.Trim();

        var trigger = ParseTrigger(head, quotes, explanation);
        var conditions = ParseConditions(head, trigger, quotes, explanation);
        var actions = ParseActions(body, trigger, quotes, warnings, explanation);
        if (actions.Count == 0)
            return new RuleCompileResult { Warnings = [.. warnings, $"No actions recognised in “{Restore(body, quotes)}”."], Confidence = 0.1, Explanation = explanation };
        if (trigger.Kind.IsFileTrigger() && trigger.Folders.Count == 0 && conditions.Count == 0)
            warnings.Add("This rule would match every new file in all watched folders.");
        if (trigger.Kind.IsFileTrigger() && trigger.Folders.Count == 0 && conditions.Any(c => c.Field == ConditionField.kind && c.Value == "screenshot"))
            trigger.Folders = [Paths.Expand("~/Pictures/Screenshots"), Paths.Expand("~/Desktop")];
        conditions = Dedupe(conditions);

        var rule = new Rule
        {
            Name = MakeName(trigger, conditions, actions), Trigger = trigger,
            Conditions = new ConditionGroup { Match = IsAnyMatch(head) ? MatchMode.any : MatchMode.all, Conditions = conditions },
            Actions = actions, NaturalLanguage = input,
        };
        if (!trigger.Kind.IsFileTrigger() && trigger.Kind != TriggerKind.schedule) rule.CooldownMinutes = 30;
        if (actions.Any(a => a.Kind == ActionKind.trash))
        {
            rule.RequireConfirmation = true;
            warnings.Add("Rules that delete files require confirmation in the Review Queue by default.");
        }
        rule.EstimatedSecondsSaved = actions.Count * 15 + 10;
        var confidence = Math.Min(1, 0.55 + 0.1 * actions.Count + 0.05 * conditions.Count - 0.15 * warnings.Count);
        return new RuleCompileResult { Rule = rule, Warnings = warnings, Confidence = Math.Max(0.2, confidence), Explanation = explanation };
    }

    public static bool IsAnyMatch(string head)
    {
        var stripped = Regex.Replace(head.ToLowerInvariant(), @"⟦\d+⟧(\s*(,|or)\s*⟦\d+⟧)+", "⟦alt⟧");
        return stripped.Contains(" or ") && !stripped.Contains(" and ");
    }

    // MARK: Pre-processing

    public string Normalize(string s)
    {
        var t = Regex.Replace(s, "[‘’`]", "'");
        t = Regex.Replace(t, "[“”]", "\"");
        t = Regex.Replace(t, "→|->|=>|⇒", " → ");
        t = Regex.Replace(t, @"\s+", " ");
        return t.Trim(' ', '.', '!');
    }

    public (string text, List<string> quotes) ExtractQuotes(string s)
    {
        var quotes = new List<string>();
        var i = 0;
        var outText = Regex.Replace(s, "\"([^\"]+)\"|(?<![A-Za-z])'([^']+)'(?![A-Za-z])", m =>
        {
            quotes.Add(m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value);
            return $"⟦{i++}⟧";
        });
        return (outText, quotes);
    }

    public string Restore(string s, List<string> quotes)
    {
        for (var i = 0; i < quotes.Count; i++) s = s.Replace($"⟦{i}⟧", quotes[i]);
        return s;
    }

    (string head, string body)? SplitHeadBody(string text)
    {
        var arrow = text.IndexOf(" → ", StringComparison.Ordinal);
        if (arrow >= 0) return (text[..arrow], text[(arrow + 3)..]);
        if (text.Captures(@"^(.*?)\s+(?:should\s+)?(?:goes|go|get moved|gets moved|are moved|is moved)\s+(?:in)?to\s+(.*)$") is { } g) return (g[1], "move to " + g[2]);
        if (text.Captures(@"^((?:if|when|whenever|every|each|on|at|after|once)\b[^:]*?):\s*(.*)$") is { } c) return (c[1], c[2]);
        if (text.Captures(@"^((?:if|when|whenever)\b.*?),\s*(?:then\s+)?(.*)$") is { } cm && StartsWithVerb(cm[2])) return (cm[1], cm[2]);
        var then = text.IndexOf(" then ", StringComparison.OrdinalIgnoreCase);
        if (then >= 0) return (text[..then], text[(then + 6)..]);
        if (StartsWithVerb(text) && text.Captures(@"^(move|copy|tag|rename|archive|compress|trash)\s+(.*?)\s+(?:(?:in|from)\s+(\S+(?:\s\S+)?)\s+)?(to|as|with)\s+(.*)$") is { } imp)
        {
            var subject = imp[2] + (imp[3].Length == 0 ? "" : $" in {imp[3]}");
            return (subject, $"{imp[1]} {imp[4]} {imp[5]}");
        }
        if (text.Captures(@"^(.*?)\s+(?:when|whenever|if)\s+(.*)$") is { } tail && StartsWithVerb(tail[1])) return (tail[2], tail[1]);
        var words = text.Split(' ');
        for (var i = 1; i < words.Length; i++)
        {
            var rest = string.Join(' ', words[i..]);
            if (StartsWithVerb(rest) && !new[] { "file", "files", "mark", "set", "add", "run" }.Contains(words[i].ToLowerInvariant()))
                return (string.Join(' ', words[..i]), rest);
        }
        return null;
    }

    public bool StartsWithVerb(string s)
    {
        var l = s.ToLowerInvariant().Trim();
        return ActionVerbs.Any(v => l.StartsWith(v + " ") || l == v);
    }

    // MARK: Trigger

    public Trigger ParseTrigger(string head, List<string> quotes, List<string> explanation)
    {
        var l = " " + head.ToLowerInvariant() + " ";
        string Q(string s) => Restore(s, quotes).Trim();

        if ((l.Contains(" every ") || l.Contains(" each ") || l.Contains(" daily") || l.Contains(" weekly") || l.Contains(" nightly") || l.StartsWith(" at ") || l.Contains(" on sundays") || l.Contains(" monthly"))
            && NLTime.Parse(head) is TimeResult.CronAt cron)
        {
            explanation.Add($"Runs on a schedule: {CronExpression.Describe(cron.Cron)}");
            return new Trigger(TriggerKind.schedule) { Cron = cron.Cron };
        }
        if (l.Captures(@"disk(?: space)?(?: is)?\s*(?:<|below|under|less than|drops below|falls below)\s*(\d+(?:\.\d+)?)\s*gb") is { } disk)
        {
            explanation.Add($"When free disk space drops below {disk[1]} GB");
            return new Trigger(TriggerKind.diskSpaceBelow) { Threshold = double.Parse(disk[1], System.Globalization.CultureInfo.InvariantCulture) };
        }
        if (l.Contains("low disk") || l.Contains("disk is full") || l.Contains("disk space is low"))
        {
            explanation.Add("When free disk space is low (< 25 GB)");
            return new Trigger(TriggerKind.diskSpaceBelow) { Threshold = 25 };
        }
        if ((head.Captures(@"(?:drive|volume|disk|ssd|usb)\s+(.+?)\s+(?:is\s+)?(?:connected|plugged in|mounted|attached|inserted)")
             ?? head.Captures(@"(?:connect|plug in|mount)\s+(?:the\s+|my\s+)?(.+?)\s+(?:drive|volume|disk)")) is { } vol)
        {
            var name = Q(vol[1]).Re(@"^(?:external|the|my)\s+", "");
            explanation.Add($"When the drive “{name}” is connected");
            return new Trigger(TriggerKind.volumeMounted) { VolumeName = name };
        }
        if (head.Captures(@"(?:drive|volume|disk)\s+(.+?)\s+(?:is\s+)?(?:ejected|disconnected|unmounted|removed)") is { } ej)
        {
            explanation.Add($"When the drive “{Q(ej[1])}” is ejected");
            return new Trigger(TriggerKind.volumeUnmounted) { VolumeName = Q(ej[1]) };
        }
        if ((head.Captures(@"(?:when|whenever|if)\s+(?:i\s+(?:open|launch|start)\s+)?(.+?)(?:\s+app)?\s+(?:opens|launches|starts|is opened|is launched|is started)")
             ?? head.Captures(@"(?:when|whenever)\s+i\s+(?:open|launch|start)\s+(.+?)$")) is { } app)
        {
            var name = Q(app[1]).Re(@"^the\s+", "");
            explanation.Add($"When “{name}” opens");
            return new Trigger(TriggerKind.appLaunched) { AppName = name };
        }
        if (head.Captures(@"(?:when|whenever|if)\s+(?:i\s+(?:quit|close)\s+)?(.+?)(?:\s+app)?\s+(?:quits|closes|is closed|is quit|exits)") is { } quit)
        {
            explanation.Add($"When “{Q(quit[1])}” quits");
            return new Trigger(TriggerKind.appQuit) { AppName = Q(quit[1]) };
        }
        if (head.Captures(@"(~?[\w/\\: ]+?)\s+(?:folder\s+)?(?:has|contains|reaches)\s+(?:>|more than|over|at least)\s*(\d+)\s+(?:files|items)") is { } fc)
        {
            var folder = ResolveFolder(Q(fc[1]).Re(@"^(?:when|if|my|the)\s+", ""));
            explanation.Add($"When {Paths.Abbreviate(folder)} has more than {fc[2]} files");
            return new Trigger(TriggerKind.folderCountAbove) { Folders = [folder], Threshold = double.Parse(fc[2]) };
        }
        if (head.Captures(@"(~?[\w/\\: ]+?)\s+(?:folder\s+)?(?:is|grows|gets)\s+(?:larger|bigger|beyond|over|above|more)\s+(?:than\s+)?(\d+(?:\.\d+)?)\s*gb") is { } fs)
        {
            var folder = ResolveFolder(Q(fs[1]).Re(@"^(?:when|if|my|the)\s+", ""));
            explanation.Add($"When {Paths.Abbreviate(folder)} grows beyond {fs[2]} GB");
            return new Trigger(TriggerKind.folderSizeAbove) { Folders = [folder], Threshold = double.Parse(fs[2], System.Globalization.CultureInfo.InvariantCulture) };
        }
        if (l.Captures(@"idle (?:for )?(\d+)\s*(?:min|minutes)") is { } idle)
        {
            explanation.Add($"When the PC is idle for {idle[1]} minutes");
            return new Trigger(TriggerKind.idle) { Threshold = double.Parse(idle[1]) };
        }
        if (l.Contains(" wakes") || l.Contains(" wake up") || l.Contains(" wake from sleep")) { explanation.Add("When the PC wakes"); return new Trigger(TriggerKind.wake); }
        if (l.Contains("focus starts") || l.Contains("focus begins") || l.Contains("start focus")) { explanation.Add("When a focus session starts"); return new Trigger(TriggerKind.focusStarted); }
        if (l.Contains("focus ends")) { explanation.Add("When a focus session ends"); return new Trigger(TriggerKind.focusEnded); }
        if (l.Contains("github") && (l.Contains("issue") || l.Contains("pull request") || l.Contains(" pr ")))
        {
            var ev = l.Contains("pull request") || l.Contains(" pr ") ? "github.prReviewRequested" : "github.issueAssigned";
            explanation.Add($"When GitHub reports: {ev}");
            return new Trigger(TriggerKind.connectorEvent) { ConnectorEvent = ev };
        }
        if ((l.Contains("email") || l.Contains(" mail") || l.Contains("outlook")) && l.Contains("attachment"))
        {
            explanation.Add("When an email attachment is saved (Mail inbox folder)");
            return new Trigger(TriggerKind.connectorEvent) { Folders = [Path.Combine(Paths.AppSupport, "Inbox", "Mail")], ConnectorEvent = "mail.attachment" };
        }
        if (l.Contains("calendar event") && (l.Contains("starts") || l.Contains("begins")))
        {
            explanation.Add("When a calendar event starts");
            return new Trigger(TriggerKind.connectorEvent) { ConnectorEvent = "calendar.eventStarting" };
        }

        var kind = TriggerKind.fileAdded;
        if (l.Contains("download") && (l.Contains("finish") || l.Contains("complete") || l.Contains("done"))) kind = TriggerKind.downloadCompleted;
        else if (l.Contains(" changes") || l.Contains(" modified") || l.Contains(" is edited") || l.Contains(" is saved")) kind = TriggerKind.fileModified;
        var trigger = new Trigger(kind);
        string[] folderPatterns =
        [
            // absolute paths may contain spaces ("C:\Users\John Smith\Downloads") — read up to the next keyword
            @"\b(?:in|from|into|inside|within|under)\s+((?:[A-Za-z]:[\\/]|/|~[\\/])[^,→⟦]*?)(?=\s+(?:contains|containing|with|named|called|that|which|is|are|gets|older|newer|larger|bigger|smaller|over|and|or|mentioning|about|tagged|lands|arrives|appears)\b|\s*,|\s*$)",
            @"(?:folder|location)\s+is\s+(⟦\d+⟧|~?[\w\-/\.]+(?:\s[A-Z][\w\-]*)*)",
            @"\b(?:in|from|into|on|inside|within|under)\s+(?:the\s+|my\s+)?(⟦\d+⟧|~[\w\-/\\\. ]+?|/[\w\-/\. ]+?|[A-Za-z]:[\\/][\w\-\\/\. ]+?|downloads|desktop|documents|pictures|videos|movies|music|screenshots|onedrive|icloud drive|[A-Z][\w\-]*(?:[/\\][\w\-]+)+)(?:\s+folder)?(?=\s|$|,)",
        ];
        foreach (var p in folderPatterns)
        {
            foreach (Match m in Regex.Matches(head, p, RegexOptions.IgnoreCase))
            {
                var rawSpan = m.Groups[1].Value;
                var raw = Q(rawSpan);
                if (raw.StartsWith("project", StringComparison.OrdinalIgnoreCase) || raw.Equals("the last", StringComparison.OrdinalIgnoreCase)) continue;
                if (WellKnownFolders.ContainsKey(raw) || raw.Contains('/') || raw.Contains('\\') || raw.StartsWith('~') || rawSpan.StartsWith('⟦'))
                {
                    var folder = ResolveFolder(raw);
                    // a shorter match of the same path (cut at a space) adds nothing
                    if (trigger.Folders.Any(f => f.StartsWith(folder, Paths.Cmp))) continue;
                    if (!trigger.Folders.Contains(folder, Paths.Comparer)) trigger.Folders.Add(folder);
                }
            }
        }
        if (kind == TriggerKind.downloadCompleted && trigger.Folders.Count == 0) trigger.Folders = [Paths.Expand("~/Downloads")];
        if (l.Contains("subfolder") || l.Contains("recursively") || l.Contains("anywhere in")) trigger.Recursive = true;
        explanation.Add($"{kind.Label()} in {(trigger.Folders.Count == 0 ? "any watched folder" : string.Join(", ", trigger.Folders.Select(Paths.Abbreviate)))}");
        return trigger;
    }

    // MARK: Conditions

    public List<Condition> ParseConditions(string head, Trigger trigger, List<string> quotes, List<string> explanation)
    {
        var outList = new List<Condition>();
        var l = " " + head.ToLowerInvariant() + " ";
        string Q(string s) => Restore(s, quotes).Trim();
        void Add(Condition c) { outList.Add(c); explanation.Add("Only if " + c.Summary); }
        const string valuePattern = @"(⟦\d+⟧|[^,]+?)(?=\s+(?:and|or|→|then)\s|,|$)";

        (string namePattern, ConditionField field)[] fieldOps = [("file ?name|name", ConditionField.name), ("content|text|body", ConditionField.content), ("extension", ConditionField.ext),
            ("(?:download(?:ed)? )?(?:source|url|origin)", ConditionField.sourceURL), ("type|doc(?:ument)? type", ConditionField.docType), ("topic", ConditionField.topic),
            ("project", ConditionField.project), ("tag", ConditionField.tag)];
        var explicitFields = new HashSet<ConditionField>();
        foreach (var (namePattern, field) in fieldOps)
        {
            var opPattern = @"\b(?:" + namePattern + @")\s+(contains|includes|has|does not contain|doesn't contain|starts with|begins with|ends with|is not|isn't|is|equals|matches)\s+" + valuePattern;
            foreach (Match m in Regex.Matches(head, opPattern, RegexOptions.IgnoreCase))
            {
                var opWord = m.Groups[1].Value.ToLowerInvariant();
                var value = Q(m.Groups[2].Value);
                var op = opWord switch
                {
                    "contains" or "includes" or "has" => ConditionOp.contains,
                    "does not contain" or "doesn't contain" => ConditionOp.notContains,
                    "starts with" or "begins with" => ConditionOp.startsWith,
                    "ends with" => ConditionOp.endsWith,
                    "is not" or "isn't" => ConditionOp.notEquals,
                    "matches" => ConditionOp.matches,
                    _ => field is ConditionField.name or ConditionField.content ? ConditionOp.contains : ConditionOp.equals
                };
                if (field == ConditionField.project) value = value.Re(@"^project\s+", "");
                if (field == ConditionField.docType && KindNouns.FirstOrDefault(k => k.noun == value.ToLowerInvariant()) is { noun: not null } km)
                {
                    Add(new Condition(km.field, ConditionOp.equals, km.value)); explicitFields.Add(km.field); continue;
                }
                Add(new Condition(field, op, value));
                explicitFields.Add(field);
            }
        }
        if (l.Captures(@"language\s+is\s+(\w[\w\+#]*)") is { } lang)
        {
            Add(new Condition(ConditionField.language, ConditionOp.equals, Languages.GetValueOrDefault(lang[1], lang[1].Capitalized()))); explicitFields.Add(ConditionField.language);
        }
        else if (Languages.FirstOrDefault(kv => l.Contains($" {kv.Key} file") || l.Contains($" {kv.Key} script") || l.Contains($" {kv.Key} code")) is { Key: not null } lk)
        {
            Add(new Condition(ConditionField.language, ConditionOp.equals, lk.Value)); explicitFields.Add(ConditionField.language);
        }

        if (!explicitFields.Contains(ConditionField.content) && !explicitFields.Contains(ConditionField.name))
        {
            const string generic = @"\b(?:contains|containing|with|mentioning|mentions|about|related to|that says|saying|including)\s+(?:the\s+(?:word|phrase|text)\s+)?(⟦\d+⟧(?:\s*(?:,|or)\s*⟦\d+⟧)*|[\w\-]+(?:\s[\w\-]+)?)";
            foreach (Match m in Regex.Matches(head, generic, RegexOptions.IgnoreCase))
            {
                var raw = m.Groups[1].Value;
                string value;
                if (raw.StartsWith('⟦'))
                    value = string.Join("|", raw.Split(',').SelectMany(x => Regex.Split(x, " or ")).Select(Q).Where(x => x.Length > 0));
                else
                {
                    value = Q(raw).Re(@"\s+(?:and|or|in|from|attachment|attached|goes|go|should)$", "");
                    if (new[] { "a", "an", "the", "size", "more", "less", "extension", "attachment", "tag" }.Contains(value.ToLowerInvariant()) || value.Length < 2) continue;
                    if (value.StartsWith("tag", StringComparison.OrdinalIgnoreCase)) continue;
                }
                Add(new Condition(ConditionField.anyText, ConditionOp.contains, value));
            }
        }
        if (head.Captures(@"\b(?:named|called)\s+(⟦\d+⟧|[\w\-\.\*]+)") is { } named)
        {
            var v = Q(named[1]);
            Add(new Condition(ConditionField.name, v.Contains('*') ? ConditionOp.equals : ConditionOp.contains, v));
        }
        if (!explicitFields.Contains(ConditionField.docType))
        {
            var quotedLower = quotes.Select(q => q.ToLowerInvariant()).ToList();
            foreach (var (noun, type) in DocTypeNouns)
            {
                if (!Regex.IsMatch(l, @"\b" + Regex.Escape(noun) + @"\b")) continue;
                if (quotedLower.Any(q => q.Contains(type))) break;
                if (outList.Any(c => c.Field == ConditionField.anyText && c.Value.ToLowerInvariant().Contains(type))) break;
                Add(new Condition(ConditionField.docType, ConditionOp.equals, type)); break;
            }
        }
        if (!explicitFields.Contains(ConditionField.kind) && !explicitFields.Contains(ConditionField.ext))
        {
            foreach (var (noun, field, value) in KindNouns)
            {
                if (!Regex.IsMatch(l, @"\b" + Regex.Escape(noun) + @"\b")) continue;
                if (noun == "documents" && trigger.Folders.Contains(Paths.Expand("~/Documents"), Paths.Comparer) && !l.Contains(" documents in") && !l.Contains("all documents")) continue;
                if (field == ConditionField.kind && value == "code" && explicitFields.Contains(ConditionField.language)) break;
                Add(new Condition(field, value.Contains(',') ? ConditionOp.isAnyOf : ConditionOp.equals, value)); break;
            }
            if ((l.Captures(@"\s\.(\w{1,6})\s+files?") ?? l.Captures(@"\s(\w{2,5})\s+files?\b")) is { } extM && ContentExtractor.KindByExt.ContainsKey(extM[1]) && !outList.Any(c => c.Field == ConditionField.ext))
                Add(new Condition(ConditionField.ext, ConditionOp.equals, extM[1]));
        }
        if (l.Captures(@"older than\s+(\d+)\s*(day|week|month|year)s?") is { } older)
            Add(new Condition(ConditionField.ageDays, ConditionOp.greaterThan, ((int)(double.Parse(older[1]) * UnitDays(older[2]))).ToString()));
        if (l.Captures(@"(?:newer than|in the last|from the last|within)\s+(\d+)\s*(day|week|month|year)s?") is { } newer)
            Add(new Condition(ConditionField.ageDays, ConditionOp.lessThan, ((int)(double.Parse(newer[1]) * UnitDays(newer[2]))).ToString()));
        if (l.Captures(@"(?:larger|bigger|greater|over|more) than\s+(\d+(?:\.\d+)?)\s*(kb|mb|gb)") is { } big) Add(new Condition(ConditionField.sizeMB, ConditionOp.greaterThan, SizeMB(big[1], big[2])));
        else if (l.Captures(@"(?:>|over|above)\s*(\d+(?:\.\d+)?)\s*(kb|mb|gb)") is { } big2 && trigger.Kind.IsFileTrigger()) Add(new Condition(ConditionField.sizeMB, ConditionOp.greaterThan, SizeMB(big2[1], big2[2])));
        if (l.Captures(@"(?:smaller|less) than\s+(\d+(?:\.\d+)?)\s*(kb|mb|gb)") is { } small) Add(new Condition(ConditionField.sizeMB, ConditionOp.lessThan, SizeMB(small[1], small[2])));
        if (l.Captures(@"(?:from|downloaded from|off)\s+((?:[\w\-]+\.)+(?:com|org|net|edu|io|dev|app|gov|co|ai|uk|in))\b") is { } src) Add(new Condition(ConditionField.sourceURL, ConditionOp.contains, src[1]));
        if (!explicitFields.Contains(ConditionField.tag) && head.Captures(@"\btagged\s+(?:as\s+|with\s+)?#?(⟦\d+⟧|[\w\-]+)") is { } tagged) Add(new Condition(ConditionField.tag, ConditionOp.equals, Q(tagged[1])));
        if (!explicitFields.Contains(ConditionField.project) && head.Captures(@"\b(?:belongs? to|in|for|part of)\s+(?:the\s+)?project\s+(⟦\d+⟧|[\w\- ]+?)(?=\s+(?:and|or)\s|,|$)") is { } proj)
            Add(new Condition(ConditionField.project, ConditionOp.equals, Q(proj[1])));
        if (l.Captures(@"(?:after|past)\s+(\d{1,2})(?::\d{2})?\s*(am|pm)?") is { } after)
        {
            var h = int.Parse(after[1]); if (after[2] == "pm" && h < 12) h += 12;
            Add(new Condition(ConditionField.hour, ConditionOp.greaterThan, (h - 1).ToString()));
        }
        if (l.Captures(@"before\s+(\d{1,2})(?::\d{2})?\s*(am|pm)?") is { } before)
        {
            var h = int.Parse(before[1]); if (before[2] == "pm" && h < 12) h += 12;
            Add(new Condition(ConditionField.hour, ConditionOp.lessThan, h.ToString()));
        }
        if (l.Contains("on weekends") || l.Contains("at the weekend")) Add(new Condition(ConditionField.weekday, ConditionOp.isAnyOf, "1,7"));
        if (l.Contains("on weekdays")) Add(new Condition(ConditionField.weekday, ConditionOp.isAnyOf, "2,3,4,5,6"));
        return outList;
    }

    public double UnitDays(string unit) => unit.StartsWith("week") ? 7 : unit.StartsWith("month") ? 30 : unit.StartsWith("year") ? 365 : 1;
    static string SizeMB(string n, string unit)
    {
        var v = double.Parse(n, System.Globalization.CultureInfo.InvariantCulture);
        return (unit == "gb" ? v * 1024 : unit == "kb" ? v / 1024 : v).ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
    }

    // MARK: Actions

    List<string> SplitClauses(string body)
    {
        var parts = new List<string>();
        foreach (var chunk in body.Split([',', ';']))
        {
            var current = "";
            foreach (var p in chunk.Split(" and "))
            {
                var t = p.Trim().Re(@"^(?:then|also|and)\s+", "");
                if (current.Length == 0) current = t;
                else if (StartsWithVerb(t)) { parts.Add(current); current = t; }
                else current += " and " + t;
            }
            if (current.Length > 0)
            {
                if (!StartsWithVerb(current) && parts.Count > 0) { var last = parts[^1]; parts.RemoveAt(parts.Count - 1); parts.Add(last + ", " + current); }
                else parts.Add(current);
            }
        }
        return parts.Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
    }

    public List<RuleAction> ParseActions(string body, Trigger trigger, List<string> quotes, List<string> warnings, List<string> explanation)
    {
        var outList = new List<RuleAction>();
        string Q(string s) => Restore(s, quotes).Trim();
        void Add(RuleAction a) { outList.Add(a); explanation.Add("Then: " + a.Summary); }
        const string pronoun = @"(?:(?:it|them|the file|the files|these|those)\s+)?";

        foreach (var clauseRaw in SplitClauses(body))
        {
            var clause = clauseRaw.Re(@"\s+(?:automatically|for me|please)$", "");
            var c = clause.ToLowerInvariant();

            if (clause.Captures(@"^(?:move|put|file|send|save|goes|go|drop|place)\s+" + pronoun + @"(?:in|to|into|under|inside|at)\s+(?:the\s+|my\s+)?(.+?)(?:\s+folder)?$") is { } mv && !c.Contains("trash") && !c.Contains("recycle"))
            { Add(new RuleAction(ActionKind.move, ResolveFolder(Q(mv[1])))); continue; }
            if (c.StartsWith("move to trash") || c.StartsWith("trash") || c.StartsWith("delete") || c.Contains("to the trash") || c.Contains("to trash") || c.Contains("recycle bin"))
            { Add(new RuleAction(ActionKind.trash)); continue; }
            if (clause.Captures(@"^(?:copy|duplicate|back up|backup)\s+" + pronoun + @"(?:in|to|into)\s+(?:the\s+|my\s+)?(.+?)(?:\s+folder)?$") is { } cp)
            { Add(new RuleAction(ActionKind.copy, ResolveFolder(Q(cp[1])))); continue; }
            if ((clause.Captures(@"^(?:tag|label|mark)\s+" + pronoun + @"(?:as\s+|with\s+)?(?:tags?\s+)?(.+)$") ?? clause.Captures(@"^(?:gets?|add|apply|set)\s+(?:the\s+|a\s+)?tags?\s+(.+)$")) is { } tg)
            {
                var tags = ParseTags(tg[1], quotes);
                if (tags.Count > 0) Add(new RuleAction(ActionKind.tag, tags: tags));
                continue;
            }
            if (clause.Captures(@"^(?:remove|clear)\s+(?:the\s+)?tags?\s+(.+)$") is { } rt) { Add(new RuleAction(ActionKind.removeTag, tags: ParseTags(rt[1], quotes))); continue; }
            if (clause.Captures(@"^(?:add|link|attach|assign)\s+" + pronoun + @"to\s+(?:the\s+)?(?:project\s+(.+)|(.+?)\s+project)$") is { } ap)
            {
                var name = Q(ap[1].Length == 0 ? ap[2] : ap[1]);
                Add(new RuleAction(ActionKind.addToProject, name, project: MatchProject(name))); continue;
            }
            if (c.Contains("mirror") && c.Contains("project") || c.StartsWith("create project") || c.StartsWith("create a project ") && !c.Contains("folder"))
            { Add(new RuleAction(ActionKind.createProject, "{title}", p: new() { ["tags"] = "{tag}" })); continue; }
            if (clause.Captures(@"^rename\s+" + pronoun + @"(?:to|as)\s+(.+)$") is { } rn) { Add(new RuleAction(ActionKind.rename, Q(rn[1]))); continue; }
            if (c.StartsWith("compress") || c.StartsWith("zip")) { Add(new RuleAction(ActionKind.compress)); continue; }
            if (clause.Captures(@"^sync\s+(.+?)(?:\s+folders?)?(?:\s+to\s+(?:the\s+)?(.+?))?$") is { } sy)
            {
                var rawSources = sy[1].Re(@"^(?:my|the)\s+", "");
                var pieces = rawSources.StartsWith('/') || rawSources.StartsWith('~') || rawSources.StartsWith('⟦') || Regex.IsMatch(rawSources, @"^[A-Za-z]:[\\/]") ? [rawSources]
                    : rawSources.Split(',').SelectMany(x => x.Split(" and ")).ToList();
                var sources = pieces.Select(x => Q(x).Re(@"\s+folders?$", "")).Where(x => x.Length > 0).ToList();
                var explicitDest = sy[2].Length > 0 && !sy[2].ToLowerInvariant().Contains("drive");
                string destBase;
                if (explicitDest) destBase = ResolveFolder(Q(sy[2]));
                else if (trigger.VolumeName is { } v) destBase = $"vol:{v}{Paths.Sep}Nexus Sync";
                else { destBase = $"vol:Backup{Paths.Sep}Nexus Sync"; warnings.Add("No drive specified; syncing to the drive labelled “Backup”."); }
                foreach (var s in sources)
                {
                    var src = ResolveFolder(s);
                    var target = explicitDest && sources.Count == 1 ? destBase : destBase + Paths.Sep + Path.GetFileName(src);
                    Add(new RuleAction(ActionKind.syncFolder, target, p: new() { ["source"] = src }));
                }
                continue;
            }
            if (c.Contains("archive"))
            {
                var days = 30;
                if (c.Captures(@"(\d+)\s*(day|week|month)s?") is { } dm) days = (int)(double.Parse(dm[1]) * UnitDays(dm[2]));
                var ps = new Dictionary<string, string> { ["days"] = days.ToString() };
                var folder = trigger.Folders.FirstOrDefault() ?? "~/Downloads";
                var dest = "~/Documents/Archive/{year}";
                if (c.Contains("screenshot")) { ps["kind"] = "screenshot"; folder = "~/Pictures/Screenshots"; dest = "~/Documents/Archive/Screenshots/{year}"; }
                if (clause.Captures(@"\b(?:in|from)\s+(?:the\s+|my\s+)?(⟦\d+⟧|~?[\w/\\:\- ]+?)(?:\s+folder)?(?:\s+to\s+|$)") is { } af) folder = ResolveFolder(Q(af[1]));
                if (clause.Captures(@"\bto\s+(?:the\s+)?(⟦\d+⟧|~?[\w/\\:\-\{\} ]+?)(?:\s+folder)?$") is { } at) dest = ResolveFolder(Q(at[1]));
                ps["folder"] = Paths.Expand(folder);
                Add(new RuleAction(ActionKind.archiveOld, Paths.Expand(dest), p: ps)); continue;
            }
            if (c.Contains("duplicate")) { Add(new RuleAction(ActionKind.findDuplicates, p: new() { ["large"] = c.Contains("large") ? "1" : "0" })); continue; }
            if (c.Contains("report") || c.Contains("digest"))
            {
                var type = c.Contains("storage") ? "storage" : c.Contains("week") ? "weekly" : c.Contains("month") ? "monthly" : c.Contains("markdown summary") ? "daily" : "weekly";
                Add(new RuleAction(ActionKind.generateReport, p: new() { ["type"] = type })); continue;
            }
            if (c.StartsWith("summarize") || c.StartsWith("summarise") || c.Contains("markdown summary"))
            {
                if (c.Contains("summary") && !trigger.Kind.IsFileTrigger()) Add(new RuleAction(ActionKind.generateReport, p: new() { ["type"] = "daily" }));
                else Add(new RuleAction(ActionKind.summarize));
                continue;
            }
            if (c.StartsWith("auto-sort") || c.StartsWith("sort") || c.StartsWith("organize") || c.StartsWith("organise") || c.StartsWith("clean up") || c.StartsWith("tidy"))
            {
                var folder = trigger.Folders.FirstOrDefault() ?? "~/Downloads";
                if (clause.Captures(@"^(?:auto-sort|sort|organi[sz]e|clean up|tidy(?: up)?)\s+(?:the\s+|my\s+)?(⟦\d+⟧|~?[\w/\\:\- ]+?)(?:\s+folder)?$") is { } so) folder = ResolveFolder(Q(so[1]));
                Add(new RuleAction(ActionKind.sortFolder, Paths.Expand(folder))); continue;
            }
            if (c.Contains("suggest") && (c.Contains("cleanup") || c.Contains("clean up") || c.Contains("clean-up")))
            { Add(new RuleAction(ActionKind.notify, "Cleanup suggestions are ready in Insights", p: new() { ["open"] = "insights" })); continue; }
            if (c.Contains("reminder") || c.Contains("remind me"))
            {
                var title = clause.Captures(@"remind me (?:to\s+)?(.+)$") is { } rm ? Q(rm[1]) : "Review {name}";
                Add(new RuleAction(ActionKind.createReminder, title, p: new() { ["due"] = c.Contains("next week") ? "7d" : "1d" })); continue;
            }
            if (c.Contains("calendar") || c.Contains("deadline"))
            { Add(new RuleAction(ActionKind.createCalendarEvent, c.Contains("deadline") ? "Deadline: {basename}" : "{basename}", p: new() { ["detectDate"] = "1" })); continue; }
            if (c.Contains("task"))
            {
                Add(new RuleAction(ActionKind.createTask, "Follow up: {title}{basename}"));
                if (c.Contains("folder")) Add(new RuleAction(ActionKind.createFolder, ResolveFolder("Projects/{title}")));
                continue;
            }
            if (clause.Captures(@"^(?:create|make|prepare|set up|open)\s+(?:a\s+|the\s+|my\s+)?(?:project\s+)?(?:folder\s+(⟦\d+⟧|.+)|(⟦\d+⟧|.+?)\s+folder)$") is { } cf)
            {
                var folder = ResolveFolder(Q(cf[1].Length == 0 ? cf[2] : cf[1]));
                Add(new RuleAction(ActionKind.createFolder, folder));
                if (c.StartsWith("prepare") || c.StartsWith("open")) Add(new RuleAction(ActionKind.revealInFinder, folder));
                continue;
            }
            if ((clause.Captures(@"^(?:notify|alert|tell)\s+(?:me\s+)?(?:that\s+|with\s+|about\s+)?(.*)$") ?? clause.Captures(@"^send\s+(?:me\s+)?(?:a\s+)?notification\s*(?:that|saying|:)?\s*(.*)$")) is { } nt)
            {
                var msg = Q(nt[1]);
                Add(new RuleAction(ActionKind.notify, msg.Length == 0 ? "{name} was processed" : msg)); continue;
            }
            if (clause.Captures(@"^run\s+(?:the\s+)?plugin\s+(.+)$") is { } pl) { Add(new RuleAction(ActionKind.runPlugin, Q(pl[1]))); continue; }
            if (clause.Captures(@"^run\s+(?:the\s+)?(?:powershell\s+|shell\s+)?(?:script|command)\s+(.+)$") is { } sh) { Add(new RuleAction(ActionKind.runShell, Q(sh[1]))); continue; }
            if (clause.Captures(@"^(?:post|send)\s+(?:a\s+message\s+)?(?:to\s+)?slack\s*(?:saying|:)?\s*(.*)$") is { } sl) { Add(new RuleAction(ActionKind.slackMessage, Q(sl[1]).Length == 0 ? "{name} arrived" : Q(sl[1]))); continue; }
            if (clause.Captures(@"^(?:create|open|file)\s+(?:a\s+)?github issue\s*(?:titled|:)?\s*(.*)$") is { } gh) { Add(new RuleAction(ActionKind.githubIssue, Q(gh[1]).Length == 0 ? "{name}" : Q(gh[1]))); continue; }
            if (clause.Captures(@"^(?:append|add|log)\s+(?:it\s+)?(?:to\s+)?(?:my\s+)?(?:daily\s+)?(?:obsidian)(?:\s+note)?\s*(.*)$") is { } ob) { Add(new RuleAction(ActionKind.obsidianNote, Q(ob[1]).Length == 0 ? "Nexus/Inbox.md" : Q(ob[1]))); continue; }
            if (clause.Captures(@"^call\s+(?:the\s+)?webhook\s+(\S+)") is { } wh) { Add(new RuleAction(ActionKind.webhook, Q(wh[1]))); continue; }
            if (c.StartsWith("open")) { Add(new RuleAction(ActionKind.openFile)); continue; }
            if (c.StartsWith("reveal") || c.StartsWith("show")) { Add(new RuleAction(ActionKind.revealInFinder)); continue; }
            if (clause.Captures(@"^(?:set\s+)?category\s+(?:to\s+)?(.+)$") is { } cat) { Add(new RuleAction(ActionKind.setCategory, Q(cat[1]))); continue; }
            warnings.Add($"Didn’t understand “{Q(clause)}”.");
        }
        return outList;
    }

    List<string> ParseTags(string raw, List<string> quotes) =>
        Regex.Split(Regex.Replace(raw, @"\s+(?:and|&)\s+", ","), "[, ]")
            .Select(t => Restore(t, quotes).Trim().Trim('#', '`', '\'', '"', '.'))
            .Where(t => t.Length > 0 && !new[] { "as", "with", "tag", "tags", "it", "them", "the" }.Contains(t.ToLowerInvariant())).ToList();

    string MatchProject(string name) =>
        KnownProjects.FirstOrDefault(p => p.Equals(name, StringComparison.OrdinalIgnoreCase))
        ?? KnownProjects.FirstOrDefault(p => p.Contains(name, StringComparison.OrdinalIgnoreCase) || name.Contains(p, StringComparison.OrdinalIgnoreCase)) ?? name;

    /// "School/Science/Reports" → Documents\School\Science\Reports unless it starts with a well-known folder.
    public string ResolveFolder(string raw)
    {
        var s = raw.Trim().Trim('`', '\'', '"', '.');
        s = s.Re(@"^(?:the|my)\s+", "").Re(@"\s+folder$", "");
        if (s.StartsWith('~') || s.StartsWith('/') || s.StartsWith('\\') || Regex.IsMatch(s, @"^[A-Za-z]:[\\/]") || s.StartsWith("vol:")) return s.StartsWith("vol:") ? s : Paths.Expand(s);
        var parts = s.Split('/', '\\');
        if (WellKnownFolders.TryGetValue(parts[0], out var known) || WellKnownFolders.TryGetValue(s, out known))
        {
            var rest = WellKnownFolders.ContainsKey(s) ? "" : string.Join('/', parts.Skip(1));
            return Paths.Expand(rest.Length == 0 ? known : known + "/" + rest);
        }
        return Paths.Expand(Path.Combine(Paths.Expand(LibraryRoot), s.Replace('/', Paths.Sep)));
    }

    static List<Condition> Dedupe(List<Condition> cs)
    {
        var seen = new HashSet<string>();
        return cs.Where(c => seen.Add($"{c.Field}|{c.Op}|{c.Value.ToLowerInvariant()}")).ToList();
    }

    static string MakeName(Trigger trigger, List<Condition> conditions, List<RuleAction> actions)
    {
        var left = new List<string>();
        foreach (var c in conditions.Take(2))
        {
            left.Add(c.Field switch
            {
                ConditionField.ext => c.Value.ToUpperInvariant(),
                ConditionField.kind or ConditionField.docType or ConditionField.language => c.Value.Capitalized(),
                ConditionField.anyText or ConditionField.content or ConditionField.name => $"“{c.Value}”",
                ConditionField.ageDays => c.Op == ConditionOp.greaterThan ? $">{c.Value}d old" : $"<{c.Value}d old",
                ConditionField.hour => c.Op == ConditionOp.greaterThan ? $"after {int.Parse(c.Value) + 1}:00" : $"before {c.Value}:00",
                ConditionField.sizeMB => c.Op == ConditionOp.greaterThan ? $">{c.Value} MB" : $"<{c.Value} MB",
                _ => c.Value
            });
        }
        if (left.Count == 0 || !trigger.Kind.IsFileTrigger()) left.Insert(0, trigger.Kind.IsFileTrigger() ? "New file" : trigger.Summary);
        var move = actions.FirstOrDefault(a => a.Kind is ActionKind.move or ActionKind.copy or ActionKind.syncFolder);
        var right = move != null ? Paths.Abbreviate(move.Target).Replace("~/Documents/", "") : actions[0].Kind.Label();
        return (string.Join(" + ", left) + " → " + right).Trim();
    }
}
