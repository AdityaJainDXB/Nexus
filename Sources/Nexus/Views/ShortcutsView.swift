import SwiftUI
import NexusCore

/// Cheat sheet (⌘/). Voice first, then global, palette, window and review shortcuts.
struct ShortcutsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var sections: [(String, String, [(String, String)])] {
        let v = app.settings.voiceHotkey.label
        return [
            ("Voice", "waveform", [
                (v + " (hold)", "Talk to Nexus from any app — release to send"),
                (v + " (tap)", "Hands-free: Nexus sends when you pause"),
                ("⌘D", "Start or stop dictation inside the palette"),
                ("⇧⌘D", "Speak a command (while Nexus is frontmost)"),
                ("“run it” / “cancel”", "Answer a spoken preview before files change"),
                ("esc", "Stop listening or speaking"),
            ]),
            ("Anywhere on your Mac", "globe", [
                (app.settings.paletteHotkey.label, "Open the command palette"),
            ]),
            ("Command palette", "command", [
                ("↩", "Plan the command · run the preview · open the selected file"),
                ("⌘↩", "Confirm and run"),
                ("↑ ↓", "Move through quick actions, recents or results"),
                ("⌘1 – ⌘6", "Run a quick action"),
                ("⌘Z", "Undo what the last command changed"),
                ("⌘R", "Reveal results in Finder"),
                ("⌘O", "Open the Nexus window"),
                ("⌘.  /  esc", "Cancel · back · close"),
            ]),
            ("Nexus window", "macwindow", [
                ("⌘K", "Ask Nexus"),
                ("⌘1 – ⌘9", "Switch sections"),
                ("⌘N / ⇧⌘N / ⌥⌘N", "New rule / project / schedule"),
                ("⇧⌘F", "Search files"),
                ("⌥⌘Z", "Undo last automation"),
                ("⌥⌘O", "Organize Downloads"),
                ("⌥⌘R", "Scan for insights"),
                ("⌥⌘P", "Pause or resume automations"),
                ("⌥⌘F", "Start or end focus"),
                ("⌘S", "Save rule (in the rule editor)"),
                ("⌘,", "Settings"),
            ]),
            ("Review Queue", "tray.full", [
                ("↑ ↓", "Previous / next suggestion"),
                ("↩", "Approve"),
                ("⇧↩", "Reject"),
                ("E", "Edit destination, tags or project"),
                ("Space", "Open the file"),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard & voice shortcuts").font(.title2.weight(.bold))
                Spacer()
                Button("Change…") { app.openSettings(); dismiss() }.buttonStyle(GhostButtonStyle())
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 18) {
                    ForEach(sections, id: \.0) { title, symbol, rows in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(title, systemImage: symbol).font(.headline).foregroundStyle(title == "Voice" ? Theme.accent2 : .primary)
                            ForEach(rows, id: \.0) { key, what in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(key).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                                        .frame(minWidth: 70, alignment: .leading)
                                    Text(what).font(.system(size: 12)).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 760, height: 620)
    }
}
