import Foundation
import Network
import CryptoKit

/// LAN server for the Nexus Remote iPhone app. Opt-in, Bonjour-advertised, pairing-code protected, end-to-end encrypted.
/// Decrypted requests are routed through the same handlers as the local REST API.
public final class RemoteServer {
    public struct Device: Codable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var pairedAt: Date
        public var lastSeen: Date?
    }

    let api: APIServer
    let store: NexusStore
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.nexus.remote")
    private let salt = RemoteCrypto.randomData(16)
    private var pairing: (code: String, expires: Date, attempts: Int)?
    private var seenNonces: [String: Date] = [:]
    public var onChange: (() -> Void)?
    public private(set) var isRunning = false
    public private(set) var port: UInt16 = 0

    public init(api: APIServer, store: NexusStore) { self.api = api; self.store = store }

    public var devices: [Device] { JSON.decode([Device].self, store.kv("remote.devices")) ?? [] }
    private func saveDevices(_ d: [Device]) { store.setKV("remote.devices", JSON.string(d)); onChange?() }

    public var macName: String { Host.current().localizedName ?? "Mac" }

    public func start(port: UInt16 = RemoteCrypto.defaultPort) {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.service = NWListener.Service(name: macName, type: RemoteCrypto.serviceType)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] s in
            if case .ready = s { self?.isRunning = true; self?.onChange?() }
            if case .failed = s { self?.isRunning = false; self?.onChange?() }
        }
        l.start(queue: queue)
        listener = l
        self.port = port
    }

    public func stop() { listener?.cancel(); listener = nil; isRunning = false }

    /// Opens a 3-minute pairing window and returns the 6-digit code to display on the Mac.
    public func beginPairing() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        queue.sync { pairing = (code, Date().addingTimeInterval(180), 0) }
        return code
    }

    public func revoke(_ id: String) {
        saveDevices(devices.filter { $0.id != id })
        Keychain.set(nil, for: "remote.device.\(id)")
    }

    // MARK: HTTP plumbing

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) { Task { await self.handle(c, req) } }
            else if done || error != nil || buf.count > 4 << 20 { c.cancel() }
            else { self.receive(c, buf) }
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ body: Data, contentType: String = "application/octet-stream") {
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func replyJSON(_ c: NWConnection, _ status: Int, _ obj: [String: Any]) {
        reply(c, status, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), contentType: "application/json")
    }

    private func handle(_ c: NWConnection, _ r: HTTPRequest) async {
        switch (r.method, r.path) {
        case ("GET", "/hello"):
            let open = queue.sync { (pairing?.expires ?? .distantPast) > Date() }
            replyJSON(c, 200, ["name": macName, "salt": salt.base64EncodedString(), "pairingOpen": open, "version": 1])
        case ("POST", "/pair"):
            await pair(c, r)
        case ("POST", "/r"):
            await relay(c, r)
        default:
            replyJSON(c, 404, ["error": "not found"])
        }
    }

    private func pair(_ c: NWConnection, _ r: HTTPRequest) async {
        let state: (String, Date, Int)? = queue.sync {
            guard var p = pairing, p.expires > Date(), p.attempts < 5 else { return nil }
            p.attempts += 1
            pairing = p
            return (p.code, p.expires, p.attempts)
        }
        guard let (code, _, _) = state else { return replyJSON(c, 403, ["error": "Pairing is closed. Click “Pair iPhone” on your Mac."]) }
        let key = RemoteCrypto.pairingKey(code: code, salt: salt)
        guard let hello = try? RemoteCrypto.open(r.body, key: key), let name = hello["deviceName"] as? String else {
            return replyJSON(c, 401, ["error": "Wrong code"])
        }
        let id = newID()
        let deviceKey = SymmetricKey(size: .bits256)
        let keyData = deviceKey.withUnsafeBytes { Data($0) }
        Keychain.set(keyData.base64EncodedString(), for: "remote.device.\(id)")
        var list = devices.filter { $0.name != name }
        list.append(Device(id: id, name: name, pairedAt: Date(), lastSeen: Date()))
        saveDevices(list)
        queue.sync { pairing = nil }
        store.log(ActivityEvent(kind: .connector, message: "Paired \(name) with Nexus Remote"))
        guard let sealed = try? RemoteCrypto.seal(["deviceId": id, "deviceKey": keyData.base64EncodedString(), "macName": macName], key: key) else {
            return replyJSON(c, 500, ["error": "seal failed"])
        }
        reply(c, 200, sealed)
    }

    private func relay(_ c: NWConnection, _ r: HTTPRequest) async {
        guard let deviceId = r.headers["x-nexus-device"], devices.contains(where: { $0.id == deviceId }),
              let keyB64 = Keychain.get("remote.device.\(deviceId)"), let keyData = Data(base64Encoded: keyB64) else {
            return replyJSON(c, 401, ["error": "Unknown device — pair again"])
        }
        let key = SymmetricKey(data: keyData)
        guard let msg = try? RemoteCrypto.open(r.body, key: key),
              let method = msg["method"] as? String, let path = msg["path"] as? String,
              let ts = msg["ts"] as? Double, let nonce = msg["nonce"] as? String else {
            return replyJSON(c, 400, ["error": "bad envelope"])
        }
        // Replay protection: fresh timestamp and unseen nonce
        let fresh: Bool = queue.sync {
            let now = Date()
            seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < 180 }
            guard abs(now.timeIntervalSince1970 - ts) < 90, seenNonces[nonce] == nil else { return false }
            seenNonces[nonce] = now
            return true
        }
        guard fresh else { return replyJSON(c, 401, ["error": "stale request"]) }
        let body = (msg["body"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let (status, obj) = await api.route(method: method, target: path, body: body)
        var list = devices
        if let i = list.firstIndex(where: { $0.id == deviceId }) { list[i].lastSeen = Date(); saveDevices(list) }
        let sealed = (try? RemoteCrypto.seal(["status": status, "body": obj], key: key)) ?? Data()
        reply(c, 200, sealed)
    }
}
