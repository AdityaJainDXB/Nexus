import Foundation
import AppKit
import CoreText

/// Periodic analysis → proactive, deduplicated insight cards (each with a one-click fix).
public final class InsightsEngine {
    let store: NexusStore
    let ruleEngine: RuleEngine
    public init(store: NexusStore, ruleEngine: RuleEngine) { self.store = store; self.ruleEngine = ruleEngine }

    public func scan(settings: NexusSettings, system: SystemSnapshot) {
        var liveKeys = Set<String>()
        func emit(_ i: Insight) { liveKeys.insert(i.key); store.upsertInsight(i) }
        let fm = FileManager.default
        let now = Date()

        // 1. Stale downloads & large files lying around
        for folder in settings.watchedFoldersExpanded {
            let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
            var stale: [String] = []
            var large: [(String, Int64)] = []
            for n in names {
                let p = (folder as NSString).appendingPathComponent(n)
                guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
                let mod = (a[.modificationDate] as? Date) ?? now
                if now.timeIntervalSince(mod) > Double(settings.staleDownloadDays) * 86400 { stale.append(p) }
                let size = (a[.size] as? NSNumber)?.int64Value ?? 0
                if (a[.type] as? FileAttributeType) == .typeRegular && size > 1_000_000_000 { large.append((p, size)) }
            }
            let short = Paths.abbreviate(folder)
            if stale.count >= 10 {
                emit(Insight(key: "stale:\(folder)", kind: .staleDownloads, title: "\(stale.count) unsorted files in \(short) older than \(settings.staleDownloadDays) days",
                             detail: "Nexus can sort them using your rules and learned folders, or archive them.", severity: stale.count > 60 ? .warning : .suggestion,
                             command: "organize \(short)", filePaths: Array(stale.prefix(200)), metric: Double(stale.count)))
            }
            if !large.isEmpty {
                let total = large.reduce(0) { $0 + $1.1 }
                emit(Insight(key: "large:\(folder)", kind: .largeFiles, title: "\(large.count) file\(large.count == 1 ? "" : "s") over 1 GB in \(short) (\(formatBytes(total)))",
                             detail: large.prefix(5).map { "• \(($0.0 as NSString).lastPathComponent) — \(formatBytes($0.1))" }.joined(separator: "\n"),
                             severity: .suggestion, command: "archive files older than 14 days in \(short)", filePaths: large.map(\.0), metric: Double(total)))
            }
        }

        // 2. Exact duplicates
        var wasted: Int64 = 0
        var dupPaths: [String] = []
        var groups = 0
        for h in store.duplicateHashes() {
            let files = store.files(withHash: h).filter { fm.fileExists(atPath: $0.path) }
            guard files.count > 1 else { continue }
            groups += 1
            wasted += files.dropFirst().reduce(0) { $0 + $1.size }
            dupPaths.append(contentsOf: files.map(\.path))
        }
        if groups > 0 {
            emit(Insight(key: "duplicates", kind: .duplicates, title: "\(groups) sets of duplicate files wasting \(formatBytes(wasted))",
                         detail: "Identical content found in multiple places. Review and keep one copy of each.", severity: wasted > 2_000_000_000 ? .warning : .suggestion,
                         command: "clean up duplicates", filePaths: Array(dupPaths.prefix(300)), metric: Double(wasted)))
        }

        // 3. Near-identical screenshots (perceptual hash clusters)
        let shots = store.files(limit: 3000, orderBy: "indexed DESC").filter { $0.kind == .screenshot && $0.perceptualHash != nil && fm.fileExists(atPath: $0.path) }
        var used = Set<String>()
        var bestCluster: [FileRecord] = []
        for s in shots where !used.contains(s.id) {
            let cluster = shots.filter { !used.contains($0.id) && ($0.perceptualHash! ^ s.perceptualHash!).nonzeroBitCount <= 5 }
            if cluster.count >= 3 { cluster.forEach { used.insert($0.id) } }
            if cluster.count > bestCluster.count { bestCluster = cluster }
        }
        if bestCluster.count >= 3 {
            emit(Insight(key: "similarShots", kind: .similarScreenshots, title: "These \(bestCluster.count) screenshots are nearly identical",
                         detail: "Keep the newest and move the rest to Trash?", severity: .suggestion, command: "clean up similar screenshots",
                         filePaths: bestCluster.map(\.path), metric: Double(bestCluster.count)))
        }
        let recentShots = shots.filter { now.timeIntervalSince($0.createdAt) < 7 * 86400 }.count
        if recentShots >= 30 && !store.rules().contains(where: { r in r.conditions.conditions.contains { $0.value == "screenshot" } }) {
            let draft = NLRuleCompiler(libraryRoot: settings.libraryRoots.first ?? "~/Documents").compile("Screenshots on Desktop → move to ~/Pictures/Screenshots/{year}-{month}").rule
            emit(Insight(key: "pattern:screenshots", kind: .patternRule, title: "You took \(recentShots) screenshots this week",
                         detail: "Want an auto-sort rule that files them by month?", severity: .suggestion, ruleDraft: draft, metric: Double(recentShots)))
        }

        // 4. Folder growth (daily snapshots)
        for folder in store.snapshotFolders() {
            let snaps = store.snapshots(folder: folder)
            guard let last = snaps.last, snaps.count >= 2 else { continue }
            let monthAgo = snaps.first { day in
                guard let d = ISO8601DateFormatter.dateOnly.date(from: day.day) else { return false }
                return now.timeIntervalSince(d) <= 31 * 86400
            } ?? snaps.first!
            let growth = last.size - monthAgo.size
            if growth > 2_000_000_000 {
                emit(Insight(key: "growth:\(folder)", kind: .folderGrowth, title: "\(Paths.abbreviate(folder)) grew by \(formatBytes(growth)) recently",
                             detail: "From \(formatBytes(monthAgo.size)) on \(monthAgo.day) to \(formatBytes(last.size)). Want a cleanup suggestion?",
                             severity: growth > 10_000_000_000 ? .warning : .suggestion, command: "clean up duplicates", metric: Double(growth)))
            }
        }

        // 5. Disk space
        if system.diskFreeGB > 0 && system.diskFreeGB < settings.lowDiskGB {
            emit(Insight(key: "lowDisk", kind: .lowDisk, title: String(format: "Only %.0f GB free on this Mac", system.diskFreeGB),
                         detail: "Largest opportunities: duplicates, old installers and archives in Downloads.", severity: system.diskFreeGB < 10 ? .critical : .warning,
                         command: "clean up duplicates", metric: system.diskFreeGB))
        }

        // 6. Projects: inactive & deadlines
        for p in store.projects(includeArchived: false) {
            let newest = store.files(limit: 1, projectId: p.id, orderBy: "modified DESC").first?.modifiedAt
            let last = [p.lastActivityAt, newest, p.createdAt].compactMap { $0 }.max() ?? p.createdAt
            let idle = now.timeIntervalSince(last) / 86400
            if idle > Double(settings.inactiveProjectDays) {
                emit(Insight(key: "inactive:\(p.id)", kind: .inactiveProject, title: "“\(p.name)” hasn’t been touched in \(Int(idle)) days",
                             detail: "Archive or compress the project to free space and declutter?", severity: .info,
                             command: "summarize project \(p.name)", metric: idle))
            }
            if let d = p.deadline, d > now, d.timeIntervalSince(now) < 3 * 86400 {
                emit(Insight(key: "deadline:\(p.id)", kind: .deadlineSoon, title: "“\(p.name)” is due \(relativeTime(d))",
                             detail: "Start a focus session? Nexus will route new files into the project and silence the rest.", severity: .warning,
                             command: "focus on \(p.name) for 2 hours"))
            }
        }

        // 7. Review backlog
        let backlog = store.reviewCount()
        if backlog >= 20 {
            emit(Insight(key: "backlog", kind: .reviewBacklog, title: "\(backlog) suggestions waiting in the Review Queue",
                         detail: "Approving a few teaches Nexus your preferences so more happens automatically.", severity: .suggestion, command: "open review queue"))
        }

        // 8. Rule conflicts (one card, not one per pair)
        let conflicts = ruleEngine.analyzeConflicts(store.rules())
        if !conflicts.isEmpty {
            emit(Insight(key: "conflicts", kind: .ruleConflict, title: conflicts.count == 1 ? "Two rules conflict" : "\(conflicts.count) rule conflicts to resolve",
                         detail: conflicts.prefix(4).map { "• \($0.message)" }.joined(separator: "\n"), severity: .warning, command: "open rules"))
        }

        // 9. Learned patterns from manual moves
        for i in PatternDetector(store: store).detect(libraryRoot: settings.libraryRoots.first ?? "~/Documents") { emit(i) }

        // Clear resolved insights of kinds this scan owns (keep user to-dos & project suggestions from ingest)
        let owned: Set<InsightKind> = [.staleDownloads, .duplicates, .similarScreenshots, .folderGrowth, .inactiveProject, .lowDisk, .largeFiles, .reviewBacklog, .ruleConflict]
        for i in store.insights(includeDismissed: true) where (owned.contains(i.kind) || i.key.hasPrefix("conflict:")) && !liveKeys.contains(i.key) {
            store.removeInsight(key: i.key)
        }
    }

    /// Aggregate medium-confidence project matches into a single "link these files?" card.
    public func suggestProjectLinks(_ candidates: [(file: FileRecord, project: Project, score: Double)]) {
        let byProject = Dictionary(grouping: candidates) { $0.project.id }
        for (pid, items) in byProject where items.count >= 3 {
            guard let p = items.first?.project else { continue }
            emit(Insight(key: "link:\(pid)", kind: .projectAssociation, title: "These \(items.count) files look like they belong to “\(p.name)”",
                         detail: items.prefix(6).map { "• \($0.file.name)" }.joined(separator: "\n") + (items.count > 6 ? "\n…" : ""),
                         severity: .suggestion, command: nil, filePaths: items.map(\.file.path), metric: Double(items.count)))
        }
        func emit(_ i: Insight) { store.upsertInsight(i) }
    }
}

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = .current; return f }()
}

// MARK: - Pattern detection ("You keep doing X by hand — want a rule?")

public final class PatternDetector {
    let store: NexusStore
    public init(store: NexusStore) { self.store = store }

    public func detect(libraryRoot: String, minOccurrences: Int = 3) -> [Insight] {
        let moves = store.observedMoves(since: Date().addingTimeInterval(-30 * 86400))
        let groups = Dictionary(grouping: moves) { "\($0.fromFolder)|\($0.toFolder)|\($0.ext)" }
        var out: [Insight] = []
        let existingRules = store.rules()
        for (_, g) in groups where g.count >= minOccurrences {
            let m = g[0]
            // Skip if a rule already routes this
            if existingRules.contains(where: { r in r.actions.contains { $0.kind == .move && Paths.expand($0.target) == m.toFolder } }) { continue }
            // Keyword shared by ≥60% of moved files
            var counts: [String: Int] = [:]
            for mv in g { for k in Set(mv.keywords) { counts[k, default: 0] += 1 } }
            let keyword = counts.filter { Double($0.value) >= Double(g.count) * 0.6 }.max { $0.value < $1.value }?.key
            let extPart = m.ext.isEmpty ? "files" : "\(m.ext.uppercased()) files"
            let keywordPart = keyword.map { " with ‘\($0)’" } ?? ""
            let from = Paths.abbreviate(m.fromFolder), to = Paths.abbreviate(m.toFolder)
            let sentence = "If a \(m.ext.isEmpty ? "file" : m.ext.uppercased()) in \(from)\(keyword.map { " contains '\($0)'" } ?? "") → move to \(to)"
            var draft = NLRuleCompiler(libraryRoot: libraryRoot).compile(sentence).rule
            draft?.name = "Learned: \(m.ext.isEmpty ? "files" : m.ext.uppercased())\(keyword.map { " + \($0)" } ?? "") → \(to)"
            let period = g.count >= 8 ? "regularly" : "\(g.count) times this month"
            out.append(Insight(key: "pattern:\(m.fromFolder)|\(m.toFolder)|\(m.ext)", kind: .patternRule,
                               title: "You moved \(extPart)\(keywordPart) from \(from) to \(to) \(period). Want a rule?",
                               detail: "Nexus noticed you doing this by hand. The rule is fully editable and undoable.",
                               severity: .suggestion, ruleDraft: draft, metric: Double(g.count)))
        }
        return out
    }
}

// MARK: - Reports

public final class ReportGenerator {
    let store: NexusStore
    public init(store: NexusStore) { self.store = store }

    public func markdown(type: String, now: Date = Date()) -> String {
        let cal = Calendar.current
        let days = type == "monthly" ? 30 : type == "daily" ? 1 : 7
        let since = type == "daily" ? cal.startOfDay(for: now) : now.addingTimeInterval(-Double(days) * 86400)
        let df = DateFormatter(); df.dateStyle = .medium
        var md = "# Nexus \(type.capitalized) Report\n\n_\(df.string(from: since)) – \(df.string(from: now))_\n\n"
        let projects = store.projects()
        let projectName = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })

        let newFiles = store.files(limit: 5000, orderBy: "indexed DESC").filter { $0.indexedAt >= since }
        md += "## At a glance\n\n"
        md += "- **\(newFiles.count)** new files indexed (\(formatBytes(newFiles.reduce(0) { $0 + $1.size })))\n"
        let hits = store.ruleHits(since: since)
        let rules = store.rules()
        let totalHits = hits.values.reduce(0, +)
        let secondsSaved = rules.reduce(0) { $0 + (hits[$1.id] ?? 0) * $1.estimatedSecondsSaved }
        md += "- **\(totalHits)** automation runs, saving about **\(max(1, secondsSaved / 60)) min** of busywork\n"
        md += "- **\(store.eventCount(kind: .fileMoved, since: since))** files moved · **\(store.eventCount(kind: .fileTagged, since: since))** tagged · **\(store.reviewCount())** awaiting review\n\n"

        if type == "daily" || type == "weekly" {
            md += "## New files by project\n\n"
            let grouped = Dictionary(grouping: newFiles) { $0.projectId.flatMap { projectName[$0] } ?? "Unassigned" }
            for (name, files) in grouped.sorted(by: { $0.value.count > $1.value.count }) {
                md += "### \(name) (\(files.count))\n\n"
                for f in files.prefix(25) {
                    let tags = f.tags.isEmpty ? "" : " " + f.tags.map { "`#\($0)`" }.joined(separator: " ")
                    md += "- [\(f.name)](file://\(f.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.path))\(f.docType.map { " — \($0)" } ?? "")\(tags)\n"
                }
                if files.count > 25 { md += "- …and \(files.count - 25) more\n" }
                md += "\n"
            }
        }

        md += "## Storage by type\n\n| Type | Files | Size |\n|---|---:|---:|\n"
        for (kind, size, count) in store.storageByKind().prefix(12) { md += "| \(kind) | \(count) | \(formatBytes(size)) |\n" }
        md += "\n## Storage by project\n\n| Project | Files | Size |\n|---|---:|---:|\n"
        for (pid, size, count) in store.storageByProject().prefix(12) { md += "| \(pid.flatMap { projectName[$0] } ?? "Unassigned") | \(count) | \(formatBytes(size)) |\n" }

        md += "\n## Folder growth\n\n"
        for folder in store.snapshotFolders() {
            let s = store.snapshots(folder: folder)
            guard let first = s.first, let last = s.last else { continue }
            let delta = last.size - first.size
            md += "- \(Paths.abbreviate(folder)): \(formatBytes(last.size)) (\(delta >= 0 ? "+" : "−")\(formatBytes(abs(delta))) since \(first.day))\n"
        }

        md += "\n## Automations\n\n| Rule | Runs | Time saved |\n|---|---:|---:|\n"
        for r in rules.sorted(by: { (hits[$0.id] ?? 0) > (hits[$1.id] ?? 0) }).prefix(15) {
            let h = hits[r.id] ?? 0
            md += "| \(r.name) | \(h) | \(h * r.estimatedSecondsSaved / 60) min |\n"
        }

        let insights = store.insights().prefix(10)
        if !insights.isEmpty {
            md += "\n## Hygiene suggestions\n\n"
            for i in insights { md += "- **\(i.title)** — \(i.detail.replacingOccurrences(of: "\n", with: " "))\n" }
        }
        let failed = store.jobs(status: [.failed], limit: 20).filter { ($0.finishedAt ?? .distantPast) >= since }
        if !failed.isEmpty {
            md += "\n## Failed tasks\n\n"
            for j in failed { md += "- \(j.name): \(j.error ?? "unknown error")\n" }
        }
        md += "\n---\n_Generated on-device by Nexus._\n"
        return md
    }

    @discardableResult
    public func save(type: String) -> URL {
        let md = markdown(type: type)
        let name = "\(ISO8601DateFormatter.dateOnly.string(from: Date()))-\(type).md"
        let url = Paths.reports.appendingPathComponent(name)
        try? md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Renders markdown-ish text to a paginated PDF with CoreText (no WebKit, works off the main thread).
    public static func pdf(markdown: String, to url: URL) throws {
        let body = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 11)
        for line in markdown.components(separatedBy: "\n") {
            var attrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.black]
            var text = line
            if line.hasPrefix("# ") { attrs[.font] = NSFont.boldSystemFont(ofSize: 22); text = String(line.dropFirst(2)) }
            else if line.hasPrefix("## ") { attrs[.font] = NSFont.boldSystemFont(ofSize: 15); text = "\n" + String(line.dropFirst(3)) }
            else if line.hasPrefix("### ") { attrs[.font] = NSFont.boldSystemFont(ofSize: 12); text = String(line.dropFirst(4)) }
            else if line.hasPrefix("|---") { continue }
            else if line.hasPrefix("|") { attrs[.font] = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular); text = line.replacingOccurrences(of: "|", with: "  ") }
            text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            body.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw LLMError("cannot create PDF") }
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        var range = CFRange(location: 0, length: 0)
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: mediaBox.insetBy(dx: 54, dy: 54), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            range = CFRange(location: visible.location + visible.length, length: 0)
            ctx.endPDFPage()
        } while range.location < body.length
        ctx.closePDF()
    }
}
