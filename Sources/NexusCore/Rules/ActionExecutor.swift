import Foundation
import AppKit

/// Services the executor needs from the engine (keeps the executor testable).
public protocol ActionHost: AnyObject {
    var settings: NexusSettings { get }
    func notify(title: String, body: String, important: Bool)
    func summarize(file: FileRecord) async -> String
    func indexCopy(at path: String)
    func sortFolder(_ path: String, batchId: String) async -> String
    func findDuplicates(largeOnly: Bool) -> String
    func generateReport(type: String) async -> String
    func resolveProject(named: String, create: Bool) -> Project?
    func runPlugin(named: String, file: FileRecord?, info: [String: String]) async -> (Bool, String)
    func pause(reason: String)
}

public struct ActionOutcome: Hashable {
    public var action: RuleAction
    public var success: Bool
    public var message: String
}

/// Sliding-window circuit breaker: a buggy rule can't move 10,000 files in a loop.
public final class RunawayGuard {
    private var stamps: [Date] = []
    private let lock = NSLock()
    public var limitPerMinute: Int
    public init(limitPerMinute: Int) { self.limitPerMinute = limitPerMinute }
    public func allow(_ n: Int = 1) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        stamps.removeAll { $0 < cutoff }
        guard stamps.count + n <= limitPerMinute else { return false }
        stamps.append(contentsOf: Array(repeating: Date(), count: n))
        return true
    }
}

public final class ActionExecutor {
    let store: NexusStore
    let connectors: Connectors
    public weak var host: ActionHost?
    public let guardrail: RunawayGuard

    public init(store: NexusStore, connectors: Connectors, guardrail: RunawayGuard) {
        self.store = store; self.connectors = connectors; self.guardrail = guardrail
    }

    struct Failure: Error { let message: String }

    /// Runs actions sequentially; file-scoped actions follow the file (a move then a tag tags the moved file).
    public func run(actions: [RuleAction], file initial: FileRecord?, info: [String: String] = [:], ruleId: String? = nil,
                    jobId: String? = nil, batchId: String = newID(), dryRun: Bool = false) async -> (FileRecord?, [ActionOutcome]) {
        var file = initial
        var outcomes: [ActionOutcome] = []
        for action in actions {
            if action.kind.isFileScoped && file == nil && action.kind != .openFile && action.kind != .revealInFinder {
                outcomes.append(ActionOutcome(action: action, success: false, message: "Skipped: no file in context"))
                continue
            }
            let projectName = file?.projectId.flatMap { store.project(id: $0)?.name }
            if dryRun {
                outcomes.append(ActionOutcome(action: action, success: true, message: "Would " + Templates.describe(action, file: file, projectName: projectName).lowercased()))
                continue
            }
            if action.kind.isMutating && !guardrail.allow() {
                let msg = "Runaway guard: more than \(guardrail.limitPerMinute) file operations in a minute. Automations paused."
                host?.pause(reason: msg)
                store.log(ActivityEvent(kind: .guardTripped, message: msg, ruleId: ruleId, jobId: jobId, batchId: batchId))
                outcomes.append(ActionOutcome(action: action, success: false, message: msg))
                break
            }
            do {
                let msg = try await perform(action, file: &file, projectName: projectName, info: info, ruleId: ruleId, jobId: jobId, batchId: batchId)
                outcomes.append(ActionOutcome(action: action, success: true, message: msg))
            } catch let f as Failure {
                outcomes.append(ActionOutcome(action: action, success: false, message: f.message))
                store.log(ActivityEvent(kind: .error, message: "\(action.kind.label) failed: \(f.message)", fileId: file?.id, ruleId: ruleId, jobId: jobId, batchId: batchId))
                if action.kind.isMutating { break } // don't continue a chain on a broken file state
            } catch {
                outcomes.append(ActionOutcome(action: action, success: false, message: error.localizedDescription))
                store.log(ActivityEvent(kind: .error, message: "\(action.kind.label) failed: \(error.localizedDescription)", fileId: file?.id, ruleId: ruleId, jobId: jobId, batchId: batchId))
                if action.kind.isMutating { break }
            }
        }
        return (file, outcomes)
    }

    private func checkWritable(_ paths: String...) throws {
        for p in paths where Paths.isProtected(p) && !p.hasPrefix(Paths.appSupport.path) {
            throw Failure(message: "\(Paths.abbreviate(p)) is a protected location")
        }
    }

    private func perform(_ a: RuleAction, file: inout FileRecord?, projectName: String?, info: [String: String],
                         ruleId: String?, jobId: String?, batchId: String) async throws -> String {
        let fm = FileManager.default
        func expand(_ s: String) -> String { Templates.expand(s, file: file, projectName: projectName, info: info) }
        func log(_ kind: EventKind, _ msg: String, undo: UndoRecord? = nil) {
            store.log(ActivityEvent(kind: kind, message: msg, fileId: file?.id, ruleId: ruleId, jobId: jobId, batchId: batchId, undo: undo))
        }

        switch a.kind {
        case .move, .copy:
            guard var f = file else { throw Failure(message: "no file") }
            let destFolder = expand(a.target)
            guard !destFolder.isEmpty else { throw Failure(message: "no destination") }
            if a.kind == .move { try checkWritable(f.path, destFolder) } else { try checkWritable(destFolder) }   // copying *out* of a protected place is fine
            guard fm.fileExists(atPath: f.path) else { throw Failure(message: "\(f.name) no longer exists") }
            if a.kind == .move && f.folder == destFolder { return "Already in \(Paths.abbreviate(destFolder))" }
            try fm.createDirectory(atPath: destFolder, withIntermediateDirectories: true)
            let dest = Paths.uniquePath((destFolder as NSString).appendingPathComponent(f.name))
            if a.kind == .move {
                try fm.moveItem(atPath: f.path, toPath: dest)
                let from = f.path
                f.path = dest
                f.status = .filed
                store.upsertFile(f)
                file = f
                log(.fileMoved, "Moved \(f.name) → \(Paths.abbreviate(destFolder))", undo: UndoRecord(op: .move, from: from, to: dest, fileId: f.id))
                return "Moved to \(Paths.abbreviate(destFolder))"
            } else {
                try fm.copyItem(atPath: f.path, toPath: dest)
                host?.indexCopy(at: dest)
                log(.fileCopied, "Copied \(f.name) → \(Paths.abbreviate(destFolder))", undo: UndoRecord(op: .copy, to: dest))
                return "Copied to \(Paths.abbreviate(destFolder))"
            }

        case .rename:
            guard var f = file else { throw Failure(message: "no file") }
            try checkWritable(f.path)
            var newName = expand(a.target).replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression).trimmed
            guard !newName.isEmpty else { throw Failure(message: "empty name") }
            if (newName as NSString).pathExtension.isEmpty && !f.ext.isEmpty { newName += "." + f.ext }
            if newName == f.name { return "Name unchanged" }
            let dest = Paths.uniquePath((f.folder as NSString).appendingPathComponent(newName))
            try fm.moveItem(atPath: f.path, toPath: dest)
            let from = f.path
            f.path = dest
            store.upsertFile(f)
            file = f
            log(.fileRenamed, "Renamed \((from as NSString).lastPathComponent) → \(f.name)", undo: UndoRecord(op: .rename, from: from, to: dest, fileId: f.id))
            return "Renamed to \(f.name)"

        case .tag, .removeTag:
            guard var f = file else { throw Failure(message: "no file") }
            let tags = a.tags.map(expand).filter { !$0.isEmpty }
            let before = Set(f.tags)
            if a.kind == .tag {
                for t in tags where !f.tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { f.tags.append(t) }
            } else {
                f.tags.removeAll { t in tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
            }
            let changed = Set(f.tags).symmetricDifference(before)
            guard !changed.isEmpty else { return "Tags unchanged" }
            store.ensureTags(tags)
            setFinderTags(f.path, f.tags)
            store.upsertFile(f)
            store.addEdges(tags.map { GraphEdge(srcType: .file, srcId: f.id, dstType: .tag, dstId: $0.lowercased(), relation: "taggedWith") })
            file = f
            log(.fileTagged, "\(a.kind == .tag ? "Tagged" : "Untagged") \(f.name): \(Array(changed).map { "#\($0)" }.joined(separator: " "))",
                undo: UndoRecord(op: a.kind == .tag ? .tag : .untag, tags: Array(changed), fileId: f.id))
            return "\(a.kind == .tag ? "Tagged" : "Untagged") \(Array(changed).joined(separator: ", "))"

        case .addToProject:
            guard var f = file else { throw Failure(message: "no file") }
            let name = expand(a.project ?? a.target)
            guard var p = host?.resolveProject(named: name, create: true) else { throw Failure(message: "project “\(name)” not found") }
            let previous = f.projectId
            f.projectId = p.id
            store.upsertFile(f)
            p.lastActivityAt = Date()
            store.saveProject(p)
            store.addEdges([GraphEdge(srcType: .file, srcId: f.id, dstType: .project, dstId: p.id, relation: "belongsTo")])
            file = f
            log(.fileTagged, "Added \(f.name) to project \(p.name)", undo: UndoRecord(op: .project, fileId: f.id, previousProjectId: previous))
            return "Added to \(p.name)"

        case .createProject:
            let name = expand(a.target).trimmed
            guard !name.isEmpty, name != "{title}" else { throw Failure(message: "no project name in event") }
            guard var p = host?.resolveProject(named: name, create: true) else { throw Failure(message: "could not create project") }
            let extraTags = (a.params["tags"].map(expand) ?? "").split(separator: ",").map { $0.trimmed }.filter { !$0.isEmpty && !$0.contains("{") }
            p.tags = Array(Set(p.tags + extraTags))
            if let url = info["url"], !p.links.contains(where: { $0.url == url }) { p.links.append(ProjectLink(title: info["source"] ?? "Link", url: url)) }
            p.lastActivityAt = Date()
            store.saveProject(p)
            log(.connector, "Updated project \(p.name) from \(info["source"] ?? "event")")
            return "Project \(p.name) updated"

        case .setCategory:
            guard var f = file else { throw Failure(message: "no file") }
            f.category = expand(a.target)
            store.upsertFile(f); file = f
            return "Category set to \(f.category ?? "")"

        case .trash:
            guard var f = file else { throw Failure(message: "no file") }
            try checkWritable(f.path)
            var result: NSURL?
            if let testTrash = ProcessInfo.processInfo.environment["NEXUS_TRASH_DIR"] {   // isolated test runs
                try fm.createDirectory(atPath: testTrash, withIntermediateDirectories: true)
                let dest = Paths.uniquePath((testTrash as NSString).appendingPathComponent(f.name))
                try fm.moveItem(atPath: f.path, toPath: dest)
                result = NSURL(fileURLWithPath: dest)
            } else {
                try fm.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: &result)
            }
            let from = f.path
            f.status = .missing
            store.upsertFile(f); file = f
            log(.fileTrashed, "Moved \(f.name) to Trash", undo: UndoRecord(op: .trash, from: from, to: result?.path, fileId: f.id))
            return "Moved to Trash"

        case .compress:
            guard let f = file else { throw Failure(message: "no file") }
            try checkWritable(f.folder)
            let dest = Paths.uniquePath(f.path + ".zip")
            let (code, out) = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", f.path, dest], timeout: 600)
            guard code == 0 else { throw Failure(message: "zip failed: \(out)") }
            log(.fileCompressed, "Compressed \(f.name)", undo: UndoRecord(op: .createFile, to: dest))
            return "Created \((dest as NSString).lastPathComponent)"

        case .createFolder:
            let path = expand(a.target)
            try checkWritable(path)
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            log(.system, "Prepared folder \(Paths.abbreviate(path))")
            return "Folder ready: \(Paths.abbreviate(path))"

        case .notify:
            let body = expand(a.target)
            host?.notify(title: "Nexus", body: body, important: a.params["important"] == "1")
            return "Notified"

        case .createTask, .createReminder:
            let title = expand(a.target).replacingOccurrences(of: "{title}", with: "")
            let days = Int(a.params["due"]?.replacingOccurrences(of: "d", with: "") ?? "1") ?? 1
            let notes = file.map { "File: \($0.path)" } ?? info.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            let ok = await connectors.eventKit.createReminder(title: title, notes: notes, due: Calendar.current.date(byAdding: .day, value: days, to: Date()))
            if !ok {
                store.upsertInsight(Insight(key: "todo:\(newID())", kind: .deadlineSoon, title: title, detail: notes, severity: .suggestion))
                return "Reminders unavailable — added to Insights as a to-do"
            }
            log(.connector, "Created reminder “\(title)”")
            return "Reminder created"

        case .createCalendarEvent:
            let title = expand(a.target)
            let futureDates = (file?.entities ?? []).filter { $0.kind == .date }.compactMap { e -> Date? in
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: e.value)
            }.filter { $0 > Date() }.sorted()
            let date = futureDates.first ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
            let ok = await connectors.eventKit.createEvent(title: title, date: date, notes: file?.path)
            guard ok else { throw Failure(message: "Calendar access not granted") }
            log(.connector, "Added “\(title)” to Calendar on \(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))")
            return "Calendar event created"

        case .summarize:
            guard var f = file, let host else { throw Failure(message: "no file") }
            f.summary = await host.summarize(file: f)
            store.upsertFile(f); file = f
            return "Summarized"

        case .openFile:
            let path = a.target.isEmpty ? (file?.path ?? "") : expand(a.target)
            await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            return "Opened"

        case .revealInFinder:
            let path = a.target.isEmpty ? (file?.path ?? "") : expand(a.target)
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            return "Revealed in Finder"

        case .runShell:
            let env = Self.environment(file: file, info: info)
            let sandboxWrite = [file?.folder, a.params["write"].map(Paths.expand)].compactMap { $0 }
            let (code, out) = Shell.runScript(expand(a.target), env: env, sandboxed: host?.settings.scriptSandbox ?? true, writablePaths: sandboxWrite)
            log(code == 0 ? .system : .error, "Script exited \(code): \(out.prefix(300))")
            guard code == 0 else { throw Failure(message: "exit \(code): \(out.prefix(200))") }
            return out.isEmpty ? "Script finished" : String(out.prefix(200))

        case .runAppleScript:
            let script = expand(a.target)
            let args = fm.fileExists(atPath: Paths.expand(script)) ? [Paths.expand(script), file?.path ?? ""] : ["-e", script]
            let (code, out) = Shell.run("/usr/bin/osascript", args, timeout: 120)
            guard code == 0 else { throw Failure(message: out) }
            return out.isEmpty ? "AppleScript finished" : out

        case .runShortcut:
            var args = ["run", expand(a.target)]
            if let f = file { args += ["-i", f.path] }
            let (code, out) = Shell.run("/usr/bin/shortcuts", args, timeout: 300)
            guard code == 0 else { throw Failure(message: out.isEmpty ? "Shortcut failed" : out) }
            return "Shortcut “\(a.target)” ran"

        case .runPlugin:
            guard let host else { throw Failure(message: "no host") }
            let (ok, out) = await host.runPlugin(named: expand(a.target), file: file, info: info)
            guard ok else { throw Failure(message: out) }
            return out

        case .webhook:
            try await connectors.webhook(url: expand(a.target), payload: Self.payload(file: file, info: info, event: a.params["event"] ?? "rule"))
            return "Webhook delivered"

        case .syncFolder:
            let source = Paths.expand(expand(a.params["source"] ?? file?.folder ?? ""))
            let dest = expand(a.target)
            if dest.hasPrefix("/Volumes/") {
                let volume = "/Volumes/" + (dest.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "")
                guard fm.fileExists(atPath: volume) else { throw Failure(message: "\(volume) is not mounted") }
            }
            try checkWritable(dest)
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            let (code, out) = Shell.run("/usr/bin/rsync", ["-a", "--exclude", ".DS_Store", source + "/", dest + "/"], timeout: 6 * 3600)
            guard code == 0 else { throw Failure(message: "rsync: \(out.prefix(200))") }
            log(.system, "Synced \(Paths.abbreviate(source)) → \(Paths.abbreviate(dest))")
            return "Synced \(Paths.abbreviate(source))"

        case .archiveOld:
            let folder = Paths.expand(a.params["folder"] ?? file?.folder ?? "~/Downloads")
            let days = Double(a.params["days"] ?? "30") ?? 30
            let kindFilter = a.params["kind"]
            let cutoff = Date().addingTimeInterval(-days * 86400)
            var moved = 0
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where !name.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: path), (attrs[.type] as? FileAttributeType) == .typeRegular,
                      let mod = attrs[.modificationDate] as? Date, mod < cutoff else { continue }
                var rec = store.file(path: path) ?? FileRecord(path: path, kind: ContentExtractor.kind(for: path), size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                                              createdAt: (attrs[.creationDate] as? Date) ?? mod, modifiedAt: mod)
                if let k = kindFilter {
                    let isScreenshot = rec.kind == .screenshot || name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot")
                    if k == "screenshot" ? !isScreenshot : rec.kind.rawValue != k { continue }
                }
                guard guardrail.allow() else { host?.pause(reason: "Runaway guard tripped during archive"); break }
                let destFolder = Templates.expand(a.target, file: rec, projectName: nil)
                try fm.createDirectory(atPath: destFolder, withIntermediateDirectories: true)
                let dest = Paths.uniquePath((destFolder as NSString).appendingPathComponent(name))
                try fm.moveItem(atPath: path, toPath: dest)
                rec.path = dest; rec.status = .filed
                store.upsertFile(rec)
                store.log(ActivityEvent(kind: .fileMoved, message: "Archived \(name) → \(Paths.abbreviate(destFolder))", fileId: rec.id, ruleId: ruleId, jobId: jobId, batchId: batchId,
                                        undo: UndoRecord(op: .move, from: path, to: dest, fileId: rec.id)))
                moved += 1
            }
            return "Archived \(moved) file\(moved == 1 ? "" : "s") from \(Paths.abbreviate(folder))"

        case .sortFolder:
            guard let host else { throw Failure(message: "no host") }
            return await host.sortFolder(Paths.expand(expand(a.target.isEmpty ? (file?.folder ?? "~/Downloads") : a.target)), batchId: batchId)

        case .findDuplicates:
            return host?.findDuplicates(largeOnly: a.params["large"] == "1") ?? ""

        case .generateReport:
            return await host?.generateReport(type: a.params["type"] ?? "weekly") ?? ""

        case .githubIssue:
            let title = expand(a.target)
            let body = file.map { "Created by Nexus from `\(Paths.abbreviate($0.path))`\n\n\($0.summary ?? $0.snippet.prefix(500).description)" } ?? info.description
            let url = try await connectors.github.createIssue(repo: host?.settings.githubRepo ?? "", title: title, body: body)
            log(.connector, "Opened GitHub issue \(url)")
            return "Issue created: \(url)"

        case .obsidianNote:
            let vault = host?.settings.obsidianVault ?? ""
            guard !vault.isEmpty else { throw Failure(message: "Set your Obsidian vault in Connectors") }
            var note = expand(a.target.isEmpty ? "Nexus/Inbox.md" : a.target)
            if !note.hasSuffix(".md") { note += ".md" }
            let line = file.map { "- \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)) [\($0.name)](file://\($0.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0.path))\($0.tags.isEmpty ? "" : " " + $0.tags.map { "#\($0.replacingOccurrences(of: " ", with: "-"))" }.joined(separator: " "))" }
                ?? "- \(Date()) \(a.params["text"] ?? "Nexus event")"
            try connectors.appendObsidian(vault: Paths.expand(vault), note: note, line: line)
            return "Appended to \(note)"

        case .slackMessage:
            try await connectors.slack(text: expand(a.target))
            return "Posted to Slack"

        case .notionPage:
            let url = try await connectors.notionCreatePage(title: expand(a.target), body: file?.summary ?? file?.snippet ?? "")
            return "Notion page created \(url)"
        }
    }

    // MARK: - Undo

    /// Reverts every undoable operation in a batch, newest first. Returns number of reverted ops.
    @discardableResult
    public func undo(batchId: String) -> Int {
        let fm = FileManager.default
        var count = 0
        for var e in store.events(batch: batchId) where !e.undone {
            guard let u = e.undo else { continue }
            var ok = false
            switch u.op {
            case .move, .rename, .trash:
                if let from = u.from, let to = u.to, fm.fileExists(atPath: to) {
                    try? fm.createDirectory(atPath: (from as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    let target = Paths.uniquePath(from)
                    if (try? fm.moveItem(atPath: to, toPath: target)) != nil {
                        ok = true
                        if let id = u.fileId, var f = store.file(id: id) {
                            f.path = target
                            f.status = .indexed
                            store.upsertFile(f)
                        }
                    }
                }
            case .copy, .createFile:
                if let to = u.to, fm.fileExists(atPath: to) {
                    ok = (try? fm.trashItem(at: URL(fileURLWithPath: to), resultingItemURL: nil)) != nil
                    if let rec = store.file(path: to) { store.deleteFile(id: rec.id) }
                }
            case .tag, .untag:
                if let id = u.fileId, var f = store.file(id: id) {
                    if u.op == .tag { f.tags.removeAll { u.tags.contains($0) } } else { f.tags.append(contentsOf: u.tags.filter { !f.tags.contains($0) }) }
                    setFinderTags(f.path, f.tags)
                    store.upsertFile(f)
                    ok = true
                }
            case .project:
                if let id = u.fileId, var f = store.file(id: id) {
                    f.projectId = u.previousProjectId
                    store.upsertFile(f)
                    ok = true
                }
            }
            if ok {
                e.undone = true
                store.log(e)
                count += 1
            }
        }
        if count > 0 { store.log(ActivityEvent(kind: .undo, message: "Undid \(count) operation\(count == 1 ? "" : "s")")) }
        return count
    }

    // MARK: - Helpers

    func setFinderTags(_ path: String, _ tags: [String]) {
        try? (URL(fileURLWithPath: path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    static func environment(file: FileRecord?, info: [String: String]) -> [String: String] {
        var env: [String: String] = ["NEXUS_EVENT_JSON": JSON.string(info)]
        if let f = file {
            env["NEXUS_FILE"] = f.path; env["NEXUS_NAME"] = f.name; env["NEXUS_FOLDER"] = f.folder; env["NEXUS_EXT"] = f.ext
            env["NEXUS_TAGS"] = f.tags.joined(separator: ","); env["NEXUS_DOCTYPE"] = f.docType ?? ""; env["NEXUS_PROJECT_ID"] = f.projectId ?? ""
        }
        for (k, v) in info { env["NEXUS_INFO_" + k.uppercased().replacingOccurrences(of: ".", with: "_")] = v }
        return env
    }

    static func payload(file: FileRecord?, info: [String: String], event: String) -> [String: Any] {
        var p: [String: Any] = ["event": event, "timestamp": ISO8601DateFormatter().string(from: Date()), "info": info]
        if let f = file {
            p["file"] = ["path": f.path, "name": f.name, "kind": f.kind.rawValue, "size": f.size, "tags": f.tags,
                         "docType": f.docType ?? "", "topics": f.topics, "projectId": f.projectId ?? ""]
        }
        return p
    }
}

// MARK: - Shell (with optional sandbox-exec profile)

public enum Shell {
    @discardableResult
    public static func run(_ exe: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 60, stdin: String? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        if stdin != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)); try? inPipe.fileHandleForWriting.close() }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (-2, "Timed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmed ?? "")
    }

    /// Generates a Seatbelt profile: read system + allowed paths, write only to allowed paths and temp.
    public static func sandboxProfile(readable: [String], writable: [String], network: Bool) -> String {
        func sub(_ paths: [String]) -> String { paths.map { "(subpath \"\(Paths.expand($0).replacingOccurrences(of: "\"", with: ""))\")" }.joined(separator: " ") }
        return """
        (version 1)
        (deny default)
        (allow process-exec process-fork signal sysctl-read mach-lookup ipc-posix-shm iokit-open)
        (allow file-read-metadata)
        (allow file-read* (literal "/") (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/Library") (subpath "/private") (subpath "/dev") (subpath "/opt/homebrew") (subpath "/Applications/Xcode.app") \(sub(readable)))
        (allow file-write* (literal "/dev/null") (literal "/dev/tty") (subpath "/private/tmp") (subpath "/private/var/folders") \(sub(writable)))
        \(network ? "(allow network*)" : "")
        """
    }

    public static func runScript(_ script: String, env: [String: String], sandboxed: Bool, readable: [String] = [], writablePaths: [String] = [],
                                 network: Bool = false, timeout: TimeInterval = 120) -> (Int32, String) {
        let expanded = Paths.expand(script)
        let isFile = FileManager.default.fileExists(atPath: expanded) && !script.contains(" ")
        let shellArgs = isFile ? [expanded] : ["-c", script]
        guard sandboxed else { return run("/bin/zsh", shellArgs, env: env, timeout: timeout) }
        let profile = sandboxProfile(readable: readable + writablePaths + [Paths.scripts.path, Paths.plugins.path] + (isFile ? [(expanded as NSString).deletingLastPathComponent] : []),
                                     writable: writablePaths, network: network)
        return run("/usr/bin/sandbox-exec", ["-p", profile, "/bin/zsh"] + shellArgs, env: env, timeout: timeout)
    }
}
