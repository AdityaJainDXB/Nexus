import Foundation
import Network

/// Local-only HTTP/JSON API (127.0.0.1, bearer token in ~/Library/Application Support/Nexus/api.json, mode 0600).
/// Used by `nexusctl`, scripts, Shortcuts ("Get contents of URL") and inbound webhooks (POST /v1/events).
public final class APIServer {
    let engine: NexusEngine
    private var listener: NWListener?
    public private(set) var token: String = ""
    public private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "app.nexus.api")

    public struct ClientConfig: Codable { public var port: Int; public var token: String }

    public init(engine: NexusEngine) { self.engine = engine }

    public static func loadClientConfig() -> ClientConfig? {
        guard let data = try? Data(contentsOf: Paths.appSupport.appendingPathComponent("api.json")) else { return nil }
        return try? JSONDecoder().decode(ClientConfig.self, from: data)
    }

    public func start(port: Int) {
        stop()
        token = Self.loadClientConfig()?.token ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let url = Paths.appSupport.appendingPathComponent("api.json")
        let config = ClientConfig(port: port, token: token)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Publish credentials only once we actually own the port (a second instance must not clobber them).
                if let data = try? JSONEncoder().encode(config) {
                    try? data.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            case .failed(let error):
                NSLog("Nexus API could not listen on 127.0.0.1:\(port): \(error)")
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
        self.port = UInt16(port)
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) {
                Task { await self.respond(c, req) }
            } else if done || error != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func send(_ c: NWConnection, _ status: Int, _ obj: Any) {
        // NSJSONSerialization raises an ObjC exception (not a Swift error) on invalid values — validate first.
        let safe: Any = JSONSerialization.isValidJSONObject(obj) ? obj : ["error": "internal: response not serializable"]
        let status = JSONSerialization.isValidJSONObject(obj) ? status : 500
        let body = (try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 401 { head = head.replacingOccurrences(of: "Connection: close", with: "WWW-Authenticate: Bearer\r\nConnection: close") }
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func respond(_ c: NWConnection, _ r: HTTPRequest) async {
        guard r.headers["authorization"] == "Bearer \(token)" || r.query["token"] == token else {
            return send(c, 401, ["error": "missing or invalid token (see ~/Library/Application Support/Nexus/api.json)"])
        }
        let e = engine
        let parts = r.path.split(separator: "/").map(String.init)
        do {
            switch (r.method, parts) {
            case ("GET", ["v1", "status"]):
                let snap = e.monitor.snapshot
                send(c, 200, ["status": e.status.rawValue, "paused": e.paused, "files": e.store.fileCount(), "review": e.store.reviewCount(),
                              "rules": e.store.rules().count, "runningTasks": e.queue.runningCount, "insights": e.store.insights().count,
                              "diskFreeGB": Int(snap.diskFreeGB), "llm": await e.llm.providerName(),
                              "focus": e.focus.map { ["project": e.store.project(id: $0.projectId)?.name ?? "", "endsAt": ISO8601DateFormatter().string(from: $0.endsAt)] } ?? NSNull()])
            case ("POST", ["v1", "command"]):
                let text = r.json["text"] as? String ?? ""
                let plan = await e.plan(text)
                if (r.json["confirm"] as? Bool) == true || !plan.requiresConfirmation {
                    let res = await e.execute(plan)
                    send(c, 200, ["executed": true, "message": res.message, "details": res.details, "files": res.files.prefix(200).map(\.path), "batchId": res.batchId ?? ""])
                } else {
                    send(c, 200, ["executed": false, "understood": plan.understood, "requiresConfirmation": true,
                                  "steps": plan.steps.map { ["intent": $0.step.intent.label, "text": $0.step.text, "note": $0.note ?? "", "preview": $0.preview] }])
                }
            case ("GET", ["v1", "rules"]):
                send(c, 200, e.store.rules().map(Self.ruleJSON))
            case ("POST", ["v1", "rules"]):
                let result = await e.compileRule(r.json["text"] as? String ?? "")
                guard var rule = result.rule else { return send(c, 400, ["error": "could not compile", "warnings": result.warnings]) }
                if (r.json["dryRun"] as? Bool) == true { return send(c, 200, ["rule": Self.ruleJSON(rule), "explanation": result.explanation, "warnings": result.warnings]) }
                rule.enabled = (r.json["enabled"] as? Bool) ?? true
                e.store.saveRule(rule)
                send(c, 201, ["rule": Self.ruleJSON(rule), "explanation": result.explanation, "warnings": result.warnings])
            case ("POST", let p) where p.count == 4 && p[1] == "rules" && p[3] == "run":
                guard let rule = e.store.rule(id: p[2]) ?? e.store.rules().first(where: { $0.name.lowercased().contains(p[2].lowercased()) }) else { return send(c, 404, ["error": "rule not found"]) }
                let job = e.queue.enqueue(Job(name: "Run rule: \(rule.name)", kind: .file, priority: .high, spec: JobSpec(operation: .runRule, ruleId: rule.id)))
                send(c, 200, ["jobId": job.id])
            case ("DELETE", let p) where p.count == 3 && p[1] == "rules":
                e.store.deleteRule(p[2]); send(c, 200, ["deleted": p[2]])
            case ("POST", ["v1", "simulate"]):
                guard let path = (r.json["path"] as? String).map(Paths.expand), let report = e.simulate(path: path) else { return send(c, 400, ["error": "path not readable"]) }
                send(c, 200, ["file": path, "docType": report.file.docType ?? "", "topics": report.file.topics, "conflicts": report.conflicts,
                              "rules": report.evaluations.map { ["rule": $0.rule.name, "fired": $0.fired, "triggerMatched": $0.triggerMatched, "blockedByStop": $0.skippedByStop,
                                                                  "conditions": $0.conditionResults.map { ["condition": $0.condition.summary, "passed": $0.passed, "actual": $0.actual] },
                                                                  "actions": $0.plannedActions] }])
            case ("GET", ["v1", "tasks"]):
                send(c, 200, e.store.jobs(limit: Int(r.query["limit"] ?? "50") ?? 50).map { j in
                    ["id": j.id, "name": j.name, "kind": j.kind.rawValue, "status": j.status.rawValue, "priority": j.priority.label,
                     "created": ISO8601DateFormatter().string(from: j.createdAt), "result": j.resultSummary ?? "", "error": j.error ?? "", "log": Array(j.log.suffix(20))] as [String: Any]
                })
            case ("POST", ["v1", "tasks"]):
                guard let op = (r.json["operation"] as? String).flatMap(JobOperation.init(rawValue:)) else { return send(c, 400, ["error": "operation required", "valid": JobOperation.allCases.map(\.rawValue)]) }
                let spec = JobSpec(operation: op, path: r.json["path"] as? String, command: r.json["command"] as? String, params: r.json["params"] as? [String: String] ?? [:])
                let job = e.queue.enqueue(Job(name: r.json["name"] as? String ?? op.rawValue, kind: .system, priority: .high, spec: spec))
                send(c, 201, ["jobId": job.id])
            case ("POST", let p) where p.count == 4 && p[1] == "tasks" && p[3] == "retry":
                e.queue.retry(p[2]); send(c, 200, ["retried": p[2]])
            case ("GET", ["v1", "schedule"]):
                send(c, 200, e.scheduler.upcoming().map { ["at": ISO8601DateFormatter().string(from: $0.date), "name": $0.name] })
            case ("GET", ["v1", "insights"]):
                send(c, 200, e.store.insights().map { ["id": $0.id, "kind": $0.kind.rawValue, "title": $0.title, "detail": $0.detail, "severity": $0.severity.rawValue, "command": $0.command ?? ""] })
            case ("GET", ["v1", "search"]):
                let q = r.query["q"] ?? ""
                let files = e.resolve(CommandParser(compiler: NLRuleCompiler()).query(q), previous: [])
                send(c, 200, files.prefix(200).map { ["path": $0.path, "docType": $0.docType ?? "", "tags": $0.tags, "topics": $0.topics, "project": $0.projectId ?? ""] })
            case ("GET", ["v1", "projects"]):
                send(c, 200, e.store.projects().map { p in
                    let s = e.store.projectStats(p.id)
                    return ["id": p.id, "name": p.name, "files": s.count, "bytes": s.size, "deadline": p.deadline.map { ISO8601DateFormatter().string(from: $0) } ?? "", "keywords": p.keywords] as [String: Any]
                })
            case ("GET", ["v1", "report"]):
                send(c, 200, ["markdown": e.reports.markdown(type: r.query["type"] ?? "weekly")])
            case ("GET", ["v1", "review"]):
                send(c, 200, e.store.reviewItems().map { ["id": $0.id, "path": $0.path, "destination": $0.suggestedDestination ?? "", "tags": $0.suggestedTags,
                                                          "confidence": $0.confidence, "reasons": $0.reasons, "alternatives": $0.alternatives] as [String: Any] })
            case ("POST", let p) where p.count == 4 && p[1] == "review" && (p[3] == "approve" || p[3] == "reject"):
                guard let item = e.store.reviewItems().first(where: { $0.id == p[2] }) else { return send(c, 404, ["error": "review item not found"]) }
                if p[3] == "approve" {
                    await e.approve(item, destination: (r.json["destination"] as? String).map(Paths.expand), tags: r.json["tags"] as? [String])
                } else { e.reject(item) }
                send(c, 200, [p[3]: item.id])
            case ("GET", ["v1", "files"]):
                let path = r.query["path"].map(Paths.expand)
                if let path, let f = e.store.file(path: path) {
                    send(c, 200, ["id": f.id, "path": f.path, "kind": f.kind.rawValue, "docType": f.docType ?? "", "topics": f.topics, "tags": f.tags,
                                  "project": f.projectId ?? "", "status": f.status.rawValue, "confidence": f.confidence,
                                  "entities": f.entities.map { "\($0.kind.rawValue):\($0.value)" }, "suggestions": e.debugSuggestions(for: f)])
                } else { send(c, 404, ["error": "not indexed"]) }
            case ("GET", ["v1", "events"]):
                send(c, 200, e.store.events(limit: Int(r.query["limit"] ?? "50") ?? 50).map { ["kind": $0.kind.rawValue, "message": $0.message, "undone": $0.undone, "batch": $0.batchId ?? ""] as [String: Any] })
            case ("POST", ["v1", "settings"]):
                // Partial settings update (testing & automation): merge JSON keys into current settings
                var current = (try? JSONSerialization.jsonObject(with: JSON.encoder.encode(e.settings))) as? [String: Any] ?? [:]
                for (k, v) in r.json { current[k] = v }
                guard let data = try? JSONSerialization.data(withJSONObject: current), let new = try? JSON.decoder.decode(NexusSettings.self, from: data) else { return send(c, 400, ["error": "invalid settings"]) }
                e.updateSettings(new)
                send(c, 200, ["ok": true])
            case ("POST", ["v1", "projects"]):
                var proj = Project(name: r.json["name"] as? String ?? "Untitled", folders: r.json["folders"] as? [String] ?? [], keywords: r.json["keywords"] as? [String] ?? [], tags: r.json["tags"] as? [String] ?? [])
                if let days = r.json["dueInDays"] as? Double { proj.deadline = Date().addingTimeInterval(days * 86400) }
                e.store.saveProject(proj)
                send(c, 201, ["id": proj.id])
            case ("POST", ["v1", "undo"]):
                send(c, 200, ["undone": e.undoLast()])
            case ("POST", ["v1", "pause"]): e.setPaused(true); send(c, 200, ["paused": true])
            case ("POST", ["v1", "resume"]): e.setPaused(false); send(c, 200, ["paused": false])
            case ("POST", ["v1", "events"]):
                // Custom inbound event → connector rules ("connectorEvent": "custom.<name>")
                let name = r.json["name"] as? String ?? "custom"
                var payload = (r.json["payload"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                payload["connectorEvent"] = name.contains(".") ? name : "custom.\(name)"
                payload["source"] = payload["source"] ?? "API"
                e.bus.post(.connector(name: "api", payload: payload))
                send(c, 200, ["accepted": payload["connectorEvent"] ?? name])
            case ("POST", ["v1", "ingest"]):
                guard let path = (r.json["path"] as? String).map(Paths.expand) else { return send(c, 400, ["error": "path required"]) }
                e.enqueueIngest(path, trigger: .manual)
                send(c, 200, ["queued": path])
            default:
                send(c, 404, ["error": "unknown endpoint \(r.method) \(r.path)"])
            }
        }
    }

    static func ruleJSON(_ r: Rule) -> [String: Any] {
        ["id": r.id, "name": r.name, "enabled": r.enabled, "summary": r.summary, "hits": r.hitCount, "priority": r.priority,
         "lastTriggered": r.lastTriggeredAt.map { ISO8601DateFormatter().string(from: $0) } ?? "", "naturalLanguage": r.naturalLanguage ?? ""]
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)), let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        method = String(first[0])
        let target = String(first[1])
        var hs: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            hs[l[..<i].lowercased()] = l[l.index(after: i)...].trimmed
        }
        headers = hs
        let length = Int(hs["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
        let comps = URLComponents(string: target)
        path = comps?.path ?? target
        query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}
