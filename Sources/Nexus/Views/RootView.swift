import SwiftUI
import NexusCore

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background)
                if let toast = app.toast {
                    Text(toast)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Theme.cardStroke))
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture { app.toast = nil }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.toast)
        }
        .sheet(isPresented: $app.showShortcuts) { ShortcutsView().environmentObject(app).preferredColorScheme(app.settings.appearance.colorScheme) }
        .sheet(isPresented: $app.showOnboarding, onDismiss: { app.markOnboardingSeen() }) { OnboardingView().environmentObject(app).preferredColorScheme(app.settings.appearance.colorScheme) }
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in openWindow(id: "main") }
        .onChange(of: app.ruleDraft) { draft in if draft != nil { app.selection = .rules } }
    }

    var background: some View { GridBackdrop() }

    @ViewBuilder var detail: some View {
        switch app.selection ?? .today {
        case .today: TodayView()
        case .review: ReviewQueueView()
        case .files: FilesView()
        case .projects: ProjectsView()
        case .rules: RulesView()
        case .tasks: TasksView()
        case .insights: InsightsView()
        case .activity: ActivityView()
        case .connectors: ConnectorsView()
        case .access: SystemAccessView()
        case .developer: DeveloperView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.gradient).frame(width: 30, height: 30)
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.white).font(.system(size: 15, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nexus").font(.system(size: 15, weight: .bold, design: .rounded))
                    HStack(spacing: 4) {
                        StatusDot(status: app.status).scaleEffect(0.7).frame(width: 10, height: 10)
                        Text(statusText).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 36).padding(.bottom, 10)

            HStack(spacing: 6) {
                Button { PaletteController.shared.show() } label: {
                    HStack {
                        Image(systemName: "sparkle").foregroundStyle(Theme.accent)
                        Text("Ask Nexus…").foregroundStyle(.secondary)
                        Spacer()
                        Text("⌘K").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                MicButton(size: 30)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            List(selection: $app.selection) {
                Section {
                    ForEach([SidebarItem.today, .review, .files, .projects]) { row($0) }
                }
                Section("Automation") {
                    ForEach([SidebarItem.rules, .tasks, .insights, .activity]) { row($0) }
                }
                Section("Extend") {
                    ForEach([SidebarItem.connectors, .access, .developer]) { row($0) }
                }
            }
            .listStyle(.sidebar)

            if let f = app.focus {
                focusBadge(f)
            }
            HStack {
                Button { app.setPaused(!app.paused) } label: {
                    Label(app.paused ? "Resume" : "Pause", systemImage: app.paused ? "play.fill" : "pause.fill").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
                SettingsLink14 { Image(systemName: "gearshape") }
            }
            .padding(12)
        }
    }

    var statusText: String {
        switch app.status {
        case .idle: return "All caught up"
        case .working: return "Working…"
        case .attention: return "\(app.reviewItems.count) to review"
        case .paused: return "Paused"
        }
    }

    func row(_ item: SidebarItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                Spacer()
                if item == .review && !app.reviewItems.isEmpty { badge(app.reviewItems.count, Theme.warning) }
                if item == .insights && !app.insights.isEmpty { badge(app.insights.count, Theme.accent) }
                if item == .tasks, case let n = app.jobs.filter({ $0.status == .running }).count, n > 0 { badge(n, Theme.accent2) }
                if item == .rules && !app.conflicts.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.system(size: 10)) }
            }
        } icon: { Image(systemName: item.symbol) }
        .tag(item)
    }

    func badge(_ n: Int, _ c: Color) -> some View {
        Text("\(n)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 1).background(c.opacity(0.22), in: Capsule()).foregroundStyle(c)
    }

    func focusBadge(_ f: FocusSession) -> some View {
        let name = app.projects.first { $0.id == f.projectId }?.name ?? "Project"
        return HStack(spacing: 8) {
            Image(systemName: "scope").foregroundStyle(Theme.accent2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Focus: \(name)").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text("until \(DateFormatter.localizedString(from: f.endsAt, dateStyle: .none, timeStyle: .short))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { app.engine.endFocus(); app.reloadAll() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.accent2.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }
}

/// SettingsLink is macOS 14+; fall back to the legacy selector on 13.
struct SettingsLink14<Label: View>: View {
    @ViewBuilder var label: Label
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { label }.buttonStyle(.plain).foregroundStyle(.secondary)
        } else {
            Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: { label }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
