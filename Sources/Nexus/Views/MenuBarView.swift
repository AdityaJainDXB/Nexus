import SwiftUI
import NexusCore

struct MenuBarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(status: app.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nexus").font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { app.setPaused(!app.paused) } label: { Image(systemName: app.paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(GhostButtonStyle()).help(app.paused ? "Resume automations" : "Pause automations")
            }

            HStack(spacing: 8) {
                Button { PaletteController.shared.show() } label: {
                    HStack {
                        Image(systemName: "sparkle").foregroundStyle(Theme.accent)
                        Text("Ask Nexus…").foregroundStyle(.secondary)
                        Spacer()
                        Text(app.settings.paletteHotkey.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(9).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
                MicButton(size: 34)
            }
            if app.settings.voiceHotkey != .off {
                Text("Hold \(app.settings.voiceHotkey.label) anywhere to talk").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                tile("Review", "\(app.reviewItems.count)", "tray.full", Theme.warning) { app.openMainWindow(.review) }
                tile("Insights", "\(app.insights.count)", "lightbulb", Theme.accent) { app.openMainWindow(.insights) }
                tile("Running", "\(app.jobs.filter { $0.status == .running }.count)", "gearshape.2", Theme.accent2) { app.openMainWindow(.tasks) }
            }

            if let f = app.focus {
                HStack {
                    Image(systemName: "scope").foregroundStyle(Theme.accent2)
                    Text("Focus: \(app.projects.first { $0.id == f.projectId }?.name ?? "") · until \(DateFormatter.localizedString(from: f.endsAt, dateStyle: .none, timeStyle: .short))").font(.system(size: 11.5))
                    Spacer()
                    Button("End") { app.engine.endFocus(); app.reloadAll() }.buttonStyle(GhostButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK ACTIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    quick("Organize Downloads", "wand.and.stars") { app.runCommand("organize Downloads") }
                    quick("Weekly report", "chart.bar.doc.horizontal") { app.runCommand("generate weekly report") }
                    quick("Find duplicates", "square.on.square") { app.runCommand("find duplicates") }
                    quick("Undo last", "arrow.uturn.backward") { app.runCommand("undo") }
                }
            }

            if !app.insights.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEXUS NOTICED").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    ForEach(app.insights.prefix(3)) { i in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Theme.severity(i.severity)).frame(width: 6, height: 6).padding(.top, 5)
                            Text(i.title).font(.system(size: 11.5)).lineLimit(2)
                            Spacer(minLength: 4)
                            if let c = i.command { Button("Fix") { app.runCommand(c) }.buttonStyle(GhostButtonStyle()) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("RECENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(app.events.filter { $0.kind != .fileIndexed && $0.kind != .jobStarted }.prefix(5)) { e in
                    HStack(spacing: 6) {
                        Image(systemName: Theme.eventSymbol(e.kind)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                        Text(e.message).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                        Spacer()
                        Text(relativeTime(e.timestamp)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open Nexus") { app.openMainWindow() }.buttonStyle(PrimaryButtonStyle())
                Spacer()
                SettingsLink14 { Text("Settings…").font(.system(size: 12)) }
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 8)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    var subtitle: String {
        switch app.status {
        case .idle: return "Idle · \(app.fileCount) files indexed"
        case .working: return "Working in the background…"
        case .attention: return "\(app.reviewItems.count) item\(app.reviewItems.count == 1 ? "" : "s") need a quick look"
        case .paused: return "Automations paused"
        }
    }

    func tile(_ title: String, _ value: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11, weight: .semibold))
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }

    func quick(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 14)
                Text(title).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(7).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}
