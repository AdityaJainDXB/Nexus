using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Nexus.Core;

// nexusctl — command line for Nexus for Windows.
//   nexusctl serve                      run the engine headless (API on 127.0.0.1:7788)
//   nexusctl status | rules | review | insights | tasks | undo | pause | resume
//   nexusctl do "organize Downloads"    plan + run a command (asks before changes unless --yes)
//   nexusctl rule "If a PDF in Downloads contains 'MYP3' → move to School"
//   nexusctl compile "<rule text>"      offline: show how a sentence compiles
//   nexusctl remote-test <host> <code>  exercise the iPhone protocol against a running Nexus

var cmd = args.FirstOrDefault() ?? "help";
var rest = args.Skip(1).ToArray();
var yes = rest.Contains("--yes") || rest.Contains("-y");
rest = rest.Where(a => a is not ("--yes" or "-y")).ToArray();

switch (cmd)
{
    case "serve": return await Serve();
    case "compile": return Compile(string.Join(' ', rest));
    case "remote-test": return await RemoteTest(rest.ElementAtOrDefault(0) ?? "127.0.0.1", rest.ElementAtOrDefault(1) ?? "");
    case "status": return await Call("GET", "/v1/status");
    case "rules": return await Call("GET", "/v1/rules");
    case "review": return await Call("GET", "/v1/review");
    case "insights": return await Call("GET", "/v1/insights");
    case "tasks": return await Call("GET", "/v1/tasks?limit=20");
    case "undo": return await Call("POST", "/v1/undo");
    case "pause": return await Call("POST", "/v1/pause");
    case "resume": return await Call("POST", "/v1/resume");
    case "search": return await Call("GET", "/v1/search?q=" + Uri.EscapeDataString(string.Join(' ', rest)));
    case "rule": return await Call("POST", "/v1/rules", new JsonObject { ["text"] = string.Join(' ', rest) });
    case "approve": return await Call("POST", $"/v1/review/{rest.FirstOrDefault()}/approve", new JsonObject());
    case "do":
        {
            var text = string.Join(' ', rest);
            var (_, plan) = await Api("POST", "/v1/command", new JsonObject { ["text"] = text });
            if (plan?["executed"]?.GetValue<bool>() == true) { Console.WriteLine(plan["message"]); return 0; }
            foreach (var s in plan?["steps"]?.AsArray() ?? []) Console.WriteLine($"• {s?["intent"]}: {s?["note"]}\n  " + string.Join("\n  ", s?["preview"]?.AsArray().Select(p => p?.ToString()) ?? []));
            if (!yes) { Console.Write("Run it? [y/N] "); if (Console.ReadLine()?.Trim().ToLowerInvariant() != "y") return 1; }
            var (_, done) = await Api("POST", "/v1/command", new JsonObject { ["text"] = text, ["confirm"] = true });
            Console.WriteLine(done?["message"]);
            return 0;
        }
    default:
        Console.WriteLine("nexusctl serve | status | do \"<command>\" [--yes] | rule \"<sentence>\" | rules | review | approve <id> | insights | tasks | search <q> | undo | pause | resume | compile \"<sentence>\" | remote-test <host> <code>");
        return cmd == "help" ? 0 : 1;
}

static async Task<int> Serve()
{
    var store = new NexusStore();
    var engine = new NexusEngine(store);
    var api = new ApiServer(engine);
    var remote = new RemoteServer(api, store);
    api.Remote = remote;
    engine.Notifier = (t, b, _) => Console.WriteLine($"[notify] {t}: {b}");
    engine.Start();
    if (engine.Settings.ApiEnabled) api.Start(engine.Settings.ApiPort);
    if (engine.Settings.RemoteEnabled) remote.Start();
    store.OnChange += e => { if (e == "settings") { var on = engine.Settings.RemoteEnabled; if (on != remote.IsRunning) { if (on) remote.Start(); else remote.Stop(); } } };
    Console.WriteLine($"Nexus engine running · API http://127.0.0.1:{api.Port} · data {Paths.AppSupport}");
    var quit = new TaskCompletionSource();
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; quit.TrySetResult(); };
    AppDomain.CurrentDomain.ProcessExit += (_, _) => quit.TrySetResult();
    await quit.Task;
    engine.Stop(); api.Stop(); remote.Stop();
    return 0;
}

static int Compile(string text)
{
    var r = new NLRuleCompiler().Compile(text);
    if (r.Rule == null) { Console.WriteLine("✗ " + string.Join("; ", r.Warnings)); return 1; }
    Console.WriteLine($"✓ {r.Rule.Name}\n  {r.Rule.Summary}\n  confidence {r.Confidence:0.00}");
    foreach (var e in r.Explanation) Console.WriteLine("  · " + e);
    foreach (var w in r.Warnings) Console.WriteLine("  ⚠ " + w);
    return 0;
}

static (string url, string token)? ApiInfo()
{
    try
    {
        var j = JsonNode.Parse(File.ReadAllText(Path.Combine(Paths.AppSupport, "api.json")))!;
        return (j["url"]!.ToString(), j["token"]!.ToString());
    }
    catch { return null; }
}

static async Task<(int, JsonNode?)> Api(string method, string path, JsonNode? body = null)
{
    var found = ApiInfo();
    if (found is not { } info) { Console.Error.WriteLine("Nexus isn't running (no api.json). Start Nexus or run `nexusctl serve`."); Environment.Exit(2); return (0, null); }
    using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
    using var req = new HttpRequestMessage(new HttpMethod(method), info.url + path);
    req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", info.token);
    if (body != null) req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
    var r = await http.SendAsync(req);
    var text = await r.Content.ReadAsStringAsync();
    try { return ((int)r.StatusCode, JsonNode.Parse(text)); } catch { return ((int)r.StatusCode, JsonValue.Create(text)); }
}

static async Task<int> Call(string method, string path, JsonNode? body = null)
{
    var (status, json) = await Api(method, path, body);
    Console.WriteLine(json?.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
    return status < 400 ? 0 : 1;
}

/// Speaks the same protocol as the Nexus Remote iPhone app.
static async Task<int> RemoteTest(string host, string code)
{
    var baseUrl = host.StartsWith("http") ? host.TrimEnd('/') : $"http://{host}:{RemoteCrypto.DefaultPort}";
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    var failures = 0;
    void Ok(string m) => Console.WriteLine("✓ " + m);
    void Bad(string m) { failures++; Console.WriteLine("✗ " + m); }

    var hello = JsonNode.Parse(await http.GetStringAsync(baseUrl + "/hello"))!;
    var salt = Convert.FromBase64String(hello["salt"]!.ToString());
    Ok($"hello from {hello["name"]} (pairing open: {hello["pairingOpen"]})");

    var wrong = await http.PostAsync(baseUrl + "/pair", new ByteArrayContent(RemoteCrypto.Seal(new JsonObject { ["deviceName"] = "nexusctl" }, RemoteCrypto.PairingKey(code == "000000" ? "111111" : "000000", salt))));
    if ((int)wrong.StatusCode == 401) Ok("wrong code rejected"); else Bad($"wrong code returned {(int)wrong.StatusCode}");

    var pairKey = RemoteCrypto.PairingKey(code, salt);
    var pr = await http.PostAsync(baseUrl + "/pair", new ByteArrayContent(RemoteCrypto.Seal(new JsonObject { ["deviceName"] = "nexusctl remote-test" }, pairKey)));
    if (!pr.IsSuccessStatusCode) { Bad($"pairing failed {(int)pr.StatusCode}: {await pr.Content.ReadAsStringAsync()}"); return 1; }
    var paired = RemoteCrypto.Open(await pr.Content.ReadAsByteArrayAsync(), pairKey);
    var deviceId = paired["deviceId"]!.ToString();
    var key = Convert.FromBase64String(paired["deviceKey"]!.ToString());
    Ok($"paired as {deviceId[..8]} with {paired["macName"]}");

    async Task<(HttpResponseMessage resp, byte[] sent)> Send(string method, string path, JsonObject? body, byte[]? raw = null)
    {
        var env = new JsonObject { ["method"] = method, ["path"] = path, ["ts"] = Time.Epoch(DateTime.Now), ["nonce"] = Convert.ToHexString(RandomNumberGenerator.GetBytes(12)) };
        if (body != null) env["body"] = body;
        var sealedBody = raw ?? RemoteCrypto.Seal(env, key);
        using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl + "/r") { Content = new ByteArrayContent(sealedBody) };
        req.Headers.Add("X-Nexus-Device", deviceId);
        return (await http.SendAsync(req), sealedBody);
    }

    var (sr, sent) = await Send("GET", "/v1/status", null);
    var status = RemoteCrypto.Open(await sr.Content.ReadAsByteArrayAsync(), key);
    if (status["status"]?.GetValue<int>() == 200) Ok($"encrypted status: {status["body"]?["files"]} files, llm {status["body"]?["llm"]}"); else Bad("status failed");

    var (replay, _) = await Send("GET", "/v1/status", null, sent);
    if ((int)replay.StatusCode == 401) Ok("replayed request rejected"); else Bad($"replay returned {(int)replay.StatusCode}");

    var (cr, _) = await Send("POST", "/v1/command", new JsonObject { ["text"] = "brief me" });
    var cmdRes = RemoteCrypto.Open(await cr.Content.ReadAsByteArrayAsync(), key);
    if (cmdRes["body"]?["message"] != null) Ok("command over remote: " + cmdRes["body"]!["message"]!.ToString().Split('\n')[0]); else Bad("command failed");

    var (rr, _) = await Send("GET", "/v1/review", null);
    if (RemoteCrypto.Open(await rr.Content.ReadAsByteArrayAsync(), key)["body"] is JsonArray a) Ok($"review queue: {a.Count} items"); else Bad("review failed");

    var tampered = RemoteCrypto.Seal(new JsonObject { ["method"] = "GET", ["path"] = "/v1/status", ["ts"] = Time.Epoch(DateTime.Now), ["nonce"] = "x" }, key);
    var bytes = Convert.FromBase64String(Encoding.ASCII.GetString(tampered)); bytes[20] ^= 0xFF;
    var (tr, _) = await Send("GET", "/v1/status", null, Encoding.ASCII.GetBytes(Convert.ToBase64String(bytes)));
    if ((int)tr.StatusCode == 400) Ok("tampered ciphertext rejected"); else Bad($"tampered returned {(int)tr.StatusCode}");
    return failures == 0 ? 0 : 1;
}
