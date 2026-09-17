import SwiftUI
import AppKit
import NexusCore
import UserNotifications

@main
struct NexusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState.shared
    @StateObject private var voice = VoiceController.shared

    var body: some Scene {
        Window("Nexus", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(voice)
                .preferredColorScheme(app.settings.appearance.colorScheme)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { NexusCommands(app: app) }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
                .environmentObject(voice)
                .preferredColorScheme(app.settings.appearance.colorScheme)
        } label: {
            // A fixed-size template image: never changes width, so the menu bar never shifts.
            Image(nsImage: MenuBarIconRenderer.image(for: app.status, reviewCount: app.reviewItems.count))
                .accessibilityLabel("Nexus, \(app.status.rawValue)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(voice)
                .preferredColorScheme(app.settings.appearance.colorScheme)
                .frame(width: 660, height: 580)
        }
    }
}

/// Menu commands. Follows platform conventions: no standard shortcut is repurposed
/// (⌘Z stays text undo, ⇧⌘P stays Page Setup, ⌘, opens Settings, ⌘? opens Help).
struct NexusCommands: Commands {
    @ObservedObject var app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Rule") { app.ruleDraft = Rule(name: "New rule", trigger: Trigger(kind: .fileAdded, folders: ["~/Downloads"])); app.openMainWindow(.rules) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Project") { app.openMainWindow(.projects); NotificationCenter.default.post(name: .newProject, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Schedule") { app.openMainWindow(.tasks); NotificationCenter.default.post(name: .newSchedule, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Undo Last Automation") { app.runCommand("undo") }.keyboardShortcut("z", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Button("Search Files") { app.openMainWindow(.files); NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Assistant") {
            Button("Ask Nexus…") { PaletteController.shared.show() }.keyboardShortcut("k", modifiers: .command)
            Button("Speak a Command") { PaletteController.shared.show(listen: true) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Organize Downloads") { app.runCommand("organize Downloads") }.keyboardShortcut("o", modifiers: [.command, .option])
            Button("Scan for Insights") { app.engine.queue.enqueue(Job(name: "Scan for insights", kind: .ai, priority: .high, spec: JobSpec(operation: .scanInsights))) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Generate Weekly Report") { app.runCommand("generate weekly report") }
            Divider()
            Button(app.paused ? "Resume Automations" : "Pause Automations") { app.setPaused(!app.paused) }.keyboardShortcut("p", modifiers: [.command, .option])
            Button(app.focus == nil ? "Start Focus…" : "End Focus") {
                if app.focus != nil { app.engine.endFocus(); app.reloadAll() } else { app.openMainWindow(.today) }
            }.keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarItem.allCases.prefix(9).enumerated()), id: \.element) { i, item in
                Button(item.title) { app.openMainWindow(item) }.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { app.showShortcuts = true; app.openMainWindow() }.keyboardShortcut("/", modifiers: .command)
            Button("Nexus Help") { app.showShortcuts = true; app.openMainWindow() }.keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// Renders the menu bar glyph at a constant 22×18 pt so state changes never shift neighbouring items.
enum MenuBarIconRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(for status: EngineStatus, reviewCount: Int) -> NSImage {
        let badge = status == .attention || reviewCount > 0
        let key = "\(status.rawValue)-\(badge)"
        if let img = cache[key] { return img }
        let size = NSSize(width: 22, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let symbolName: String
            switch status {
            case .paused: symbolName = "pause.circle"
            case .working: symbolName = "circle.hexagongrid.circle"
            default: symbolName = "circle.hexagongrid"
            }
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = sym.size
                sym.draw(in: NSRect(x: (18 - s.width) / 2 + 1, y: (rect.height - s.height) / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: status == .paused ? 0.6 : 1)
            }
            if badge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16, y: 11, width: 6, height: 6)).fill()
            }
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // An always-on agent must never be reaped by AppKit's automatic/sudden termination when it has no windows
        ProcessInfo.processInfo.disableAutomaticTermination("Nexus background agent")
        ProcessInfo.processInfo.disableSuddenTermination()
        Task { @MainActor in
            let app = AppState.shared
            app.start()
            let headless = ProcessInfo.processInfo.environment["NEXUS_HEADLESS"] == "1"   // automated tests / CI
            if headless {
                app.showOnboarding = false
                NSApp.setActivationPolicy(.prohibited)
                NSApp.windows.forEach { $0.orderOut(nil) }
            } else {
                NSApp.setActivationPolicy(app.settings.showDockIcon || !app.settings.onboardingComplete ? .regular : .accessory)
            }
            PaletteController.shared.registerHotkeys(palette: app.settings.paletteHotkey, voice: app.settings.voiceHotkey)
            if !headless { HotbarController.shared.apply(app.settings.hotbar) }
            LocalModelServer.shared.cleanupStale()
            // Make sure macOS knows about the bundled widgets (first launch from a DMG copy)
            let appex = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/NexusWidgets.appex").path
            if FileManager.default.fileExists(atPath: appex) { DispatchQueue.global(qos: .utility).async { Shell.run("/usr/bin/pluginkit", ["-a", appex]) } }
            if Bundle.main.bundlePath.hasSuffix(".app") { UNUserNotificationCenter.current().delegate = self }
            if !headless { NSApp.activate(ignoringOtherApps: true) }
            ScreenshotMode.runIfRequested()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach(WidgetBridge.handle) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalModelServer.shared.stop()
        MainActor.assumeIsolated { AppState.shared.engine.store.log(ActivityEvent(kind: .system, message: "Nexus quit")) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in AppState.shared.openMainWindow() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            AppState.shared.openMainWindow(response.actionIdentifier == "insights" ? .insights : .review)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

extension Notification.Name {
    static let newProject = Notification.Name("NexusNewProject")
    static let newSchedule = Notification.Name("NexusNewSchedule")
    static let focusSearch = Notification.Name("NexusFocusSearch")
}
