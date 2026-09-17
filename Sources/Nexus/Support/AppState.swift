import SwiftUI
import NexusCore
import UserNotifications
import ServiceManagement

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today, review, files, projects, rules, tasks, insights, activity, connectors, access, developer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .review: return "Review Queue"
        case .files: return "Files"
        case .projects: return "Projects"
        case .rules: return "Rules & Automations"
        case .tasks: return "Tasks & Schedule"
        case .insights: return "Insights"
        case .activity: return "Activity"
        case .connectors: return "Connectors"
        case .access: return "System Access"
        case .developer: return "Developer"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "sun.horizon"
        case .review: return "tray.full"
        case .files: return "doc.text.magnifyingglass"
        case .projects: return "square.stack.3d.up"
        case .rules: return "point.3.connected.trianglepath.dotted"
        case .tasks: return "calendar.day.timeline.left"
        case .insights: return "chart.xyaxis.line"
        case .activity: return "clock.arrow.circlepath"
        case .connectors: return "puzzlepiece.extension"
        case .access: return "lock.shield"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        }
    }
    static func from(_ name: String) -> SidebarItem? {
        let n = name.lowercased()
        if n.contains("review") { return .review }
        if n.contains("insight") { return .insights }
        if n.contains("rule") { return .rules }
        if n.contains("project") { return .projects }
        if n.contains("task") || n.contains("schedule") { return .tasks }
        if n.contains("activity") { return .activity }
        if n.contains("connector") { return .connectors }
        if n.contains("file") { return .files }
        if n.contains("today") { return .today }
        if n.contains("access") || n.contains("permission") { return .access }
        return nil
    }
}

/// Main-actor bridge between the engine (background) and SwiftUI.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine: NexusEngine
    let api: APIServer
    let remote: RemoteServer
    @Published var remoteDevices: [RemoteServer.Device] = []
    @Published var remoteRunning = false

    @Published var selection: SidebarItem? = .today
    @Published var status: EngineStatus = .idle
    @Published var settings: NexusSettings
    @Published var reviewItems: [ReviewItem] = []
    @Published var insights: [Insight] = []
    @Published var rules: [Rule] = []
    @Published var conflicts: [RuleConflict] = []
    @Published var projects: [Project] = []
    @Published var jobs: [Job] = []
    @Published var schedules: [Schedule] = []
    @Published var events: [ActivityEvent] = []
    @Published var fileCount = 0
    @Published var focus: FocusSession?
    @Published var paused = false
    @Published var llmName = "Checking…"
    @Published var recentCommands: [String] = []
    @Published var showOnboarding = false
    @Published var ruleDraft: Rule?          // opened in the rules editor (e.g. from an insight)
    @Published var selectedProjectId: String?
    @Published var toast: String?
    @Published var showShortcuts = false

    private var pending = Set<String>()
    private var flushScheduled = false
    private var statusWork: DispatchWorkItem?
    private var workingSince: Date?
    private var pendingStatus: EngineStatus?

    private init() {
        let store: NexusStore
        do { store = try NexusStore() } catch {
            fatalError("Nexus could not open its database: \(error)")
        }
        engine = NexusEngine(store: store)
        api = APIServer(engine: engine)
        remote = RemoteServer(api: api, store: store)
        api.remote = remote
        settings = engine.settings
    }

    func start() {
        engine.notifier = { title, body, important in
            Task { @MainActor in AppState.shared.deliverNotification(title: title, body: body, important: important) }
        }
        engine.bus.subscribe { event in
            switch event {
            case .storeChanged(let entity): Task { @MainActor in AppState.shared.invalidate(entity) }
            case .status(let s): Task { @MainActor in AppState.shared.setStatus(s) }
            case .focusChanged: Task { @MainActor in AppState.shared.invalidate("focus") }
            default: break
            }
        }
        // Snapshot taken when Nexus is summoned (before it activates); safe to read from any thread.
        engine.contextSelection = { ContextCapture.selection }
        engine.start()
        if settings.apiEnabled { api.start(port: settings.apiPort) }
        remote.onChange = { Task { @MainActor in AppState.shared.remoteDevices = AppState.shared.remote.devices; AppState.shared.remoteRunning = AppState.shared.remote.isRunning } }
        if settings.remoteEnabled { remote.start() }
        remoteDevices = remote.devices
        requestNotificationPermission()
        reloadAll()
        showOnboarding = !settings.onboardingComplete
        Task { llmName = await engine.llm.providerName() }
    }

    /// Status is debounced so bursts of tiny background work don't make the menu bar flicker:
    /// "working" only shows after 0.8s of continuous activity and stays at least 1.5s.
    func setStatus(_ s: EngineStatus) {
        if s == pendingStatus { return }          // already scheduled — don't restart the debounce
        if s == status { statusWork?.cancel(); pendingStatus = nil; return }
        pendingStatus = s
        statusWork?.cancel()
        let apply = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStatus = nil
            guard self.status != s else { return }
            self.workingSince = s == .working ? Date() : nil
            self.status = s
        }
        statusWork = apply
        let delay: TimeInterval
        if s == .working { delay = 0.8 }
        else if let since = workingSince { delay = max(0, 1.5 - Date().timeIntervalSince(since)) }
        else { delay = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply)
    }

    func invalidate(_ entity: String) {
        pending.insert(entity)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let entities = self.pending
            self.pending.removeAll()
            self.reload(entities)
        }
    }

    func reloadAll() { reload(["files", "rules", "projects", "jobs", "schedules", "events", "insights", "review", "settings", "focus", "commands"]) }

    private func reload(_ e: Set<String>) {
        let store = engine.store
        if e.contains("review") || e.contains("files") { reviewItems = store.reviewItems() }
        if e.contains("insights") { insights = store.insights() }
        if e.contains("rules") { rules = store.rules(); conflicts = engine.ruleEngine.analyzeConflicts(rules) }
        if e.contains("projects") { projects = store.projects() }
        if e.contains("jobs") { jobs = store.jobs(limit: 300) }
        if e.contains("schedules") { schedules = store.schedules() }
        if e.contains("events") { events = store.events(limit: 400); recentCommands = store.commandHistory() }
        if e.contains("files") { fileCount = store.fileCount() }
        if e.contains("settings") {
            settings = engine.settings
            // Apply changes made outside the Settings UI (API, CLI, iPhone)
            if settings.remoteEnabled != remote.isRunning { settings.remoteEnabled ? remote.start() : remote.stop() }
            if settings.apiEnabled && api.port == 0 { api.start(port: settings.apiPort) }
        }
        focus = engine.focus
        paused = engine.paused
        if engine.status != status { setStatus(engine.status) }
        WidgetBridge.publish(self)
    }

    // MARK: Actions

    func saveSettings(_ s: NexusSettings) {
        let apiChanged = s.apiEnabled != settings.apiEnabled || s.apiPort != settings.apiPort
        let hotkeyChanged = s.paletteHotkey != settings.paletteHotkey || s.voiceHotkey != settings.voiceHotkey
        engine.updateSettings(s)
        settings = s
        if apiChanged { s.apiEnabled ? api.start(port: s.apiPort) : api.stop() }
        if s.remoteEnabled != remote.isRunning { s.remoteEnabled ? remote.start() : remote.stop(); remoteRunning = remote.isRunning }
        if hotkeyChanged { PaletteController.shared.registerHotkeys(palette: s.paletteHotkey, voice: s.voiceHotkey) }
        NSApp.setActivationPolicy(s.showDockIcon ? .regular : .accessory)
        HotbarController.shared.apply(s.hotbar)
        Task { llmName = await engine.llm.providerName() }
    }

    func runCommand(_ text: String) {
        Task {
            let plan = await engine.plan(text)
            let result = await engine.execute(plan)
            showToast(result.message)
            if let nav = result.navigate.flatMap(SidebarItem.from) { selection = nav; openMainWindow() }
        }
    }

    /// Onboarding is shown exactly once — even if the sheet is closed without finishing.
    func markOnboardingSeen() {
        guard !settings.onboardingComplete else { return }
        var s = settings
        s.onboardingComplete = true
        saveSettings(s)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        else { NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) }
    }

    func setPaused(_ p: Bool) { engine.setPaused(p); paused = p }

    func showToast(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.toast == message { self?.toast = nil } }
    }

    func openMainWindow(_ item: SidebarItem? = nil) {
        if let item { selection = item }
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Nexus" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }

    // MARK: Notifications

    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let review = UNNotificationAction(identifier: "review", title: "Open Review Queue", options: [.foreground])
        let insights = UNNotificationAction(identifier: "insights", title: "Show Insights", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "nexus", actions: [review, insights], intentIdentifiers: [])])
    }

    func deliverNotification(title: String, body: String, important: Bool) {
        guard notificationsAvailable else { showToast("\(title): \(body)"); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "nexus"
        if important { content.sound = .default; content.interruptionLevel = .timeSensitive } else { content.interruptionLevel = .passive }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { showToast("Launch at login requires running the bundled Nexus.app (\(error.localizedDescription))") }
            objectWillChange.send()
        }
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("NexusOpenMainWindow")
}
