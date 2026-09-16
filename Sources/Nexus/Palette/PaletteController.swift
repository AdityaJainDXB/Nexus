import SwiftUI
import AppKit
import Carbon.HIToolbox
import NexusCore

/// Global hotkey via Carbon (no Accessibility permission needed). Reports press *and* release for push-to-talk.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let onDown: () -> Void
    private let onUp: (() -> Void)?
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    init?(keyCode: Int, modifiers: Int, onDown: @escaping () -> Void, onUp: (() -> Void)? = nil) {
        self.onDown = onDown
        self.onUp = onUp
        id = Self.nextID
        Self.nextID += 1
        Self.installHandlerOnce()
        let hkID = EventHotKeyID(signature: OSType(0x4E585553), id: id) // 'NXUS'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        Self.instances[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.instances[id] = nil
    }

    private static func installHandlerOnce() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard let target = HotKey.instances[hk.id] else { return noErr }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { target.onDown() } else { target.onUp?() }
            return noErr
        }, 2, &specs, nil, &handler)
    }

    static func palette(_ choice: PaletteHotkey, action: @escaping () -> Void) -> HotKey? {
        switch choice {
        case .cmdShiftK: return HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey | shiftKey, onDown: action)
        case .cmdShiftJ: return HotKey(keyCode: kVK_ANSI_J, modifiers: cmdKey | shiftKey, onDown: action)
        case .optionSpace: return HotKey(keyCode: kVK_Space, modifiers: optionKey, onDown: action)
        case .ctrlSpace: return HotKey(keyCode: kVK_Space, modifiers: controlKey, onDown: action)
        }
    }

    static func voice(_ choice: VoiceHotkey, down: @escaping () -> Void, up: @escaping () -> Void) -> HotKey? {
        switch choice {
        case .optionShiftSpace: return HotKey(keyCode: kVK_Space, modifiers: optionKey | shiftKey, onDown: down, onUp: up)
        case .controlOptionSpace: return HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey, onDown: down, onUp: up)
        case .rightCommandHold: return HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey | cmdKey, onDown: down, onUp: up)
        case .off: return nil
        }
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { PaletteController.shared.escape() }
}

/// Floating, non-blocking command palette window.
@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()
    private var panel: PalettePanel?
    private var paletteHotKey: HotKey?
    private var voiceHotKey: HotKey?
    private var keyMonitor: Any?
    let model = PaletteModel()

    var isVisible: Bool { panel?.isVisible == true }

    func registerHotkeys(palette: PaletteHotkey, voice: VoiceHotkey) {
        paletteHotKey = nil
        voiceHotKey = nil
        paletteHotKey = HotKey.palette(palette) { Task { @MainActor in PaletteController.shared.toggle() } }
        voiceHotKey = HotKey.voice(voice,
                                   down: { Task { @MainActor in VoiceController.shared.hotkeyDown() } },
                                   up: { Task { @MainActor in VoiceController.shared.hotkeyUp() } })
    }

    func toggle() { isVisible ? hide() : show() }

    func show(prefill: String? = nil, listen: Bool = false) {
        if !isVisible {
            ContextCapture.capture()
            // Warm the offline model so the first answer is instant (no-op if Apple Intelligence/Ollama is used)
            Task.detached(priority: .utility) {
                if await AppState.shared.engine.llm.provider() is BundledModelProvider { _ = try? await LocalModelServer.shared.ensureRunning() }
            }
        }
        if panel == nil { build() }
        guard let panel else { return }
        if !panel.isVisible || prefill != nil { model.reset(prefill: prefill) }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let s = screen?.visibleFrame, !panel.isVisible {
            panel.setFrameOrigin(NSPoint(x: s.midX - panel.frame.width / 2, y: s.maxY - s.height * 0.22 - panel.frame.height))
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = reduceMotion ? 0 : 0.14; panel.animator().alphaValue = 1 }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        model.focusToken += 1
        if listen { VoiceController.shared.start(mode: .tap) }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        VoiceController.shared.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; panel.animator().alphaValue = 0 }) {
            Task { @MainActor in panel.orderOut(nil) }
        }
    }

    /// Esc: stop listening → leave preview → clear text → close.
    func escape() {
        if VoiceController.shared.isActive || VoiceController.shared.phase == .speaking { VoiceController.shared.cancel(); return }
        if model.phase == .preview { model.cancelPreview(); return }
        if !model.text.isEmpty && model.phase != .done { model.text = ""; model.textChanged(); return }
        hide()
    }

    private func build() {
        let p = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                             styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.delegate = self
        p.setAccessibilityLabel("Nexus command palette")
        let host = NSHostingView(rootView: PaletteRoot(model: model).environmentObject(AppState.shared).environmentObject(VoiceController.shared))
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        p.contentView = host
        panel = p
        installKeyMonitor()
    }

    /// Palette keyboard shortcuts that must work while the text field has focus.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let controller = PaletteController.shared
            guard let panel = controller.panel, event.window === panel else { return event }
            let m = controller.model
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = flags.contains(.command)
            switch (Int(event.keyCode), cmd) {
            case (kVK_DownArrow, false): m.moveSelection(1); return nil
            case (kVK_UpArrow, false): m.moveSelection(-1); return nil
            case (kVK_Return, true): m.submit(); return nil                        // ⌘↩ confirm & run
            case (kVK_ANSI_Period, true): controller.escape(); return nil           // ⌘. cancel
            case (kVK_ANSI_D, true): VoiceController.shared.toggleFromUI(); return nil // ⌘D dictate
            case (kVK_ANSI_Z, true) where m.result?.batchId != nil && m.text == m.lastRunText: m.undo(); return nil
            case (kVK_ANSI_R, true): m.revealResults(); return nil                 // ⌘R reveal results
            case (kVK_ANSI_O, true): AppState.shared.openMainWindow(); controller.hide(); return nil
            case (kVK_ANSI_Comma, true): AppState.shared.openSettings(); controller.hide(); return nil
            default:
                if cmd, let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...6).contains(n) {
                    m.runQuickAction(n - 1); return nil                                   // ⌘1…⌘6 quick actions
                }
                return event
            }
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            let c = PaletteController.shared
            if !c.model.isExecuting && !VoiceController.shared.isActive && VoiceController.shared.phase != .speaking { c.hide() }
        }
    }
}

/// Applies the chosen appearance to the palette's hosting view.
struct PaletteRoot: View {
    @ObservedObject var model: PaletteModel
    @EnvironmentObject var app: AppState
    var body: some View { PaletteView(model: model).preferredColorScheme(app.settings.appearance.colorScheme) }
}

// MARK: - Palette model

@MainActor
final class PaletteModel: ObservableObject {
    enum Phase: Equatable { case idle, planning, preview, executing, done }

    struct QuickAction: Identifiable { let id = UUID(); let title: String; let symbol: String; let command: String }
    static let quickActions = [
        QuickAction(title: "Organize Downloads", symbol: "wand.and.stars", command: "organize Downloads"),
        QuickAction(title: "Show unsorted files", symbol: "tray.full", command: "open review queue"),
        QuickAction(title: "Run weekly report", symbol: "chart.bar.doc.horizontal", command: "generate weekly report"),
        QuickAction(title: "Find duplicates", symbol: "square.on.square", command: "find duplicates"),
        QuickAction(title: "Archive old screenshots", symbol: "archivebox", command: "archive screenshots older than 30 days"),
        QuickAction(title: "Undo last action", symbol: "arrow.uturn.backward", command: "undo"),
    ]

    @Published var text = ""
    @Published var phase: Phase = .idle
    @Published var localSteps: [CommandStep] = []
    @Published var plan: CommandPlan?
    @Published var result: CommandResult?
    @Published var focusToken = 0
    @Published var selectedIndex: Int?
    private(set) var lastRunText = ""
    private var planTask: Task<Void, Never>?

    var isExecuting: Bool { phase == .executing || phase == .planning }

    /// Rows navigable with ↑/↓ in the current state.
    var navigableCount: Int {
        if phase == .done { return min(40, result?.files.count ?? 0) }
        if text.trimmed.isEmpty { return Self.quickActions.count + min(5, AppState.shared.recentCommands.count) }
        return 0
    }

    func reset(prefill: String?) {
        text = prefill ?? ""
        phase = .idle
        plan = nil
        result = nil
        localSteps = []
        selectedIndex = nil
        if prefill != nil { textChanged() }
    }

    func textChanged() {
        if phase == .done || phase == .preview { phase = .idle; result = nil; plan = nil }
        let engine = AppState.shared.engine
        let compiler = NLRuleCompiler(libraryRoot: engine.settings.libraryRoots.first ?? "~/Documents", knownProjects: AppState.shared.projects.map(\.name))
        localSteps = text.trimmed.isEmpty ? [] : CommandParser(compiler: compiler).parse(text)
        selectedIndex = nil
    }

    func setTextFromVoice(_ t: String) {
        guard t != text else { return }
        text = t
        textChanged()
    }

    func moveSelection(_ delta: Int) {
        let n = navigableCount
        guard n > 0 else { return }
        selectedIndex = ((selectedIndex ?? (delta > 0 ? -1 : n)) + delta + n) % n
    }

    func submit() {
        let input = text.trimmed
        if input.isEmpty, let i = selectedIndex {
            let quick = Self.quickActions
            let recents = Array(AppState.shared.recentCommands.prefix(5))
            let cmd = i < quick.count ? quick[i].command : recents[i - quick.count]
            text = cmd
            textChanged()
            submit()
            return
        }
        if phase == .done, let i = selectedIndex, let f = result?.files[safe: i] { Panels.open(f.path); return }
        guard !input.isEmpty else { return }
        if phase == .preview, let plan { run(plan); return }
        guard phase != .planning && phase != .executing else { return }
        phase = .planning
        planTask?.cancel()
        planTask = Task {
            let p = await AppState.shared.engine.plan(input)
            guard !Task.isCancelled else { return }
            plan = p
            if p.requiresConfirmation && p.understood {
                phase = .preview
                VoiceController.shared.confirm(plan: p)
            } else {
                run(p)
            }
        }
    }

    func runQuickAction(_ i: Int) {
        guard let qa = Self.quickActions[safe: i] else { return }
        text = qa.command
        textChanged()
        submit()
    }

    func confirmFromVoice() { if phase == .preview, let plan { run(plan) } }

    func cancelPreview() {
        phase = .idle
        plan = nil
    }

    func run(_ p: CommandPlan) {
        phase = .executing
        lastRunText = text
        Task {
            let r = await AppState.shared.engine.execute(p)
            result = r
            phase = .done
            selectedIndex = nil
            VoiceController.shared.reply(r)
            AppState.shared.recentCommands = AppState.shared.engine.store.commandHistory()
            if let rule = r.createdRule { AppState.shared.ruleDraft = rule }
            if let nav = r.navigate.flatMap(SidebarItem.from) {
                AppState.shared.openMainWindow(nav)
                PaletteController.shared.hide()
            }
        }
    }

    func undo() {
        guard let batch = result?.batchId else { return }
        let n = AppState.shared.engine.executor.undo(batchId: batch)
        result?.message = n > 0 ? "Undid \(n) operation\(n == 1 ? "" : "s")." : "Nothing to undo."
        result?.batchId = nil
    }

    func revealResults() {
        guard let files = result?.files, !files.isEmpty else { return }
        if let i = selectedIndex, let f = files[safe: i] { Panels.reveal([f.path]) } else { Panels.reveal(files.prefix(50).map(\.path)) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension AppearanceChoice {
    var colorScheme: ColorScheme? {
        switch self { case .dark: return .dark; case .light: return .light; case .system: return nil }
    }
}
