import Foundation

public struct FileQuery: Hashable {
    public var folders: [String] = []
    public var recursive = true
    public var conditions: [Condition] = []
    public var useLastResults = false
    public var useContext = false          // "this", "these", "the selected files", "this document"
    public var limit = 500
    public var text: String = ""

    public var searchTerms: [String] {
        conditions.filter { [.anyText, .content, .topic, .entity].contains($0.field) && $0.op == .contains }.map(\.value)
    }
}

public indirect enum CommandIntent: Hashable {
    case find(FileQuery)
    case fileActions(FileQuery, [RuleAction])
    case summarizeFolder(String)
    case summarizeQuery(FileQuery)
    case summarizeProject(String)
    case createRule(String)
    case schedule(command: String, when: NLTime.Result)
    case organize(String)
    case findDuplicates
    case report(String)
    case createProject(name: String, keywords: [String], folder: String?, deadline: Date?)
    case focus(project: String, minutes: Int)
    case endFocus
    case undo
    case archive(folder: String, days: Int, kind: String?)
    case pause, resume
    case navigate(String)
    case learnTaxonomy
    case runRule(String)
    case classify(String)
    case ask(String)                        // question answered from your files (on-device RAG)
    case briefing                           // spoken/visual daily briefing
    case smartFile(FileQuery)               // "file this" — rules first, then learned destinations
    case cleanDuplicates                    // trash extra copies, keep the organized one
    case cleanSimilarScreenshots            // keep newest of each near-identical group
    case unknown(String)

    public var label: String {
        switch self {
        case .find: return "Search"
        case .fileActions(_, let a): return a.map { $0.kind.label }.joined(separator: " + ")
        case .summarizeFolder, .summarizeQuery, .summarizeProject: return "Summarize"
        case .createRule: return "Create rule"
        case .schedule: return "Schedule"
        case .organize: return "Organize"
        case .findDuplicates: return "Find duplicates"
        case .report: return "Report"
        case .createProject: return "Create project"
        case .focus: return "Start focus"
        case .endFocus: return "End focus"
        case .undo: return "Undo"
        case .archive: return "Archive"
        case .pause: return "Pause automations"
        case .resume: return "Resume automations"
        case .navigate: return "Open"
        case .learnTaxonomy: return "Learn folders"
        case .runRule: return "Run rule"
        case .classify: return "Classify"
        case .ask: return "Answer from your files"
        case .briefing: return "Briefing"
        case .smartFile: return "File it"
        case .cleanDuplicates: return "Clean up duplicates"
        case .cleanSimilarScreenshots: return "Clean up similar screenshots"
        case .unknown: return "Ask"
        }
    }
    public var symbol: String {
        switch self {
        case .find: return "magnifyingglass"
        case .fileActions(_, let a): return a.first?.kind.symbol ?? "bolt"
        case .summarizeFolder, .summarizeQuery, .summarizeProject: return "sparkles"
        case .createRule: return "point.3.connected.trianglepath.dotted"
        case .schedule: return "calendar.badge.clock"
        case .organize: return "wand.and.stars"
        case .findDuplicates: return "square.on.square"
        case .report: return "chart.bar.doc.horizontal"
        case .createProject: return "square.stack.3d.up.badge.a"
        case .focus, .endFocus: return "scope"
        case .undo: return "arrow.uturn.backward"
        case .archive: return "archivebox"
        case .pause: return "pause.circle"
        case .resume: return "play.circle"
        case .navigate: return "arrow.up.right.square"
        case .learnTaxonomy: return "brain"
        case .runRule: return "play"
        case .classify: return "doc.text.magnifyingglass"
        case .ask: return "text.bubble"
        case .briefing: return "sun.max"
        case .smartFile: return "tray.and.arrow.down"
        case .cleanDuplicates: return "trash.square"
        case .cleanSimilarScreenshots: return "camera.on.rectangle"
        case .unknown: return "questionmark.bubble"
        }
    }
    /// Whether execution changes anything (needs the one-confirm step).
    public var isMutating: Bool {
        switch self {
        case .find, .summarizeFolder, .summarizeQuery, .summarizeProject, .navigate, .unknown, .ask, .briefing: return false
        case .fileActions(_, let a): return a.contains { $0.kind != .summarize && $0.kind != .revealInFinder && $0.kind != .openFile }
        default: return true
        }
    }
}

public struct CommandStep: Hashable {
    public var text: String
    public var intent: CommandIntent
}

/// Natural-language command → ordered steps. Pure & deterministic (the engine may ask the local LLM
/// to rewrite unparseable input into this grammar and parse again).
public final class CommandParser {
    public var compiler: NLRuleCompiler

    public init(compiler: NLRuleCompiler) { self.compiler = compiler }

    static let contextSubjects: Set<String> = ["this", "this file", "these", "these files", "the selection", "selected files", "the selected files", "my selection",
                                               "this document", "the current file", "current file", "the current document", "what i'm looking at", "this pdf", "this image"]

    public static let grammarHelp = """
    move|copy <files> to <folder> · tag <files> as <tags> · add <files> to project <name> · rename <files> to <pattern>
    find|show <files> · summarize <folder> folder · summarize project <name> · organize <folder> · archive screenshots older than N days
    find duplicates · generate weekly|storage report · create project <name> with keywords a, b · focus on <project> for N hours · end focus
    create rule: <if/when … → actions> · <command> tonight at 10pm / every Sunday at 9am · undo · pause · resume
    <files> examples: "all invoices from Downloads", "PDFs containing 'MYP3'", "everything about hydroponics in the last 3 months", "them"
    """

    public func parse(_ input: String) -> [CommandStep] {
        let text = input.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !text.isEmpty else { return [] }
        // Rules are single units even when they contain "and"/"then"
        if looksLikeRule(text) { return [CommandStep(text: text, intent: .createRule(text))] }
        return splitSteps(text).map { CommandStep(text: $0, intent: parseStep($0)) }
    }

    func looksLikeRule(_ t: String) -> Bool {
        let l = t.lowercased()
        // "When is my report due?" / "If I moved it, where is it?" are questions, not automations
        if l.hasSuffix("?") || l.range(of: #"^(?:when|if)\s+(?:is|are|was|were|does|do|did|will|am|can|should|'s)\b"#, options: .regularExpression) != nil { return false }
        if l.range(of: #"^(?:create|make|add|new)\s+(?:a\s+)?(?:rule|automation)"#, options: .regularExpression) != nil { return true }
        if t.contains("→") || t.contains("->") { return true }
        if l.hasPrefix("if ") || l.hasPrefix("when ") || l.hasPrefix("whenever ") { return true }
        if (l.hasPrefix("every ") || l.hasPrefix("each ")) && l.contains(":") { return true }
        if l.contains(" goes to ") || l.contains(" should go to ") { return true }
        return false
    }

    static let stepVerbs = "move|copy|tag|label|add|link|rename|summarize|summarise|compress|zip|archive|trash|delete|find|show|search|list|organize|organise|sort|generate|create|open|reveal|focus|undo"

    func splitSteps(_ text: String) -> [String] {
        let pattern = #"\s*(?:,\s*then\s+|\s+then\s+|;\s*|,\s*and\s+(?=(?:"# + Self.stepVerbs + #")\b)|\s+and\s+(?=(?:then\s+)?(?:"# + Self.stepVerbs + #")\s+(?:them|those|these|it|all|every|the|my)\b)|,\s*(?=(?:"# + Self.stepVerbs + #")\s+(?:them|those|these|it)\b))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [text] }
        var parts: [String] = []
        var last = text.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            parts.append(String(text[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(text[last...]))
        return parts.map { $0.trimmed }.filter { !$0.isEmpty }
    }

    func parseStep(_ s: String) -> CommandIntent {
        let l = s.lowercased()
        let compiler = self.compiler

        // Time-shifted command: "Run classification on Projects tonight at 10 PM"
        if let when = scheduledPhrase(s) {
            let stripped = s.replacingOccurrences(of: #"\s*(?:tonight|tomorrow|this evening|(?:next|on|this)\s+(?:mon|tues|wednes|thurs|fri|satur|sun)day|in\s+\d+\s*(?:minutes?|mins?|hours?|hrs?|days?)|every\s+\w+(?:\s+\w+)?|daily|weekly|nightly)?\s*(?:at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?|at\s+noon|at\s+midnight)?\s*$"#,
                                              with: "", options: [.regularExpression, .caseInsensitive]).trimmed
            if !stripped.isEmpty && stripped.lowercased() != l {
                // Interpret only the time phrase ("in 1 minute"), not words inside the command ("daily report")
                let phrase = String(s.dropFirst(stripped.count)).trimmed
                return .schedule(command: stripped, when: NLTime.parse(phrase) ?? when)
            }
        }

        switch l {
        case "undo", "undo that", "undo last", "undo last command", "revert": return .undo
        case "pause", "pause nexus", "pause automations": return .pause
        case "resume", "resume nexus", "resume automations", "unpause": return .resume
        case "find duplicates", "find duplicate files", "show duplicates", "find large duplicate files": return .findDuplicates
        case "end focus", "stop focus", "exit focus", "stop focusing": return .endFocus
        case "learn my folders", "learn folders", "learn my folder structure", "relearn taxonomy": return .learnTaxonomy
        default: break
        }
        if l.range(of: #"^(?:brief me|briefing|daily briefing|morning briefing|good morning|what'?s (?:up|new|on my plate)|catch me up|what did i miss)\b"#, options: .regularExpression) != nil {
            return .briefing
        }
        if let m = s.captures(#"^(?:file|put away|tidy|organi[sz]e|sort)\s+(this|these|this file|these files|the selection|selected files|the selected files|this document)$"#) {
            return .smartFile(query(m[1]))
        }
        if let m = s.captures(#"^summari[sz]e\s+(this|these|this file|these files|this document|the selection|selected files)$"#) {
            return .summarizeQuery(query(m[1]))
        }
        if isQuestion(s) { return .ask(s) }
        if let m = l.captures(#"^(?:open|show|go to)\s+(?:the\s+)?(review queue|review|insights|rules|projects|tasks|schedule|activity|settings|connectors|files|today)$"#) {
            return .navigate(m[1])
        }
        if let m = l.captures(#"^run\s+(?:the\s+)?rule\s+(.+)$"#) { return .runRule(restoreCase(s, m[1])) }
        if let m = s.captures(#"^(?:run\s+)?(?:classification|classify|index|scan|re-?index)\s+(?:on\s+|of\s+)?(?:my\s+|the\s+)?(.+?)(?:\s+folder)?$"#) {
            return .classify(compiler.resolveFolder(m[1]))
        }
        if l.range(of: #"^(?:clean(?: up)?|delete|remove|trash|get rid of|dedupe|deduplicate)\b.*(?:duplicate|dupes|copies)"#, options: .regularExpression) != nil || l == "dedupe" {
            return .cleanDuplicates
        }
        if l.range(of: #"^(?:clean(?: up)?|delete|remove|trash|tidy)\b.*(?:similar|identical|duplicate) screenshots"#, options: .regularExpression) != nil {
            return .cleanSimilarScreenshots
        }
        if l.contains("duplicate") && (l.hasPrefix("find") || l.hasPrefix("show")) { return .findDuplicates }
        if let m = l.captures(#"^(?:generate|run|create|make|build|show)\s+(?:a\s+|the\s+|my\s+)?(weekly|monthly|daily|storage)?\s*(?:storage\s+)?(?:report|digest)"#) {
            return .report(m[1].isEmpty ? (l.contains("storage") ? "storage" : "weekly") : m[1])
        }
        if let m = s.captures(#"^(?:create|make|start|new)\s+(?:a\s+)?project\s+(?:called\s+|named\s+)?(.+?)(?:\s+with\s+keywords?\s+(.+?))?(?:\s+(?:in|at)\s+folder\s+(.+?))?(?:\s+due\s+(.+))?$"#) {
            let keywords = m[2].split(separator: ",").map { $0.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }.filter { !$0.isEmpty }
            var deadline: Date?
            if !m[4].isEmpty {
                if case .once(let d)? = NLTime.parse(m[4]) { deadline = d }
                else if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
                        let match = detector.firstMatch(in: m[4], range: NSRange(m[4].startIndex..., in: m[4])) { deadline = match.date }
            }
            return .createProject(name: m[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\"")), keywords: keywords,
                                  folder: m[3].isEmpty ? nil : compiler.resolveFolder(m[3]), deadline: deadline)
        }
        if let m = s.captures(#"^(?:start\s+)?focus(?:ing)?\s+(?:on\s+)?(?:project\s+)?(.+?)(?:\s+for\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m))?$"#) {
            let n = Double(m[2]) ?? 2
            let minutes = m[3].isEmpty ? 120 : (m[3].hasPrefix("h") ? Int(n * 60) : Int(n))
            return .focus(project: m[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\"")), minutes: minutes)
        }
        if let m = s.captures(#"^summari[sz]e\s+(?:the\s+)?project\s+(.+)$"#) { return .summarizeProject(m[1]) }
        if let m = s.captures(#"^summari[sz]e\s+(?:what(?:'s| is) in\s+)?(?:my\s+|the\s+)?(.+?)\s+folder$"#) ?? s.captures(#"^summari[sz]e\s+(?:what(?:'s| is) in\s+)?(?:my\s+|the\s+)?(~?/\S+|downloads|desktop|documents)$"#) {
            return .summarizeFolder(compiler.resolveFolder(m[1].trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))))
        }
        if l.hasPrefix("summarize") || l.hasPrefix("summarise") {
            let subject = String(s.dropFirst("summarize".count)).trimmed
            return .summarizeQuery(query(subject))
        }
        if let m = s.captures(#"^(?:organi[sz]e|sort|auto-sort|clean up|tidy(?: up)?)\s*(?:my\s+|the\s+)?(.*?)(?:\s+folder)?$"#), !l.contains(" older than") {
            return .organize(compiler.resolveFolder(m[1].isEmpty ? "Downloads" : m[1]))
        }
        if l.hasPrefix("archive") {
            var days = 30
            if let m = l.captures(#"(\d+)\s*(day|week|month)s?"#) { days = Int(Double(m[1])! * compiler.unitDays(m[2])) }
            let isShots = l.contains("screenshot")
            var folder = isShots ? "~/Desktop" : "~/Downloads"
            if let m = s.captures(#"\b(?:in|from)\s+(?:my\s+|the\s+)?(~?[\w/\- ]+?)(?:\s+folder)?(?:\s+older|\s*$)"#) { folder = m[1] }
            return .archive(folder: compiler.resolveFolder(folder), days: days, kind: isShots ? "screenshot" : nil)
        }

        // File actions
        if let m = s.captures(#"^(move|copy|put|file)\s+(.+?)\s+(?:in)?to\s+(?!project\b)(.+)$"#) {
            let verb = m[1].lowercased() == "copy" ? "copy" : "move"
            return fileActions(subject: m[2], body: "\(verb) to \(m[3])")
        }
        if let m = s.captures(#"^(?:tag|label)\s+(.+?)\s+(?:as|with)\s+(.+)$"#) ?? s.captures(#"^(?:tag|label)\s+(them|those|these|it)\s+(.+)$"#) {
            return fileActions(subject: m[1], body: "tag \(m[2])")
        }
        if let m = s.captures(#"^(?:add|link|put|move)\s+(.+?)\s+(?:to|into|with)\s+(?:the\s+)?project\s+(.+)$"#) ?? s.captures(#"^(?:add|link)\s+(.+?)\s+to\s+(?:the\s+)?(.+?)\s+project$"#) {
            return fileActions(subject: m[1], body: "add to project \(m[2])")
        }
        if let m = s.captures(#"^(?:add|link|attach)\s+(?:them\s+|those\s+|it\s+)?to\s+(?:the\s+)?project\s+(.+)$"#) {
            return fileActions(subject: "them", body: "add to project \(m[1])")
        }
        if let m = s.captures(#"^(?:and\s+)?(?:tag|label)\s+(?!them\b|those\b|it\b)([#\w\-']+)$"#) {
            return fileActions(subject: "them", body: "tag \(m[1])")
        }
        if let m = s.captures(#"^rename\s+(.+?)\s+(?:to|as)\s+(.+)$"#) { return fileActions(subject: m[1], body: "rename to \(m[2])") }
        if let m = s.captures(#"^(trash|delete|remove|compress|zip|reveal|open)\s+(.+)$"#) {
            let verb = ["delete", "remove"].contains(m[1].lowercased()) ? "trash" : m[1].lowercased()
            return fileActions(subject: m[2], body: verb)
        }
        if let m = s.captures(#"^(?:find|show|list|search(?: for)?|get|where (?:are|is))\s+(?:me\s+)?(.+)$"#) {
            return .find(query(m[1]))
        }
        // Bare query ("invoices from last month")
        let q = query(s)
        if !q.conditions.isEmpty && q.conditions.count >= 1 && s.split(separator: " ").count <= 8 { return .find(q) }
        return .unknown(s)
    }

    func fileActions(subject: String, body: String) -> CommandIntent {
        var warnings: [String] = []
        var explanation: [String] = []
        let q = query(subject)
        let (text, quotes) = compiler.extractQuotes(compiler.normalize(body))
        let actions = compiler.parseActions(text, trigger: Trigger(kind: .manual, folders: q.folders), quotes: quotes, warnings: &warnings, explanation: &explanation)
        return actions.isEmpty ? .unknown(subject + " " + body) : .fileActions(q, actions)
    }

    public func query(_ subjectRaw: String) -> FileQuery {
        var q = FileQuery()
        q.text = subjectRaw
        let subject = subjectRaw.trimmed
        let l = subject.lowercased()
        if Self.contextSubjects.contains(l) {
            q.useContext = true
            return q
        }
        if ["them", "those", "it", "those files", "the files", "the results", "that"].contains(l) {
            q.useLastResults = true
            return q
        }
        var explanation: [String] = []
        let (text, quotes) = compiler.extractQuotes(compiler.normalize(subject))
        var trigger = compiler.parseTrigger(text, quotes: quotes, explanation: &explanation)
        if !trigger.kind.isFileTrigger { trigger = Trigger(kind: .fileAdded) }
        q.folders = trigger.folders.map(Paths.expand)
        q.conditions = compiler.parseConditions(text, trigger: &trigger, quotes: quotes, explanation: &explanation)

        // Relative time windows
        let cal = Calendar.current
        let now = Date()
        func since(_ d: Date) { q.conditions.append(Condition(.ageDays, .lessThan, String(format: "%.2f", now.timeIntervalSince(d) / 86400))) }
        if l.contains("this year") { since(cal.date(from: cal.dateComponents([.year], from: now))!) }
        else if l.contains("this month") { since(cal.date(from: cal.dateComponents([.year, .month], from: now))!) }
        else if l.contains("this week") { since(cal.dateInterval(of: .weekOfYear, for: now)!.start) }
        else if l.contains("today") { since(cal.startOfDay(for: now)) }
        else if l.contains("yesterday") { since(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!) }
        else if l.contains("last month") && !l.contains("in the last") { since(cal.date(byAdding: .month, value: -1, to: now)!) }
        else if l.contains("last week") && !l.contains("in the last") { since(cal.date(byAdding: .day, value: -7, to: now)!) }

        // Bare topic words: "files about F1", "everything related to hydroponics" are handled by the compiler.
        // If nothing matched but there is a meaningful word, treat it as a search term.
        if q.conditions.isEmpty && q.folders.isEmpty {
            let filler: Set<String> = ["all", "my", "the", "files", "file", "everything", "stuff", "things", "documents", "every", "any", "in", "from", "of", "to", "me"]
            let words = subject.split(separator: " ").map(String.init).filter { !filler.contains($0.lowercased()) }
            if !words.isEmpty { q.conditions.append(Condition(.anyText, .contains, compiler.restore(words.joined(separator: " "), quotes))) }
        }
        if l.hasPrefix("the latest") || l.hasPrefix("latest") || l.hasPrefix("newest") || l.hasPrefix("last ") && !l.contains("last month") { q.limit = 10 }
        return q
    }

    /// Questions about file *contents* ("when is my lab report due?") rather than file lists.
    func isQuestion(_ s: String) -> Bool {
        let l = s.lowercased().trimmed
        let starters = ["what ", "when ", "who ", "which ", "how much", "how many", "how do", "why ", "is there", "does ", "do i ", "did ", "tell me", "explain", "according to", "remind me what"]
        guard starters.contains(where: { l.hasPrefix($0) }) || l.hasSuffix("?") else { return false }
        // "which files…"/"what files…" are searches, not questions
        if l.range(of: #"^(?:what|which|where)\s+(?:files|documents|pdfs|images|screenshots)\b"#, options: .regularExpression) != nil { return false }
        return true
    }

    func scheduledPhrase(_ s: String) -> NLTime.Result? {
        let l = " " + s.lowercased() + " "
        let markers = [" tonight", " tomorrow", " at ", " every ", " in ", " daily", " weekly", " nightly", " on monday", " on tuesday", " on wednesday", " on thursday", " on friday", " on saturday", " on sunday", " next "]
        guard markers.contains(where: { l.contains($0) }) else { return nil }
        // "in Downloads" isn't a time; require a time-ish signal
        let timeish = l.range(of: #"(tonight|tomorrow|\d{1,2}(:\d{2})?\s*(am|pm)|noon|midnight|every\s+(day|night|morning|week|month|hour|\d+|mon|tue|wed|thu|fri|sat|sun)|in\s+\d+\s*(min|hour|hr|day)|daily|weekly|nightly|next\s+(mon|tue|wed|thu|fri|sat|sun))"#, options: .regularExpression) != nil
        return timeish ? NLTime.parse(s) : nil
    }

    func restoreCase(_ original: String, _ lowered: String) -> String {
        guard let r = original.lowercased().range(of: lowered) else { return lowered }
        let start = original.index(original.startIndex, offsetBy: original.lowercased().distance(from: original.lowercased().startIndex, to: r.lowerBound))
        return String(original[start..<original.index(start, offsetBy: lowered.count)])
    }
}
