import Foundation
import NexusCore

// nexusctl — command-line client for the Nexus local API.

let usage = """
nexusctl — control Nexus from the terminal

USAGE
  nexusctl status
  nexusctl run "<natural language command>" [--yes]     plan (and with --yes, execute) a command
  nexusctl rules                                          list rules
  nexusctl rule add "<natural language rule>" [--dry]     compile & save a rule (--dry: just show it)
  nexusctl rule run <id|name>                             run a rule now
  nexusctl rule rm <id>                                   delete a rule
  nexusctl compile "<rule text>"                          offline: show how a sentence compiles (no app needed)
  nexusctl simulate <path>                                which rules would fire for a file, and why
  nexusctl search "<query>"                               semantic + full-text search
  nexusctl tasks                                          recent tasks
  nexusctl task <operation> [path] [--command "..."]     enqueue a task (e.g. sortFolder ~/Downloads)
  nexusctl schedule                                       upcoming scheduled runs
  nexusctl insights                                       current suggestions
  nexusctl projects                                       projects with stats
  nexusctl report [weekly|monthly|daily|storage]          print a Markdown report
  nexusctl event <name> ['{"json":"payload"}']            fire a custom connector event
  nexusctl ingest <path>                                  process a file now
  nexusctl undo | pause | resume
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

// Offline commands
if cmd == "compile" {
    guard let text = args.first else { die("usage: nexusctl compile \"<rule>\"") }
    let r = NLRuleCompiler().compile(text)
    guard let rule = r.rule else { die("✗ " + r.warnings.joined(separator: "\n")) }
    print("✓ \(rule.name)\n  \(rule.summary)")
    r.explanation.forEach { print("  · \($0)") }
    r.warnings.forEach { print("  ⚠︎ \($0)") }
    exit(0)
}
if cmd == "ai-test" {
    // Offline check of the bundled local model (no app needed)
    let prompt = args.first ?? "Rewrite as a Nexus command: put my physics homework pdfs into the physics folder"
    let sem = DispatchSemaphore(value: 0)
    Task {
        let server = LocalModelServer.shared
        print("runtime:", LocalModelServer.runtimeURL?.path ?? "missing")
        print("model:  ", server.modelURL?.lastPathComponent ?? "missing")
        let t0 = Date()
        do {
            let out = try await server.complete(system: "You are Nexus, a concise macOS file assistant.", prompt: prompt, maxTokens: 120)
            print(String(format: "reply (%.1fs incl. load):", Date().timeIntervalSince(t0)), out)
            let t1 = Date()
            let out2 = try await server.complete(system: "Reply with ONLY minified JSON.", prompt: "Extract {\"due\":date,\"amount\":number} from: INVOICE #2041 Amount due $420.00 Due date 2026-10-01", maxTokens: 60)
            print(String(format: "json  (%.1fs warm):", Date().timeIntervalSince(t1)), out2)
        } catch { print("error:", error) }
        server.stop()
        sem.signal()
    }
    sem.wait()
    exit(0)
}
if cmd == "discover" {
    // Offline: show the folder structure Nexus would learn from and where built-in categories would route
    let cands = FolderDiscovery.candidates()
    for c in cands { print("\(c.recommended ? "●" : "○") \(c.label): \(Paths.abbreviate(c.path))  [\(c.subfolders.prefix(6).joined(separator: ", "))\(c.subfolders.count > 6 ? ", …" : "")]") }
    let roots = cands.filter(\.recommended).map(\.path)
    print("\nCategory routing:")
    for name in ["Invoices", "Lab reports", "Syllabi", "Assignments", "Essays", "Contracts", "3D models", "Screenshots", "Code snippets"] {
        print("  \(name) → \(FolderDiscovery.existingFolder(for: name, roots: roots).map(Paths.abbreviate) ?? "(new folder in ~/Documents)")")
    }
    exit(0)
}
if cmd == "remote-test" {
    // Protocol self-test for Nexus Remote: pair with a code, then send encrypted requests (and a replay).
    import_remote_test(args)
    exit(0)
}
if cmd == "help" || cmd == "--help" || cmd == "-h" { print(usage); exit(0) }

guard let config = APIServer.loadClientConfig() else {
    die("Nexus API config not found. Start Nexus.app and enable the API in Developer settings.")
}

func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> Any {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)\(path)")!)
    req.httpMethod = method
    req.timeoutInterval = 600
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    if let body {
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    var result: Any = [:]
    var failure: String?
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err { failure = "Cannot reach Nexus on port \(config.port): \(err.localizedDescription)"; return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        if code >= 400 { failure = "HTTP \(code): \((obj as? [String: Any])?["error"] ?? obj)"; return }
        result = obj
    }.resume()
    sem.wait()
    if let failure { die(failure) }
    return result
}

func printJSON(_ obj: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), let s = String(data: d, encoding: .utf8) { print(s) }
}

func rows(_ obj: Any) -> [[String: Any]] { obj as? [[String: Any]] ?? [] }

switch cmd {
case "status":
    let s = request("GET", "/v1/status") as? [String: Any] ?? [:]
    print("""
    Nexus: \(s["status"] ?? "?")\((s["paused"] as? Bool) == true ? " (paused)" : "")
      files indexed: \(s["files"] ?? 0)   review queue: \(s["review"] ?? 0)   rules: \(s["rules"] ?? 0)
      running tasks: \(s["runningTasks"] ?? 0)   insights: \(s["insights"] ?? 0)   disk free: \(s["diskFreeGB"] ?? "?") GB
      language model: \(s["llm"] ?? "?")
    """)
case "run":
    let yes = flag("--yes") || flag("-y")
    guard let text = args.first else { die("usage: nexusctl run \"<command>\" [--yes]") }
    let r = request("POST", "/v1/command", ["text": text, "confirm": yes]) as? [String: Any] ?? [:]
    if (r["executed"] as? Bool) == true {
        print(r["message"] ?? "")
        (r["details"] as? [String])?.forEach { print("  ⚠︎ \($0)") }
        let files = r["files"] as? [String] ?? []
        files.prefix(50).forEach { print("  \($0)") }
        if files.count > 50 { print("  … \(files.count - 50) more") }
    } else {
        print("Preview (nothing changed yet):")
        for s in rows(r["steps"] ?? []) {
            print("• \(s["intent"] ?? ""): \(s["note"] ?? "")")
            (s["preview"] as? [String])?.prefix(10).forEach { print("    \($0)") }
        }
        print("\nRe-run with --yes to execute.")
    }
case "rules":
    for r in rows(request("GET", "/v1/rules")) {
        print("\((r["enabled"] as? Bool) == true ? "●" : "○") \(r["name"] ?? "")  [\(r["hits"] ?? 0) hits]  id=\(r["id"] ?? "")")
        print("    \(r["summary"] ?? "")")
    }
case "rule":
    guard let sub = args.first else { die("usage: nexusctl rule add|run|rm …") }
    args.removeFirst()
    switch sub {
    case "add":
        let dry = flag("--dry")
        guard let text = args.first else { die("usage: nexusctl rule add \"<rule>\"") }
        let r = request("POST", "/v1/rules", ["text": text, "dryRun": dry]) as? [String: Any] ?? [:]
        let rule = r["rule"] as? [String: Any] ?? [:]
        print("\(dry ? "Would create" : "Created"): \(rule["name"] ?? "")\n  \(rule["summary"] ?? "")")
        (r["warnings"] as? [String])?.forEach { print("  ⚠︎ \($0)") }
    case "run":
        guard let id = args.first else { die("usage: nexusctl rule run <id|name>") }
        let r = request("POST", "/v1/rules/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/run") as? [String: Any] ?? [:]
        print("Queued job \(r["jobId"] ?? "")")
    case "rm":
        guard let id = args.first else { die("usage: nexusctl rule rm <id>") }
        _ = request("DELETE", "/v1/rules/\(id)")
        print("Deleted \(id)")
    default: die(usage)
    }
case "simulate":
    guard let path = args.first else { die("usage: nexusctl simulate <path>") }
    let r = request("POST", "/v1/simulate", ["path": (path as NSString).expandingTildeInPath]) as? [String: Any] ?? [:]
    print("\(r["file"] ?? "") — \(r["docType"] ?? "") \((r["topics"] as? [String])?.joined(separator: ", ") ?? "")")
    for e in rows(r["rules"] ?? []) {
        let fired = (e["fired"] as? Bool) == true
        print("\(fired ? "✓" : "·") \(e["rule"] ?? "")\((e["blockedByStop"] as? Bool) == true ? " (blocked by stop)" : "")")
        for c in rows(e["conditions"] ?? []) { print("    \((c["passed"] as? Bool) == true ? "✓" : "✗") \(c["condition"] ?? "")  [actual: \(c["actual"] ?? "")]") }
        if fired { (e["actions"] as? [String])?.forEach { print("    → \($0)") } }
    }
    (r["conflicts"] as? [String])?.forEach { print("⚠︎ \($0)") }
case "search":
    let q = args.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    for f in rows(request("GET", "/v1/search?q=\(q)")) { print("\(f["path"] ?? "")  \(f["docType"] ?? "")  \((f["tags"] as? [String])?.map { "#\($0)" }.joined(separator: " ") ?? "")") }
case "tasks":
    for j in rows(request("GET", "/v1/tasks?limit=30")) {
        print("[\(j["status"] ?? "")] \(j["name"] ?? "")  \(j["result"] ?? "")\((j["error"] as? String).flatMap { $0.isEmpty ? nil : "  ✗ \($0)" } ?? "")")
    }
case "task":
    guard let op = args.first else { die("usage: nexusctl task <operation> [path]") }
    var command: String?
    if let i = args.firstIndex(of: "--command"), i + 1 < args.count { command = args[i + 1]; args.removeSubrange(i...(i + 1)) }
    var body: [String: Any] = ["operation": op]
    if args.count > 1 { body["path"] = (args[1] as NSString).expandingTildeInPath }
    if let command { body["command"] = command }
    let r = request("POST", "/v1/tasks", body) as? [String: Any] ?? [:]
    print("Queued job \(r["jobId"] ?? "")")
case "schedule":
    for s in rows(request("GET", "/v1/schedule")) { print("\(s["at"] ?? "")  \(s["name"] ?? "")") }
case "insights":
    for i in rows(request("GET", "/v1/insights")) {
        print("• \(i["title"] ?? "")")
        if let c = i["command"] as? String, !c.isEmpty { print("    fix: nexusctl run \"\(c)\" --yes") }
    }
case "projects":
    for p in rows(request("GET", "/v1/projects")) {
        let bytes = (p["bytes"] as? NSNumber)?.int64Value ?? 0
        print("\(p["name"] ?? "")  \(p["files"] ?? 0) files  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))  \(p["deadline"] as? String ?? "")")
    }
case "report":
    let r = request("GET", "/v1/report?type=\(args.first ?? "weekly")") as? [String: Any] ?? [:]
    print(r["markdown"] ?? "")
case "event":
    guard let name = args.first else { die("usage: nexusctl event <name> [json]") }
    let payload = args.count > 1 ? ((try? JSONSerialization.jsonObject(with: Data(args[1].utf8))) as? [String: Any] ?? [:]) : [:]
    printJSON(request("POST", "/v1/events", ["name": name, "payload": payload]))
case "ingest":
    guard let path = args.first else { die("usage: nexusctl ingest <path>") }
    printJSON(request("POST", "/v1/ingest", ["path": (path as NSString).expandingTildeInPath]))
case "undo":
    let r = request("POST", "/v1/undo") as? [String: Any] ?? [:]
    print("Undid \(r["undone"] ?? 0) operation(s)")
case "pause": _ = request("POST", "/v1/pause"); print("Automations paused")
case "resume": _ = request("POST", "/v1/resume"); print("Automations resumed")
default:
    print(usage)
    exit(1)
}

import CryptoKit

func import_remote_test(_ args: [String]) {
    let host = args.first ?? "127.0.0.1"
    let code = args.count > 1 ? args[1] : ""
    let base = "http://\(host):\(RemoteCrypto.defaultPort)"
    func http(_ method: String, _ path: String, _ body: Data? = nil, headers: [String: String] = [:]) -> (Int, Data) {
        var req = URLRequest(url: URL(string: base + path)!); req.httpMethod = method; req.httpBody = body; req.timeoutInterval = 60
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let sem = DispatchSemaphore(value: 0); var out = (0, Data())
        URLSession.shared.dataTask(with: req) { d, r, _ in out = ((r as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data()); sem.signal() }.resume(); sem.wait()
        return out
    }
    let (hc, hd) = http("GET", "/hello")
    guard hc == 200, let hello = try? JSONSerialization.jsonObject(with: hd) as? [String: Any], let saltB64 = hello["salt"] as? String, let salt = Data(base64Encoded: saltB64) else { print("✗ hello failed \(hc)"); return }
    print("✓ hello: \(hello["name"] ?? "") pairingOpen=\(hello["pairingOpen"] ?? false)")
    // wrong code first
    let wrong = RemoteCrypto.pairingKey(code: "000000" == code ? "111111" : "000000", salt: salt)
    let (wc, _) = http("POST", "/pair", try! RemoteCrypto.seal(["deviceName": "Attacker"], key: wrong))
    print(wc == 401 ? "✓ wrong code rejected (401)" : "✗ wrong code not rejected: \(wc)")
    let pk = RemoteCrypto.pairingKey(code: code, salt: salt)
    let (pc, pd) = http("POST", "/pair", try! RemoteCrypto.seal(["deviceName": "Test iPhone"], key: pk))
    guard pc == 200, let paired = try? RemoteCrypto.open(pd, key: pk), let id = paired["deviceId"] as? String, let kb = paired["deviceKey"] as? String else { print("✗ pairing failed \(pc) \(String(data: pd, encoding: .utf8) ?? "")"); return }
    print("✓ paired as \(id.prefix(8))… with \(paired["macName"] ?? "")")
    let key = SymmetricKey(data: Data(base64Encoded: kb)!)
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, replay: Data? = nil) -> (Int, Any?, Data) {
        var env: [String: Any] = ["method": method, "path": path, "ts": Date().timeIntervalSince1970, "nonce": UUID().uuidString]
        if let body { env["body"] = body }
        let sealed = replay ?? (try! RemoteCrypto.seal(env, key: key))
        let (sc, sd) = http("POST", "/r", sealed, headers: ["X-Nexus-Device": id])
        guard sc == 200, let msg = try? RemoteCrypto.open(sd, key: key) else { return (sc, nil, sealed) }
        return (msg["status"] as? Int ?? 0, msg["body"], sealed)
    }
    let (s1, b1, sealed1) = call("GET", "/v1/status")
    print(s1 == 200 ? "✓ encrypted status: \((b1 as? [String: Any])?["status"] ?? "?") files=\((b1 as? [String: Any])?["files"] ?? "?")" : "✗ status \(s1)")
    let (s2, _, _) = call("GET", "/v1/status", replay: sealed1)
    print(s2 == 401 ? "✓ replayed request rejected" : "✗ replay accepted (\(s2))")
    let (s3, b3, _) = call("POST", "/v1/command", ["text": "brief me", "confirm": true])
    print(s3 == 200 ? "✓ remote command: \(((b3 as? [String: Any])?["message"] as? String ?? "").prefix(90))" : "✗ command \(s3)")
    let (s4, b4, _) = call("GET", "/v1/review")
    print(s4 == 200 ? "✓ review list: \((b4 as? [Any])?.count ?? 0) items" : "✗ review \(s4)")
    var tampered = Data(base64Encoded: sealed1)!; tampered[tampered.count - 1] ^= 0xFF
    let (s5, _) = http("POST", "/r", tampered.base64EncodedData(), headers: ["X-Nexus-Device": id])
    print(s5 != 200 ? "✓ tampered ciphertext rejected (\(s5))" : "✗ tampered accepted")
}
