import SwiftUI

/// Mirrors the Mac's state for the UI; every call goes through the encrypted RemoteClient.
@MainActor
final class RemoteModel: ObservableObject {
    weak var client: RemoteClient?

    @Published var status: [String: Any] = [:]
    @Published var review: [[String: Any]] = []
    @Published var insights: [[String: Any]] = []
    @Published var projects: [[String: Any]] = []
    @Published var tasks: [[String: Any]] = []
    @Published var events: [[String: Any]] = []
    @Published var error: String?
    @Published var loading = false

    var files: Int { status["files"] as? Int ?? 0 }
    var paused: Bool { status["paused"] as? Bool ?? false }
    var stateText: String { paused ? "Paused" : (status["status"] as? String ?? "offline").capitalized }
    var focusProject: String? { (status["focus"] as? [String: Any])?["project"] as? String }

    func call(_ m: String, _ p: String, _ body: [String: Any]? = nil) async -> Any? {
        guard let client else { return nil }
        do { let r = try await client.call(m, p, body: body); error = nil; return r }
        catch { self.error = error.localizedDescription; return nil }
    }

    func refreshAll() async {
        loading = true
        async let s = call("GET", "/v1/status")
        async let r = call("GET", "/v1/review")
        async let i = call("GET", "/v1/insights")
        async let p = call("GET", "/v1/projects")
        async let t = call("GET", "/v1/tasks?limit=25")
        async let e = call("GET", "/v1/events?limit=40")
        status = await s as? [String: Any] ?? status
        review = await r as? [[String: Any]] ?? review
        insights = await i as? [[String: Any]] ?? insights
        projects = await p as? [[String: Any]] ?? projects
        tasks = await t as? [[String: Any]] ?? tasks
        events = (await e as? [[String: Any]] ?? events).filter { ($0["kind"] as? String) != "fileIndexed" && ($0["kind"] as? String) != "jobStarted" }
        loading = false
    }

    struct Plan { var steps: [[String: Any]]; var needsConfirm: Bool; var message: String?; var files: [String] }

    /// Plans a command on the Mac; mutating plans come back as a preview to confirm.
    func command(_ text: String, confirm: Bool) async -> Plan? {
        guard let r = await call("POST", "/v1/command", ["text": text, "confirm": confirm]) as? [String: Any] else { return nil }
        if (r["executed"] as? Bool) == true {
            Task { await refreshAll() }
            return Plan(steps: [], needsConfirm: false, message: r["message"] as? String, files: r["files"] as? [String] ?? [])
        }
        return Plan(steps: r["steps"] as? [[String: Any]] ?? [], needsConfirm: true, message: nil, files: [])
    }

    func approve(_ id: String) async { _ = await call("POST", "/v1/review/\(id)/approve", [:]); review.removeAll { ($0["id"] as? String) == id }; Task { await refreshAll() } }
    func reject(_ id: String) async { _ = await call("POST", "/v1/review/\(id)/reject", [:]); review.removeAll { ($0["id"] as? String) == id } }
    func setPaused(_ p: Bool) async { _ = await call("POST", p ? "/v1/pause" : "/v1/resume"); await refreshAll() }
    func undo() async -> String { let r = await call("POST", "/v1/undo") as? [String: Any]; await refreshAll(); return "Undid \(r?["undone"] ?? 0) operation(s)" }
}
