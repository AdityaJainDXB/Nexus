import Foundation
import Security

// MARK: - Paths

public enum Paths {
    /// Real home, or NEXUS_HOME_ROOT for realistic sandboxed testing.
    public static var home: String { ProcessInfo.processInfo.environment["NEXUS_HOME_ROOT"] ?? NSHomeDirectory() }

    public static func expand(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst()) }
        else if !p.hasPrefix("/") && !p.isEmpty { p = (home as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    public static func abbreviate(_ rawPath: String) -> String {
        let h = canonical(home)
        let path = rawPath.hasPrefix("/") ? canonical(rawPath) : rawPath
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    /// ~/Library/Application Support/Nexus (override with NEXUS_HOME for tests / portable installs).
    public static var appSupport: URL {
        let url: URL
        if let custom = ProcessInfo.processInfo.environment["NEXUS_HOME"] {
            url = URL(fileURLWithPath: custom)
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nexus")
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var database: URL { appSupport.appendingPathComponent("nexus.sqlite") }
    public static var plugins: URL { dir("Plugins") }
    public static var reports: URL { dir("Reports") }
    public static var scripts: URL { dir("Scripts") }
    public static var apiTokenFile: URL { appSupport.appendingPathComponent("api-token") }

    private static func dir(_ name: String) -> URL {
        let u = appSupport.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// True if `path` is `folder` or inside it.
    /// Canonical form used everywhere paths are compared (/private/tmp → /tmp, no trailing slash, no ..).
    public static func canonical(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        if std.hasPrefix("/private/") {
            let stripped = String(std.dropFirst("/private".count))
            // /tmp, /var and /etc are symlinks into /private on macOS
            if ["/tmp", "/var", "/etc"].contains(where: { stripped == $0 || stripped.hasPrefix($0 + "/") }) { return stripped }
        }
        return std
    }

    public static func isInside(_ path: String, _ folder: String, recursive: Bool = true) -> Bool {
        let path = canonical(path)
        let folder = canonical(folder)
        let f = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        if recursive { return path == f || path.hasPrefix(f + "/") }
        return (path as NSString).deletingLastPathComponent == f
    }

    /// Returns a non-colliding path by appending " 2", " 3"... before the extension.
    public static func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let ext = (path as NSString).pathExtension
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    /// Folders Nexus must never mutate, regardless of rules.
    public static var protectedPrefixes: [String] {
        ["/System", "/Library", "/bin", "/sbin", "/usr", "/Applications", "/private/etc", "/private/var/db", "/private/var/root",
         home + "/Library", home + "/.ssh", home + "/.gnupg", home + "/.config"]
    }
    /// User-content locations inside ~/Library that are safe to organize.
    static var libraryAllowList: [String] { [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"] }

    public static func isProtected(_ raw: String) -> Bool {
        let path = canonical(raw)
        if path == canonical(home) { return true }
        if libraryAllowList.contains(where: { isInside(path, $0) && canonical(path) != canonical($0) }) { return false }
        return protectedPrefixes.contains { isInside(path, $0) }
    }
}

// MARK: - Settings

public enum LLMProviderChoice: String, Codable, CaseIterable {
    case auto, appleIntelligence, bundled, ollama, off
    public var label: String {
        switch self {
        case .auto: return "Automatic (best available on-device)"
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .bundled: return "Nexus local model (bundled, fully offline)"
        case .ollama: return "Ollama (local server)"
        case .off: return "Off — heuristics only"
        }
    }
}

public enum PaletteHotkey: String, Codable, CaseIterable {
    case cmdShiftK, optionSpace, cmdShiftJ, ctrlSpace
    public var label: String {
        switch self {
        case .cmdShiftK: return "⇧⌘K"
        case .optionSpace: return "⌥Space"
        case .cmdShiftJ: return "⇧⌘J"
        case .ctrlSpace: return "⌃Space"
        }
    }
}

public enum VoiceHotkey: String, Codable, CaseIterable {
    case optionShiftSpace, controlOptionSpace, rightCommandHold, off
    public var label: String {
        switch self {
        case .optionShiftSpace: return "⌥⇧Space"
        case .controlOptionSpace: return "⌃⌥Space"
        case .rightCommandHold: return "⌃⌥⌘V"
        case .off: return "Off"
        }
    }
}

public enum HotbarMode: String, Codable, CaseIterable {
    case floating, desktop, off
    public var label: String { ["floating": "Floating above apps", "desktop": "On the desktop (behind windows)", "off": "Hidden"][rawValue]! }
}

public enum AppearanceChoice: String, Codable, CaseIterable {
    case dark, system, light
    public var label: String { ["dark": "Dark", "system": "Match System", "light": "Light"][rawValue]! }
}

public struct NexusSettings: Codable, Equatable {
    public var watchedFolders: [String] = ["~/Downloads", "~/Desktop"]
    public var libraryRoots: [String] = ["~/Documents"]
    public var autopilotEnabled = true
    public var autoThreshold = 0.85
    public var reviewThreshold = 0.55
    public var dryRun = false
    public var llmProvider: LLMProviderChoice = .auto
    public var ollamaURL = "http://127.0.0.1:11434"
    public var ollamaModel = "llama3.2"
    public var enableOCR = true
    public var enableSpeech = false
    public var maxExtractKB = 512
    public var notificationsEnabled = true
    public var quietHoursStart = 22
    public var quietHoursEnd = 7
    public var paletteHotkey: PaletteHotkey = .cmdShiftK
    public var apiEnabled = true
    public var apiPort = 7788
    public var maxOpsPerMinute = 120
    public var batteryAware = true
    public var ignoredPatterns: [String] = [".DS_Store", "*.crdownload", "*.download", "*.part", "*.tmp", "~$*", ".~lock*", "*.icloud"]
    public var staleDownloadDays = 7
    public var inactiveProjectDays = 30
    public var lowDiskGB = 25.0
    public var onboardingComplete = false
    public var obsidianVault: String = ""
    public var githubRepo: String = ""        // owner/repo for githubIssue actions
    public var digestWeekday = 1              // Sunday
    public var digestHour = 9
    public var scriptSandbox = true
    public var showDockIcon = false
    public var autoRemoveDuplicates = true     // trash new downloads whose exact content already exists in your folders
    public var voiceHotkey: VoiceHotkey = .optionShiftSpace
    public var voiceAutoSubmit = true          // send after a short pause in speech
    public var voiceConfirmBySpeech = true     // "run it" / "cancel" after a preview
    public var speakResponses = true           // read results aloud for voice-initiated commands
    public var appearance: AppearanceChoice = .dark
    public var hotbar: HotbarMode = .floating
    public var localModelPath = ""             // "" = first bundled / added GGUF

    public init() {}

    public var watchedFoldersExpanded: [String] { watchedFolders.map(Paths.expand) }
    public var libraryRootsExpanded: [String] { libraryRoots.map(Paths.expand) }

    // Tolerant decoding so adding settings never breaks existing installs.
    public init(from decoder: Decoder) throws {
        let d = NexusSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        watchedFolders = v(.watchedFolders, d.watchedFolders)
        libraryRoots = v(.libraryRoots, d.libraryRoots)
        autopilotEnabled = v(.autopilotEnabled, d.autopilotEnabled)
        autoThreshold = v(.autoThreshold, d.autoThreshold)
        reviewThreshold = v(.reviewThreshold, d.reviewThreshold)
        dryRun = v(.dryRun, d.dryRun)
        llmProvider = v(.llmProvider, d.llmProvider)
        ollamaURL = v(.ollamaURL, d.ollamaURL)
        ollamaModel = v(.ollamaModel, d.ollamaModel)
        enableOCR = v(.enableOCR, d.enableOCR)
        enableSpeech = v(.enableSpeech, d.enableSpeech)
        maxExtractKB = v(.maxExtractKB, d.maxExtractKB)
        notificationsEnabled = v(.notificationsEnabled, d.notificationsEnabled)
        quietHoursStart = v(.quietHoursStart, d.quietHoursStart)
        quietHoursEnd = v(.quietHoursEnd, d.quietHoursEnd)
        paletteHotkey = v(.paletteHotkey, d.paletteHotkey)
        apiEnabled = v(.apiEnabled, d.apiEnabled)
        apiPort = v(.apiPort, d.apiPort)
        maxOpsPerMinute = v(.maxOpsPerMinute, d.maxOpsPerMinute)
        batteryAware = v(.batteryAware, d.batteryAware)
        ignoredPatterns = v(.ignoredPatterns, d.ignoredPatterns)
        staleDownloadDays = v(.staleDownloadDays, d.staleDownloadDays)
        inactiveProjectDays = v(.inactiveProjectDays, d.inactiveProjectDays)
        lowDiskGB = v(.lowDiskGB, d.lowDiskGB)
        onboardingComplete = v(.onboardingComplete, d.onboardingComplete)
        obsidianVault = v(.obsidianVault, d.obsidianVault)
        githubRepo = v(.githubRepo, d.githubRepo)
        digestWeekday = v(.digestWeekday, d.digestWeekday)
        digestHour = v(.digestHour, d.digestHour)
        scriptSandbox = v(.scriptSandbox, d.scriptSandbox)
        showDockIcon = v(.showDockIcon, d.showDockIcon)
        autoRemoveDuplicates = v(.autoRemoveDuplicates, d.autoRemoveDuplicates)
        voiceHotkey = v(.voiceHotkey, d.voiceHotkey)
        voiceAutoSubmit = v(.voiceAutoSubmit, d.voiceAutoSubmit)
        voiceConfirmBySpeech = v(.voiceConfirmBySpeech, d.voiceConfirmBySpeech)
        speakResponses = v(.speakResponses, d.speakResponses)
        appearance = v(.appearance, d.appearance)
        hotbar = v(.hotbar, d.hotbar)
        localModelPath = v(.localModelPath, d.localModelPath)
    }
}

// MARK: - Keychain (connector secrets never touch SQLite)

public enum Keychain {
    private static let service = "app.nexus.secrets"

    public static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Event bus

public enum NexusEvent {
    case fileAdded(path: String)
    case fileModified(path: String)
    case fileRemoved(path: String)
    case fileRenamed(from: String, to: String)
    case downloadCompleted(path: String)
    case appLaunched(name: String, bundleId: String?)
    case appQuit(name: String, bundleId: String?)
    case volumeMounted(name: String, path: String)
    case volumeUnmounted(name: String, path: String)
    case diskSpace(freeGB: Double)
    case idle(minutes: Int)
    case wake
    case focusChanged(active: Bool, projectId: String?)
    case connector(name: String, payload: [String: String])
    case storeChanged(String)
    case status(EngineStatus)
}

public enum EngineStatus: String { case idle, working, attention, paused }

/// Tiny multi-subscriber pub/sub. Handlers are invoked on the posting thread.
public final class EventBus {
    public typealias Handler = (NexusEvent) -> Void
    private var handlers: [UUID: Handler] = [:]
    private let lock = NSLock()
    public init() {}

    @discardableResult
    public func subscribe(_ h: @escaping Handler) -> UUID {
        let id = UUID()
        lock.lock(); handlers[id] = h; lock.unlock()
        return id
    }
    public func unsubscribe(_ id: UUID) { lock.lock(); handlers[id] = nil; lock.unlock() }
    public func post(_ e: NexusEvent) {
        lock.lock(); let hs = Array(handlers.values); lock.unlock()
        hs.forEach { $0(e) }
    }
}

// MARK: - Helpers

public extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

public extension String {
    func glob(_ pattern: String) -> Bool { fnmatch(pattern, self, FNM_CASEFOLD) == 0 }
    func regexMatches(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
            .firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }
    /// Captures of the first match of `pattern` (case-insensitive).
    func captures(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: self) else { return "" }
            return String(self[r])
        }
    }
}

public func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

public func relativeTime(_ d: Date, now: Date = Date()) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: now)
}

public enum JSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()
    public static func string<T: Encodable>(_ v: T) -> String {
        (try? encoder.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
    public static func decode<T: Decodable>(_ t: T.Type, _ s: String?) -> T? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? decoder.decode(t, from: d)
    }
}
