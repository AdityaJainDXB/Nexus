import Foundation
import AppKit

public struct FocusSession: Codable, Hashable {
    public var projectId: String
    public var startedAt: Date
    public var endsAt: Date
    public var source: String            // "manual" | "calendar"
    public var suppressed: Int
}

public struct PlannedStep: Identifiable {
    public var id = newID()
    public var step: CommandStep
    public var files: [FileRecord]
    public var preview: [String]
    public var note: String?
    public var ruleResult: RuleCompileResult?
}

public struct CommandPlan: Identifiable {
    public var id = newID()
    public var input: String
    public var steps: [PlannedStep]
    public var understood: Bool
    public var requiresConfirmation: Bool
    public var usedLLM: Bool
}

public struct CommandResult {
    public var message: String
    public var files: [FileRecord] = []
    public var details: [String] = []
    public var batchId: String?
    public var navigate: String?
    public var createdRule: Rule?
}

/// The always-on agent. Owns every subsystem and connects them through the event bus and task queue.
///
///   FSEvents ─┐                        ┌─► RuleEngine ─► ActionExecutor (undo journal, guard)
///   System  ──┼─► EventBus ─► Ingest ──┼─► Autopilot (confidence gating) ─► Review Queue
///   Connectors┘                        └─► Knowledge graph / embeddings / insights
///   Scheduler ─► TaskQueue (persistent, prioritized, retries) ─► job runner
public final class NexusEngine: ActionHost {
    public let store: NexusStore
    public let bus = EventBus()
    public let extractor = ContentExtractor()
    public let classifier = Classifier()
    public let embedder = Embedder()
    public let ruleEngine = RuleEngine()
    public let plugins = PluginHost()
    public let taxonomy: TaxonomyLearner
    public let projectMatcher: ProjectMatcher
    public let llm: LLMRouter
    public let connectors: Connectors
    public let executor: ActionExecutor
    public let queue: TaskQueue
    public let scheduler: Scheduler
    public let monitor: SystemMonitor
    public let insights: InsightsEngine
    public let reports: ReportGenerator

    public private(set) var settings: NexusSettings
    public private(set) var paused = false
    public private(set) var status: EngineStatus = .idle
    public private(set) var focus: FocusSession?
    /// Delivered to the UI layer (UserNotifications). Engine decides *whether* to notify.
    public var notifier: ((String, String, Bool) -> Void)?
    /// Files the user is looking at right now (Finder selection / front document), supplied by the app layer.
    public var contextSelection: (() -> [String])?

    private let watcher = FileWatcher()
    private let stabilizer = FileStabilizer()
    private let ingestQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "app.nexus.ingest"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    private var recentRemovals: [UInt64: (path: String, at: Date, record: FileRecord?)] = [:]
    private let removalsLock = NSLock()
    private var lastEventRuleFire: [String: Date] = [:]
    private var projectVectors: [String: [Float]] = [:]
    private var pendingProjectLinks: [(file: FileRecord, project: Project, score: Double)] = []
    private var notificationDigest: (filed: Int, review: Int) = (0, 0)
    private var lastCommandResults: [String] = []
    private let stateLock = NSLock()

    public init(store: NexusStore) {
        self.store = store
        settings = store.loadSettings()
        taxonomy = TaxonomyLearner(store: store)
        projectMatcher = ProjectMatcher(embedder: embedder)
        llm = LLMRouter(settings: settings)
        connectors = Connectors(bus: bus)
        executor = ActionExecutor(store: store, connectors: connectors, guardrail: RunawayGuard(limitPerMinute: settings.maxOpsPerMinute))
        queue = TaskQueue(store: store)
        scheduler = Scheduler(store: store, queue: queue)
        monitor = SystemMonitor(bus: bus)
        insights = InsightsEngine(store: store, ruleEngine: ruleEngine)
        reports = ReportGenerator(store: store)
        focus = JSON.decode(FocusSession.self, store.kv("focus"))
        paused = store.kv("paused") == "1"

        executor.host = self
        connectors.settingsProvider = { [weak self] in self?.settings ?? NexusSettings() }
        connectors.kvReader = { [weak store] in store?.kv($0) }
        applySettings()
        store.onChange = { [weak self] entity in self?.bus.post(.storeChanged(entity)) }
    }

    // MARK: - Lifecycle

    public func start() {
        seedIfNeeded()
        plugins.installExamples()
        bus.subscribe { [weak self] in self?.handle($0) }

        watcher.onChange = { [weak self] in self?.handleFileChanges($0) }
        stabilizer.onStable = { [weak self] path in self?.enqueueIngest(path, trigger: self?.triggerFor(path) ?? .fileAdded) }
        restartWatcher()

        queue.runner = { [weak self] job, ctx in
            guard let self else { throw LLMError("engine gone") }
            return try await self.runJob(job, ctx)
        }
        queue.isPaused = { [weak self] in self?.paused ?? false }
        queue.isThrottled = { [weak self] in
            guard let self, self.settings.batteryAware else { return false }
            return self.monitor.snapshot.shouldThrottle
        }
        queue.onActivityChange = { [weak self] _ in self?.refreshStatus() }
        queue.start()

        scheduler.systemSnapshot = { [weak self] in self?.monitor.snapshot ?? SystemMonitor.sample() }
        scheduler.fireRule = { [weak self] rule, info in self?.enqueueRuleJob(rule, info: info) }
        scheduler.maintenance = [
            ("insights", 3 * 3600, { [weak self] in self?.enqueueOnce(.scanInsights, name: "Scan for insights", kind: .ai, priority: .low) }),
            ("snapshots", 24 * 3600, { [weak self] in self?.takeSnapshots() }),
            ("taxonomy", 24 * 3600, { [weak self] in self?.enqueueOnce(.learnTaxonomy, name: "Learn folder structure", kind: .ai, priority: .low) }),
            ("ageSweep", 3600, { [weak self] in self?.sweepAgeRules() }),
            ("focus", 120, { [weak self] in self?.checkFocus() }),
            ("prune", 24 * 3600, { [weak self] in self?.store.pruneJobs() }),
            // Keep library folders searchable (incremental: unchanged files are skipped)
            ("libraryIndex", 24 * 3600, { [weak self] in
                guard let self else { return }
                for root in Set(self.settings.libraryRootsExpanded + self.settings.watchedFoldersExpanded) {
                    self.enqueueOnce(.classifyFolder, name: "Index \(Paths.abbreviate(root))", kind: .ai, priority: .low, spec: JobSpec(operation: .classifyFolder, path: root))
                }
            }),
            ("digest", 60, { [weak self] in self?.flushNotificationDigest() }),
            ("projectLinks", 600, { [weak self] in self?.flushProjectLinks() }),
        ]
        scheduler.start()
        monitor.start()
        connectors.startPolling()
        rebuildProjectVectors()
        store.log(ActivityEvent(kind: .system, message: "Nexus started · watching \(watcher.paths.count) folders"))
    }

    public func stop() {
        watcher.stop()
        monitor.stop()
    }

    public func updateSettings(_ new: NexusSettings) {
        let foldersChanged = new.watchedFolders != settings.watchedFolders || new.libraryRoots != settings.libraryRoots
        settings = new
        store.saveSettings(new)
        applySettings()
        if foldersChanged { restartWatcher() }
    }

    private func applySettings() {
        extractor.enableOCR = settings.enableOCR
        extractor.enableSpeech = settings.enableSpeech
        extractor.maxChars = settings.maxExtractKB * 1024
        llm.settings = settings
        llm.invalidate()
        executor.guardrail.limitPerMinute = settings.maxOpsPerMinute
    }

    public func restartWatcher() {
        var paths = settings.watchedFoldersExpanded + settings.libraryRootsExpanded + [Connectors.mailInbox.path]
        for r in store.rules() where r.enabled && r.trigger.kind.isFileTrigger { paths += r.trigger.folders.map(Paths.expand) }
        if !settings.obsidianVault.isEmpty { paths.append(Paths.expand(settings.obsidianVault)) }
        if let mail = Self.mailLibrary { paths.append(mail) }   // requires Full Disk Access
        try? FileManager.default.createDirectory(at: Connectors.mailInbox, withIntermediateDirectories: true)
        // FSEvents is recursive: drop paths already covered by a parent
        let unique = Array(Set(paths)).sorted()
        let roots = unique.filter { p in !unique.contains { $0 != p && Paths.isInside(p, $0) } }
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
        if Set(existing) == Set(watcher.paths) { return }   // nothing changed — keep the live stream
        watcher.start(paths: roots)
    }

    public func setPaused(_ p: Bool) {
        paused = p
        store.setKV("paused", p ? "1" : "0")
        store.log(ActivityEvent(kind: .system, message: p ? "Automations paused" : "Automations resumed"))
        refreshStatus()
    }

    public func pause(reason: String) {
        setPaused(true)
        notify(title: "Nexus paused automations", body: reason, important: true)
    }

    func refreshStatus() {
        let busy = ingestQueue.operationCount > 0 || queue.runningCount > 0
        let new: EngineStatus = paused ? .paused : busy ? .working : (store.reviewCount() > 0 ? .attention : .idle)
        if new != status { status = new; bus.post(.status(new)) }
    }

    // MARK: - Seeding

    private func seedIfNeeded() {
        guard store.kv("seeded") == nil else { return }
        // Fresh install: learn from the places this user actually keeps things
        if store.kv("settings") == nil {
            let found = FolderDiscovery.candidates().filter(\.recommended).map { Paths.abbreviate($0.path) }
            if !found.isEmpty { settings.libraryRoots = found; store.saveSettings(settings) }
        }
        let root = settings.libraryRoots.first { $0.hasSuffix("Documents") } ?? settings.libraryRoots.first ?? "~/Documents"
        let roots = settings.libraryRootsExpanded
        func dest(_ s: String) -> String { s.hasPrefix("~") ? s : (root as NSString).appendingPathComponent(s) }
        let defaults: [(String, String, [String], [String])] = [
            ("Invoices", "Finance/Invoices/{year}", ["invoice"], ["invoice", "amount due"]),
            ("Receipts", "Finance/Receipts/{year}", ["receipt"], ["receipt", "order total"]),
            ("Bank statements", "Finance/Statements", ["bank statement"], []),
            ("Tax documents", "Finance/Taxes/{year}", ["tax document"], ["1099", "w-2"]),
            ("Lab reports", "School/Lab Reports", ["lab report"], ["hypothesis", "lab report"]),
            ("Syllabi", "School/Syllabi", ["syllabus"], ["syllabus"]),
            ("Assignments", "School/Assignments", ["assignment"], ["rubric", "worksheet"]),
            ("Essays", "School/Essays", ["essay"], []),
            ("Resumes", "Career", ["resume"], []),
            ("Contracts", "Legal", ["contract"], ["agreement"]),
            ("Research papers", "Library/Papers", ["research paper"], ["arxiv", "doi"]),
            ("Manuals", "Library/Manuals", ["manual"], []),
            ("Tickets", "Travel", ["ticket"], ["boarding pass"]),
            ("Meeting notes", "Notes/Meetings", ["meeting notes"], []),
            ("Specs", "Dev/Specs", ["spec"], []),
            ("Code snippets", "Dev/Snippets/{language}", ["code"], []),
            ("3D models", "3D Printing/Models", ["3d model"], []),
            ("Screenshots", "~/Pictures/Screenshots/{year}-{month}", ["screenshot"], []),
            ("Installers", "~/Downloads/Installers", ["installer"], []),
        ]
        for (name, d, types, keys) in defaults {
            // Prefer a folder the user already has ("Science", "School & Documents", "CAD & Electronics"…)
            let existing = FolderDiscovery.existingFolder(for: name, roots: roots).map(Paths.abbreviate)
            store.saveCategory(Category(name: name, destination: existing ?? dest(d), keywords: keys, docTypes: types, learned: existing != nil))
        }
        store.saveSchedule(Schedule(name: "Weekly report", mode: .recurring, cron: "0 \(settings.digestHour) * * \(settings.digestWeekday - 1)",
                                    jobKind: .ai, job: JobSpec(operation: .generateReport, params: ["type": "weekly"]), priority: .low,
                                    naturalLanguage: "Every Sunday at 9 AM generate weekly report"))
        store.saveSchedule(Schedule(name: "Evening Downloads tidy", mode: .conditional,
                                    conditions: [SystemCondition(kind: .folderCountAbove, folder: "~/Downloads", number: 50), SystemCondition(kind: .hourAtLeast, number: 20)],
                                    job: JobSpec(operation: .sortFolder, path: "~/Downloads"), enabled: false, cooldownMinutes: 12 * 60,
                                    naturalLanguage: "When Downloads has > 50 files and it's after 8 PM → auto-sort"))
        store.setKV("seeded", "1")
    }

    // MARK: - Event handling

    private func handle(_ e: NexusEvent) {
        switch e {
        case .appLaunched(let name, let bid): fireEventRules(.appLaunched, info: ["appName": name, "bundleId": bid ?? ""])
        case .appQuit(let name, let bid): fireEventRules(.appQuit, info: ["appName": name, "bundleId": bid ?? ""])
        case .volumeMounted(let name, let path): fireEventRules(.volumeMounted, info: ["volumeName": name, "volumePath": path])
        case .volumeUnmounted(let name, let path): fireEventRules(.volumeUnmounted, info: ["volumeName": name, "volumePath": path])
        case .diskSpace(let gb):
            fireEventRules(.diskSpaceBelow, info: ["freeGB": String(format: "%.1f", gb)])
            if gb < settings.lowDiskGB && store.kv("lowDiskNotified") != ISO8601DateFormatter.dateOnly.string(from: Date()) {
                store.setKV("lowDiskNotified", ISO8601DateFormatter.dateOnly.string(from: Date()))
                enqueueOnce(.scanInsights, name: "Low disk: scan for cleanup", kind: .system, priority: .high)
            }
        case .idle(let m): fireEventRules(.idle, info: ["idleMinutes": String(m)])
        case .wake: fireEventRules(.wake, info: [:]); scheduler.tickNow()
        case .connector(_, let payload):
            fireEventRules(.connectorEvent, info: payload)
            if payload["connectorEvent"] == "calendar.eventStarting", let title = payload["title"] { prepareForMeeting(title: title) }
        case .focusChanged(let active, let pid): fireEventRules(active ? .focusStarted : .focusEnded, info: ["projectId": pid ?? ""])
        case .storeChanged(let entity):
            if entity == "projects" { rebuildProjectVectors() }
            if entity == "rules" { DispatchQueue.main.async { [weak self] in self?.restartWatcher() } }
            if entity == "review" { refreshStatus() }
        default: break
        }
    }

    // MARK: - File events

    /// ~/Library/Mail when readable (Full Disk Access granted).
    static var mailLibrary: String? {
        let p = Paths.expand("~/Library/Mail")
        return (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil ? p : nil
    }

    static func isMailAttachment(_ path: String) -> Bool {
        (path.contains("/Library/Mail/") && path.contains("/Attachments/")) || Paths.isInside(path, Connectors.mailInbox.path)
    }

    func triggerFor(_ path: String) -> TriggerKind {
        if Self.isMailAttachment(path) { return .connectorEvent }
        if Paths.isInside(path, Paths.expand("~/Downloads")) { return .downloadCompleted }
        return .fileAdded
    }

    func shouldProcess(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        if settings.ignoredPatterns.contains(where: { name.glob($0) }) { return false }
        if path.contains("/.git/") || path.contains("/node_modules/") || path.contains("/.Trash/") { return false }
        if Paths.isInside(path, Paths.appSupport.path) && !Paths.isInside(path, Connectors.mailInbox.path) { return false }
        if path.contains("/Library/Mail/") && !path.contains("/Attachments/") { return false }
        // Only files inside packages count as the package itself
        let comps = path.split(separator: "/")
        if comps.dropLast().contains(where: { ["app", "rtfd", "pages", "key", "numbers", "photoslibrary", "xcodeproj", "bundle"].contains(($0 as NSString).pathExtension) }) { return false }
        return true
    }

    func isAutomationFolder(_ path: String) -> Bool {
        settings.watchedFoldersExpanded.contains { Paths.isInside(path, $0, recursive: false) }
    }

    func handleFileChanges(_ changes: [FileChange]) {
        let now = Date()
        removalsLock.lock()
        recentRemovals = recentRemovals.filter { now.timeIntervalSince($0.value.at) < 20 }
        removalsLock.unlock()

        for c in changes where shouldProcess(c.path) {
            switch c.kind {
            case .removed:
                let rec = store.file(path: c.path)
                if let inode = c.inode {
                    removalsLock.lock(); recentRemovals[inode] = (c.path, now, rec); removalsLock.unlock()
                }
                // mark missing lazily (a rename's "new" half may follow)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, !FileManager.default.fileExists(atPath: c.path), self.store.file(path: c.path) != nil else { return }
                    self.store.markMissing(path: c.path)
                }
            case .created, .renamed:
                if c.isDirectory { continue }
                removalsLock.lock()
                let moved = c.inode.flatMap { recentRemovals.removeValue(forKey: $0) }
                removalsLock.unlock()
                if let moved, moved.path != c.path {
                    handleUserMove(from: moved.path, to: c.path, record: moved.record)
                    // moved *into* an automation folder counts as new
                    if isAutomationFolder(c.path) && !isAutomationFolder(moved.path) { stabilizer.submit(c.path) }
                    continue
                }
                stabilizer.submit(c.path)
            case .modified:
                if c.isDirectory { continue }
                if let rec = store.file(path: c.path),
                   let mod = (try? FileManager.default.attributesOfItem(atPath: c.path))?[.modificationDate] as? Date,
                   abs(mod.timeIntervalSince(rec.modifiedAt)) < 1 { continue }
                if isAutomationFolder(c.path) || store.rules().contains(where: { $0.enabled && $0.trigger.kind == .fileModified }) {
                    enqueueIngest(c.path, trigger: .fileModified)
                }
            }
        }
    }

    /// The user moved a file by hand: keep the index in sync and learn from it.
    func handleUserMove(from: String, to: String, record: FileRecord?) {
        let fromFolder = (from as NSString).deletingLastPathComponent
        let toFolder = (to as NSString).deletingLastPathComponent
        if var rec = record ?? store.file(path: from) {
            rec.path = to
            store.upsertFile(rec)
            if fromFolder != toFolder {
                let keywords = Array(Set(Classifier.tokens((rec.name as NSString).deletingPathExtension) + rec.topics.map { $0.lowercased() })).prefix(12)
                store.recordObservedMove(ObservedMove(fromFolder: fromFolder, toFolder: toFolder, ext: rec.ext, keywords: Array(keywords)))
                taxonomy.reinforce(folder: toFolder, docType: rec.docType, keywords: Array(keywords))
                // a pending review for this file is now moot
                if var item = store.pendingReview(fileId: rec.id) {
                    item.status = item.suggestedDestination.map(Paths.expand) == toFolder ? .approved : .rejected
                    item.resolvedAt = Date()
                    store.saveReview(item)
                }
            }
        } else if fromFolder != toFolder {
            let ext = (to as NSString).pathExtension.lowercased()
            store.recordObservedMove(ObservedMove(fromFolder: fromFolder, toFolder: toFolder, ext: ext,
                                                  keywords: Classifier.tokens(((to as NSString).lastPathComponent as NSString).deletingPathExtension)))
        }
    }

    public func enqueueIngest(_ path: String, trigger: TriggerKind, info: [String: String] = [:]) {
        ingestQueue.addOperation { [weak self] in
            guard let self else { return }
            let sem = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                await self.ingest(path, trigger: trigger, info: info)
                sem.signal()
            }
            sem.wait()
            self.refreshStatus()
        }
        refreshStatus()
    }

    // MARK: - Ingest pipeline

    public func ingest(_ rawPath: String, trigger: TriggerKind, info: [String: String] = [:]) async {
        let path = Paths.canonical(rawPath)
        guard shouldProcess(path), FileManager.default.fileExists(atPath: path) else { return }
        guard let (rec, content) = index(path) else { return }
        var info = info
        if trigger == .connectorEvent && Self.isMailAttachment(path) {
            info["connectorEvent"] = "mail.attachment"; info["source"] = "Mail"
        }
        guard !paused else { return }

        // A new download whose exact content is already filed elsewhere is just clutter: move it to Trash (undoable)
        if settings.autoRemoveDuplicates, isAutomationFolder(path), let hash = rec.contentHash, rec.size > 0,
           let original = store.files(withHash: hash).first(where: { $0.id != rec.id && !isAutomationFolder($0.path) && FileManager.default.fileExists(atPath: $0.path) }) {
            let batch = newID()
            let (_, out) = await executor.run(actions: [RuleAction(kind: .trash)], file: rec, batchId: batch, dryRun: settings.dryRun)
            if out.first?.success == true {
                store.log(ActivityEvent(kind: .fileTrashed, message: "Removed duplicate \(rec.name) — already filed at \(Paths.abbreviate(original.path))", fileId: rec.id, batchId: batch))
                stateLock.lock(); notificationDigest.filed += 1; stateLock.unlock()
                return
            }
        }

        let fired = await runRules(file: rec, content: content, trigger: trigger, info: info)
        // Autopilot never touches files inside other apps' storage (e.g. Mail's attachment cache)
        guard fired == 0, isAutomationFolder(path) || (trigger == .connectorEvent && !Paths.isProtected(path)) else { return }
        let current = store.file(id: rec.id) ?? rec
        if await routeForFocus(current) { return }
        if settings.autopilotEnabled { await autopilot(current, content: content) }
    }

    /// Extract → classify → match project → persist (FTS, embeddings, knowledge graph). No side effects on disk.
    @discardableResult
    public func index(_ rawPath: String) -> (FileRecord, String)? {
        let path = Paths.canonical(rawPath)
        guard let x = extractor.extract(path: path), x.kind != .folder else { return nil }
        let prev = store.file(path: path)
        let cls = classifier.classify(path: path, content: x, taxonomyTerms: projectTerms() + taxonomy.knownTerms)
        var rec = prev ?? FileRecord(path: path)
        rec.path = path
        rec.kind = x.kind
        rec.size = x.size
        rec.createdAt = x.createdAt
        rec.modifiedAt = x.modifiedAt
        rec.indexedAt = prev?.indexedAt ?? Date()
        rec.contentHash = x.contentHash
        rec.perceptualHash = x.perceptualHash
        rec.sourceURL = x.sourceURL
        rec.docType = cls.docType
        rec.confidence = cls.docTypeConfidence
        rec.language = cls.language
        rec.topics = cls.topics
        rec.entities = cls.entities
        rec.snippet = String(x.text.trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(400))
        if rec.status == .missing { rec.status = .indexed }
        // Merge Finder tags
        if let finderTags = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames {
            for t in finderTags where !rec.tags.contains(t) { rec.tags.append(t) }
        }

        let vector = embedder.vector((rec.name as NSString).deletingPathExtension + ". " + rec.topics.joined(separator: ", ") + ". " + String(x.text.prefix(1200)))
        if rec.projectId == nil {
            let matches = projectMatcher.match(file: rec, text: x.text, projects: store.projects(includeArchived: false), fileVector: vector, projectVectors: projectVectors)
            if let best = matches.first {
                if best.score >= settings.autoThreshold {
                    rec.projectId = best.project.id
                    var p = best.project; p.lastActivityAt = Date(); store.saveProject(p)
                } else if best.score >= settings.reviewThreshold {
                    stateLock.lock(); pendingProjectLinks.append((rec, best.project, best.score)); stateLock.unlock()
                }
            }
        }
        store.upsertFile(rec, content: x.text)
        if let vector { store.saveEmbedding(fileId: rec.id, vector: vector) }

        store.removeEdges(srcType: .file, srcId: rec.id)
        var edges: [GraphEdge] = rec.topics.map { GraphEdge(srcType: .file, srcId: rec.id, dstType: .topic, dstId: $0.lowercased(), relation: "about") }
        for e in rec.entities {
            let type: NodeType? = [.person: .person, .organization: .organization, .place: .place, .date: .date, .course: .topic][e.kind]
            if let type { edges.append(GraphEdge(srcType: .file, srcId: rec.id, dstType: type, dstId: e.value.lowercased(), relation: "mentions")) }
        }
        edges += rec.tags.map { GraphEdge(srcType: .file, srcId: rec.id, dstType: .tag, dstId: $0.lowercased(), relation: "taggedWith") }
        if let pid = rec.projectId { edges.append(GraphEdge(srcType: .file, srcId: rec.id, dstType: .project, dstId: pid, relation: "belongsTo")) }
        store.addEdges(edges)
        if prev == nil { store.log(ActivityEvent(kind: .fileIndexed, message: "Indexed \(rec.name)\(rec.docType.map { " · \($0)" } ?? "")", fileId: rec.id)) }
        return (rec, x.text)
    }

    func projectTerms() -> [String] {
        store.projects(includeArchived: false).flatMap { [$0.name] + $0.keywords }
    }

    func rebuildProjectVectors() {
        var v: [String: [Float]] = [:]
        for p in store.projects(includeArchived: false) {
            if let vec = embedder.vector(([p.name] + p.keywords + p.tags).joined(separator: ", ") + ". " + p.notes) { v[p.id] = vec }
        }
        stateLock.lock(); projectVectors = v; stateLock.unlock()
    }

    // MARK: - Rules

    @discardableResult
    func runRules(file: FileRecord, content: String, trigger: TriggerKind, info: [String: String], batchId: String = newID()) async -> Int {
        let rules = store.rules().filter { $0.enabled && ($0.trigger.kind.isFileTrigger || $0.trigger.kind == .connectorEvent) }
        guard !rules.isEmpty else { return 0 }
        let projectName = file.projectId.flatMap { store.project(id: $0)?.name }
        let ctx = RuleContext(file: file, content: content, projectName: projectName, trigger: trigger, info: info)
        var current = file
        var fired = 0
        for rule in ruleEngine.firingRules(rules: rules, ctx: ctx) {
            if rule.trigger.kind == .connectorEvent && trigger != .connectorEvent { continue }
            fired += 1
            if rule.requireConfirmation {
                let move = rule.actions.first { $0.kind == .move }
                store.saveReview(ReviewItem(fileId: current.id, path: current.path, suggestedDestination: move.map { Templates.expand($0.target, file: current, projectName: projectName) },
                                            suggestedTags: rule.actions.filter { $0.kind == .tag }.flatMap(\.tags), confidence: 1,
                                            reasons: ["Rule “\(rule.name)” requires confirmation", rule.summary], ruleId: rule.id))
                current.status = .review
                store.upsertFile(current)
                continue
            }
            // Files inside protected locations (Mail's store) are copied out, never moved
            let actions = Paths.isProtected(current.path) ? rule.actions.map { a -> RuleAction in var x = a; if x.kind == .move { x.kind = .copy }; return x }.filter { ![.rename, .trash, .compress].contains($0.kind) } : rule.actions
            let (after, outcomes) = await executor.run(actions: actions, file: current, info: info, ruleId: rule.id, batchId: batchId, dryRun: settings.dryRun)
            if let after { current = after }
            store.recordRuleHit(rule.id)
            let ok = outcomes.filter(\.success).count
            store.log(ActivityEvent(kind: .ruleFired, message: "“\(rule.name)” on \(file.name): \(outcomes.map(\.message).joined(separator: " · "))",
                                    fileId: file.id, ruleId: rule.id, batchId: batchId))
            if ok > 0 { stateLock.lock(); notificationDigest.filed += 1; stateLock.unlock() }
        }
        return fired
    }

    func fireEventRules(_ kind: TriggerKind, info: [String: String]) {
        guard !paused else { return }
        let ctx = RuleContext(file: nil, trigger: kind, info: info)
        for rule in store.rules() where rule.enabled && rule.trigger.kind == kind && ruleEngine.triggerMatches(rule, ctx) {
            if rule.trigger.kind == .connectorEvent && !rule.trigger.folders.isEmpty { continue } // file-backed connector (mail) handled by ingest
            let (ok, _) = ruleEngine.conditionsPass(rule.conditions, ctx)
            guard ok else { continue }
            stateLock.lock()
            let last = lastEventRuleFire[rule.id]
            let cooling = last.map { Date().timeIntervalSince($0) < Double(max(rule.cooldownMinutes, 1)) * 60 } ?? false
            if !cooling { lastEventRuleFire[rule.id] = Date() }
            stateLock.unlock()
            if cooling { continue }
            enqueueRuleJob(rule, info: info)
        }
    }

    func enqueueRuleJob(_ rule: Rule, info: [String: String]) {
        guard !paused else { return }
        let kind: JobKind = rule.actions.contains { [.runShell, .runAppleScript, .runShortcut, .runPlugin].contains($0.kind) } ? .script
            : rule.actions.contains { [.githubIssue, .slackMessage, .notionPage, .webhook, .createReminder, .createCalendarEvent, .obsidianNote].contains($0.kind) } ? .integration
            : rule.actions.contains { [.summarize, .generateReport].contains($0.kind) } ? .ai : .file
        let priority: JobPriority = focus != nil && rule.projectId == focus?.projectId ? .focus : .high
        queue.enqueue(Job(name: rule.name, kind: kind, priority: priority,
                          spec: JobSpec(operation: .runActions, ruleId: rule.id, actions: rule.actions, params: info), maxAttempts: 2))
    }

    /// Runs a rule on demand: file rules apply to files currently in their trigger folders.
    public func runRuleNow(_ rule: Rule, ctx jobCtx: JobContext? = nil) async -> String {
        guard rule.trigger.kind.isFileTrigger else {
            let (_, outcomes) = await executor.run(actions: rule.actions, file: nil, info: ["manual": "1"], ruleId: rule.id, jobId: jobCtx?.jobId, dryRun: settings.dryRun)
            store.recordRuleHit(rule.id)
            return outcomes.map(\.message).joined(separator: " · ")
        }
        let folders = (rule.trigger.folders.isEmpty ? settings.watchedFolders : rule.trigger.folders).map(Paths.expand)
        let batch = newID()
        var matched = 0, total = 0
        for folder in folders {
            for path in listFiles(folder, recursive: rule.trigger.recursive) {
                if jobCtx?.isCancelled == true { break }
                total += 1
                guard let (rec, content) = index(path) else { continue }
                let pctx = RuleContext(file: rec, content: content, projectName: rec.projectId.flatMap { store.project(id: $0)?.name }, trigger: .manual)
                let (ok, _) = ruleEngine.conditionsPass(rule.conditions, pctx)
                guard ok else { continue }
                matched += 1
                let (_, outcomes) = await executor.run(actions: rule.actions, file: rec, ruleId: rule.id, jobId: jobCtx?.jobId, batchId: batch, dryRun: settings.dryRun)
                jobCtx?.log("\(rec.name): \(outcomes.map(\.message).joined(separator: " · "))")
                store.recordRuleHit(rule.id)
            }
        }
        return "Matched \(matched) of \(total) files"
    }

    public func simulate(path: String, rules: [Rule]? = nil) -> SimulationReport? {
        guard let (rec, content) = index(path) else { return nil }
        return ruleEngine.simulate(rules: rules ?? store.rules(), file: rec, content: content, projectName: rec.projectId.flatMap { store.project(id: $0)?.name })
    }

    /// Dry-run a rule against every file in a folder: which would match and what would happen.
    public func testRule(_ rule: Rule, folder: String, limit: Int = 300) -> [(FileRecord, RuleEvaluation)] {
        var out: [(FileRecord, RuleEvaluation)] = []
        for path in listFiles(Paths.expand(folder), recursive: false).prefix(limit) {
            guard let (rec, content) = index(path) else { continue }
            let ctx = RuleContext(file: rec, content: content, projectName: rec.projectId.flatMap { store.project(id: $0)?.name }, trigger: .manual)
            var r = rule; r.enabled = true; r.stopProcessing = false
            if let e = ruleEngine.evaluate(rules: [r], ctx: ctx).first { out.append((rec, e)) }
        }
        return out.sorted { $0.1.fired && !$1.1.fired }
    }

    /// Deterministic compiler first, local LLM as a fallback that rewrites into the supported grammar.
    public func compileRule(_ text: String) async -> RuleCompileResult {
        let compiler = NLRuleCompiler(libraryRoot: settings.libraryRoots.first ?? "~/Documents", knownProjects: store.projects().map(\.name))
        let first = compiler.compile(text)
        if first.rule != nil && first.warnings.filter({ $0.hasPrefix("Didn’t understand") }).isEmpty { return first }
        struct Rewrite: Decodable { let rule: String }
        let system = """
        Rewrite the user's automation request as ONE sentence in this exact grammar:
        "<If|When> <trigger and conditions> → <action>, <action>, ..."
        Triggers: a <type> in <Folder>; download finishes; drive '<name>' is connected; <App> app opens; disk < N GB; <Folder> has > N files; Every <day> <time>:
        Conditions: contains '<text>'; filename contains '<text>'; older than N days; larger than N MB; tagged <tag>; language is <lang>; after N PM.
        Actions: move to <Folder/Path>; copy to <path>; tag <t1> <t2>; add to project <name>; rename to <pattern with {date} {basename}>; notify <message>;
        create a reminder; add deadline to calendar; compress; run shortcut <name>; run script <cmd>; sync <Folder> to <path>; archive old files; auto-sort; generate weekly report.
        Return JSON {"rule": "<sentence>"}.
        """
        if let r = await llm.json(Rewrite.self, system: system, prompt: text) {
            var second = compiler.compile(r.rule)
            if second.rule != nil {
                second.rule?.naturalLanguage = text
                second.explanation.insert("Interpreted by the local model as: “\(r.rule)”", at: 0)
                return second
            }
        }
        return first
    }

    // MARK: - Autopilot (confidence-gated filing)

    struct Suggestion { var folder: String; var score: Double; var reason: String }

    func suggestions(for file: FileRecord) -> [Suggestion] {
        var out: [Suggestion] = []
        let projectName = file.projectId.flatMap { store.project(id: $0)?.name }
        for c in store.categories() {
            let typeHit = file.docType.map { c.docTypes.contains($0) } ?? false
            guard typeHit else { continue }
            let keyHit = c.keywords.contains { k in file.snippet.lowercased().contains(k.lowercased()) || file.name.lowercased().contains(k.lowercased()) }
            var score = 0.5 + 0.3 * file.confidence + (keyHit ? 0.04 : 0)
            let folder = Templates.expand(c.destination, file: file, projectName: projectName)
            // Creating brand-new folders needs more evidence than routing into existing ones
            let exists = FileManager.default.fileExists(atPath: folder) || FileManager.default.fileExists(atPath: (folder as NSString).deletingLastPathComponent)
            if !exists { score *= 0.85 }
            let noun = file.docType ?? c.name
            let article = "aeiou".contains(noun.lowercased().first ?? "x") ? "an" : "a"
            out.append(Suggestion(folder: Paths.canonical(folder), score: min(0.84, score), reason: "Looks like \(article) \(noun) → \(c.name)\(exists ? "" : " (new folder)")"))
        }
        let generic = Set(settings.libraryRootsExpanded + settings.watchedFoldersExpanded + [Paths.home])
        for s in taxonomy.suggest(for: file, keywords: Classifier.tokens(file.name + " " + file.snippet), excluding: generic) {
            let folder = Paths.canonical(s.folder)
            if let i = out.firstIndex(where: { $0.folder == folder }) {
                out[i].score = 1 - (1 - out[i].score) * (1 - s.score)   // agreeing signals reinforce
                out[i].reason += " · " + s.reason
            } else if let i = out.firstIndex(where: { Paths.isInside(folder, $0.folder) && folder != $0.folder }), s.score >= 0.5,
                      Self.nameOverlap(file: file, subfolder: folder, parent: out[i].folder) {
                // Category says "School & Documents", learned structure says ".../Physics": prefer the more specific folder
                let combined = 1 - (1 - out[i].score) * (1 - s.score)
                out[i] = Suggestion(folder: folder, score: combined, reason: s.reason + " · " + out[i].reason)
            } else {
                out.append(Suggestion(folder: folder, score: s.score, reason: s.reason))
            }
        }
        return out.filter { $0.folder != file.folder }.sorted { $0.score > $1.score }
    }

    /// True when the extra path components below `parent` actually describe the file ("Physics" for a physics syllabus),
    /// not merely share its file type ("AMG Wallpapers" for a screenshot).
    static func nameOverlap(file: FileRecord, subfolder: String, parent: String) -> Bool {
        let extra = subfolder.dropFirst(parent.count).split(separator: "/").flatMap { Classifier.tokens(String($0)) }
        let fileTerms = Set(Classifier.tokens(file.name) + file.topics.flatMap { Classifier.tokens($0) } + file.entities.filter { $0.kind == .course }.flatMap { Classifier.tokens($0.value) })
        return extra.contains { t in fileTerms.contains(t) || fileTerms.contains { $0.hasPrefix(t) || t.hasPrefix($0) } }
    }

    func suggestedTags(for file: FileRecord) -> [String] {
        var tags: [String] = []
        for e in file.entities where e.kind == .course { tags.append(e.value) }
        if let p = file.projectId.flatMap({ store.project(id: $0) }) { tags += p.tags }
        if let d = file.docType, !["photo", "archive", "code", "screenshot", "installer"].contains(d) { tags.append(d.replacingOccurrences(of: " ", with: "-")) }
        if file.kind == .code, let l = file.language { tags.append(l.lowercased()) }
        return Array(NSOrderedSet(array: tags).array as? [String] ?? []).filter { t in !file.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }.prefix(4).map { $0 }
    }

    func autopilot(_ file: FileRecord, content: String) async {
        let sugg = suggestions(for: file)
        let tags = suggestedTags(for: file)
        guard let best = sugg.first else {
            var f = file
            if !tags.isEmpty && file.confidence >= settings.autoThreshold {
                _ = await executor.run(actions: [RuleAction(kind: .tag, tags: tags)], file: f, dryRun: settings.dryRun)
            } else {
                f.status = .ignored
                store.upsertFile(f)
            }
            return
        }
        if best.score >= settings.autoThreshold {
            var actions = [RuleAction(kind: .move, target: best.folder)]
            if !tags.isEmpty { actions.append(RuleAction(kind: .tag, tags: tags)) }
            let batch = newID()
            let (_, outcomes) = await executor.run(actions: actions, file: file, batchId: batch, dryRun: settings.dryRun)
            store.log(ActivityEvent(kind: .fileMoved, message: "Autopilot (\(Int(best.score * 100))%): \(file.name) — \(best.reason)", fileId: file.id, batchId: batch))
            if outcomes.contains(where: \.success) { stateLock.lock(); notificationDigest.filed += 1; stateLock.unlock() }
        } else if best.score >= settings.reviewThreshold {
            guard store.pendingReview(fileId: file.id) == nil else { return }
            store.saveReview(ReviewItem(fileId: file.id, path: file.path, suggestedDestination: best.folder, suggestedTags: tags,
                                        suggestedProjectId: file.projectId, suggestedCategory: file.docType, confidence: best.score,
                                        reasons: [best.reason], alternatives: sugg.dropFirst().prefix(3).map(\.folder)))
            var f = file; f.status = .review; store.upsertFile(f)
            stateLock.lock(); notificationDigest.review += 1; stateLock.unlock()
        } else {
            var f = file; f.status = .ignored; store.upsertFile(f)
            store.log(ActivityEvent(kind: .fileIndexed, message: "Low confidence (\(Int(best.score * 100))%) for \(file.name) — left in place", fileId: file.id))
        }
    }

    /// Sorts every top-level file in a folder with rules first, then autopilot.
    public func sortFolder(_ path: String, batchId: String) async -> String {
        var filed = 0, review = 0, untouched = 0
        for p in listFiles(path, recursive: false) {
            guard let (rec, content) = index(p) else { continue }
            if await runRules(file: rec, content: content, trigger: .fileAdded, info: [:], batchId: batchId) > 0 { filed += 1; continue }
            await autopilot(rec, content: content)
            switch store.file(id: rec.id)?.status {
            case .filed?: filed += 1
            case .review?: review += 1
            default: untouched += 1
            }
        }
        let msg = "Sorted \(Paths.abbreviate(path)): \(filed) filed, \(review) to review, \(untouched) left in place"
        store.log(ActivityEvent(kind: .command, message: msg, batchId: batchId))
        return msg
    }

    public struct CleanupGroup { public var keep: FileRecord; public var trash: [FileRecord] }

    /// Exact-content duplicates: keep the copy already filed in your library (not an inbox), else the oldest.
    public func duplicateCleanupPlan() -> [CleanupGroup] {
        var groups: [CleanupGroup] = []
        for h in store.duplicateHashes() {
            let files = store.files(withHash: h).filter { FileManager.default.fileExists(atPath: $0.path) }
            guard files.count > 1 else { continue }
            let ranked = files.sorted { a, b in
                let ai = isAutomationFolder(a.path), bi = isAutomationFolder(b.path)
                if ai != bi { return !ai }
                return a.createdAt < b.createdAt
            }
            let trash = ranked.dropFirst().filter { !Paths.isProtected($0.path) }
            if !trash.isEmpty { groups.append(CleanupGroup(keep: ranked[0], trash: Array(trash))) }
        }
        return groups
    }

    /// Near-identical screenshots (perceptual hash distance ≤ 5): keep the newest of each cluster.
    public func similarScreenshotPlan() -> [CleanupGroup] {
        let shots = store.files(limit: 5000).filter { $0.kind == .screenshot && $0.perceptualHash != nil && FileManager.default.fileExists(atPath: $0.path) && !Paths.isProtected($0.path) }
        var used = Set<String>()
        var groups: [CleanupGroup] = []
        for s in shots.sorted(by: { $0.createdAt > $1.createdAt }) where !used.contains(s.id) {
            let cluster = shots.filter { !used.contains($0.id) && ($0.perceptualHash! ^ s.perceptualHash!).nonzeroBitCount <= 5 }
            guard cluster.count > 1 else { continue }
            cluster.forEach { used.insert($0.id) }
            let sorted = cluster.sorted { $0.createdAt > $1.createdAt }
            groups.append(CleanupGroup(keep: sorted[0], trash: Array(sorted.dropFirst())))
        }
        return groups
    }

    /// Where autopilot would route a file and why (for the simulator, API and tests).
    public func debugSuggestions(for file: FileRecord) -> [String] {
        suggestions(for: file).prefix(4).map { "\(Int($0.score * 100))% \(Paths.abbreviate($0.folder)) — \($0.reason)" }
    }

    // MARK: - Review queue

    public func approve(_ item: ReviewItem, destination: String? = nil, tags: [String]? = nil, projectId: String? = nil) async {
        guard let file = store.file(id: item.fileId) ?? store.file(path: item.path) else { return }
        var actions: [RuleAction] = []
        if let ruleId = item.ruleId, let rule = store.rule(id: ruleId), destination == nil && tags == nil {
            actions = rule.actions
            store.recordRuleHit(rule.id)
        } else {
            if let d = destination ?? item.suggestedDestination { actions.append(RuleAction(kind: .move, target: d)) }
            let t = tags ?? item.suggestedTags
            if !t.isEmpty { actions.append(RuleAction(kind: .tag, tags: t)) }
            if let pid = projectId ?? item.suggestedProjectId, let p = store.project(id: pid) { actions.append(RuleAction(kind: .addToProject, target: p.name, project: p.name)) }
        }
        let batch = newID()
        let (after, _) = await executor.run(actions: actions, file: file, ruleId: item.ruleId, batchId: batch, dryRun: settings.dryRun)
        var resolved = item
        resolved.status = .approved
        resolved.resolvedAt = Date()
        if let d = destination { resolved.suggestedDestination = d }
        store.saveReview(resolved)
        // Learning: approvals (especially edits) teach the taxonomy
        if let d = destination ?? item.suggestedDestination {
            let folder = Templates.expand(d, file: file, projectName: nil)
            taxonomy.reinforce(folder: folder, docType: file.docType, keywords: Classifier.tokens(file.name), weight: destination == nil ? 1 : 2)
        }
        if var f = after ?? store.file(id: file.id), f.status == .review { f.status = .filed; store.upsertFile(f) }
        store.log(ActivityEvent(kind: .review, message: "Approved \(file.name)", fileId: file.id, batchId: batch))
    }

    public func reject(_ item: ReviewItem) {
        var r = item
        r.status = .rejected
        r.resolvedAt = Date()
        store.saveReview(r)
        if let file = store.file(id: item.fileId) {
            if let d = item.suggestedDestination { taxonomy.penalize(folder: Templates.expand(d, file: file, projectName: nil), docType: file.docType) }
            var f = file; f.status = .indexed; store.upsertFile(f)
        }
        store.log(ActivityEvent(kind: .review, message: "Rejected suggestion for \((item.path as NSString).lastPathComponent)", fileId: item.fileId))
    }

    public func undoLast() -> Int {
        guard let batch = store.lastUndoableBatch() else { return 0 }
        return executor.undo(batchId: batch)
    }

    // MARK: - Focus mode

    public func startFocus(projectId: String, minutes: Int, source: String = "manual") {
        let session = FocusSession(projectId: projectId, startedAt: Date(), endsAt: Date().addingTimeInterval(Double(minutes) * 60), source: source, suppressed: 0)
        focus = session
        store.setKV("focus", JSON.string(session))
        let name = store.project(id: projectId)?.name ?? "project"
        store.log(ActivityEvent(kind: .focus, message: "Focus started: \(name) for \(minutes) min"))
        bus.post(.focusChanged(active: true, projectId: projectId))
        queue.enqueue(Job(name: "Pre-warm \(name)", kind: .ai, priority: .focus, spec: JobSpec(operation: .prewarmProject, params: ["projectId": projectId])))
    }

    public func endFocus() {
        guard let f = focus else { return }
        focus = nil
        store.setKV("focus", "null")
        let name = store.project(id: f.projectId)?.name ?? "project"
        store.log(ActivityEvent(kind: .focus, message: "Focus ended: \(name)"))
        bus.post(.focusChanged(active: false, projectId: f.projectId))
        if f.suppressed > 0 { notify(title: "Focus session complete", body: "\(f.suppressed) non-urgent notification\(f.suppressed == 1 ? " was" : "s were") held back. Check Insights & Review.", important: true) }
    }

    func checkFocus() {
        if let f = focus, f.endsAt <= Date() { endFocus(); return }
        guard focus == nil else { return }
        // Infer focus from Calendar: an event happening now whose title mentions a project
        let now = Date()
        for e in connectors.eventKit.events(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60)) where e.start <= now && e.end > now {
            if let p = store.projects(includeArchived: false).first(where: { e.title.lowercased().contains($0.name.lowercased()) || $0.keywords.contains { k in !k.isEmpty && e.title.lowercased().contains(k.lowercased()) } }) {
                startFocus(projectId: p.id, minutes: max(15, Int(e.end.timeIntervalSince(now) / 60)), source: "calendar")
                break
            }
        }
    }

    /// During focus, new files related to the active project go straight into its folder.
    func routeForFocus(_ file: FileRecord) async -> Bool {
        guard let f = focus, let p = store.project(id: f.projectId), let folder = p.folders.first.map(Paths.expand) else { return false }
        let vector = embedder.vector(file.name + " " + file.snippet)
        let score = projectMatcher.match(file: file, text: store.fileContent(id: file.id) ?? file.snippet, projects: [p], fileVector: vector, projectVectors: projectVectors).first?.score ?? 0
        guard score >= settings.reviewThreshold else { return false }
        let batch = newID()
        _ = await executor.run(actions: [RuleAction(kind: .move, target: folder), RuleAction(kind: .addToProject, target: p.name, project: p.name)],
                               file: file, batchId: batch, dryRun: settings.dryRun)
        store.log(ActivityEvent(kind: .focus, message: "Focus routing: \(file.name) → \(p.name)", fileId: file.id, batchId: batch))
        return true
    }

    // MARK: - Commands

    public func plan(_ input: String) async -> CommandPlan {
        let compiler = NLRuleCompiler(libraryRoot: settings.libraryRoots.first ?? "~/Documents", knownProjects: store.projects().map(\.name))
        let parser = CommandParser(compiler: compiler)
        var steps = parser.parse(input)
        var usedLLM = false
        if steps.contains(where: { if case .unknown = $0.intent { return true }; return false }) {
            struct Rewrite: Decodable { let commands: [String] }
            let system = "Rewrite the user's request for a Mac file assistant into one or more commands using ONLY this grammar:\n\(CommandParser.grammarHelp)\nReturn JSON {\"commands\": [\"...\"]}."
            if let r = await llm.json(Rewrite.self, system: system, prompt: input), !r.commands.isEmpty {
                let rewritten = r.commands.flatMap { parser.parse($0) }
                if !rewritten.contains(where: { if case .unknown = $0.intent { return true }; return false }) { steps = rewritten; usedLLM = true }
            }
        }
        var planned: [PlannedStep] = []
        var previous = lastCommandResults.compactMap { store.file(id: $0) }
        for s in steps {
            var ps = PlannedStep(step: s, files: [], preview: [])
            switch s.intent {
            case .find(let q):
                ps.files = resolve(q, previous: previous)
                ps.preview = ps.files.prefix(8).map { "\($0.name) — \(Paths.abbreviate($0.folder))" }
                ps.note = "\(ps.files.count) file\(ps.files.count == 1 ? "" : "s") found"
                previous = ps.files
            case .fileActions(let q, let actions):
                ps.files = resolve(q, previous: previous)
                ps.preview = ps.files.prefix(8).map { f in "\(f.name): " + actions.map { Templates.describe($0, file: f, projectName: nil) }.joined(separator: ", ") }
                ps.note = ps.files.isEmpty ? "No matching files" : "\(ps.files.count) file\(ps.files.count == 1 ? "" : "s") will be changed"
                previous = ps.files
            case .summarizeQuery(let q):
                ps.files = resolve(q, previous: previous)
                ps.note = "Summarize \(ps.files.count) files"
            case .createRule(let text):
                let r = await compileRule(text)
                ps.ruleResult = r
                ps.preview = r.explanation + r.warnings.map { "⚠︎ \($0)" }
                ps.note = r.rule.map { "Rule: \($0.name)" } ?? "Couldn’t build a rule from that"
            case .schedule(let command, let when):
                switch when {
                case .once(let d): ps.note = "Run “\(command)” \(DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short))"
                case .cron(let c): ps.note = "Run “\(command)” — \(CronExpression.describe(c))"
                }
            case .organize(let folder):
                let count = listFiles(folder, recursive: false).count
                ps.note = "Sort \(count) files in \(Paths.abbreviate(folder)) using rules + learned folders"
            case .archive(let folder, let days, let kind):
                ps.note = "Move \(kind ?? "file")s older than \(days) days from \(Paths.abbreviate(folder)) into the archive"
            case .focus(let project, let minutes):
                ps.note = store.project(named: project).map { "Focus on \($0.name) for \(minutes) min" } ?? "No project named “\(project)” — it will be created"
            case .smartFile(let q):
                ps.files = resolve(q, previous: previous)
                ps.preview = ps.files.prefix(8).map { f in
                    let dest = suggestions(for: f).first.map { "→ \(Paths.abbreviate($0.folder)) (\(Int($0.score * 100))%)" } ?? "→ rules / review"
                    return "\(f.name) \(dest)"
                }
                ps.note = ps.files.isEmpty ? "Nothing selected — select files in Finder first" : "File \(ps.files.count) selected item\(ps.files.count == 1 ? "" : "s")"
                previous = ps.files
            case .cleanDuplicates:
                let groups = duplicateCleanupPlan()
                ps.files = groups.flatMap(\.trash)
                ps.preview = groups.prefix(8).map { g in "keep \(Paths.abbreviate(g.keep.path)) · trash \(g.trash.count) cop\(g.trash.count == 1 ? "y" : "ies")" }
                let bytes = ps.files.reduce(Int64(0)) { $0 + $1.size }
                ps.note = groups.isEmpty ? "No duplicates found" : "Move \(ps.files.count) duplicate\(ps.files.count == 1 ? "" : "s") to Trash · frees \(formatBytes(bytes))"
            case .cleanSimilarScreenshots:
                let groups = similarScreenshotPlan()
                ps.files = groups.flatMap(\.trash)
                ps.preview = groups.prefix(8).map { g in "keep \(g.keep.name) · trash \(g.trash.count) similar" }
                ps.note = groups.isEmpty ? "No near-identical screenshots" : "Move \(ps.files.count) near-identical screenshot\(ps.files.count == 1 ? "" : "s") to Trash"
            case .ask(let question):
                ps.note = "Searching your files for: \(question)"
            case .briefing:
                ps.note = "Today’s briefing"
            case .unknown(let text):
                ps.note = "Not sure how to do “\(text)”. Try: organize Downloads · find invoices from last month · create rule: …"
            default:
                ps.note = s.intent.label
            }
            planned.append(ps)
        }
        let understood = !planned.isEmpty && !planned.contains { if case .unknown = $0.step.intent { return true }; return false }
        return CommandPlan(input: input, steps: planned, understood: understood, requiresConfirmation: planned.contains { $0.step.intent.isMutating }, usedLLM: usedLLM)
    }

    public func execute(_ plan: CommandPlan) async -> CommandResult {
        store.addCommandHistory(plan.input)
        store.log(ActivityEvent(kind: .command, message: "⌘ \(plan.input)"))
        let batch = newID()
        var result = CommandResult(message: "", batchId: batch)
        var previous: [FileRecord] = lastCommandResults.compactMap { store.file(id: $0) }
        var messages: [String] = []
        for ps in plan.steps {
            switch ps.step.intent {
            case .find(let q):
                previous = ps.files.isEmpty ? resolve(q, previous: previous) : ps.files
                result.files = previous
                messages.append("Found \(previous.count) file\(previous.count == 1 ? "" : "s")")
            case .fileActions(let q, let actions):
                let targets = q.useLastResults ? previous.compactMap { store.file(id: $0.id) } : (ps.files.isEmpty ? resolve(q, previous: previous) : ps.files)
                var ok = 0
                var updated: [FileRecord] = []
                for f in targets {
                    let (after, outcomes) = await executor.run(actions: actions, file: store.file(id: f.id) ?? f, batchId: batch, dryRun: settings.dryRun)
                    if outcomes.allSatisfy(\.success) { ok += 1 }
                    result.details += outcomes.filter { !$0.success }.map { "\(f.name): \($0.message)" }
                    updated.append(after ?? f)
                }
                previous = updated
                result.files = updated
                messages.append("\(actions.map { $0.kind.label }.joined(separator: " + ")): \(ok)/\(targets.count) files")
            case .summarizeFolder(let folder):
                messages.append(await summarizeFolder(folder))
            case .summarizeQuery(let q):
                let files = ps.files.isEmpty ? resolve(q, previous: previous) : ps.files
                let text = files.prefix(25).map { "\($0.name): \($0.summary ?? $0.snippet)" }.joined(separator: "\n")
                messages.append(await llm.summarize(text, context: "set of files"))
                result.files = files
            case .summarizeProject(let name):
                guard let p = store.project(named: name) else { messages.append("No project “\(name)”"); continue }
                let files = store.files(limit: 40, projectId: p.id, orderBy: "modified DESC")
                let text = "Project \(p.name). Notes: \(p.notes)\n" + files.map { "\($0.name) (\($0.docType ?? $0.kind.rawValue)): \($0.summary ?? $0.snippet)" }.joined(separator: "\n")
                messages.append(await llm.summarize(text, context: "project"))
                result.files = files
            case .createRule:
                guard var rule = ps.ruleResult?.rule else { messages.append("Rule not created"); continue }
                if let pname = rule.actions.first(where: { $0.kind == .addToProject })?.project, let p = resolveProject(named: pname, create: true) { rule.projectId = p.id }
                store.saveRule(rule)
                result.createdRule = rule
                messages.append("Created rule “\(rule.name)”. Want to test it?")
            case .schedule(let command, let when):
                var s = Schedule(name: command, mode: .once, job: JobSpec(operation: .runCommand, command: command), naturalLanguage: plan.input)
                switch when {
                case .once(let d): s.runAt = d; s.nextRunAt = d
                case .cron(let c): s.mode = .recurring; s.cron = c; s.nextRunAt = CronExpression(c)?.next(after: Date())
                }
                store.saveSchedule(s)
                messages.append("Scheduled “\(command)” · \(s.cron.map(CronExpression.describe) ?? s.runAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")")
            case .organize(let folder):
                messages.append(await sortFolder(folder, batchId: batch))
            case .findDuplicates:
                messages.append(findDuplicates(largeOnly: false))
                result.navigate = "insights"
            case .report(let type):
                messages.append(await generateReport(type: type))
            case .createProject(let name, let keywords, let folder, let deadline):
                var p = store.project(named: name).flatMap { $0.name.lowercased() == name.lowercased() ? $0 : nil } ?? Project(name: name, color: Self.palette.randomElement()!)
                p.keywords = Array(Set(p.keywords + keywords))
                if let folder { p.folders = Array(Set(p.folders + [folder])); try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
                if let deadline { p.deadline = deadline }
                store.saveProject(p)
                messages.append("Project “\(p.name)” is ready")
                result.navigate = "projects"
            case .focus(let project, let minutes):
                guard let p = resolveProject(named: project, create: true) else { continue }
                startFocus(projectId: p.id, minutes: minutes)
                messages.append("Focusing on \(p.name) for \(minutes) min. Non-critical notifications are silenced.")
            case .endFocus:
                endFocus(); messages.append("Focus ended")
            case .undo:
                let n = undoLast(); messages.append(n > 0 ? "Undid \(n) operation\(n == 1 ? "" : "s")" : "Nothing to undo")
            case .archive(let folder, let days, let kind):
                var params = ["folder": folder, "days": String(days)]
                if let kind { params["kind"] = kind }
                let dest = kind == "screenshot" ? "~/Documents/Archive/Screenshots/{year}" : "~/Documents/Archive/{year}"
                let (_, out) = await executor.run(actions: [RuleAction(kind: .archiveOld, target: Paths.expand(dest), params: params)], file: nil, batchId: batch, dryRun: settings.dryRun)
                messages.append(out.map(\.message).joined(separator: " "))
            case .pause: setPaused(true); messages.append("Automations paused")
            case .resume: setPaused(false); messages.append("Automations resumed")
            case .navigate(let v): result.navigate = v; messages.append("Opening \(v)")
            case .learnTaxonomy:
                enqueueOnce(.learnTaxonomy, name: "Learn folder structure", kind: .ai, priority: .high)
                messages.append("Learning your folder structure in the background")
            case .runRule(let name):
                guard let r = store.rules().first(where: { $0.name.lowercased().contains(name.lowercased()) }) else { messages.append("No rule matching “\(name)”"); continue }
                queue.enqueue(Job(name: "Run rule: \(r.name)", kind: .file, priority: .high, spec: JobSpec(operation: .runRule, ruleId: r.id)))
                messages.append("Running “\(r.name)”")
            case .classify(let folder):
                queue.enqueue(Job(name: "Classify \(Paths.abbreviate(folder))", kind: .ai, priority: .normal, spec: JobSpec(operation: .classifyFolder, path: folder)))
                messages.append("Classifying \(Paths.abbreviate(folder)) in the background")
            case .smartFile(let q):
                let files = ps.files.isEmpty ? resolve(q, previous: previous) : ps.files
                var filed = 0, review = 0
                for f in files {
                    guard let (rec, content) = index(f.path) else { continue }
                    if await runRules(file: rec, content: content, trigger: .manual, info: [:], batchId: batch) > 0 { filed += 1; continue }
                    if let best = suggestions(for: rec).first, best.score >= settings.reviewThreshold {
                        let (_, out) = await executor.run(actions: [RuleAction(kind: .move, target: best.folder)] + (suggestedTags(for: rec).isEmpty ? [] : [RuleAction(kind: .tag, tags: suggestedTags(for: rec))]),
                                                          file: rec, batchId: batch, dryRun: settings.dryRun)
                        if out.contains(where: \.success) { filed += 1 }
                        taxonomy.reinforce(folder: best.folder, docType: rec.docType, keywords: Classifier.tokens(rec.name))
                    } else {
                        await autopilot(rec, content: content)
                        if store.file(id: rec.id)?.status == .review { review += 1 }
                    }
                }
                previous = files.compactMap { store.file(id: $0.id) }
                result.files = previous
                messages.append("Filed \(filed) of \(files.count)\(review > 0 ? ", \(review) need a quick review" : "")")
            case .cleanDuplicates, .cleanSimilarScreenshots:
                let isDup: Bool = { if case .cleanDuplicates = ps.step.intent { return true }; return false }()
                let groups = isDup ? duplicateCleanupPlan() : similarScreenshotPlan()
                var trashed = 0
                var freed: Int64 = 0
                for g in groups {
                    for f in g.trash where FileManager.default.fileExists(atPath: f.path) {
                        let (_, out) = await executor.run(actions: [RuleAction(kind: .trash)], file: f, batchId: batch, dryRun: settings.dryRun)
                        if out.first?.success == true { trashed += 1; freed += f.size }
                    }
                }
                store.removeInsight(key: isDup ? "duplicates" : "similarShots")
                messages.append(trashed == 0 ? "Nothing to clean up" : "Moved \(trashed) \(isDup ? "duplicate" : "similar screenshot")\(trashed == 1 ? "" : "s") to Trash · freed \(formatBytes(freed)). Undo anytime.")
            case .ask(let question):
                let (answer, sources) = await answer(question: question)
                messages.append(answer)
                result.files = sources
                previous = sources
            case .briefing:
                messages.append(await briefing())
            case .unknown(let text):
                if let p = await llm.provider() {
                    let answer = (try? await p.complete(system: "You are Nexus, a concise macOS file assistant. Answer briefly. If the user wants an action, suggest a command from: \(CommandParser.grammarHelp)", prompt: text)) ?? ""
                    messages.append(answer.isEmpty ? "I couldn't do that." : answer)
                } else {
                    messages.append("I didn’t understand “\(text)”. Try “organize Downloads” or “find PDFs about hydroponics”.")
                }
            }
        }
        stateLock.lock(); lastCommandResults = previous.map(\.id); stateLock.unlock()
        result.message = messages.joined(separator: "\n")
        return result
    }

    /// Resolves a file query against disk (for folder scopes) and the index (FTS + semantic search).
    public func resolve(_ q: FileQuery, previous: [FileRecord]) -> [FileRecord] {
        if q.useLastResults { return previous.compactMap { store.file(id: $0.id) ?? $0 } }
        if q.useContext {
            return (contextSelection?() ?? []).flatMap { p -> [String] in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                return isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: p) ? listFiles(p, recursive: false) : [p]
            }.compactMap { store.file(path: Paths.canonical($0)) ?? index($0)?.0 }
        }
        let needsContent = q.conditions.contains { [.content, .anyText, .docType, .topic, .entity, .language].contains($0.field) }
        var candidates: [FileRecord] = []
        var ftsMatched = Set<String>()
        if !q.folders.isEmpty {
            for folder in q.folders {
                let recursive = !settings.watchedFoldersExpanded.contains(folder)
                for path in listFiles(folder, recursive: recursive).prefix(3000) {
                    if let existing = store.file(path: path), (!needsContent || existing.indexedAt > Date.distantPast) {
                        candidates.append(existing)
                    } else if let (rec, _) = index(path) {
                        candidates.append(rec)
                    }
                }
            }
        } else if !q.searchTerms.isEmpty {
            var seen = Set<String>()
            for term in q.searchTerms {
                for f in store.searchFiles(term, limit: 400) where seen.insert(f.id).inserted { candidates.append(f); ftsMatched.insert(f.id) }
                // semantic neighbours broaden recall ("hydroponics" ≈ "nutrient film technique")
                if let v = embedder.vector(term) {
                    let scored = store.allEmbeddings().map { ($0.0, Embedder.cosine(v, $0.1)) }.filter { $0.1 > 0.42 }.sorted { $0.1 > $1.1 }.prefix(60)
                    for (id, _) in scored where seen.insert(id).inserted { if let f = store.file(id: id) { candidates.append(f); ftsMatched.insert(id) } }
                }
            }
        } else {
            candidates = store.files(limit: 5000)
        }
        let conds = q.conditions.filter { !(ftsMatched.isEmpty == false && [.anyText, .content].contains($0.field) && $0.op == .contains) }
        let filtered = candidates.filter { f in
            guard FileManager.default.fileExists(atPath: f.path) else { return false }
            let content = conds.contains { [.content, .anyText].contains($0.field) } ? (store.fileContent(id: f.id) ?? f.snippet) : ""
            let ctx = RuleContext(file: f, content: content, projectName: f.projectId.flatMap { store.project(id: $0)?.name }, trigger: .manual)
            return ruleEngine.conditionsPass(ConditionGroup(match: .all, conditions: conds), ctx).0
        }
        return Array(filtered.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(q.limit))
    }

    public func summarizeFolder(_ folder: String) async -> String {
        let files = listFiles(folder, recursive: true).prefix(60)
        guard !files.isEmpty else { return "\(Paths.abbreviate(folder)) is empty or not found." }
        var kinds: [String: Int] = [:]
        var lines: [String] = []
        for p in files {
            let rec = store.file(path: p) ?? index(p)?.0
            guard let r = rec else { continue }
            kinds[r.docType ?? r.kind.rawValue, default: 0] += 1
            if lines.count < 30 { lines.append("\(r.name) [\(r.docType ?? r.kind.rawValue)]: \(r.summary ?? String(r.snippet.prefix(200)))") }
        }
        let overview = kinds.sorted { $0.value > $1.value }.prefix(5).map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let summary = await llm.summarize("Folder \(Paths.abbreviate(folder)) contains: \(overview)\n" + lines.joined(separator: "\n"), context: "folder")
        store.setKV("summary:\(folder)", summary)
        return "\(Paths.abbreviate(folder)) — \(files.count)\(files.count == 60 ? "+" : "") files (\(overview)).\n\(summary)"
    }

    /// Knowledge-graph neighbours: files sharing people, topics, tags or project.
    public func related(to file: FileRecord, limit: Int = 12) -> [(FileRecord, Double, [String])] {
        var scores: [String: (Double, Set<String>)] = [:]
        for e in store.edges(from: .file, id: file.id) {
            let weight: Double = e.dstType == .project ? 3 : e.dstType == .person || e.dstType == .organization ? 2 : e.dstType == .date ? 0.3 : 1
            for other in store.edges(to: e.dstType, id: e.dstId) where other.srcId != file.id && other.srcType == .file {
                var s = scores[other.srcId] ?? (0, [])
                s.0 += weight
                s.1.insert("\(e.dstType.rawValue): \(e.dstId)")
                scores[other.srcId] = s
            }
        }
        return scores.sorted { $0.value.0 > $1.value.0 }.prefix(limit).compactMap { id, v in
            store.file(id: id).map { ($0, v.0, Array(v.1).sorted()) }
        }
    }

    // MARK: - Assistant skills (things Siri can't do with your files)

    /// Answers a question from the *contents* of your files: hybrid retrieval (FTS + embeddings) → on-device LLM with citations.
    public func answer(question: String) async -> (String, [FileRecord]) {
        let terms = Classifier.tokens(question).filter { !["file", "files", "document", "documents", "my", "the"].contains($0) }
        var scored: [String: Double] = [:]
        for (i, t) in terms.prefix(6).enumerated() {
            for (rank, f) in store.searchFiles(t, limit: 40).enumerated() { scored[f.id, default: 0] += 1.0 / Double(rank + 2) + (i == 0 ? 0.1 : 0) }
        }
        if !terms.isEmpty {
            for (rank, f) in store.searchFiles(terms.joined(separator: " "), limit: 20).enumerated() { scored[f.id, default: 0] += 2.0 / Double(rank + 1) }
        }
        if let v = embedder.vector(question) {
            for (id, vec) in store.allEmbeddings() {
                let sim = Embedder.cosine(v, vec)
                if sim > 0.45 { scored[id, default: 0] += sim }
            }
        }
        let top = scored.sorted { $0.value > $1.value }.prefix(6).compactMap { store.file(id: $0.key) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !top.isEmpty else { return ("I couldn’t find anything about that in your indexed files.", []) }
        var sources: [String] = []
        for (i, f) in top.enumerated() {
            let content = store.fileContent(id: f.id) ?? f.snippet
            sources.append("[\(i + 1)] \(f.name)\n\(Self.passage(content, terms: terms))")
        }
        if let p = await llm.provider() {
            let system = "You answer questions using ONLY the provided excerpts from the user's own files. Be concise (1-3 sentences). Cite sources like [1]. If the excerpts don't contain the answer, say so."
            if let answer = try? await p.complete(system: system, prompt: "Question: \(question)\n\nExcerpts:\n" + sources.joined(separator: "\n\n")), !answer.trimmed.isEmpty {
                return (answer.trimmed, top)
            }
        }
        // No model: return the most relevant passage with its source
        let best = Self.passage(store.fileContent(id: top[0].id) ?? top[0].snippet, terms: terms, length: 280)
        return ("From \(top[0].name): “\(best)”", top)
    }

    static func passage(_ text: String, terms: [String], length: Int = 700) -> String {
        let lower = text.lowercased()
        let hit = terms.compactMap { lower.range(of: $0)?.lowerBound }.min() ?? lower.startIndex
        let startOffset = max(0, lower.distance(from: lower.startIndex, to: hit) - length / 3)
        let start = text.index(text.startIndex, offsetBy: min(startOffset, text.count))
        let end = text.index(start, offsetBy: min(length, text.distance(from: start, to: text.endIndex)))
        return text[start..<end].replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    }

    /// A concise "what matters today" digest: calendar, deadlines, new files, review queue, insights.
    public func briefing() async -> String {
        let cal = Calendar.current
        let now = Date()
        var lines: [String] = []
        let events = connectors.eventKit.events(from: now, to: cal.date(byAdding: .hour, value: 14, to: now)!)
        if !events.isEmpty {
            lines.append("Today: " + events.prefix(4).map { "\($0.title) at \(DateFormatter.localizedString(from: $0.start, dateStyle: .none, timeStyle: .short))" }.joined(separator: "; ") + ".")
        }
        let due = store.projects(includeArchived: false).filter { ($0.deadline ?? .distantPast) > now && $0.deadline!.timeIntervalSince(now) < 7 * 86400 }
        if !due.isEmpty { lines.append("Due this week: " + due.map { "\($0.name) \(relativeTime($0.deadline!))" }.joined(separator: ", ") + ".") }
        let newFiles = store.files(limit: 2000).filter { now.timeIntervalSince($0.indexedAt) < 86400 }
        let filed = store.eventCount(kind: .fileMoved, since: now.addingTimeInterval(-86400))
        lines.append("\(newFiles.count) new file\(newFiles.count == 1 ? "" : "s") in the last day; I filed \(filed).")
        let review = store.reviewCount()
        if review > 0 { lines.append("\(review) suggestion\(review == 1 ? " needs" : "s need") your OK.") }
        if let top = store.insights().first { lines.append("Worth a look: \(top.title).") }
        if let f = focus, let p = store.project(id: f.projectId) { lines.append("You’re in focus on \(p.name) until \(DateFormatter.localizedString(from: f.endsAt, dateStyle: .none, timeStyle: .short)).") }
        let raw = lines.joined(separator: " ")
        if let p = await llm.provider(), let polished = try? await p.complete(system: "Rewrite this status into a warm, crisp spoken briefing of at most 4 sentences. Keep every fact. No preamble.", prompt: raw), !polished.trimmed.isEmpty {
            return polished.trimmed
        }
        return raw
    }

    /// 10 minutes before a calendar event: gather files related to its title and surface them.
    func prepareForMeeting(title: String) {
        let parser = CommandParser(compiler: NLRuleCompiler())
        let words = Classifier.tokens(title).filter { $0.count > 3 }
        guard !words.isEmpty else { return }
        var files: [FileRecord] = []
        for w in words.prefix(4) { files += resolve(parser.query(w), previous: []).prefix(6) }
        if let p = store.projects(includeArchived: false).first(where: { title.lowercased().contains($0.name.lowercased()) }) {
            files += store.files(limit: 8, projectId: p.id, orderBy: "modified DESC")
        }
        var seen = Set<String>()
        files = files.filter { seen.insert($0.id).inserted }
        guard !files.isEmpty else { return }
        store.upsertInsight(Insight(key: "meeting:\(title)", kind: .deadlineSoon, title: "“\(title)” starts soon — \(files.count) related file\(files.count == 1 ? "" : "s") ready",
                                    detail: files.prefix(6).map { "• \($0.name)" }.joined(separator: "\n"), severity: .suggestion, filePaths: files.map(\.path)))
        notify(title: "Meeting prep: \(title)", body: "\(files.count) related files gathered — open Insights.", important: true)
    }

    // MARK: - Jobs

    func enqueueOnce(_ op: JobOperation, name: String, kind: JobKind, priority: JobPriority, spec: JobSpec? = nil) {
        if store.jobs(status: [.queued, .running, .scheduled], limit: 200).contains(where: { $0.spec.operation == op && $0.name == name }) { return }
        queue.enqueue(Job(name: name, kind: kind, priority: priority, spec: spec ?? JobSpec(operation: op)))
    }

    func runJob(_ job: Job, _ ctx: JobContext) async throws -> String {
        let spec = job.spec
        switch spec.operation {
        case .ingestFile:
            guard let p = spec.path.map(Paths.expand) else { throw LLMError("no path") }
            await ingest(p, trigger: .manual)
            return "Processed \((p as NSString).lastPathComponent)"
        case .classifyFolder:
            guard let folder = spec.path.map(Paths.expand) else { throw LLMError("no folder") }
            var n = 0
            for p in listFiles(folder, recursive: true) {
                if ctx.isCancelled { break }
                if let rec = store.file(path: p), let mod = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                   abs(mod.timeIntervalSince(rec.modifiedAt)) < 1, rec.status != .missing { continue }
                index(p)
                n += 1
                if n % 50 == 0 { ctx.log("Indexed \(n) files…") }
                if settings.batteryAware && monitor.snapshot.shouldThrottle { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
            return "Indexed \(n) new or changed files in \(Paths.abbreviate(folder))"
        case .runRule:
            guard let id = spec.ruleId, let rule = store.rule(id: id) else { throw LLMError("rule not found") }
            return await runRuleNow(rule, ctx: ctx)
        case .runActions:
            let rule = spec.ruleId.flatMap { store.rule(id: $0) }
            let actions = spec.actions.isEmpty ? (rule?.actions ?? []) : spec.actions
            let batch = newID()
            var messages: [String] = []
            let files = spec.paths.compactMap { store.file(path: Paths.expand($0)) ?? index(Paths.expand($0))?.0 }
            if files.isEmpty {
                let (_, out) = await executor.run(actions: actions, file: nil, info: spec.params, ruleId: rule?.id, jobId: job.id, batchId: batch, dryRun: settings.dryRun)
                messages = out.map(\.message)
                if out.contains(where: { !$0.success }) && out.allSatisfy({ !$0.success }) { throw LLMError(messages.joined(separator: " · ")) }
            } else {
                for f in files {
                    let (_, out) = await executor.run(actions: actions, file: f, info: spec.params, ruleId: rule?.id, jobId: job.id, batchId: batch, dryRun: settings.dryRun)
                    ctx.log("\(f.name): \(out.map(\.message).joined(separator: " · "))")
                }
                messages = ["Processed \(files.count) files"]
            }
            if let rule {
                store.recordRuleHit(rule.id)
                store.log(ActivityEvent(kind: .ruleFired, message: "“\(rule.name)”: \(messages.joined(separator: " · "))", ruleId: rule.id, jobId: job.id, batchId: batch))
            }
            messages.forEach { ctx.log($0) }
            return messages.joined(separator: " · ")
        case .runCommand:
            guard let c = spec.command else { throw LLMError("no command") }
            let p = await plan(c)
            guard p.understood else { throw LLMError("Couldn’t understand “\(c)”") }
            let r = await execute(p)
            ctx.log(r.message)
            return r.message
        case .summarizeFolder:
            return await summarizeFolder(Paths.expand(spec.path ?? "~/Downloads"))
        case .generateReport:
            return await generateReport(type: spec.params["type"] ?? "weekly")
        case .findDuplicates:
            return findDuplicates(largeOnly: spec.params["large"] == "1")
        case .archiveOld:
            let (_, out) = await executor.run(actions: [RuleAction(kind: .archiveOld, target: spec.params["target"] ?? "~/Documents/Archive/{year}", params: spec.params)], file: nil, jobId: job.id, dryRun: settings.dryRun)
            return out.map(\.message).joined()
        case .sortFolder:
            return await sortFolder(Paths.expand(spec.path ?? "~/Downloads"), batchId: newID())
        case .scanInsights:
            insights.scan(settings: settings, system: monitor.snapshot)
            flushProjectLinks()
            let n = store.insights().count
            if let critical = store.insights().first(where: { $0.severity == .critical }) { notify(title: critical.title, body: critical.detail, important: true) }
            return "\(n) active insight\(n == 1 ? "" : "s")"
        case .syncFolder:
            let (_, out) = await executor.run(actions: [RuleAction(kind: .syncFolder, target: spec.params["target"] ?? "", params: ["source": spec.path ?? ""])], file: nil, jobId: job.id)
            if let fail = out.first(where: { !$0.success }) { throw LLMError(fail.message) }
            return out.map(\.message).joined()
        case .runShell:
            let (code, out) = Shell.runScript(spec.command ?? "", env: [:], sandboxed: settings.scriptSandbox, writablePaths: spec.params["write"].map { [Paths.expand($0)] } ?? [])
            ctx.log(out)
            guard code == 0 else { throw LLMError("exit \(code): \(out.prefix(200))") }
            return out.isEmpty ? "Done" : String(out.prefix(200))
        case .runShortcut:
            let (code, out) = Shell.run("/usr/bin/shortcuts", ["run", spec.command ?? ""], timeout: 300)
            guard code == 0 else { throw LLMError(out) }
            return "Shortcut finished"
        case .learnTaxonomy:
            taxonomy.learn(roots: settings.libraryRootsExpanded, isCancelled: { ctx.isCancelled })
            return "Learned \(taxonomy.profiles.count) folders"
        case .prewarmProject:
            guard let pid = spec.params["projectId"], let p = store.project(id: pid) else { throw LLMError("project not found") }
            var n = 0
            for folder in p.folders.map(Paths.expand) {
                for path in listFiles(folder, recursive: true).prefix(2000) where store.file(path: path) == nil { index(path); n += 1 }
            }
            let recent = store.files(limit: 15, projectId: pid, orderBy: "modified DESC")
            for var f in recent.prefix(5) where f.summary == nil && !f.snippet.isEmpty {
                f.summary = await summarize(file: f)
                store.upsertFile(f)
            }
            return "Indexed \(n) files, summarized \(min(5, recent.count)) recent files for \(p.name)"
        }
    }

    func sweepAgeRules() {
        guard !paused else { return }
        let rules = store.rules().filter { $0.enabled && $0.trigger.kind.isFileTrigger && $0.conditions.conditions.contains { $0.field == .ageDays && $0.op == .greaterThan } }
        for r in rules { queue.enqueue(Job(name: "Sweep: \(r.name)", kind: .file, priority: .low, spec: JobSpec(operation: .runRule, ruleId: r.id), maxAttempts: 1)) }
    }

    func takeSnapshots() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            for folder in Set(self.settings.watchedFoldersExpanded + self.settings.libraryRootsExpanded) {
                let s = SystemMonitor.folderStats(folder)
                self.store.saveSnapshot(folder: folder, size: s.size, count: s.count)
            }
        }
    }

    func flushProjectLinks() {
        stateLock.lock(); let items = pendingProjectLinks; pendingProjectLinks = []; stateLock.unlock()
        guard !items.isEmpty else { return }
        insights.suggestProjectLinks(items)
    }

    func flushNotificationDigest() {
        stateLock.lock(); let d = notificationDigest; notificationDigest = (0, 0); stateLock.unlock()
        guard d.filed + d.review > 0 else { return }
        var parts: [String] = []
        if d.filed > 0 { parts.append("Filed \(d.filed) new file\(d.filed == 1 ? "" : "s")") }
        if d.review > 0 { parts.append("\(d.review) need\(d.review == 1 ? "s" : "") a quick review") }
        notify(title: "Nexus", body: parts.joined(separator: " · "), important: false)
    }

    public func listFiles(_ folder: String, recursive: Bool) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        if recursive {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            for case let url as URL in en {
                if TaxonomyLearner.skipDirs.contains(url.lastPathComponent) { en.skipDescendants(); continue }
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
                if v?.isRegularFile == true || v?.isPackage == true, shouldProcess(url.path) { out.append(url.path) }
                if out.count > 20_000 { break }
            }
        } else {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where !name.hasPrefix(".") {
                let p = (folder as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                if (!isDir.boolValue || NSWorkspace.shared.isFilePackage(atPath: p)) && shouldProcess(p) { out.append(p) }
            }
        }
        return out
    }

    public static let palette = ["#FF6B6B", "#FFA94D", "#FFD43B", "#69DB7C", "#38D9A9", "#4DABF7", "#748FFC", "#DA77F2", "#F783AC"]

    // MARK: - ActionHost

    public func notify(title: String, body: String, important: Bool) {
        guard settings.notificationsEnabled else { return }
        if !important {
            if var f = focus { f.suppressed += 1; focus = f; store.setKV("focus", JSON.string(f)); return }
            let hour = Calendar.current.component(.hour, from: Date())
            let quiet = settings.quietHoursStart > settings.quietHoursEnd
                ? (hour >= settings.quietHoursStart || hour < settings.quietHoursEnd)
                : (hour >= settings.quietHoursStart && hour < settings.quietHoursEnd)
            if quiet { return }
        }
        notifier?(title, body, important)
    }

    public func summarize(file: FileRecord) async -> String {
        let text = store.fileContent(id: file.id) ?? file.snippet
        return await llm.summarize(text.isEmpty ? file.name : text, context: file.docType ?? "file")
    }

    public func indexCopy(at path: String) {
        ingestQueue.addOperation { [weak self] in _ = self?.index(path) }
    }

    public func findDuplicates(largeOnly: Bool) -> String {
        var groups: [[FileRecord]] = []
        for h in store.duplicateHashes(minSize: largeOnly ? 50_000_000 : 1) {
            let files = store.files(withHash: h).filter { FileManager.default.fileExists(atPath: $0.path) }
            if files.count > 1 { groups.append(files) }
        }
        let wasted = groups.reduce(Int64(0)) { $0 + $1.dropFirst().reduce(0) { $0 + $1.size } }
        let paths = groups.flatMap { $0.map(\.path) }
        if !groups.isEmpty {
            store.upsertInsight(Insight(key: "duplicates", kind: .duplicates, title: "\(groups.count) sets of duplicate files wasting \(formatBytes(wasted))",
                                        detail: groups.prefix(6).map { g in "• \(g[0].name) ×\(g.count)" }.joined(separator: "\n"),
                                        severity: .suggestion, command: "clean up duplicates", filePaths: paths, metric: Double(wasted)))
        }
        // Make sure the library is hashed for next time
        for root in settings.libraryRootsExpanded { enqueueOnce(.classifyFolder, name: "Classify \(Paths.abbreviate(root))", kind: .ai, priority: .low, spec: JobSpec(operation: .classifyFolder, path: root)) }
        return groups.isEmpty ? "No duplicates found among indexed files (indexing your library in the background)" : "Found \(groups.count) duplicate sets (\(formatBytes(wasted)) reclaimable). Say “clean up duplicates” to move the extra copies to Trash."
    }

    public func generateReport(type: String) async -> String {
        let url = reports.save(type: type)
        store.log(ActivityEvent(kind: .system, message: "Generated \(type) report → \(Paths.abbreviate(url.path))"))
        notify(title: "Your \(type) report is ready", body: url.lastPathComponent, important: false)
        return "Report saved: \(Paths.abbreviate(url.path))"
    }

    public func resolveProject(named name: String, create: Bool) -> Project? {
        if let p = store.project(named: name), p.name.lowercased() == name.lowercased() || !create { return p }
        guard create, !name.trimmed.isEmpty else { return nil }
        let p = Project(name: name.trimmed, color: Self.palette.randomElement()!)
        store.saveProject(p)
        store.log(ActivityEvent(kind: .system, message: "Created project \(p.name)"))
        return p
    }

    public func runPlugin(named: String, file: FileRecord?, info: [String: String]) async -> (Bool, String) {
        plugins.run(named: named, file: file, info: info, sandboxed: settings.scriptSandbox)
    }
}
