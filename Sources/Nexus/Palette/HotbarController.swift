import SwiftUI
import AppKit
import NexusCore

/// The desktop hotbar: a slim HUD strip that keeps Nexus one click (or one word) away.
/// Draggable; position is remembered. Floating above apps or pinned to the desktop layer.
@MainActor
final class HotbarController: NSObject, NSWindowDelegate {
    static let shared = HotbarController()
    private var panel: NSPanel?
    private let positionKey = "NexusHotbarOrigin"
    var panelWindow: NSWindow? { panel }

    func apply(_ mode: HotbarMode) {
        guard mode != .off else { panel?.orderOut(nil); return }
        if panel == nil { build() }
        guard let panel else { return }
        panel.level = mode == .floating ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = mode == .floating ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary] : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.orderFrontRegardless()
    }

    private func build() {
        let size = NSSize(width: 600, height: 56)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.delegate = self
        p.setAccessibilityLabel("Nexus hotbar")
        let host = NSHostingView(rootView: HotbarRoot().environmentObject(AppState.shared).environmentObject(VoiceController.shared))
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        p.contentView = host
        if let saved = UserDefaults.standard.string(forKey: positionKey) {
            p.setFrameOrigin(NSPointFromString(saved))
        } else if let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: s.midX - size.width / 2, y: s.minY + 14))
        }
        panel = p
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let p = HotbarController.shared.panel else { return }
            UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: HotbarController.shared.positionKey)
        }
    }
}

struct HotbarRoot: View {
    @EnvironmentObject var app: AppState
    var body: some View { HotbarView().preferredColorScheme(app.settings.appearance.colorScheme) }
}

struct HotbarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var voice: VoiceController
    @State private var hovering = false

    var ticker: String {
        if voice.isActive { return voice.transcript.isEmpty ? "Listening…" : "“\(voice.transcript)”" }
        if let f = app.focus, let p = app.projects.first(where: { $0.id == f.projectId }) {
            let mins = max(0, Int(f.endsAt.timeIntervalSinceNow / 60))
            return "FOCUS · \(p.name) · \(mins)m left"
        }
        if app.paused { return "Automations paused" }
        if let e = app.events.first(where: { ![.fileIndexed, .jobStarted].contains($0.kind) }) { return e.message }
        return "\(app.fileCount) files understood · all systems nominal"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.gradient).frame(width: 30, height: 30)
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(light: "#FFFFFF", dark: "#04121A"))
            }
            .overlay(alignment: .bottomTrailing) { StatusDot(status: app.status).scaleEffect(0.7).offset(x: 4, y: 4) }
            .onTapGesture { app.openMainWindow() }
            .help("Open Nexus")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open Nexus")

            Button { PaletteController.shared.show() } label: {
                HStack(spacing: 8) {
                    Text(ticker)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(voice.isActive ? Theme.accent : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("⌘K").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ask Nexus (\(app.settings.paletteHotkey.label))")
            .accessibilityLabel("Ask Nexus. \(ticker)")

            MicButton(size: 34)

            Divider().frame(height: 24)
            bar("wand.and.stars", "Organize Downloads") { app.runCommand("organize Downloads") }
            bar("tray.full", "Review Queue", badge: app.reviewItems.count) { app.openMainWindow(.review) }
            bar("lightbulb", "Insights", badge: app.insights.count) { app.openMainWindow(.insights) }
            bar(app.focus == nil ? "scope" : "stop.circle", app.focus == nil ? "Start focus" : "End focus") {
                if app.focus != nil { app.engine.endFocus(); app.reloadAll() } else { app.openMainWindow(.today) }
            }
            bar(app.paused ? "play.fill" : "pause.fill", app.paused ? "Resume automations" : "Pause automations") { app.setPaused(!app.paused) }
        }
        .padding(.horizontal, 12)
        .frame(width: 600, height: 56)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow)
                Theme.space.opacity(0.6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(voice.isActive ? Theme.accent.opacity(0.8) : Theme.cardStroke, lineWidth: 1))
        .overlay(CornerBrackets(inset: 5, length: 10).stroke(Theme.accent.opacity(0.6), lineWidth: 1.2).allowsHitTesting(false))
        .contextMenu {
            Button("Open Nexus") { app.openMainWindow() }
            Button("Keyboard Shortcuts") { app.showShortcuts = true; app.openMainWindow() }
            Divider()
            ForEach(HotbarMode.allCases, id: \.self) { m in
                Button(m.label) { var s = app.settings; s.hotbar = m; app.saveSettings(s) }
            }
        }
    }

    func bar(_ symbol: String, _ label: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.warning, in: Capsule()).foregroundStyle(Color.black)
                            .offset(x: 5, y: -5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(badge > 0 ? "\(label), \(badge)" : label)
    }
}
