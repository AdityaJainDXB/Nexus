using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Nexus.Core;

/// Same wire format as Nexus for Mac / Nexus Remote (iOS):
///   Pairing key = HKDF-SHA256(6-digit code, salt, info "nexus-remote-pairing-v1", 32 bytes)
///   Envelope    = base64( nonce(12) ‖ ChaCha20-Poly1305 ciphertext ‖ tag(16) ) of a JSON object
public static class RemoteCrypto
{
    public const string ServiceType = "_nexusremote._tcp";
    public const int DefaultPort = 7789;

    public static byte[] PairingKey(string code, byte[] salt) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes(code), 32, salt, Encoding.UTF8.GetBytes("nexus-remote-pairing-v1"));

    public static byte[] Seal(JsonNode obj, byte[] key)
    {
        var plain = Encoding.UTF8.GetBytes(obj.ToJsonString());
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        using (var c = new ChaCha20Poly1305(key)) c.Encrypt(nonce, plain, cipher, tag);
        return Encoding.ASCII.GetBytes(Convert.ToBase64String([.. nonce, .. cipher, .. tag]));
    }

    public static JsonObject Open(byte[] data, byte[] key)
    {
        var raw = Convert.FromBase64String(Encoding.ASCII.GetString(data).Trim());
        if (raw.Length < 28) throw new CryptographicException("short envelope");
        var nonce = raw[..12]; var tag = raw[^16..]; var cipher = raw[12..^16];
        var plain = new byte[cipher.Length];
        using (var c = new ChaCha20Poly1305(key)) c.Decrypt(nonce, cipher, tag, plain);
        return JsonNode.Parse(plain) as JsonObject ?? throw new CryptographicException("not an object");
    }
}

/// LAN server for the Nexus Remote iPhone app. Opt-in, Bonjour-advertised, pairing-code protected, end-to-end encrypted.
public class RemoteServer(ApiServer api, NexusStore store)
{
    public record Device(string Id, string Name, DateTime PairedAt, DateTime? LastSeen);

    MiniHttpServer? server;
    Makaretu.Dns.ServiceDiscovery? mdns;
    Makaretu.Dns.ServiceProfile? profile;
    readonly byte[] salt = RandomNumberGenerator.GetBytes(16);
    (string code, DateTime expires, int attempts)? pairing;
    readonly Dictionary<string, DateTime> seenNonces = [];
    readonly object gate = new();
    public Action? OnChange;
    public bool IsRunning => server?.IsRunning == true;
    public int Port => server?.Port ?? 0;
    public string MachineName => Platform.Current.MachineName;

    public List<Device> Devices => Json.Parse<List<Device>>(store.Kv("remote.devices")) ?? [];
    void SaveDevices(List<Device> d) { store.SetKv("remote.devices", Json.Str(d)); OnChange?.Invoke(); }

    public bool Start(int port = RemoteCrypto.DefaultPort)
    {
        Stop();
        server = new MiniHttpServer(IPAddress.Any, port, Handle);
        if (!server.Start()) { server = null; OnChange?.Invoke(); return false; }
        try
        {
            mdns = new Makaretu.Dns.ServiceDiscovery();
            profile = new Makaretu.Dns.ServiceProfile(MachineName, RemoteCrypto.ServiceType, (ushort)server.Port);
            profile.AddProperty("platform", "windows");
            mdns.Advertise(profile);
        }
        catch { }
        OnChange?.Invoke();
        return true;
    }

    public void Stop()
    {
        try { if (mdns != null && profile != null) mdns.Unadvertise(profile); } catch { }
        try { mdns?.Dispose(); } catch { }
        mdns = null; profile = null;
        server?.Stop(); server = null;
        OnChange?.Invoke();
    }

    /// Opens a 3-minute pairing window and returns the 6-digit code to show on the PC.
    public string BeginPairing()
    {
        var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("000000");
        lock (gate) pairing = (code, DateTime.Now.AddMinutes(3), 0);
        return code;
    }

    public void Revoke(string id)
    {
        SaveDevices(Devices.Where(d => d.Id != id).ToList());
        Secrets.Set("remote.device." + id, null);
    }

    static Task Json200(Stream s, int status, object o) => HttpRequest.Reply(s, status, Encoding.UTF8.GetBytes(JsonSerializer.Serialize(o, Json.Options)), "application/json");

    async Task Handle(HttpRequest r, Stream s)
    {
        switch (r.Method, r.Path)
        {
            case ("GET", "/hello"):
                bool open; lock (gate) open = pairing is { } p && p.expires > DateTime.Now;
                await Json200(s, 200, new { name = MachineName, salt = Convert.ToBase64String(salt), pairingOpen = open, version = 1, platform = "windows" });
                break;
            case ("POST", "/pair"): await Pair(r, s); break;
            case ("POST", "/r"): await Relay(r, s); break;
            default: await Json200(s, 404, new { error = "not found" }); break;
        }
    }

    async Task Pair(HttpRequest r, Stream s)
    {
        string? code = null;
        lock (gate)
        {
            if (pairing is { } p && p.expires > DateTime.Now && p.attempts < 5) { pairing = (p.code, p.expires, p.attempts + 1); code = p.code; }
        }
        if (code == null) { await Json200(s, 403, new { error = "Pairing is closed. Click “Pair iPhone” on your PC." }); return; }
        var key = RemoteCrypto.PairingKey(code, salt);
        string? name;
        try { name = RemoteCrypto.Open(r.Body, key)["deviceName"]?.GetValue<string>(); }
        catch { name = null; }
        if (name == null) { await Json200(s, 401, new { error = "Wrong code" }); return; }
        var id = Ids.New();
        var deviceKey = RandomNumberGenerator.GetBytes(32);
        Secrets.Set("remote.device." + id, Convert.ToBase64String(deviceKey));
        var list = Devices.Where(d => d.Name != name).ToList();
        list.Add(new Device(id, name, DateTime.Now, DateTime.Now));
        SaveDevices(list);
        lock (gate) pairing = null;
        store.Log(new ActivityEvent { Kind = EventKind.connector, Message = $"Paired {name} with Nexus Remote" });
        var sealedReply = RemoteCrypto.Seal(new JsonObject { ["deviceId"] = id, ["deviceKey"] = Convert.ToBase64String(deviceKey), ["macName"] = MachineName }, key);
        await HttpRequest.Reply(s, 200, sealedReply, "application/octet-stream");
    }

    async Task Relay(HttpRequest r, Stream s)
    {
        var deviceId = r.Headers.GetValueOrDefault("X-Nexus-Device");
        if (deviceId == null || Devices.All(d => d.Id != deviceId) || Secrets.Get("remote.device." + deviceId) is not { } keyB64)
        { await Json200(s, 401, new { error = "Unknown device — pair again" }); return; }
        var key = Convert.FromBase64String(keyB64);
        JsonObject msg;
        try { msg = RemoteCrypto.Open(r.Body, key); }
        catch { await Json200(s, 400, new { error = "bad envelope" }); return; }
        var method = msg["method"]?.GetValue<string>(); var path = msg["path"]?.GetValue<string>();
        var nonce = msg["nonce"]?.GetValue<string>();
        double ts = msg["ts"] is JsonValue tv && tv.TryGetValue<double>(out var t) ? t : 0;
        if (method == null || path == null || nonce == null || ts == 0) { await Json200(s, 400, new { error = "bad envelope" }); return; }
        bool fresh;
        lock (gate)
        {
            var now = DateTime.Now;
            foreach (var k in seenNonces.Where(kv => (now - kv.Value).TotalSeconds > 180).Select(kv => kv.Key).ToList()) seenNonces.Remove(k);
            fresh = Math.Abs(Time.Epoch(now) - ts) < 90 && !seenNonces.ContainsKey(nonce);
            if (fresh) seenNonces[nonce] = now;
        }
        if (!fresh) { await Json200(s, 401, new { error = "stale request" }); return; }
        var body = msg["body"] is JsonObject b ? Encoding.UTF8.GetBytes(b.ToJsonString()) : [];
        var (status, obj) = await api.Route(method, path, body);
        var list = Devices;
        var i = list.FindIndex(d => d.Id == deviceId);
        if (i >= 0) { list[i] = list[i] with { LastSeen = DateTime.Now }; SaveDevices(list); }
        await HttpRequest.Reply(s, 200, RemoteCrypto.Seal(new JsonObject { ["status"] = status, ["body"] = obj.DeepClone() }, key), "application/octet-stream");
    }
}
