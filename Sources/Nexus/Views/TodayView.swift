import SwiftUI
import NexusCore

struct TodayView: View {
    @EnvironmentObject var app: AppState
    @State private var focusProject: String = ""
    @State private var focusMinutes = 90.0

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var weekStart: Date { Date().addingTimeInterval(-7 * 86400) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: greeting, subtitle: headline) {
                    Button { PaletteController.shared.show() } label: { Label("Ask Nexus", systemImage: "sparkle") }.buttonStyle(PrimaryButtonStyle())
                }

                let events = app.events
                let filedToday = events.filter { Calendar.current.isDateInToday($0.timestamp) && ($0.kind == .fileMoved || $0.kind == .ruleFired) }.count
                let hitsWeek = app.engine.store.ruleHits(since: weekStart)
                let saved = app.rules.reduce(0) { $0 + (hitsWeek[$1.id] ?? 0) * $1.estimatedSecondsSaved }
                HStack(spacing: 12) {
                    StatTile(title: "Handled today", value: "\(filedToday)", symbol: "checkmark.seal", tint: Theme.success, footnote: "moves, tags & rule runs")
                    StatTile(title: "Needs review", value: "\(app.reviewItems.count)", symbol: "tray.full", tint: Theme.warning, footnote: "medium-confidence suggestions")
                    StatTile(title: "Automations this week", value: "\(hitsWeek.values.reduce(0, +))", symbol: "bolt", tint: Theme.accent, footnote: "\(app.rules.filter(\.enabled).count) active rules")
                    StatTile(title: "Time saved", value: saved < 3600 ? "\(saved / 60)m" : String(format: "%.1fh", Double(saved) / 3600), symbol: "hourglass", tint: Theme.accent2, footnote: "estimated, last 7 days")
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        focusCard
                        insightsCard
                        if !app.reviewItems.isEmpty { reviewTeaser }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        upcomingCard
                        activityCard
                    }
                    .frame(width: 360)
                }
            }
            .padding(28)
        }
    }

    var headline: String {
        let watching = app.settings.watchedFolders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let places = app.settings.libraryRoots.count
        return "Sorting \(watching) · learning from \(places) place\(places == 1 ? "" : "s") · \(app.fileCount) files understood · \(app.llmName)"
    }

    var focusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Focus")
                if let f = app.focus, let p = app.projects.first(where: { $0.id == f.projectId }) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
                            Circle().trim(from: 0, to: max(0.02, min(1, Date().timeIntervalSince(f.startedAt) / f.endsAt.timeIntervalSince(f.startedAt))))
                                .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                            Image(systemName: p.icon).foregroundStyle(Color(hex: p.color))
                        }
                        .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.title3.weight(.semibold))
                            Text("Until \(DateFormatter.localizedString(from: f.endsAt, dateStyle: .none, timeStyle: .short)) · routing new files · \(f.suppressed) notifications held").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("End focus") { app.engine.endFocus(); app.reloadAll() }.buttonStyle(GhostButtonStyle())
                    }
                } else if app.projects.filter({ !$0.archived }).isEmpty {
                    Text("Create a project to use Focus: Nexus pre-warms its folders, routes new files into it and silences everything that isn't urgent.").font(.callout).foregroundStyle(.secondary)
                    Button("New project") { app.selection = .projects }.buttonStyle(GhostButtonStyle())
                } else {
                    HStack {
                        Picker("", selection: $focusProject) {
                            Text("Choose project").tag("")
                            ForEach(app.projects.filter { !$0.archived }) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 200)
                        Picker("", selection: $focusMinutes) {
                            Text("25 min").tag(25.0); Text("45 min").tag(45.0); Text("90 min").tag(90.0); Text("2 hours").tag(120.0); Text("4 hours").tag(240.0)
                        }.labelsHidden().frame(width: 100)
                        Button("Start focus") {
                            guard !focusProject.isEmpty else { return }
                            app.engine.startFocus(projectId: focusProject, minutes: Int(focusMinutes)); app.reloadAll()
                        }.buttonStyle(PrimaryButtonStyle()).disabled(focusProject.isEmpty)
                        Spacer()
                    }
                    Text("Nexus also starts focus automatically when a calendar event mentions one of your projects.").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    var insightsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Nexus noticed", trailing: AnyView(Button("All insights") { app.selection = .insights }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.caption)))
                if app.insights.isEmpty {
                    HStack { Image(systemName: "leaf").foregroundStyle(Theme.success); Text("Everything looks tidy. Nexus will speak up when something needs you.").foregroundStyle(.secondary).font(.callout) }
                }
                ForEach(app.insights.prefix(4)) { i in InsightRow(insight: i, compact: true) }
            }
        }
    }

    var reviewTeaser: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "tray.full.fill").font(.system(size: 24)).foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(app.reviewItems.count) suggestion\(app.reviewItems.count == 1 ? "" : "s") waiting").font(.headline)
                    Text("Approve with ↩, reject with ⇧↩. Each decision makes autopilot smarter.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review now") { app.selection = .review }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    var upcomingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Coming up")
                let upcoming = app.engine.scheduler.upcoming(limit: 6)
                if upcoming.isEmpty { Text("No scheduled tasks").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(upcoming.enumerated()), id: \.offset) { _, u in
                    HStack {
                        Image(systemName: "clock").foregroundStyle(Theme.accent2).frame(width: 16)
                        Text(u.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text(u.date.timeIntervalSinceNow < 60 ? "when ready" : relativeTime(u.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                let running = app.jobs.filter { $0.status == .running }
                ForEach(running.prefix(3)) { j in
                    HStack {
                        ProgressView().controlSize(.mini)
                        Text(j.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text(j.duration?.shortDuration ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var activityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Recent activity", trailing: AnyView(Button("Undo last") { app.runCommand("undo") }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.caption)))
                let items = app.events.filter { ![.fileIndexed, .jobStarted].contains($0.kind) }.prefix(12)
                if items.isEmpty { Text("Nothing yet — drop a file into Downloads to see Nexus work.").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(items)) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: Theme.eventSymbol(e.kind)).font(.system(size: 11)).foregroundStyle(e.kind == .error ? Theme.danger : Theme.accent).frame(width: 16)
                        Text(e.message).font(.system(size: 11.5)).lineLimit(2).foregroundStyle(e.undone ? .tertiary : .primary).strikethrough(e.undone)
                        Spacer(minLength: 4)
                        Text(relativeTime(e.timestamp)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
