import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation
import Speech
import EventKit
import UserNotifications
import NexusCore

/// What the user is looking at when they summon Nexus, so “file this” / “summarize this” just work.
@MainActor
enum ContextCapture {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var _selection: [String] = []
    /// Thread-safe snapshot (read by the engine from background tasks).
    nonisolated static var selection: [String] { lock.lock(); defer { lock.unlock() }; return _selection }
    private(set) static var appName: String?

    /// Call *before* Nexus activates (the frontmost app is still the user's app).
    static func capture() {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        appName = front.localizedName
        var paths: [String] = []
        if front.bundleIdentifier == "com.apple.finder" {
            paths = finderSelection()
        } else if let doc = frontDocument(pid: front.processIdentifier) {
            paths = [doc]
        }
        lock.lock(); _selection = paths; lock.unlock()
    }

    static func finderSelection() -> [String] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with i in (get selection)
                set out to out & POSIX path of (i as alias) & linefeed
            end repeat
            if out is "" then
                try
                    set out to POSIX path of (target of front Finder window as alias)
                end try
            end if
            return out
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue ?? ""
        return result.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    /// The document open in the frontmost window (Preview, Pages, Xcode, TextEdit…) via Accessibility.
    static func frontDocument(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let w = window else { return nil }
        var doc: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXDocumentAttribute as CFString, &doc) == .success,
              let s = doc as? String, let url = URL(string: s), url.isFileURL else { return nil }
        return url.path
    }
}

// MARK: - Permissions

struct AccessItem: Identifiable {
    enum State { case granted, missing, unknown }
    let id: String
    let title: String
    let symbol: String
    let why: String
    var state: State
    let settingsAnchor: String
}

@MainActor
final class SystemAccess: ObservableObject {
    static let shared = SystemAccess()
    @Published var items: [AccessItem] = []

    var allCriticalGranted: Bool { items.filter { ["fullDisk", "files"].contains($0.id) }.allSatisfy { $0.state == .granted } }

    func refresh() {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        func ek(_ s: EKAuthorizationStatus) -> AccessItem.State {
            if #available(macOS 14.0, *) { return s == .fullAccess || s == .writeOnly ? .granted : .missing }
            return s == .authorized ? .granted : .missing
        }
        items = [
            AccessItem(id: "fullDisk", title: "Full Disk Access", symbol: "internaldrive.fill",
                       why: "Lets Nexus understand and arrange files anywhere in your home folder — Mail attachments, iCloud Drive, app exports — not just Downloads.",
                       state: Self.hasFullDiskAccess() ? .granted : .missing, settingsAnchor: "Privacy_AllFiles"),
            AccessItem(id: "files", title: "Downloads, Desktop & Documents", symbol: "folder.fill",
                       why: "Needed to watch your inbox folders and file things into your library.",
                       state: Self.canRead(["~/Downloads", "~/Desktop", "~/Documents"]) ? .granted : .missing, settingsAnchor: "Privacy_FilesAndFolders"),
            AccessItem(id: "accessibility", title: "Accessibility", symbol: "accessibility",
                       why: "Lets “file this” and “summarize this” see the document open in the front app.",
                       state: AXIsProcessTrusted() ? .granted : .missing, settingsAnchor: "Privacy_Accessibility"),
            AccessItem(id: "automation", title: "Automation (Finder, Mail)", symbol: "gearshape.2.fill",
                       why: "Reads your Finder selection and runs AppleScript steps in your automations.",
                       state: .unknown, settingsAnchor: "Privacy_Automation"),
            AccessItem(id: "microphone", title: "Microphone", symbol: "mic.fill",
                       why: "Talk to Nexus. Audio is processed on this Mac.",
                       state: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .missing, settingsAnchor: "Privacy_Microphone"),
            AccessItem(id: "speech", title: "Speech Recognition", symbol: "waveform",
                       why: "Turns your voice into commands — on-device when supported.",
                       state: SFSpeechRecognizer.authorizationStatus() == .authorized ? .granted : .missing, settingsAnchor: "Privacy_SpeechRecognition"),
            AccessItem(id: "calendar", title: "Calendars & Reminders", symbol: "calendar",
                       why: "Adds deadlines found in files, preps files before meetings, infers focus time.",
                       state: ek(eventStatus) == .granted || ek(reminderStatus) == .granted ? .granted : .missing, settingsAnchor: "Privacy_Calendars"),
            AccessItem(id: "notifications", title: "Notifications", symbol: "bell.badge.fill",
                       why: "Calm, batched updates — only urgent ones interrupt.",
                       state: .unknown, settingsAnchor: "Notifications"),
        ]
        if Bundle.main.bundlePath.hasSuffix(".app") {
            UNUserNotificationCenter.current().getNotificationSettings { s in
                Task { @MainActor in
                    if let i = self.items.firstIndex(where: { $0.id == "notifications" }) {
                        self.items[i].state = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional ? .granted : .missing
                    }
                }
            }
        }
    }

    func request(_ item: AccessItem) {
        switch item.id {
        case "accessibility":
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { openSettings(item.settingsAnchor) }
        case "automation":
            _ = ContextCapture.finderSelection()   // triggers the Automation consent prompt for Finder
            openSettings(item.settingsAnchor)
        case "microphone":
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
        case "speech":
            SFSpeechRecognizer.requestAuthorization { _ in Task { @MainActor in self.refresh() } }
        case "calendar":
            Task { _ = await AppState.shared.engine.connectors.eventKit.requestAccess(); refresh() }
        case "files":
            _ = Self.canRead(["~/Downloads", "~/Desktop", "~/Documents"])  // triggers per-folder prompts
            refresh()
        case "notifications":
            AppState.shared.requestNotificationPermission()
            openSettings(item.settingsAnchor)
        default:
            openSettings(item.settingsAnchor)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    func openSettings(_ anchor: String) {
        let url = anchor == "Notifications"
            ? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            : URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    static func hasFullDiskAccess() -> Bool {
        let probes = ["~/Library/Safari/Bookmarks.plist", "~/Library/Application Support/com.apple.TCC/TCC.db", "~/Library/Mail"]
        return probes.map(Paths.expand).contains { FileManager.default.isReadableFile(atPath: $0) && (try? FileHandle(forReadingFrom: URL(fileURLWithPath: $0)).close()) != nil }
            || probes.map(Paths.expand).contains { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
    }

    static func canRead(_ folders: [String]) -> Bool {
        folders.map(Paths.expand).allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
    }
}

struct SystemAccessView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var access = SystemAccess.shared
    var compact = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !compact {
                    PageHeader(title: "System Access", subtitle: "Grant what you’re comfortable with. Everything Nexus reads stays on this Mac, and every change is undoable.") {
                        Button { access.refresh() } label: { Label("Re-check", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
                    }
                }
                ForEach(access.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(item.title).font(.headline)
                                switch item.state {
                                case .granted: Pill(text: "Granted", symbol: "checkmark", color: Theme.success)
                                case .missing: Pill(text: "Not granted", symbol: "xmark", color: Theme.warning)
                                case .unknown: Pill(text: "Check in Settings", color: .secondary)
                                }
                            }
                            Text(item.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if item.state != .granted {
                            Button(item.id == "fullDisk" ? "Open Settings…" : "Allow…") { access.request(item) }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .padding(14)
                    .hudPanel()
                    .accessibilityElement(children: .combine)
                }
                if !compact {
                    let homeLearned = app.settings.libraryRootsExpanded.contains(Paths.expand("~"))
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Whole-Mac mode", systemImage: "desktopcomputer").font(.headline)
                            Text("With Full Disk Access, Nexus can learn and search your entire home folder (system and app-internal folders are always skipped) and act on files wherever they live. Automations still only move files inside your inbox folders unless a rule says otherwise.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button(homeLearned ? "Whole-Mac mode is on" : "Turn on whole-Mac mode") {
                                    var s = app.settings
                                    s.libraryRoots = ["~"]
                                    app.saveSettings(s)
                                    app.engine.queue.enqueue(Job(name: "Learn folder structure", kind: .ai, priority: .normal, spec: JobSpec(operation: .learnTaxonomy)))
                                    app.engine.queue.enqueue(Job(name: "Classify home folder", kind: .ai, priority: .low, spec: JobSpec(operation: .classifyFolder, path: Paths.expand("~"))))
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(homeLearned || access.items.first { $0.id == "fullDisk" }?.state != .granted)
                                if access.items.first(where: { $0.id == "fullDisk" })?.state != .granted {
                                    Text("Requires Full Disk Access").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(compact ? 0 : 28)
        }
        .onAppear { access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in access.refresh() }
    }
}
