import Foundation
import EventKit

public struct ConnectorStatus: Identifiable, Hashable {
    public var id: String
    public var name: String
    public var symbol: String
    public var connected: Bool
    public var detail: String
    public var events: [String]
    public var actions: [String]
}

/// Integrations with apps & services. Secrets live in the Keychain; everything is opt-in.
public final class Connectors {
    public let eventKit = EventKitBridge()
    public let github = GitHubConnector()
    private weak var bus: EventBus?
    private var pollTimer: DispatchSourceTimer?
    public var settingsProvider: () -> NexusSettings = { NexusSettings() }

    public init(bus: EventBus) { self.bus = bus }

    public func statuses() -> [ConnectorStatus] {
        let s = settingsProvider()
        return [
            ConnectorStatus(id: "calendar", name: "Calendar & Reminders", symbol: "calendar", connected: eventKit.calendarAuthorized || eventKit.remindersAuthorized,
                            detail: eventKit.statusText, events: ["calendar.eventStarting"], actions: ["Create calendar event", "Create reminder"]),
            ConnectorStatus(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", connected: Keychain.get("github.token") != nil,
                            detail: s.githubRepo.isEmpty ? "Token + default repo" : s.githubRepo, events: ["github.issueAssigned", "github.prReviewRequested"], actions: ["Create issue"]),
            ConnectorStatus(id: "slack", name: "Slack", symbol: "bubble.left.and.bubble.right", connected: Keychain.get("slack.webhook") != nil,
                            detail: "Incoming webhook", events: [], actions: ["Post message"]),
            ConnectorStatus(id: "notion", name: "Notion", symbol: "doc.richtext", connected: Keychain.get("notion.token") != nil,
                            detail: store_kv("notion.database") ?? "Integration token + database", events: ["notion.pageTagged (polled every 5 min)"], actions: ["Create page"]),
            ConnectorStatus(id: "obsidian", name: "Obsidian", symbol: "note.text", connected: !s.obsidianVault.isEmpty && FileManager.default.fileExists(atPath: Paths.expand(s.obsidianVault)),
                            detail: s.obsidianVault.isEmpty ? "Choose vault folder" : Paths.abbreviate(Paths.expand(s.obsidianVault)), events: ["file events in vault"], actions: ["Append to note"]),
            ConnectorStatus(id: "mail", name: "Mail", symbol: "envelope", connected: (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Mail")) != nil || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Application Scripts/com.apple.mail/Nexus Save Attachments.scpt"),
                            detail: FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/Mail") ? "Watching Mail attachments automatically (Full Disk Access)" : "Grant Full Disk Access — or install the Mail rule bridge", events: ["mail.attachment"], actions: []),
            ConnectorStatus(id: "shortcuts", name: "Shortcuts", symbol: "square.2.layers.3d", connected: FileManager.default.fileExists(atPath: "/usr/bin/shortcuts"),
                            detail: "Run any Shortcut with the file as input", events: [], actions: ["Run Shortcut"]),
            ConnectorStatus(id: "cloud", name: "iCloud Drive / Dropbox / Google Drive", symbol: "icloud", connected: !cloudFolders().isEmpty,
                            detail: cloudFolders().map(Paths.abbreviate).joined(separator: ", ").nilIfEmpty ?? "No synced folders found", events: ["file events"], actions: ["Move / copy / sync"]),
        ]
    }

    var kvReader: ((String) -> String?)?
    private func store_kv(_ k: String) -> String? { kvReader?(k) }

    public func cloudFolders() -> [String] {
        let home = NSHomeDirectory()
        var out: [String] = []
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) { out.append(icloud) }
        let cloudStorage = home + "/Library/CloudStorage"
        for d in (try? FileManager.default.contentsOfDirectory(atPath: cloudStorage)) ?? [] where d.hasPrefix("Dropbox") || d.hasPrefix("GoogleDrive") || d.hasPrefix("OneDrive") {
            out.append(cloudStorage + "/" + d)
        }
        if FileManager.default.fileExists(atPath: home + "/Dropbox") { out.append(home + "/Dropbox") }
        return out
    }

    // MARK: Polling (GitHub assignments, upcoming calendar events)

    private var seenIssues = Set<Int>()
    private var seenEvents = Set<String>()

    public func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 20, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { [weak self] in Task { await self?.poll() } }
        t.resume()
        pollTimer = t
    }

    func poll() async {
        if Keychain.get("github.token") != nil, let issues = try? await github.assignedIssues() {
            let firstRun = seenIssues.isEmpty
            for i in issues where !seenIssues.contains(i.number) {
                seenIssues.insert(i.number)
                if !firstRun {
                    bus?.post(.connector(name: "github", payload: ["connectorEvent": "github.issueAssigned", "title": i.title, "url": i.url,
                                                                   "repo": i.repo, "number": String(i.number), "source": "GitHub"]))
                }
            }
        }
        await pollNotion()
        for e in eventKit.upcomingEvents(withinMinutes: 10) where !seenEvents.contains(e.id) {
            seenEvents.insert(e.id)
            bus?.post(.connector(name: "calendar", payload: ["connectorEvent": "calendar.eventStarting", "title": e.title, "start": ISO8601DateFormatter().string(from: e.start), "source": "Calendar"]))
        }
    }

    private var notionCursor: Date?

    /// Emits notion.pageTagged for pages edited since the last poll (title, tags from multi-select/select properties, url).
    func pollNotion() async {
        guard let token = Keychain.get("notion.token"), let db = store_kv("notion.database"), !db.isEmpty else { return }
        let since = notionCursor ?? Date()
        let firstRun = notionCursor == nil
        notionCursor = Date()
        guard !firstRun else { return }
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(db)/query")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let iso = ISO8601DateFormatter().string(from: since.addingTimeInterval(-60))
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filter": ["timestamp": "last_edited_time", "last_edited_time": ["on_or_after": iso]], "page_size": 50])
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let results = obj["results"] as? [[String: Any]] else { return }
        for page in results {
            let props = page["properties"] as? [String: [String: Any]] ?? [:]
            var title = ""
            var tags: [String] = []
            for (_, p) in props {
                switch p["type"] as? String {
                case "title": title = ((p["title"] as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
                case "multi_select": tags += ((p["multi_select"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                case "select": if let n = (p["select"] as? [String: Any])?["name"] as? String { tags.append(n) }
                default: break
                }
            }
            bus?.post(.connector(name: "notion", payload: ["connectorEvent": "notion.pageTagged", "title": title, "tag": tags.joined(separator: ","),
                                                           "url": page["url"] as? String ?? "", "source": "Notion"]))
        }
    }

    // MARK: Actions

    public func webhook(url: String, payload: [String: Any]) async throws {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { throw LLMError("Invalid webhook URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 20
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { throw LLMError("Webhook returned an error") }
    }

    public func slack(text: String) async throws {
        guard let hook = Keychain.get("slack.webhook") else { throw LLMError("Connect Slack (incoming webhook URL) first") }
        try await webhook(url: hook, payload: ["text": text])
    }

    public func appendObsidian(vault: String, note: String, line: String) throws {
        let path = (vault as NSString).appendingPathComponent(note)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { try "# Nexus Inbox\n\n".write(toFile: path, atomically: true, encoding: .utf8) }
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
    }

    public func notionCreatePage(title: String, body: String) async throws -> String {
        guard let token = Keychain.get("notion.token"), let db = store_kv("notion.database"), !db.isEmpty else {
            throw LLMError("Connect Notion (token + database id) first")
        }
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/pages")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "parent": ["database_id": db],
            "properties": ["Name": ["title": [["text": ["content": title]]]]],
            "children": [["object": "block", "type": "paragraph", "paragraph": ["rich_text": [["text": ["content": String(body.prefix(1800))]]]]]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError("Notion: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "error")") }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["url"] as? String ?? ""
    }

    // MARK: Mail bridge

    public static var mailInbox: URL { Paths.appSupport.appendingPathComponent("Inbox/Mail") }

    /// AppleScript for a Mail.app rule ("Run AppleScript") that drops attachments where Nexus watches.
    public static func mailRuleScript() -> String {
        """
        -- Nexus Mail bridge: Mail ▸ Settings ▸ Rules ▸ Add Rule ▸ Perform: Run AppleScript
        using terms from application "Mail"
            on perform mail action with messages theMessages for rule theRule
                set inboxPath to "\(mailInbox.path)/"
                tell application "Mail"
                    repeat with m in theMessages
                        repeat with a in (mail attachments of m)
                            try
                                save a in POSIX file (inboxPath & (name of a))
                            end try
                        end repeat
                    end repeat
                end tell
            end perform mail action with messages
        end using terms from
        """
    }

    public func installMailBridge() throws -> URL {
        try FileManager.default.createDirectory(at: Self.mailInbox, withIntermediateDirectories: true)
        let scriptsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Scripts/com.apple.mail")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let src = scriptsDir.appendingPathComponent("Nexus Save Attachments.applescript")
        try Self.mailRuleScript().write(to: src, atomically: true, encoding: .utf8)
        let compiled = scriptsDir.appendingPathComponent("Nexus Save Attachments.scpt")
        Shell.run("/usr/bin/osacompile", ["-o", compiled.path, src.path])
        return compiled
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

// MARK: - EventKit

public final class EventKitBridge {
    private let store = EKEventStore()
    public init() {}

    public var calendarAuthorized: Bool { Self.granted(EKEventStore.authorizationStatus(for: .event)) }
    public var remindersAuthorized: Bool { Self.granted(EKEventStore.authorizationStatus(for: .reminder)) }
    public var statusText: String {
        "Calendar: \(calendarAuthorized ? "on" : "off") · Reminders: \(remindersAuthorized ? "on" : "off")"
    }

    static func granted(_ s: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) { return s == .fullAccess || s == .writeOnly }
        return s == .authorized
    }

    public func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                let a = try await store.requestFullAccessToEvents()
                let b = try await store.requestFullAccessToReminders()
                return a || b
            } else {
                let a = try await store.requestAccess(to: .event)
                let b = try await store.requestAccess(to: .reminder)
                return a || b
            }
        } catch { return false }
    }

    public func createReminder(title: String, notes: String?, due: Date?) async -> Bool {
        if !remindersAuthorized { _ = await requestAccess() }
        guard remindersAuthorized else { return false }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = notes
        r.calendar = store.calendars(for: .reminder).first { $0.title == "Nexus" } ?? store.defaultCalendarForNewReminders()
        if let due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        do { try store.save(r, commit: true); return true } catch { return false }
    }

    public func createEvent(title: String, date: Date, notes: String?) async -> Bool {
        if !calendarAuthorized { _ = await requestAccess() }
        guard calendarAuthorized else { return false }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.notes = notes
        e.startDate = Calendar.current.startOfDay(for: date)
        e.endDate = e.startDate.addingTimeInterval(86400)
        e.isAllDay = true
        e.calendar = store.defaultCalendarForNewEvents
        e.addAlarm(EKAlarm(relativeOffset: -86400))
        do { try store.save(e, span: .thisEvent); return true } catch { return false }
    }

    public struct SimpleEvent: Hashable { public var id: String; public var title: String; public var start: Date; public var end: Date }

    public func upcomingEvents(withinMinutes: Int) -> [SimpleEvent] {
        events(from: Date(), to: Date().addingTimeInterval(Double(withinMinutes) * 60))
    }

    public func events(from: Date, to: Date) -> [SimpleEvent] {
        guard calendarAuthorized else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred).filter { !$0.isAllDay || from.timeIntervalSince($0.startDate) < 86400 }
            .map { SimpleEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "", start: $0.startDate, end: $0.endDate) }
    }
}

// MARK: - GitHub

public final class GitHubConnector {
    public struct Issue: Hashable { public var number: Int; public var title: String; public var url: String; public var repo: String }
    public init() {}

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        guard let token = Keychain.get("github.token") else { throw LLMError("Connect GitHub (personal access token) first") }
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Nexus-macOS", forHTTPHeaderField: "User-Agent")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw LLMError("GitHub: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "error")")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    public func assignedIssues() async throws -> [Issue] {
        let arr = try await request("/issues?filter=assigned&state=open&per_page=50") as? [[String: Any]] ?? []
        return arr.compactMap { i in
            guard let n = i["number"] as? Int, let t = i["title"] as? String else { return nil }
            let repo = (i["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            return Issue(number: n, title: t, url: i["html_url"] as? String ?? "", repo: repo)
        }
    }

    public func createIssue(repo: String, title: String, body: String) async throws -> String {
        guard repo.contains("/") else { throw LLMError("Set a default GitHub repo (owner/name) in Connectors") }
        let obj = try await request("/repos/\(repo)/issues", method: "POST", body: ["title": title, "body": body]) as? [String: Any]
        return obj?["html_url"] as? String ?? ""
    }
}

// MARK: - Plugins

public struct PluginManifest: Codable, Hashable, Identifiable {
    public struct Permissions: Codable, Hashable {
        public var read: [String]
        public var write: [String]
        public var network: Bool
    }
    public var id: String { folder }
    public var name: String
    public var version: String
    public var description: String
    public var entry: String
    public var permissions: Permissions
    public var folder: String = ""

    enum CodingKeys: String, CodingKey { case name, version, description, entry, permissions }
}

public final class PluginHost {
    public init() {}

    public func plugins() -> [PluginManifest] {
        let root = Paths.plugins
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { dir in
            let folder = root.appendingPathComponent(dir)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("plugin.json")),
                  var m = try? JSONDecoder().decode(PluginManifest.self, from: data) else { return nil }
            m.folder = folder.path
            return m
        }
    }

    /// Runs a plugin inside a Seatbelt sandbox limited to its declared permissions. Event JSON on stdin.
    public func run(named name: String, file: FileRecord?, info: [String: String], sandboxed: Bool = true) -> (Bool, String) {
        guard let p = plugins().first(where: { $0.name.lowercased() == name.lowercased() || ($0.folder as NSString).lastPathComponent == name }) else {
            return (false, "Plugin “\(name)” not found in \(Paths.abbreviate(Paths.plugins.path))")
        }
        let entry = (p.folder as NSString).appendingPathComponent(p.entry)
        var env = ActionExecutor.environment(file: file, info: info)
        env["NEXUS_PLUGIN_DIR"] = p.folder
        let payload = JSON.string(["file": file?.path ?? "", "name": file?.name ?? "", "tags": file?.tags.joined(separator: ",") ?? ""].merging(info) { a, _ in a })
        let writable = p.permissions.write + (file.map { [$0.folder] } ?? [])
        if sandboxed {
            let profile = Shell.sandboxProfile(readable: p.permissions.read + [p.folder] + (file.map { [$0.path] } ?? []), writable: writable, network: p.permissions.network)
            let (code, out) = Shell.run("/usr/bin/sandbox-exec", ["-p", profile, "/bin/zsh", entry], env: env, timeout: 600, stdin: payload)
            return (code == 0, out.isEmpty ? "Plugin \(p.name) finished" : out)
        }
        let (code, out) = Shell.run("/bin/zsh", [entry], env: env, timeout: 600, stdin: payload)
        return (code == 0, out.isEmpty ? "Plugin \(p.name) finished" : out)
    }

    /// Writes an example plugin so users have a template to copy.
    public func installExamples() {
        let dir = Paths.plugins.appendingPathComponent("backup-classified")
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {
          "name": "Backup classified files",
          "version": "1.0.0",
          "description": "Copies the triggering file into /Volumes/Backup/Nexus/<tag>/ when the drive is mounted.",
          "entry": "run.sh",
          "permissions": { "read": ["~/Documents", "~/Downloads"], "write": ["/Volumes/Backup"], "network": false }
        }
        """
        let script = """
        #!/bin/zsh
        # Nexus plugin: receives event JSON on stdin and NEXUS_* environment variables.
        set -euo pipefail
        [[ -d /Volumes/Backup ]] || { echo "Backup drive not mounted"; exit 0 }
        tag="${NEXUS_TAGS%%,*}"; tag="${tag:-untagged}"
        mkdir -p "/Volumes/Backup/Nexus/$tag"
        cp -p "$NEXUS_FILE" "/Volumes/Backup/Nexus/$tag/"
        echo "Backed up $NEXUS_NAME → Backup/Nexus/$tag"
        """
        try? manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try? script.write(to: dir.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("run.sh").path)

        let nightly = Paths.scripts.appendingPathComponent("nightly-summary.sh")
        let nightlyScript = """
        #!/bin/zsh
        # Example: write a markdown list of today's new files per project using the Nexus CLI.
        out=~/Documents/Nexus\\ Reports/$(date +%F).md
        mkdir -p ~/Documents/Nexus\\ Reports
        nexusctl report daily > "$out" && echo "Wrote $out"
        """
        try? nightlyScript.write(to: nightly, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nightly.path)
    }
}
