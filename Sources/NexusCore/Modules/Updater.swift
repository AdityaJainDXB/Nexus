import Foundation
import CryptoKit
import AppKit

public struct ReleaseInfo: Hashable, Sendable {
    public var version: String
    public var name: String
    public var notes: String
    public var url: String
    public var assetURL: String?
    public var assetName: String?
    public var assetSize: Int64
    public var checksumsURL: String?
    public var publishedAt: Date

    public var sizeText: String { assetSize > 0 ? formatBytes(assetSize) : "" }
    /// Bullet lines from the release notes, for the little "what's new" list.
    public var highlights: [String] {
        let lines: [String] = notes.split(separator: "\n").map { String($0).trimmed }
        let bullets: [String] = lines.filter { $0.hasPrefix("-") || $0.hasPrefix("*") }
        return bullets.prefix(5).map { "• " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "-* ")) }
    }
}

public enum UpdateStage: String, Sendable { case idle, checking, available, downloading, verifying, ready, installing, upToDate, failed }

public struct UpdateState: Sendable {
    public var stage: UpdateStage
    public var release: ReleaseInfo?
    public var progress: Double
    public var message: String?
    public var downloadedPath: String?

    public init(stage: UpdateStage = .idle, release: ReleaseInfo? = nil, progress: Double = 0, message: String? = nil, downloadedPath: String? = nil) {
        self.stage = stage; self.release = release; self.progress = progress; self.message = message; self.downloadedPath = downloadedPath
    }
}

/// Checks GitHub Releases for a newer Nexus, downloads the DMG (verifying its checksum),
/// installs it into /Applications and relaunches. Fully opt-out, and any version can be skipped.
public final class Updater: @unchecked Sendable {
    public static let defaultRepo = "AdityaJainDXB/Nexus"

    private let store: NexusStore
    private let session: URLSession
    public var repo = Updater.defaultRepo
    public var currentVersion: String
    public var apiOverride: URL?            // tests read a recorded release instead of the network
    public var onState: (@Sendable (UpdateState) -> Void)?
    public private(set) var state = UpdateState()

    public init(store: NexusStore, currentVersion: String? = nil) {
        self.store = store
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0.0"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = ["User-Agent": "Nexus-Updater/1.0", "Accept": "application/vnd.github+json"]
        session = URLSession(configuration: config)
    }

    public var lastChecked: Date? { store.kv("update.lastCheck").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
    public var skippedVersion: String? { store.kv("update.skipped").flatMap { $0.isEmpty ? nil : $0 } }
    public func skip(_ version: String) { store.setKV("update.skipped", version); set(UpdateState(stage: .idle, message: "Skipping \(version)")) }
    public func unskip() { store.setKV("update.skipped", "") }

    private func set(_ s: UpdateState) { state = s; onState?(s) }

    /// The newest release, or nil when up to date, skipped, or checks are off.
    @discardableResult
    public func check(automatic: Bool = false, enabled: Bool = true) async -> ReleaseInfo? {
        if automatic && !enabled { return nil }
        if automatic, let last = lastChecked, Date().timeIntervalSince(last) < 6 * 3600 { return state.release }
        set(UpdateState(stage: .checking, release: state.release))
        do {
            let data: Data
            if let apiOverride { data = try Data(contentsOf: apiOverride) }
            else {
                guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw UpdateError("bad repo") }
                let (d, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw UpdateError("GitHub returned \(http.statusCode)") }
                data = d
            }
            store.setKV("update.lastCheck", String(Date().timeIntervalSince1970))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateError("empty response") }

            let tag = json["tag_name"] as? String ?? ""
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = (json["assets"] as? [[String: Any]] ?? []).map {
                (name: $0["name"] as? String ?? "", url: $0["browser_download_url"] as? String ?? "", size: Int64($0["size"] as? Int ?? 0))
            }
            let dmg = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            let sums = assets.first { $0.name.hasPrefix("SHA256SUMS") && !$0.name.lowercased().contains("windows") }
            let published = ISO8601DateFormatter().date(from: json["published_at"] as? String ?? "") ?? Date()
            let release = ReleaseInfo(version: version, name: json["name"] as? String ?? tag, notes: json["body"] as? String ?? "",
                                      url: json["html_url"] as? String ?? "https://github.com/\(repo)/releases/latest",
                                      assetURL: dmg?.url, assetName: dmg?.name, assetSize: dmg?.size ?? 0,
                                      checksumsURL: sums?.url, publishedAt: published)

            guard Updater.compare(release.version, currentVersion) > 0 else {
                set(UpdateState(stage: .upToDate, message: "Nexus \(currentVersion) is the latest version"))
                return nil
            }
            if automatic, skippedVersion == release.version { set(UpdateState(stage: .idle)); return nil }
            set(UpdateState(stage: .available, release: release))
            return release
        } catch {
            set(UpdateState(stage: .failed, release: state.release, message: "Couldn't check for updates: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Downloads the DMG and verifies its SHA-256 when the release publishes checksums.
    @discardableResult
    public func download(_ release: ReleaseInfo) async -> String? {
        guard let urlString = release.assetURL, let url = URL(string: urlString), let name = release.assetName else {
            set(UpdateState(stage: .failed, release: release, message: "This release has no Mac download"))
            return nil
        }
        do {
            let dir = Paths.appSupport.appendingPathComponent("Updates")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != name {
                try? FileManager.default.removeItem(at: old)
            }
            let dest = dir.appendingPathComponent(name)
            let existing = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0

            if existing != release.assetSize {
                set(UpdateState(stage: .downloading, release: release))
                let (temp, response) = try await session.download(from: url, progress: { [weak self] fraction, done, total in
                    self?.set(UpdateState(stage: .downloading, release: release, progress: fraction, message: "\(formatBytes(done)) of \(formatBytes(total))"))
                })
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw UpdateError("download failed (\(http.statusCode))") }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
            }

            if let sums = release.checksumsURL, let sumsURL = URL(string: sums) {
                set(UpdateState(stage: .verifying, release: release, progress: 1))
                if let (data, _) = try? await session.data(from: sumsURL), let text = String(data: data, encoding: .utf8) {
                    let expected: String? = text.split(separator: "\n").compactMap { line -> String? in
                        let parts = String(line).components(separatedBy: "  ")
                        guard parts.count == 2, parts[1].trimmed == name else { return nil }
                        return parts[0].trimmed
                    }.first
                    if let expected, expected.count == 64 {
                        let actual = try Self.sha256(of: dest)
                        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                            try? FileManager.default.removeItem(at: dest)
                            set(UpdateState(stage: .failed, release: release, message: "The download didn't match its checksum — update cancelled"))
                            return nil
                        }
                    }
                }
            }
            set(UpdateState(stage: .ready, release: release, progress: 1, message: "Ready to install", downloadedPath: dest.path))
            return dest.path
        } catch {
            set(UpdateState(stage: .failed, release: release, message: "Download failed: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Mounts the DMG, replaces the installed app and relaunches it. Returns false when it couldn't (caller opens the DMG instead).
    @discardableResult
    public func install(_ dmgPath: String, appPath: String? = nil, relaunch: Bool = true) -> Bool {
        set(UpdateState(stage: .installing, release: state.release, progress: 1, message: "Installing…", downloadedPath: dmgPath))
        let target = appPath ?? Bundle.main.bundlePath
        let fm = FileManager.default
        guard target.hasSuffix(".app"), fm.isWritableFile(atPath: (target as NSString).deletingLastPathComponent) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dmgPath))
            set(UpdateState(stage: .failed, release: state.release, message: "Nexus can't replace itself at \(Paths.abbreviate(target)) — the disk image is open, drag Nexus into Applications.", downloadedPath: dmgPath))
            return false
        }
        let mount = "/Volumes/Nexus-update-\(Int(Date().timeIntervalSince1970))"
        let (attachCode, _) = Shell.run("/usr/bin/hdiutil", ["attach", dmgPath, "-nobrowse", "-noautoopen", "-mountpoint", mount], timeout: 300)
        guard attachCode == 0 else {
            set(UpdateState(stage: .failed, release: state.release, message: "Couldn't open the disk image", downloadedPath: dmgPath))
            return false
        }
        defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", mount, "-force"], timeout: 120) }
        let source = mount + "/Nexus.app"
        guard fm.fileExists(atPath: source) else {
            set(UpdateState(stage: .failed, release: state.release, message: "The disk image didn't contain Nexus.app", downloadedPath: dmgPath))
            return false
        }
        let staging = (target as NSString).deletingLastPathComponent + "/.Nexus-update-\(UUID().uuidString.prefix(6)).app"
        let (copyCode, copyOut) = Shell.run("/usr/bin/ditto", [source, staging], timeout: 900)
        guard copyCode == 0 else {
            try? fm.removeItem(atPath: staging)
            set(UpdateState(stage: .failed, release: state.release, message: "Couldn't copy the new version: \(copyOut.prefix(120))", downloadedPath: dmgPath))
            return false
        }
        let backup = target + ".old"
        try? fm.removeItem(atPath: backup)
        do {
            if fm.fileExists(atPath: target) { try fm.moveItem(atPath: target, toPath: backup) }
            try fm.moveItem(atPath: staging, toPath: target)
            try? fm.removeItem(atPath: backup)
        } catch {
            // put the old app back if the swap failed halfway
            if !fm.fileExists(atPath: target), fm.fileExists(atPath: backup) { try? fm.moveItem(atPath: backup, toPath: target) }
            try? fm.removeItem(atPath: staging)
            set(UpdateState(stage: .failed, release: state.release, message: "Couldn't replace the app: \(error.localizedDescription)", downloadedPath: dmgPath))
            return false
        }
        if relaunch {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 2; /usr/bin/open \"\(target)\""]
            try? task.run()
        }
        return true
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Semantic-ish compare: 1.2.10 > 1.2.9 > 1.2 > 1.2.0-beta.
    public static func compare(_ a: String, _ b: String) -> Int {
        func parse(_ v: String) -> ([Int], String) {
            var s = v.trimmed
            if s.hasPrefix("v") || s.hasPrefix("V") { s = String(s.dropFirst()) }
            let split = s.split(whereSeparator: { $0 == "-" || $0 == "+" })
            let core = split.first.map(String.init) ?? s
            let pre = split.count > 1 ? split.dropFirst().joined(separator: "-") : ""
            return (core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }, pre)
        }
        let (an, ap) = parse(a), (bn, bp) = parse(b)
        for i in 0..<max(an.count, bn.count) {
            let x = i < an.count ? an[i] : 0, y = i < bn.count ? bn[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if ap == bp { return 0 }
        if ap.isEmpty { return 1 }
        if bp.isEmpty { return -1 }
        return ap < bp ? -1 : 1
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension URLSession {
    /// Download with progress reporting (URLSession's own API reports it only via delegates).
    func download(from url: URL, progress: @escaping @Sendable (Double, Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await self.bytes(from: url)
        let total = response.expectedContentLength
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nexus-update-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var done: Int64 = 0
        var lastReport = Date()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                done += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    progress(total > 0 ? Double(done) / Double(total) : 0, done, total)
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); done += Int64(buffer.count) }
        progress(1, done, max(total, done))
        return (temp, response)
    }
}
