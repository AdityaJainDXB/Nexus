import Foundation

public struct RuleCompileResult {
    public var rule: Rule?
    public var warnings: [String]
    public var confidence: Double
    public var explanation: [String]     // human-readable "I understood..." lines shown in the editor
}

/// Deterministic natural-language → Rule compiler. Handles the common grammar of file rules and
/// event automations without any model; the engine falls back to the local LLM for anything else.
///
///   "If a PDF in Downloads contains 'lab report' → move to School/Science/Reports, tag MYP3, add to project Science Fair"
///   "When external drive 'Backup' is connected → sync Projects and School folders"
///   "Every Sunday 9 AM: archive old screenshots, generate storage report"
public final class NLRuleCompiler {
    public var libraryRoot: String
    public var knownProjects: [String]

    public init(libraryRoot: String = "~/Documents", knownProjects: [String] = []) {
        self.libraryRoot = libraryRoot
        self.knownProjects = knownProjects
    }

    static let actionVerbs = ["move", "put", "file", "send", "copy", "duplicate", "tag", "label", "mark", "rename", "add", "link", "archive", "sync", "back up", "backup",
                              "notify", "alert", "tell", "remind", "create", "make", "prepare", "open", "reveal", "show", "run", "compress", "zip",
                              "summarize", "summarise", "trash", "delete", "remove", "find", "suggest", "generate", "save", "post", "append", "call",
                              "sort", "auto-sort", "organize", "organise", "clean", "gets", "get", "goes", "go", "set", "mirror", "then"]

    static let wellKnownFolders = ["downloads": "~/Downloads", "desktop": "~/Desktop", "documents": "~/Documents", "pictures": "~/Pictures",
                                   "movies": "~/Movies", "music": "~/Music", "home": "~", "icloud drive": "~/Library/Mobile Documents/com~apple~CloudDocs"]

    static let docTypeNouns: [(String, String)] = [("invoices", "invoice"), ("invoice", "invoice"), ("receipts", "receipt"), ("receipt", "receipt"),
                                                   ("lab reports", "lab report"), ("lab report", "lab report"), ("syllabi", "syllabus"), ("syllabus", "syllabus"),
                                                   ("resumes", "resume"), ("resume", "resume"), ("contracts", "contract"), ("contract", "contract"),
                                                   ("bank statements", "bank statement"), ("statements", "bank statement"), ("tax documents", "tax document"),
                                                   ("research papers", "research paper"), ("papers", "research paper"), ("meeting notes", "meeting notes"),
                                                   ("specs", "spec"), ("assignments", "assignment"), ("homework", "assignment"), ("tickets", "ticket"),
                                                   ("essays", "essay"), ("manuals", "manual"), ("3d models", "3d model"), ("screen recordings", "screen recording")]

    static let kindNouns: [(String, ConditionField, String)] = [
        ("screenshots", .kind, "screenshot"), ("screenshot", .kind, "screenshot"), ("pdfs", .ext, "pdf"), ("pdf", .ext, "pdf"),
        ("images", .kind, "image"), ("image", .kind, "image"), ("photos", .kind, "image"), ("pictures", .kind, "image"),
        ("videos", .kind, "video"), ("video", .kind, "video"), ("code files", .kind, "code"), ("code file", .kind, "code"), ("scripts", .kind, "code"),
        ("spreadsheets", .kind, "spreadsheet"), ("presentations", .kind, "presentation"), ("slides", .kind, "presentation"),
        ("installers", .kind, "installer"), ("dmgs", .ext, "dmg"), ("dmg", .ext, "dmg"), ("zips", .ext, "zip"), ("zip files", .ext, "zip"), ("archives", .kind, "archive"),
        ("audio files", .kind, "audio"), ("recordings", .kind, "audio"), ("word documents", .ext, "doc,docx"), ("documents", .kind, "document"), ("docs", .kind, "document"),
        ("stl files", .ext, "stl,3mf,obj"), ("stls", .ext, "stl,3mf,obj"), ("gcode", .ext, "gcode"), ("csvs", .ext, "csv"), ("csv files", .ext, "csv"),
    ]

    static let languages = ["python": "Python", "swift": "Swift", "javascript": "JavaScript", "typescript": "TypeScript", "rust": "Rust", "go": "Go",
                            "java": "Java", "c++": "C++", "ruby": "Ruby", "shell": "Shell", "kotlin": "Kotlin", "arduino": "Arduino"]

    // MARK: - Entry

    public func compile(_ input: String, now: Date = Date()) -> RuleCompileResult {
        var warnings: [String] = []
        var explanation: [String] = []
        var (text, quotes) = extractQuotes(normalize(input))

        // Strip leading "create a rule:" / "rule:" wrappers
        if let m = text.captures(#"^\s*(?:please\s+)?(?:create|make|add|new)?\s*(?:a\s+)?(?:rule|automation)\s*(?:that|to|:|,)?\s*(.*)$"#) { text = m[1] }

        guard let (headRaw, bodyRaw) = splitHeadBody(text) else {
            return RuleCompileResult(rule: nil, warnings: ["Couldn't find an action (e.g. “→ move to …”, “tag …”)."], confidence: 0, explanation: [])
        }
        let head = headRaw.trimmed
        let body = bodyRaw.trimmed

        var trigger = parseTrigger(head, quotes: quotes, explanation: &explanation)
        var conditions = parseConditions(head, trigger: &trigger, quotes: quotes, explanation: &explanation)
        let actions = parseActions(body, trigger: trigger, quotes: quotes, warnings: &warnings, explanation: &explanation)

        guard !actions.isEmpty else {
            return RuleCompileResult(rule: nil, warnings: warnings + ["No actions recognised in “\(restore(body, quotes))”."], confidence: 0.1, explanation: explanation)
        }
        if trigger.kind.isFileTrigger && trigger.folders.isEmpty && conditions.isEmpty {
            warnings.append("This rule would match every new file in all watched folders.")
        }
        // Screenshots default to Desktop when no folder is given
        if trigger.kind.isFileTrigger && trigger.folders.isEmpty && conditions.contains(where: { $0.field == .kind && $0.value == "screenshot" }) {
            trigger.folders = ["~/Desktop"]
        }
        conditions = dedupe(conditions)

        var rule = Rule(name: makeName(trigger: trigger, conditions: conditions, actions: actions), trigger: trigger,
                        conditions: ConditionGroup(match: Self.isAnyMatch(head) ? .any : .all, conditions: conditions),
                        actions: actions, naturalLanguage: input)
        if !trigger.kind.isFileTrigger && trigger.kind != .schedule { rule.cooldownMinutes = 30 }
        if actions.contains(where: { $0.kind == .trash }) {
            rule.requireConfirmation = true
            warnings.append("Rules that trash files require confirmation in the Review Queue by default.")
        }
        rule.estimatedSecondsSaved = actions.count * 15 + 10
        let confidence = min(1, 0.55 + 0.1 * Double(actions.count) + 0.05 * Double(conditions.count) - 0.15 * Double(warnings.count))
        return RuleCompileResult(rule: rule, warnings: warnings, confidence: max(0.2, confidence), explanation: explanation)
    }

    /// "or" between whole conditions means ANY; "or" between quoted alternatives ('a' or 'b') does not.
    static func isAnyMatch(_ head: String) -> Bool {
        let stripped = head.lowercased().replacingOccurrences(of: #"⟦\d+⟧(\s*(,|or)\s*⟦\d+⟧)+"#, with: "⟦alt⟧", options: .regularExpression)
        return stripped.contains(" or ") && !stripped.contains(" and ")
    }

    // MARK: - Pre-processing

    func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "[‘’`]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[“”]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "→|->|=>|⇒", with: " → ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
    }

    /// Replaces quoted spans with ⟦n⟧ placeholders so punctuation inside them can't break parsing.
    func extractQuotes(_ s: String) -> (String, [String]) {
        var quotes: [String] = []
        guard let re = try? NSRegularExpression(pattern: #""([^"]+)"|(?<![A-Za-z])'([^']+)'(?![A-Za-z])"#) else { return (s, []) }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let r1 = Range(m.range(at: 1), in: s) ?? Range(m.range(at: 2), in: s)!
            quotes.insert(String(s[r1]), at: 0)
            out.replaceSubrange(Range(m.range, in: out)!, with: "⟦Q⟧")
        }
        // number placeholders in order
        var i = 0
        while let r = out.range(of: "⟦Q⟧") { out.replaceSubrange(r, with: "⟦\(i)⟧"); i += 1 }
        return (out, quotes)
    }

    func restore(_ s: String, _ quotes: [String]) -> String {
        var out = s
        for (i, q) in quotes.enumerated() { out = out.replacingOccurrences(of: "⟦\(i)⟧", with: q) }
        return out
    }

    func splitHeadBody(_ text: String) -> (String, String)? {
        if let r = text.range(of: " → ") { return (String(text[..<r.lowerBound]), String(text[r.upperBound...])) }
        let lower = text.lowercased()
        // "X goes to Y" / "X should go to Y"
        if let m = text.captures(#"^(.*?)\s+(?:should\s+)?(?:goes|go|get moved|gets moved|are moved|is moved)\s+(?:in)?to\s+(.*)$"#) {
            return (m[1], "move to " + m[2])
        }
        if let m = text.captures(#"^((?:if|when|whenever|every|each|on|at|after|once)\b[^:]*?):\s*(.*)$"#) { return (m[1], m[2]) }
        if let m = text.captures(#"^((?:if|when|whenever)\b.*?),\s*(?:then\s+)?(.*)$"#), startsWithVerb(m[2]) { return (m[1], m[2]) }
        if let r = lower.range(of: " then ") { return (String(text[..<r.lowerBound]), String(text[r.upperBound...])) }
        // Imperative: "Move invoices from Downloads to Finance" → treat as rule with actions first
        if startsWithVerb(text) {
            if let m = text.captures(#"^(move|copy|tag|rename|archive|compress|trash)\s+(.*?)\s+(?:(?:in|from)\s+(\S+(?:\s\S+)?)\s+)?(to|as|with)\s+(.*)$"#) {
                let subject = m[2] + (m[3].isEmpty ? "" : " in \(m[3])")
                return (subject, "\(m[1]) \(m[4]) \(m[5])")
            }
        }
        // "... when/if ..." at the end: "Tag screenshots as ui when they land on Desktop"
        if let m = text.captures(#"^(.*?)\s+(?:when|whenever|if)\s+(.*)$"#), startsWithVerb(m[1]) { return (m[2], m[1]) }
        // Fall back: first clause that starts with a verb
        let words = text.split(separator: " ").map(String.init)
        for i in 1..<max(1, words.count) where startsWithVerb(words[i...].joined(separator: " ")) && !["file", "files", "mark", "set", "add", "run"].contains(words[i].lowercased()) {
            return (words[..<i].joined(separator: " "), words[i...].joined(separator: " "))
        }
        return nil
    }

    func startsWithVerb(_ s: String) -> Bool {
        let l = s.lowercased().trimmed
        return Self.actionVerbs.contains { l.hasPrefix($0 + " ") || l == $0 }
    }

    // MARK: - Trigger

    func parseTrigger(_ head: String, quotes: [String], explanation: inout [String]) -> Trigger {
        let l = " " + head.lowercased() + " "
        func q(_ s: String) -> String { restore(s, quotes).trimmed }

        if l.contains(" every ") || l.contains(" each ") || l.contains(" daily") || l.contains(" weekly") || l.contains(" nightly") || l.hasPrefix(" at ") || l.contains(" on sundays") || l.contains(" monthly"),
           case .cron(let cron)? = NLTime.parse(head) {
            explanation.append("Runs on a schedule: \(CronExpression.describe(cron))")
            return Trigger(kind: .schedule, cron: cron)
        }
        if let m = l.captures(#"disk(?: space)?(?: is)?\s*(?:<|below|under|less than|drops below|falls below)\s*(\d+(?:\.\d+)?)\s*gb"#) {
            explanation.append("When free disk space drops below \(m[1]) GB")
            return Trigger(kind: .diskSpaceBelow, threshold: Double(m[1]))
        }
        if l.contains("low disk") || l.contains("disk is full") || l.contains("disk space is low") {
            explanation.append("When free disk space is low (< 25 GB)")
            return Trigger(kind: .diskSpaceBelow, threshold: 25)
        }
        if let m = head.captures(#"(?:drive|volume|disk|ssd|usb)\s+(.+?)\s+(?:is\s+)?(?:connected|plugged in|mounted|attached|inserted)"#)
            ?? head.captures(#"(?:connect|plug in|mount)\s+(?:the\s+|my\s+)?(.+?)\s+(?:drive|volume|disk)"#) {
            let name = q(m[1]).replacingOccurrences(of: "^(?:external|the|my)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            explanation.append("When the drive “\(name)” is connected")
            return Trigger(kind: .volumeMounted, volumeName: name)
        }
        if let m = head.captures(#"(?:drive|volume|disk)\s+(.+?)\s+(?:is\s+)?(?:ejected|disconnected|unmounted|removed)"#) {
            explanation.append("When the drive “\(q(m[1]))” is ejected")
            return Trigger(kind: .volumeUnmounted, volumeName: q(m[1]))
        }
        if let m = head.captures(#"(?:when|whenever|if)\s+(?:i\s+(?:open|launch|start)\s+)?(.+?)(?:\s+app)?\s+(?:opens|launches|starts|is opened|is launched|is started)"#)
            ?? head.captures(#"(?:when|whenever)\s+i\s+(?:open|launch|start)\s+(.+?)$"#) {
            let app = q(m[1]).replacingOccurrences(of: "^the\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            explanation.append("When “\(app)” opens")
            return Trigger(kind: .appLaunched, appName: app)
        }
        if let m = head.captures(#"(?:when|whenever|if)\s+(?:i\s+(?:quit|close)\s+)?(.+?)(?:\s+app)?\s+(?:quits|closes|is closed|is quit|exits)"#) {
            explanation.append("When “\(q(m[1]))” quits")
            return Trigger(kind: .appQuit, appName: q(m[1]))
        }
        if let m = head.captures(#"(~?[\w/ ]+?)\s+(?:folder\s+)?(?:has|contains|reaches)\s+(?:>|more than|over|at least)\s*(\d+)\s+(?:files|items)"#) {
            let folder = resolveFolder(q(m[1]).replacingOccurrences(of: "^(?:when|if|my|the)\\s+", with: "", options: [.regularExpression, .caseInsensitive]))
            explanation.append("When \(Paths.abbreviate(folder)) has more than \(m[2]) files")
            return Trigger(kind: .folderCountAbove, folders: [folder], threshold: Double(m[2]))
        }
        if let m = head.captures(#"(~?[\w/ ]+?)\s+(?:folder\s+)?(?:is|grows|gets)\s+(?:larger|bigger|beyond|over|above|more)\s+(?:than\s+)?(\d+(?:\.\d+)?)\s*gb"#) {
            let folder = resolveFolder(q(m[1]).replacingOccurrences(of: "^(?:when|if|my|the)\\s+", with: "", options: [.regularExpression, .caseInsensitive]))
            explanation.append("When \(Paths.abbreviate(folder)) grows beyond \(m[2]) GB")
            return Trigger(kind: .folderSizeAbove, folders: [folder], threshold: Double(m[2]))
        }
        if let m = l.captures(#"idle (?:for )?(\d+)\s*(?:min|minutes)"#) {
            explanation.append("When the Mac is idle for \(m[1]) minutes")
            return Trigger(kind: .idle, threshold: Double(m[1]))
        }
        if l.contains(" wakes") || l.contains(" wake up") || l.contains(" wake from sleep") { explanation.append("When the Mac wakes"); return Trigger(kind: .wake) }
        if l.contains("focus starts") || l.contains("focus begins") || l.contains("start focus") { explanation.append("When a focus session starts"); return Trigger(kind: .focusStarted) }
        if l.contains("focus ends") { explanation.append("When a focus session ends"); return Trigger(kind: .focusEnded) }
        if l.contains("github") && (l.contains("issue") || l.contains("pull request") || l.contains(" pr ")) {
            let ev = l.contains("pull request") || l.contains(" pr ") ? "github.prReviewRequested" : "github.issueAssigned"
            explanation.append("When GitHub reports: \(ev)")
            return Trigger(kind: .connectorEvent, connectorEvent: ev)
        }
        if (l.contains("email") || l.contains(" mail")) && l.contains("attachment") {
            explanation.append("When Mail saves an attachment (Mail connector)")
            return Trigger(kind: .connectorEvent, folders: ["~/Library/Application Support/Nexus/Inbox/Mail"], connectorEvent: "mail.attachment")
        }
        if l.contains("notion") && l.contains("page") {
            explanation.append("When a Notion page changes (Notion connector)")
            return Trigger(kind: .connectorEvent, connectorEvent: "notion.pageTagged")
        }
        if l.contains("calendar event") && (l.contains("starts") || l.contains("begins")) {
            explanation.append("When a calendar event starts")
            return Trigger(kind: .connectorEvent, connectorEvent: "calendar.eventStarting")
        }

        var kind: TriggerKind = .fileAdded
        if l.contains("download") && (l.contains("finish") || l.contains("complete") || l.contains("done")) {
            kind = .downloadCompleted
        } else if l.contains(" changes") || l.contains(" modified") || l.contains(" is edited") || l.contains(" is saved") {
            kind = .fileModified
        }
        var trigger = Trigger(kind: kind)
        // folder: "in Downloads", "from ~/Desktop", "folder is Downloads", "lands on Desktop"
        let folderPatterns = [#"(?:folder|location)\s+is\s+(⟦\d+⟧|~?[\w\-/\.]+(?:\s[A-Z][\w\-]*)*)"#,
                              #"\b(?:in|from|into|on|inside|within|under)\s+(?:the\s+|my\s+)?(⟦\d+⟧|~[\w\-/\. ]+?|/[\w\-/\. ]+?|downloads|desktop|documents|pictures|movies|music|icloud drive|[A-Z][\w\-]*(?:/[\w\-]+)+)(?:\s+folder)?(?=\s|$|,)"#]
        for p in folderPatterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
                guard let r = Range(m.range(at: 1), in: head) else { continue }
                let raw = q(String(head[r]))
                if raw.lowercased().hasPrefix("project") || raw.lowercased() == "the last" { continue }
                if Self.wellKnownFolders[raw.lowercased()] != nil || raw.contains("/") || raw.hasPrefix("~") || head[r].hasPrefix("⟦") {
                    let folder = resolveFolder(raw)
                    if !trigger.folders.contains(folder) { trigger.folders.append(folder) }
                }
            }
        }
        if kind == .downloadCompleted && trigger.folders.isEmpty { trigger.folders = ["~/Downloads"].map(Paths.expand) }
        if l.contains("subfolder") || l.contains("recursively") || l.contains("anywhere in") { trigger.recursive = true }
        let where_ = trigger.folders.isEmpty ? "any watched folder" : trigger.folders.map(Paths.abbreviate).joined(separator: ", ")
        explanation.append("\(kind.label) in \(where_)")
        return trigger
    }

    // MARK: - Conditions

    func parseConditions(_ head: String, trigger: inout Trigger, quotes: [String], explanation: inout [String]) -> [Condition] {
        var out: [Condition] = []
        let l = " " + head.lowercased() + " "
        func q(_ s: String) -> String { restore(s, quotes).trimmed }
        func add(_ c: Condition) { out.append(c); explanation.append("Only if \(c.summary)") }
        let valuePattern = #"(⟦\d+⟧|[^,]+?)(?=\s+(?:and|or|→|then)\s|,|$)"#

        // Explicit field comparisons
        let fieldOps: [(String, ConditionField)] = [("file ?name|name", .name), ("content|text|body", .content), ("extension", .ext),
                                                    ("(?:download(?:ed)? )?(?:source|url|origin)", .sourceURL), ("type|doc(?:ument)? type", .docType),
                                                    ("topic", .topic), ("project", .project), ("tag", .tag)]
        var explicitFields = Set<ConditionField>()
        for (namePattern, field) in fieldOps {
            let opPattern = #"\b(?:"# + namePattern + #")\s+(contains|includes|has|does not contain|doesn't contain|starts with|begins with|ends with|is not|isn't|is|equals|matches)\s+"# + valuePattern
            guard let re = try? NSRegularExpression(pattern: opPattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
                guard let opR = Range(m.range(at: 1), in: head), let vR = Range(m.range(at: 2), in: head) else { continue }
                let opWord = head[opR].lowercased()
                var value = q(String(head[vR]))
                let op: ConditionOp
                switch opWord {
                case "contains", "includes", "has": op = .contains
                case "does not contain", "doesn't contain": op = .notContains
                case "starts with", "begins with": op = .startsWith
                case "ends with": op = .endsWith
                case "is not", "isn't": op = .notEquals
                case "matches": op = .matches
                default: op = field == .name || field == .content ? .contains : .equals
                }
                if field == .project { value = value.replacingOccurrences(of: "^project\\s+", with: "", options: [.regularExpression, .caseInsensitive]) }
                if field == .docType, let kindMatch = Self.kindNouns.first(where: { $0.0 == value.lowercased() }) {
                    add(Condition(kindMatch.1, .equals, kindMatch.2)); explicitFields.insert(kindMatch.1); continue
                }
                add(Condition(field, op, value))
                explicitFields.insert(field)
            }
        }
        // language
        if let m = l.captures(#"language\s+is\s+(\w[\w\+#]*)"#) {
            add(Condition(.language, .equals, Self.languages[m[1]] ?? m[1].capitalized)); explicitFields.insert(.language)
        } else if let lang = Self.languages.first(where: { l.contains(" \($0.key) file") || l.contains(" \($0.key) script") || l.contains(" \($0.key) code") }) {
            add(Condition(.language, .equals, lang.value)); explicitFields.insert(.language)
        }
        // Folder condition handled in trigger for file triggers
        if trigger.kind == .folderCountAbove || trigger.kind == .folderSizeAbove { /* folder already bound */ }

        // Generic "contains X" / "with X" / "mentioning X" (name or content)
        if !explicitFields.contains(.content) && !explicitFields.contains(.name) {
            let generic = #"\b(?:contains|containing|with|mentioning|mentions|about|related to|that says|saying|including)\s+(?:the\s+(?:word|phrase|text)\s+)?(⟦\d+⟧(?:\s*(?:,|or)\s*⟦\d+⟧)*|[\w\-]+(?:\s[\w\-]+)?)"#
            if let re = try? NSRegularExpression(pattern: generic, options: [.caseInsensitive]) {
                for m in re.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
                    guard let r = Range(m.range(at: 1), in: head) else { continue }
                    let raw = String(head[r])
                    // 'a' or 'b' → one condition matching either alternative
                    var value = raw.hasPrefix("⟦") ? raw.components(separatedBy: CharacterSet(charactersIn: ",")).flatMap { $0.components(separatedBy: " or ") }.map { q($0) }.filter { !$0.isEmpty }.joined(separator: "|") : q(raw)
                    if !raw.hasPrefix("⟦") {
                        // unquoted: stop at filler words
                        value = value.replacingOccurrences(of: "\\s+(?:and|or|in|from|attachment|attached|goes|go|should)$", with: "", options: [.regularExpression, .caseInsensitive])
                        if ["a", "an", "the", "size", "more", "less", "extension", "attachment", "tag"].contains(value.lowercased()) || value.count < 2 { continue }
                        if value.lowercased().hasPrefix("tag") { continue }
                    }
                    add(Condition(.anyText, .contains, value))
                }
            }
        }
        // Filenames: "named X"
        if let m = head.captures(#"\b(?:named|called)\s+(⟦\d+⟧|[\w\-\.\*]+)"#) {
            let v = q(m[1])
            add(Condition(.name, v.contains("*") ? .equals : .contains, v))
        }
        // Doc types ("invoices", "lab reports") when not already expressed as quoted content
        if !explicitFields.contains(.docType) {
            let quotedLower = quotes.map { $0.lowercased() }
            for (noun, type) in Self.docTypeNouns where l.range(of: "\\b\(NSRegularExpression.escapedPattern(for: noun))\\b", options: .regularExpression) != nil {
                if quotedLower.contains(where: { $0.contains(type) }) { break }
                if out.contains(where: { $0.field == .anyText && $0.value.lowercased().contains(type) }) { break }
                add(Condition(.docType, .equals, type)); break
            }
        }
        // File kinds
        if !explicitFields.contains(.kind) && !explicitFields.contains(.ext) {
            for (noun, field, value) in Self.kindNouns where l.range(of: "\\b\(NSRegularExpression.escapedPattern(for: noun))\\b", options: .regularExpression) != nil {
                if noun == "documents" && trigger.folders.contains(Paths.expand("~/Documents")) && !l.contains(" documents in") && !l.contains("all documents") { continue }
                if field == .kind && value == "code" && explicitFields.contains(.language) { break }
                add(Condition(field, value.contains(",") ? .isAnyOf : .equals, value)); break
            }
            if let m = l.captures(#"\s\.(\w{1,6})\s+files?"#) ?? l.captures(#"\s(\w{2,5})\s+files?\b"#), ContentExtractor.kindByExt[m[1]] != nil, !out.contains(where: { $0.field == .ext }) {
                add(Condition(.ext, .equals, m[1]))
            }
        }
        // Age & size
        if let m = l.captures(#"older than\s+(\d+)\s*(day|week|month|year)s?"#) {
            add(Condition(.ageDays, .greaterThan, String(Int(Double(m[1])! * unitDays(m[2])))))
        }
        if let m = l.captures(#"(?:newer than|in the last|from the last|within)\s+(\d+)\s*(day|week|month|year)s?"#) {
            add(Condition(.ageDays, .lessThan, String(Int(Double(m[1])! * unitDays(m[2])))))
        }
        if let m = l.captures(#"(?:larger|bigger|greater|over|more) than\s+(\d+(?:\.\d+)?)\s*(kb|mb|gb)"#) {
            add(Condition(.sizeMB, .greaterThan, sizeMB(m[1], m[2])))
        } else if let m = l.captures(#"(?:>|over|above)\s*(\d+(?:\.\d+)?)\s*(kb|mb|gb)"#), trigger.kind.isFileTrigger {
            add(Condition(.sizeMB, .greaterThan, sizeMB(m[1], m[2])))
        }
        if let m = l.captures(#"(?:smaller|less) than\s+(\d+(?:\.\d+)?)\s*(kb|mb|gb)"#) {
            add(Condition(.sizeMB, .lessThan, sizeMB(m[1], m[2])))
        }
        // Download source: "from github.com"
        if let m = l.captures(#"(?:from|downloaded from|off)\s+((?:[\w\-]+\.)+(?:com|org|net|edu|io|dev|app|gov|co|ai|uk|in))\b"#) {
            add(Condition(.sourceURL, .contains, m[1]))
        }
        // Tags / projects
        if !explicitFields.contains(.tag), let m = head.captures(#"\btagged\s+(?:as\s+|with\s+)?#?(⟦\d+⟧|[\w\-]+)"#) {
            add(Condition(.tag, .equals, q(m[1])))
        }
        if !explicitFields.contains(.project), let m = head.captures(#"\b(?:belongs? to|in|for|part of)\s+(?:the\s+)?project\s+(⟦\d+⟧|[\w\- ]+?)(?=\s+(?:and|or)\s|,|$)"#) {
            add(Condition(.project, .equals, q(m[1])))
        }
        // Time of day / weekday
        if let m = l.captures(#"(?:after|past)\s+(\d{1,2})(?::\d{2})?\s*(am|pm)?"#) {
            var h = Int(m[1]) ?? 0
            if m[2] == "pm" && h < 12 { h += 12 }
            add(Condition(.hour, .greaterThan, String(h - 1)))
        }
        if let m = l.captures(#"before\s+(\d{1,2})(?::\d{2})?\s*(am|pm)?"#) {
            var h = Int(m[1]) ?? 0
            if m[2] == "pm" && h < 12 { h += 12 }
            add(Condition(.hour, .lessThan, String(h)))
        }
        if l.contains("on weekends") || l.contains("at the weekend") { add(Condition(.weekday, .isAnyOf, "1,7")) }
        if l.contains("on weekdays") { add(Condition(.weekday, .isAnyOf, "2,3,4,5,6")) }
        return out
    }

    func unitDays(_ unit: String) -> Double { unit.hasPrefix("week") ? 7 : unit.hasPrefix("month") ? 30 : unit.hasPrefix("year") ? 365 : 1 }
    func sizeMB(_ n: String, _ unit: String) -> String {
        let v = Double(n) ?? 0
        return String(format: "%g", unit == "gb" ? v * 1024 : unit == "kb" ? v / 1024 : v)
    }

    // MARK: - Actions

    func splitClauses(_ body: String) -> [String] {
        var parts: [String] = []
        for chunk in body.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let pieces = chunk.components(separatedBy: " and ")
            var current = ""
            for p in pieces {
                let t = p.trimmed.replacingOccurrences(of: "^(?:then|also|and)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
                if current.isEmpty { current = t }
                else if startsWithVerb(t) { parts.append(current); current = t }
                else { current += " and " + t }
            }
            if !current.isEmpty {
                if !startsWithVerb(current), let last = parts.popLast() { parts.append(last + ", " + current) }
                else { parts.append(current) }
            }
        }
        return parts.map { $0.trimmed }.filter { !$0.isEmpty }
    }

    func parseActions(_ body: String, trigger: Trigger, quotes: [String], warnings: inout [String], explanation: inout [String]) -> [RuleAction] {
        var out: [RuleAction] = []
        func q(_ s: String) -> String { restore(s, quotes).trimmed }
        func add(_ a: RuleAction) { out.append(a); explanation.append("Then: \(a.summary)") }
        let pronoun = #"(?:(?:it|them|the file|the files|these|those)\s+)?"#

        for clauseRaw in splitClauses(body) {
            let clause = clauseRaw.replacingOccurrences(of: "\\s+(?:automatically|for me|please)$", with: "", options: [.regularExpression, .caseInsensitive])
            let c = clause.lowercased()

            if let m = clause.captures(#"^(?:move|put|file|send|save|goes|go|drop|place)\s+"# + pronoun + #"(?:in|to|into|under|inside|at)\s+(?:the\s+|my\s+)?(.+?)(?:\s+folder)?$"#), !c.contains("trash") {
                add(RuleAction(kind: .move, target: resolveFolder(q(m[1])))); continue
            }
            if c.hasPrefix("move to trash") || c.hasPrefix("trash") || c.hasPrefix("delete") || c.contains("to the trash") || c.contains("to trash") {
                add(RuleAction(kind: .trash)); continue
            }
            if let m = clause.captures(#"^(?:copy|duplicate|back up|backup)\s+"# + pronoun + #"(?:in|to|into)\s+(?:the\s+|my\s+)?(.+?)(?:\s+folder)?$"#) {
                add(RuleAction(kind: .copy, target: resolveFolder(q(m[1])))); continue
            }
            if let m = clause.captures(#"^(?:tag|label|mark)\s+"# + pronoun + #"(?:as\s+|with\s+)?(?:tags?\s+)?(.+)$"#) ?? clause.captures(#"^(?:gets?|add|apply|set)\s+(?:the\s+|a\s+)?tags?\s+(.+)$"#) {
                let tags = parseTags(m[1], quotes)
                if !tags.isEmpty { add(RuleAction(kind: .tag, tags: tags)) }
                continue
            }
            if let m = clause.captures(#"^(?:remove|clear)\s+(?:the\s+)?tags?\s+(.+)$"#) {
                add(RuleAction(kind: .removeTag, tags: parseTags(m[1], quotes))); continue
            }
            if let m = clause.captures(#"^(?:add|link|attach|assign)\s+"# + pronoun + #"to\s+(?:the\s+)?(?:project\s+(.+)|(.+?)\s+project)$"#) {
                let name = q(m[1].isEmpty ? m[2] : m[1])
                add(RuleAction(kind: .addToProject, target: name, project: matchProject(name))); continue
            }
            if c.contains("mirror") && c.contains("project") || c.hasPrefix("create project") || c.hasPrefix("create a project ") && !c.contains("folder") {
                add(RuleAction(kind: .createProject, target: "{title}", params: ["tags": "{tag}"])); continue
            }
            if let m = clause.captures(#"^rename\s+"# + pronoun + #"(?:to|as)\s+(.+)$"#) {
                add(RuleAction(kind: .rename, target: q(m[1]))); continue
            }
            if c.hasPrefix("compress") || c.hasPrefix("zip") { add(RuleAction(kind: .compress)); continue }
            if let m = clause.captures(#"^sync\s+(.+?)(?:\s+folders?)?(?:\s+to\s+(?:the\s+)?(.+?))?$"#) {
                let rawSources = m[1].replacingOccurrences(of: "^(?:my|the)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
                // A path ("~/Documents/Documents & Proposals") is one source; plain names may be listed with "and"/","
                let pieces = rawSources.hasPrefix("/") || rawSources.hasPrefix("~") || rawSources.hasPrefix("⟦") ? [rawSources]
                    : rawSources.components(separatedBy: ",").flatMap { $0.components(separatedBy: " and ") }
                let sources = pieces.map { q($0).replacingOccurrences(of: "\\s+folders?$", with: "", options: [.regularExpression, .caseInsensitive]) }.filter { !$0.isEmpty }
                let destBase: String
                if !m[2].isEmpty && !m[2].lowercased().contains("drive") { destBase = resolveFolder(q(m[2])) }
                else if let v = trigger.volumeName { destBase = "/Volumes/\(v)/Nexus Sync" }
                else { destBase = "/Volumes/Backup/Nexus Sync"; warnings.append("No drive specified; syncing to /Volumes/Backup.") }
                let explicitDest = !m[2].isEmpty && !m[2].lowercased().contains("drive")
                for s in sources {
                    let src = resolveFolder(s)
                    let target = explicitDest && sources.count == 1 ? destBase : (destBase as NSString).appendingPathComponent((src as NSString).lastPathComponent)
                    add(RuleAction(kind: .syncFolder, target: target, params: ["source": src]))
                }
                continue
            }
            if c.contains("archive") {
                var days = 30
                if let m = c.captures(#"(\d+)\s*(day|week|month)s?"#) { days = Int(Double(m[1])! * unitDays(m[2])) }
                var params = ["days": String(days)]
                var folder = trigger.folders.first ?? "~/Downloads"
                var dest = "~/Documents/Archive/{year}"
                if c.contains("screenshot") { params["kind"] = "screenshot"; folder = "~/Desktop"; dest = "~/Documents/Archive/Screenshots/{year}" }
                if let m = clause.captures(#"\b(?:in|from)\s+(?:the\s+|my\s+)?(⟦\d+⟧|~?[\w/\- ]+?)(?:\s+folder)?(?:\s+to\s+|$)"#) { folder = resolveFolder(q(m[1])) }
                if let m = clause.captures(#"\bto\s+(?:the\s+)?(⟦\d+⟧|~?[\w/\-\{\} ]+?)(?:\s+folder)?$"#) { dest = resolveFolder(q(m[1])) }
                params["folder"] = Paths.expand(folder)
                add(RuleAction(kind: .archiveOld, target: Paths.expand(dest), params: params)); continue
            }
            if c.contains("duplicate") { add(RuleAction(kind: .findDuplicates, params: ["large": c.contains("large") ? "1" : "0"])); continue }
            if c.contains("report") || c.contains("digest") {
                let type = c.contains("storage") ? "storage" : c.contains("week") ? "weekly" : c.contains("month") ? "monthly" : c.contains("markdown summary") ? "daily" : "weekly"
                add(RuleAction(kind: .generateReport, params: ["type": type])); continue
            }
            if c.hasPrefix("summarize") || c.hasPrefix("summarise") || c.contains("markdown summary") {
                if c.contains("summary") && !trigger.kind.isFileTrigger { add(RuleAction(kind: .generateReport, params: ["type": "daily"])) }
                else { add(RuleAction(kind: .summarize)) }
                continue
            }
            if c.hasPrefix("auto-sort") || c.hasPrefix("sort") || c.hasPrefix("organize") || c.hasPrefix("organise") || c.hasPrefix("clean up") || c.hasPrefix("tidy") {
                var folder = trigger.folders.first ?? "~/Downloads"
                if let m = clause.captures(#"^(?:auto-sort|sort|organi[sz]e|clean up|tidy(?: up)?)\s+(?:the\s+|my\s+)?(⟦\d+⟧|~?[\w/\- ]+?)(?:\s+folder)?$"#) { folder = resolveFolder(q(m[1])) }
                add(RuleAction(kind: .sortFolder, target: Paths.expand(folder))); continue
            }
            if c.contains("suggest") && (c.contains("cleanup") || c.contains("clean up") || c.contains("clean-up")) {
                add(RuleAction(kind: .notify, target: "Cleanup suggestions are ready in Insights", params: ["open": "insights"])); continue
            }
            if c.contains("reminder") || c.contains("remind me") {
                let title = clause.captures(#"remind me (?:to\s+)?(.+)$"#).map { q($0[1]) } ?? "Review {name}"
                let due = c.contains("tomorrow") ? "1d" : c.contains("next week") ? "7d" : "1d"
                add(RuleAction(kind: .createReminder, target: title, params: ["due": due])); continue
            }
            if c.contains("calendar") || c.contains("deadline") {
                add(RuleAction(kind: .createCalendarEvent, target: c.contains("deadline") ? "Deadline: {basename}" : "{basename}", params: ["detectDate": "1"])); continue
            }
            if c.contains("task") {
                add(RuleAction(kind: .createTask, target: "Follow up: {title}{basename}"))
                if c.contains("folder") {
                    add(RuleAction(kind: .createFolder, target: resolveFolder("Projects/{title}")))
                }
                continue
            }
            if let m = clause.captures(#"^(?:create|make|prepare|set up|open)\s+(?:a\s+|the\s+|my\s+)?(?:project\s+)?(?:folder\s+(⟦\d+⟧|.+)|(⟦\d+⟧|.+?)\s+folder)$"#) {
                let folder = resolveFolder(q(m[1].isEmpty ? m[2] : m[1]))
                add(RuleAction(kind: .createFolder, target: folder))
                if c.hasPrefix("prepare") || c.hasPrefix("open") { add(RuleAction(kind: .revealInFinder, target: folder)) }
                continue
            }
            if let m = clause.captures(#"^(?:notify|alert|tell)\s+(?:me\s+)?(?:that\s+|with\s+|about\s+)?(.*)$"#) ?? clause.captures(#"^send\s+(?:me\s+)?(?:a\s+)?notification\s*(?:that|saying|:)?\s*(.*)$"#) {
                let msg = q(m[1])
                add(RuleAction(kind: .notify, target: msg.isEmpty ? "{name} was processed" : msg)); continue
            }
            if let m = clause.captures(#"^run\s+(?:the\s+)?shortcut\s+(.+)$"#) { add(RuleAction(kind: .runShortcut, target: q(m[1]))); continue }
            if let m = clause.captures(#"^run\s+(?:the\s+)?applescript\s+(.+)$"#) { add(RuleAction(kind: .runAppleScript, target: q(m[1]))); continue }
            if let m = clause.captures(#"^run\s+(?:the\s+)?plugin\s+(.+)$"#) { add(RuleAction(kind: .runPlugin, target: q(m[1]))); continue }
            if let m = clause.captures(#"^run\s+(?:the\s+)?(?:shell\s+)?(?:script|command)\s+(.+)$"#) { add(RuleAction(kind: .runShell, target: q(m[1]))); continue }
            if let m = clause.captures(#"^(?:post|send)\s+(?:a\s+message\s+)?(?:to\s+)?slack\s*(?:saying|:)?\s*(.*)$"#) { add(RuleAction(kind: .slackMessage, target: q(m[1]).isEmpty ? "{name} arrived" : q(m[1]))); continue }
            if let m = clause.captures(#"^(?:create|open|file)\s+(?:a\s+)?github issue\s*(?:titled|:)?\s*(.*)$"#) { add(RuleAction(kind: .githubIssue, target: q(m[1]).isEmpty ? "{name}" : q(m[1]))); continue }
            if let m = clause.captures(#"^(?:append|add|log)\s+(?:it\s+)?(?:to\s+)?(?:my\s+)?(?:daily\s+)?(?:obsidian)(?:\s+note)?\s*(.*)$"#) { add(RuleAction(kind: .obsidianNote, target: q(m[1]).isEmpty ? "Nexus/Inbox.md" : q(m[1]))); continue }
            if c.contains("notion") { add(RuleAction(kind: .notionPage, target: "{name}")); continue }
            if let m = clause.captures(#"^call\s+(?:the\s+)?webhook\s+(\S+)"#) { add(RuleAction(kind: .webhook, target: q(m[1]))); continue }
            if c.hasPrefix("open") { add(RuleAction(kind: .openFile)); continue }
            if c.hasPrefix("reveal") || c.hasPrefix("show") { add(RuleAction(kind: .revealInFinder)); continue }
            if let m = clause.captures(#"^(?:set\s+)?category\s+(?:to\s+)?(.+)$"#) { add(RuleAction(kind: .setCategory, target: q(m[1]))); continue }
            warnings.append("Didn’t understand “\(q(clause))”.")
        }
        return out
    }

    func parseTags(_ raw: String, _ quotes: [String]) -> [String] {
        raw.replacingOccurrences(of: "\\s+(?:and|&)\\s+", with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { restore($0, quotes).trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#`'\".")) }
            .filter { !$0.isEmpty && !["as", "with", "tag", "tags", "it", "them", "the"].contains($0.lowercased()) }
    }

    func matchProject(_ name: String) -> String {
        knownProjects.first { $0.lowercased() == name.lowercased() }
            ?? knownProjects.first { $0.lowercased().contains(name.lowercased()) || name.lowercased().contains($0.lowercased()) }
            ?? name
    }

    /// "School/Science/Reports" → ~/Documents/School/Science/Reports unless it starts with a well-known home folder.
    public func resolveFolder(_ raw: String) -> String {
        var s = raw.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"."))
        s = s.replacingOccurrences(of: "^(?:the|my)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s+folder$", with: "", options: [.regularExpression, .caseInsensitive])
        if s.hasPrefix("~") || s.hasPrefix("/") { return Paths.expand(s) }
        let first = s.split(separator: "/").first.map { String($0).lowercased() } ?? s.lowercased()
        if let known = Self.wellKnownFolders[first] {
            let rest = s.split(separator: "/").dropFirst().joined(separator: "/")
            return Paths.expand(rest.isEmpty ? known : known + "/" + rest)
        }
        return Paths.expand((libraryRoot as NSString).appendingPathComponent(s))
    }

    func dedupe(_ cs: [Condition]) -> [Condition] {
        var seen = Set<String>()
        return cs.filter { seen.insert("\($0.field)|\($0.op)|\($0.value.lowercased())").inserted }
    }

    func makeName(trigger: Trigger, conditions: [Condition], actions: [RuleAction]) -> String {
        var left: [String] = []
        for c in conditions.prefix(2) {
            switch c.field {
            case .ext: left.append(c.value.uppercased())
            case .kind, .docType, .language: left.append(c.value.capitalized)
            case .anyText, .content, .name: left.append("“\(c.value)”")
            case .ageDays: left.append(c.op == .greaterThan ? ">\(c.value)d old" : "<\(c.value)d old")
            case .hour: left.append(c.op == .greaterThan ? "after \((Int(c.value) ?? 0) + 1):00" : "before \(c.value):00")
            case .sizeMB: left.append(c.op == .greaterThan ? ">\(c.value) MB" : "<\(c.value) MB")
            default: left.append(c.value)
            }
        }
        if left.isEmpty || !trigger.kind.isFileTrigger { left.insert(trigger.kind.isFileTrigger ? "New file" : trigger.summary, at: 0) }
        let right: String
        if let move = actions.first(where: { [.move, .copy, .syncFolder].contains($0.kind) }) {
            right = Paths.abbreviate(move.target).replacingOccurrences(of: "~/Documents/", with: "")
        } else {
            right = actions.first?.kind.label ?? "Action"
        }
        return (left.joined(separator: " + ") + " → " + right).trimmed
    }
}
