import SwiftUI
import AppKit
import NexusCore

/// NEXUS_SCREENSHOT_DIR=/path → walks every screen and writes PNGs (used for README/release images).
@MainActor
enum ScreenshotMode {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["NEXUS_SCREENSHOT_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            let app = AppState.shared
            app.showOnboarding = false
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            app.reloadAll()
            app.openMainWindow(.today)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let window = NSApp.windows.first(where: { $0.title == "Nexus" && $0.isVisible }) ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 900 }) else { NSApp.terminate(nil); return }
            window.setFrame(NSRect(x: 80, y: 80, width: 1360, height: 860), display: true)
            let pages: [(SidebarItem, String)] = [(.today, "01-today"), (.review, "02-review-queue"), (.files, "03-files"), (.projects, "04-projects"),
                                                  (.rules, "05-rules"), (.tasks, "06-tasks"), (.insights, "07-insights"), (.activity, "08-activity"),
                                                  (.access, "09-system-access")]
            for (item, name) in pages {
                app.selection = item
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                capture(window, out.appendingPathComponent(name + ".png"))
            }
            if let rule = app.rules.first {
                app.ruleDraft = rule
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                capture(window, out.appendingPathComponent("05b-rule-editor.png"))
            }
            HotbarController.shared.apply(.floating)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let h = HotbarController.shared.panelWindow { capture(h, out.appendingPathComponent("12-hotbar.png")) }
            let menu = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            menu.contentView = NSHostingView(rootView: MenuBarView().environmentObject(app).environmentObject(VoiceController.shared)
                .background(VisualEffectBlur(material: .menu)).preferredColorScheme(.dark))
            menu.setContentSize(NSSize(width: 340, height: 660))
            menu.orderFront(nil)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            capture(menu, out.appendingPathComponent("13-menu-bar.png"))
            menu.orderOut(nil)
            PaletteController.shared.show(prefill: "move all invoices from Downloads to Finance and tag them tax")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let p = PaletteController.shared.panelWindow { capture(p, out.appendingPathComponent("10-palette.png")) }
            PaletteController.shared.model.submit()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let p = PaletteController.shared.panelWindow { capture(p, out.appendingPathComponent("11-palette-preview.png")) }
            PaletteController.shared.hide()
            NSApp.terminate(nil)
        }
    }

    static func capture(_ window: NSWindow, _ url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
