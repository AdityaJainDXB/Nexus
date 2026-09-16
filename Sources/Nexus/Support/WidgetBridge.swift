import Foundation
import WidgetKit
import NexusCore

/// Publishes a small read-only JSON snapshot for the WidgetKit extension and asks WidgetKit to refresh.
@MainActor
enum WidgetBridge {
    private struct Item: Codable { var title: String; var detail: String; var command: String? }
    private struct Snapshot: Codable {
        var status: String; var paused: Bool; var filesIndexed: Int; var handledToday: Int; var reviewCount: Int; var insightCount: Int
        var automationsWeek: Int; var minutesSaved: Int; var focusProject: String?; var focusEnds: Date?; var model: String
        var insights: [Item]; var upcoming: [Item]; var recent: [Item]; var updatedAt: Date
    }

    private static var lastWrite = Date.distantPast
    private static var pending = false

    /// Real ~/Library/Application Support/Nexus/widget (independent of NEXUS_HOME so the widget can always find it).
    static var directory: URL {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let u = URL(fileURLWithPath: home + "/Library/Application Support/Nexus/widget")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func publish(_ app: AppState) {
        // at most every 20 s; coalesce bursts
        let wait = 20 - Date().timeIntervalSince(lastWrite)
        guard wait <= 0 else {
            if !pending { pending = true; DispatchQueue.main.asyncAfter(deadline: .now() + wait) { pending = false; publish(app) } }
            return
        }
        lastWrite = Date()
        let store = app.engine.store
        let week = Date().addingTimeInterval(-7 * 86400)
        let hits = store.ruleHits(since: week)
        let saved = app.rules.reduce(0) { $0 + (hits[$1.id] ?? 0) * $1.estimatedSecondsSaved } / 60
        let handled = app.events.filter { Calendar.current.isDateInToday($0.timestamp) && [.fileMoved, .ruleFired, .fileTagged].contains($0.kind) }.count
        let snap = Snapshot(
            status: app.status.rawValue, paused: app.paused, filesIndexed: app.fileCount, handledToday: handled,
            reviewCount: app.reviewItems.count, insightCount: app.insights.count, automationsWeek: hits.values.reduce(0, +), minutesSaved: saved,
            focusProject: app.focus.flatMap { f in app.projects.first { $0.id == f.projectId }?.name }, focusEnds: app.focus?.endsAt, model: app.llmName,
            insights: app.insights.prefix(4).map { Item(title: $0.title, detail: $0.detail.components(separatedBy: "\n").first ?? "", command: $0.command) },
            upcoming: app.engine.scheduler.upcoming(limit: 3).map { Item(title: $0.name, detail: DateFormatter.localizedString(from: $0.date, dateStyle: .short, timeStyle: .short), command: nil) },
            recent: app.events.filter { ![.fileIndexed, .jobStarted].contains($0.kind) }.prefix(5).map { Item(title: $0.message, detail: relativeTime($0.timestamp), command: nil) },
            updatedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(snap) else { return }
        try? data.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// nexus://palette · nexus://voice · nexus://review · nexus://insights · nexus://run?cmd=…
    static func handle(_ url: URL) {
        guard url.scheme == "nexus" else { return }
        let app = AppState.shared
        switch url.host ?? "" {
        case "palette": PaletteController.shared.show()
        case "voice": PaletteController.shared.show(listen: true)
        case "run":
            let cmd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cmd" }?.value ?? ""
            PaletteController.shared.show(prefill: cmd)
            // Plans that change files still stop at the preview step
            if !cmd.isEmpty { PaletteController.shared.model.submit() }
        case let host: app.openMainWindow(SidebarItem.from(host) ?? .today)
        }
    }
}
