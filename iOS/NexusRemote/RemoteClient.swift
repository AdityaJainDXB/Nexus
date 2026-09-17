import Foundation
import Network
import CryptoKit
import Security

/// Discovers Nexus on the local network, pairs with a 6-digit code, and sends end-to-end encrypted requests.
@MainActor
final class RemoteClient: ObservableObject {
    struct Mac: Identifiable, Hashable { let id: String; let name: String; let endpoint: NWEndpoint? ; var host: String? }

    @Published var discovered: [Mac] = []
    @Published var paired: Bool = false
    @Published var macName: String = ""
    @Published var host: String = ""
    @Published var lastError: String?
    @Published var connected = false

    private var browser: NWBrowser?
    private var deviceId: String?
    private var key: SymmetricKey?

    init() { loadPairing() }

    // MARK: Discovery

    func startBrowsing() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: RemoteCrypto.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discovered = results.compactMap { r in
                    if case let .service(name, _, _, _) = r.endpoint { return Mac(id: name, name: name, endpoint: r.endpoint) }
                    return nil
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Resolves a Bonjour endpoint to host:port by opening a short TCP connection.
    func resolve(_ mac: Mac) async -> String? {
        guard let ep = mac.endpoint else { return mac.host }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(to: ep, using: .tcp)
            var done = false
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    var result: String?
                    if case let .hostPort(h, _)? = conn.currentPath?.remoteEndpoint {
                        var hs = "\(h)"
                        if let pct = hs.firstIndex(of: "%") { hs = String(hs[..<pct]) }
                        result = hs.contains(":") ? "[\(hs)]" : hs
                    }
                    conn.cancel(); cont.resume(returning: result)
                case .failed, .cancelled:
                    done = true; cont.resume(returning: nil)
                default: break
                }
            }
            conn.start(queue: .global())
        }
    }

    // MARK: Pairing

    func pair(host: String, code: String) async -> Bool {
        lastError = nil
        let base = "http://\(host):\(RemoteCrypto.defaultPort)"
        do {
            let (hd, _) = try await URLSession.shared.data(from: URL(string: base + "/hello")!)
            guard let hello = try JSONSerialization.jsonObject(with: hd) as? [String: Any], let saltB64 = hello["salt"] as? String, let salt = Data(base64Encoded: saltB64) else {
                lastError = "That doesn't look like a Nexus Mac."; return false
            }
            let pk = RemoteCrypto.pairingKey(code: code, salt: salt)
            var req = URLRequest(url: URL(string: base + "/pair")!)
            req.httpMethod = "POST"
            req.httpBody = try RemoteCrypto.seal(["deviceName": deviceName], key: pk)
            let (pd, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let msg = try? RemoteCrypto.open(pd, key: pk),
                  let id = msg["deviceId"] as? String, let kb = msg["deviceKey"] as? String, let keyData = Data(base64Encoded: kb) else {
                let err = (try? JSONSerialization.jsonObject(with: pd) as? [String: Any])?["error"] as? String
                lastError = err ?? "Pairing failed (\(status))."
                return false
            }
            deviceId = id
            key = SymmetricKey(data: keyData)
            self.host = host
            macName = msg["macName"] as? String ?? (hello["name"] as? String ?? "Mac")
            savePairing(keyData: keyData)
            paired = true
            connected = true
            return true
        } catch {
            lastError = "Can't reach \(host). Make sure Nexus Remote is on and both devices are on the same Wi-Fi."
            return false
        }
    }

    var deviceName: String {
        #if targetEnvironment(simulator)
        return "iPhone Simulator"
        #else
        return UIDeviceName.current
        #endif
    }

    func unpair() {
        UserDefaults.standard.removeObject(forKey: "nexus.remote.host")
        UserDefaults.standard.removeObject(forKey: "nexus.remote.device")
        UserDefaults.standard.removeObject(forKey: "nexus.remote.mac")
        KeychainStore.delete("nexus.remote.key")
        key = nil; deviceId = nil; paired = false; connected = false
    }

    private func savePairing(keyData: Data) {
        UserDefaults.standard.set(host, forKey: "nexus.remote.host")
        UserDefaults.standard.set(deviceId, forKey: "nexus.remote.device")
        UserDefaults.standard.set(macName, forKey: "nexus.remote.mac")
        KeychainStore.set(keyData, for: "nexus.remote.key")
    }

    private func loadPairing() {
        guard let h = UserDefaults.standard.string(forKey: "nexus.remote.host"), let d = UserDefaults.standard.string(forKey: "nexus.remote.device"),
              let k = KeychainStore.get("nexus.remote.key") else { return }
        host = h; deviceId = d; key = SymmetricKey(data: k); macName = UserDefaults.standard.string(forKey: "nexus.remote.mac") ?? "Mac"; paired = true
    }

    // MARK: Encrypted calls

    struct RemoteError: LocalizedError { let message: String; var errorDescription: String? { message } }

    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let key, let deviceId else { throw RemoteError(message: "Not paired") }
        var env: [String: Any] = ["method": method, "path": path, "ts": Date().timeIntervalSince1970, "nonce": UUID().uuidString]
        if let body { env["body"] = body }
        var req = URLRequest(url: URL(string: "http://\(host):\(RemoteCrypto.defaultPort)/r")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(deviceId, forHTTPHeaderField: "X-Nexus-Device")
        req.httpBody = try RemoteCrypto.seal(env, key: key)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { connected = false; throw RemoteError(message: "This iPhone is no longer paired. Pair again from Nexus → Connectors.") }
            guard code == 200 else { throw RemoteError(message: "Mac returned \(code)") }
            let msg = try RemoteCrypto.open(data, key: key)
            connected = true
            let status = msg["status"] as? Int ?? 0
            if status >= 400 { throw RemoteError(message: (msg["body"] as? [String: Any])?["error"] as? String ?? "Error \(status)") }
            return msg["body"] ?? [:]
        } catch let e as RemoteError { throw e }
        catch { connected = false; throw RemoteError(message: "Can't reach \(macName). Is your Mac awake and on the same network?") }
    }
}

enum UIDeviceName {
    static var current: String {
        #if canImport(UIKit)
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        #else
        return "iPhone"
        #endif
    }
}

enum KeychainStore {
    private static func fallbackURL(_ key: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(key + ".bin")
    }
    static func set(_ data: Data, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecAttrService as String: "app.nexus.remote"]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            // Unsigned/simulator builds may lack keychain access: fall back to an OS-encrypted, device-only file
            try? data.write(to: fallbackURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecAttrService as String: "app.nexus.remote",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        return try? Data(contentsOf: fallbackURL(key))
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecAttrService as String: "app.nexus.remote"] as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL(key))
    }
}
