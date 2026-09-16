import Foundation
import Darwin
#if canImport(FoundationModels)
import FoundationModels
#endif

public protocol LLMProvider {
    var name: String { get }
    func isAvailable() async -> Bool
    func complete(system: String, prompt: String) async throws -> String
}

public struct LLMError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
public final class AppleIntelligenceProvider: LLMProvider {
    public let name = "Apple Intelligence (on-device)"
    public init() {}
    public func isAvailable() async -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    public func complete(system: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(to: String(prompt.prefix(9000)))
        return response.content
    }
}
#endif

public final class OllamaProvider: LLMProvider {
    public var name: String { "Ollama · \(model)" }
    let baseURL: String
    let model: String
    public init(baseURL: String, model: String) { self.baseURL = baseURL; self.model = model }

    public func isAvailable() async -> Bool {
        guard let url = URL(string: baseURL + "/api/tags") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
    }

    public func complete(system: String, prompt: String) async throws -> String {
        guard let url = URL(string: baseURL + "/api/generate") else { throw LLMError("bad Ollama URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "system": system, "prompt": String(prompt.prefix(24_000)),
                                                                   "stream": false, "options": ["temperature": 0.2]])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["response"] as? String else {
            throw LLMError("unexpected Ollama response")
        }
        return text
    }
}

/// Picks the best available local model according to settings; everything degrades gracefully to heuristics.
public final class LLMRouter {
    public var settings: NexusSettings
    private var cached: (provider: LLMProvider?, checkedAt: Date)?

    public init(settings: NexusSettings) { self.settings = settings }

    public func invalidate() { cached = nil }

    public func provider() async -> LLMProvider? {
        if let c = cached, Date().timeIntervalSince(c.checkedAt) < 300 { return c.provider }
        var candidates: [LLMProvider] = []
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), [.auto, .appleIntelligence].contains(settings.llmProvider) {
            candidates.append(AppleIntelligenceProvider())
        }
        #endif
        LocalModelServer.shared.preferredModelPath = settings.localModelPath
        if [.auto, .bundled].contains(settings.llmProvider) {
            candidates.append(BundledModelProvider())
        }
        if [.auto, .ollama].contains(settings.llmProvider) {
            candidates.append(OllamaProvider(baseURL: settings.ollamaURL, model: settings.ollamaModel))
        }
        var chosen: LLMProvider?
        for c in candidates where await c.isAvailable() { chosen = c; break }
        cached = (chosen, Date())
        return chosen
    }

    public func providerName() async -> String { await provider()?.name ?? "Heuristics (no local LLM)" }

    public func summarize(_ text: String, context: String = "file") async -> String {
        guard !text.trimmed.isEmpty else { return "No readable content." }
        if let p = await provider() {
            let sys = "You summarize a user's local \(context) for a desktop assistant. Reply with 2-4 concise sentences, no preamble."
            if let r = try? await p.complete(system: sys, prompt: String(text.prefix(8000))), !r.trimmed.isEmpty { return r.trimmed }
        }
        return ExtractiveSummarizer.summarize(text)
    }

    /// Asks the model for strict JSON and decodes it. Returns nil when no model or invalid output.
    public func json<T: Decodable>(_ type: T.Type, system: String, prompt: String) async -> T? {
        guard let p = await provider(), let raw = try? await p.complete(system: system + "\nRespond with ONLY valid minified JSON, no markdown.", prompt: prompt) else { return nil }
        var s = raw.trimmed
        if let start = s.firstIndex(where: { $0 == "{" || $0 == "[" }), let end = s.lastIndex(where: { $0 == "}" || $0 == "]" }) {
            s = String(s[start...end])
        }
        return try? JSONDecoder().decode(T.self, from: Data(s.utf8))
    }
}

// MARK: - Bundled offline model (llama.cpp server + GGUF shipped inside Nexus.app)

/// Runs a local llama.cpp server on demand against a GGUF model that ships with Nexus (or one the user adds).
/// Nothing leaves the Mac; the server binds to 127.0.0.1 on a random port and shuts down when idle.
public final class LocalModelServer {
    public static let shared = LocalModelServer()

    private var process: Process?
    private var port: Int = 0
    private var lastUse = Date()
    private var idleTimer: DispatchSourceTimer?
    private let lock = NSLock()
    public var idleMinutes: Double = 10
    public var preferredModelPath: String = ""

    /// llama-server binary: inside the app bundle, or NEXUS_LLAMA_DIR / Vendor for development.
    public static var runtimeURL: URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NEXUS_LLAMA_DIR"] { candidates.append(URL(fileURLWithPath: env).appendingPathComponent("llama-server")) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama/llama-server"))
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for up in 0..<6 {
            var base = exeDir
            for _ in 0..<up { base.deleteLastPathComponent() }
            if let items = try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Vendor/llama").path),
               let dir = items.first(where: { $0.hasPrefix("llama-b") }) {
                candidates.append(base.appendingPathComponent("Vendor/llama/\(dir)/llama-server"))
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var userModelsDir: URL {
        let u = Paths.appSupport.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// All GGUF models found (bundled first, then user-added).
    public static func availableModels() -> [URL] {
        var dirs = [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Models"), userModelsDir]
        if let rt = runtimeURL { dirs.append(rt.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")) }
        var out: [URL] = []
        for d in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where name.lowercased().hasSuffix(".gguf") {
                let u = d.appendingPathComponent(name).resolvingSymlinksInPath()
                if !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    public var modelURL: URL? {
        let models = Self.availableModels()
        if !preferredModelPath.isEmpty, let m = models.first(where: { $0.path == preferredModelPath }) { return m }
        return models.first
    }

    public var isInstalled: Bool { Self.runtimeURL != nil && modelURL != nil }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    public static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-instruct", with: " Instruct", options: .caseInsensitive)
            .replacingOccurrences(of: "-q4_k_m", with: " (Q4)", options: .caseInsensitive)
            .replacingOccurrences(of: "qwen2.5", with: "Qwen2.5", options: .caseInsensitive)
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private var pidFile: URL { Paths.appSupport.appendingPathComponent("llama-server.pid") }

    /// Kills a server left behind by a previous crash.
    public func cleanupStale() {
        guard let s = try? String(contentsOf: pidFile), let pid = Int32(s.trimmed), pid > 0 else { return }
        let (_, name) = Shell.run("/bin/ps", ["-p", String(pid), "-o", "comm="])
        if name.contains("llama-server") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Starts the server if needed and returns its base URL.
    public func ensureRunning() async throws -> URL {
        lastUse = Date()
        lock.lock()
        if let p = process, p.isRunning { let port = self.port; lock.unlock(); return URL(string: "http://127.0.0.1:\(port)")! }
        lock.unlock()
        guard let runtime = Self.runtimeURL else { throw LLMError("Local model runtime not found") }
        guard let model = modelURL else { throw LLMError("No local model installed") }
        cleanupStale()
        let port = Self.freePort()
        let p = Process()
        p.executableURL = runtime
        let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-c", "8192", "-ngl", "99",
                       "-t", String(threads), "--parallel", "1", "--no-webui", "--log-disable"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        lock.lock(); process = p; self.port = port; lock.unlock()
        try? String(p.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning { throw LLMError("Local model failed to start") }
            var req = URLRequest(url: base.appendingPathComponent("health")); req.timeoutInterval = 2
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        startIdleTimer()
        return base
    }

    private func startIdleTimer() {
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastUse) > self.idleMinutes * 60 { self.stop() }
        }
        t.resume()
        idleTimer = t
    }

    public func stop() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        idleTimer?.cancel(); idleTimer = nil
        if let p, p.isRunning { p.terminate() }
        try? FileManager.default.removeItem(at: pidFile)
    }

    public func complete(system: String, prompt: String, maxTokens: Int = 700) async throws -> String {
        let base = try await ensureRunning()
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "system", "content": system], ["role": "user", "content": String(prompt.prefix(14_000))]],
            "temperature": 0.2, "max_tokens": maxTokens, "stream": false,
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        lastUse = Date()
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            throw LLMError("Unexpected local model response")
        }
        return content
    }
}

public final class BundledModelProvider: LLMProvider {
    public var name: String { "\(LocalModelServer.shared.modelURL.map(LocalModelServer.displayName) ?? "Local model") · offline" }
    public init() {}
    public func isAvailable() async -> Bool { LocalModelServer.shared.isInstalled }
    public func complete(system: String, prompt: String) async throws -> String {
        try await LocalModelServer.shared.complete(system: system, prompt: prompt)
    }
}
