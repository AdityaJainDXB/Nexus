import SwiftUI
import NexusCore

/// Formula 1: live timing board, race control, weather, countdown and championships.
struct F1View: View {
    @EnvironmentObject var app: AppState
    @State private var live: F1Live?
    @State private var next: F1Race?
    @State private var drivers: [F1Standing] = []
    @State private var teams: [F1Standing] = []
    @State private var showTeams = false
    @State private var updated = Date()
    @State private var now = Date()
    @State private var loading = true

    private var refresh: Timer.TimerPublisher { Timer.publish(every: 1, on: .main, in: .common) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: live?.session.title ?? "Formula 1", subtitle: "Live timing · race control · championships") {
                HStack(spacing: 10) {
                    Text(updated, style: .time).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    Button("Refresh") { Task { await load(force: true) } }.buttonStyle(GhostButtonStyle())
                }
            }
            statusLine
            HStack(alignment: .top, spacing: 18) {
                board
                side.frame(width: 320)
            }
            .padding(.top, 10)
        }
        .padding(22)
        .task { await load() }
        .onReceive(refresh.autoconnect()) { t in
            now = t
            let interval = (live?.running ?? false) ? 5.0 : 60.0
            if t.timeIntervalSince(updated) >= interval { Task { await load() } }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            Text(live?.status ?? (loading ? "LOADING" : "NO SESSION"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 10).fill(statusColour.opacity(0.18)))
                .foregroundStyle(statusColour)
            if let live {
                Text([live.session.type, live.lap.map { "lap \($0)" }, live.running ? "live" : nil, live.weather?.summary]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            } else if let error = app.engine.f1.lastError {
                Text("Timing feed unreachable — \(error)").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var statusColour: Color {
        switch live?.status {
        case "GREEN": return Theme.success
        case "RED": return Theme.danger
        case "YELLOW", "DOUBLE YELLOW": return Theme.warning
        case "CHEQUERED FLAG": return Theme.accent
        default: return .secondary
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let live, !live.rows.isEmpty {
                HStack(spacing: 0) {
                    Text("P").frame(width: 28, alignment: .leading)
                    Text("DRIVER").frame(maxWidth: .infinity, alignment: .leading)
                    Text("GAP").frame(width: 84, alignment: .leading)
                    Text("INTERVAL").frame(width: 84, alignment: .leading)
                    Text("LAST").frame(width: 84, alignment: .leading)
                    Text("BEST").frame(width: 84, alignment: .leading)
                    Text("TYRE").frame(width: 56, alignment: .leading)
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(live.rows) { row in rowView(row) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loading ? "Loading the timing feed…" : "No session on track right now")
                        .font(.system(size: 14, weight: .semibold))
                    Text("The board fills in by itself when practice, qualifying or the race starts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .hudPanel()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(_ row: F1Row) -> some View {
        HStack(spacing: 0) {
            Text("\(row.position)").font(.system(size: 13, weight: .semibold, design: .monospaced)).frame(width: 28, alignment: .leading)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(teamColour(row.driver.colour)).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(row.driver.acronym)  \(row.driver.fullName)").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(row.driver.team).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.gap).frame(width: 84, alignment: .leading)
            Text(row.intervalText).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(row.last).frame(width: 84, alignment: .leading)
            Text(row.best).foregroundStyle(Theme.accent2).frame(width: 84, alignment: .leading)
            Text(row.tyre).foregroundStyle(tyreColour(row.compound)).frame(width: 56, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(highlight(row) ? Theme.accent : Theme.cardStroke)))
    }

    private func highlight(_ row: F1Row) -> Bool {
        let fav = app.settings.f1Favourite
        guard !fav.isEmpty else { return false }
        return row.driver.acronym.caseInsensitiveCompare(fav) == .orderedSame || row.driver.fullName.localizedCaseInsensitiveContains(fav)
    }

    private func teamColour(_ hex: String) -> Color {
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return .gray }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private func tyreColour(_ compound: String?) -> Color {
        switch compound?.uppercased() {
        case "SOFT": return Theme.danger
        case "MEDIUM": return Theme.warning
        case "HARD": return .primary
        case "INTERMEDIATE": return Theme.success
        case "WET": return Theme.accent
        default: return .secondary
        }
    }

    private var side: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let next {
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            SectionHeader(title: "NEXT UP")
                            Text(next.name).font(.system(size: 14, weight: .semibold))
                            Text("\(next.circuit) · \(next.locality), \(next.country)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(countdown(to: next.start))
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent).padding(.top, 4)
                            ForEach(next.sessions.indices, id: \.self) { i in
                                let s = next.sessions[i]
                                Text("\(s.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))  \(s.name)")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .hudPanel()
                }
                if let live, !live.messages.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "RACE CONTROL")
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(live.messages.prefix(10)) { m in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(m.time).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 36, alignment: .leading)
                                    Text(m.text).font(.system(size: 11.5)).foregroundStyle(flagColour(m.flag)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .hudPanel()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SectionHeader(title: showTeams ? "CONSTRUCTORS" : "DRIVERS")
                        Spacer()
                        Button(showTeams ? "Drivers" : "Teams") { showTeams.toggle() }.buttonStyle(GhostButtonStyle())
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach((showTeams ? teams : drivers).prefix(12)) { s in
                            HStack {
                                Text("\(s.position)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 20, alignment: .leading)
                                Text(showTeams ? s.name : "\(s.code)  \(s.name)").font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text("\(Int(s.points))").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .hudPanel()
                }
                Text("Live timing from the public OpenF1 feed; schedule and standings from the Jolpica/Ergast mirror. Unofficial — not affiliated with Formula 1.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func flagColour(_ flag: String?) -> Color {
        switch flag?.uppercased() {
        case "RED": return Theme.danger
        case "YELLOW", "DOUBLE YELLOW": return Theme.warning
        case "GREEN", "CLEAR": return Theme.success
        case "BLUE": return Theme.accent
        default: return .secondary
        }
    }

    private func countdown(to date: Date) -> String {
        let d = date.timeIntervalSince(now)
        if d <= 0 { return "under way" }
        if d >= 86400 { return "\(Int(d / 86400))d \(Int(d.truncatingRemainder(dividingBy: 86400) / 3600))h" }
        return String(format: "%02d:%02d:%02d", Int(d / 3600), Int(d.truncatingRemainder(dividingBy: 3600) / 60), Int(d.truncatingRemainder(dividingBy: 60)))
    }

    private func load(force: Bool = false) async {
        let service = app.engine.f1
        async let liveTask = service.live()
        async let nextTask = service.nextRace()
        async let driversTask = service.driverStandings()
        async let teamsTask = service.constructorStandings()
        let (l, n, d, t) = await (liveTask, nextTask, driversTask, teamsTask)
        live = l; next = n; drivers = d; teams = t
        updated = Date(); loading = false
    }
}
