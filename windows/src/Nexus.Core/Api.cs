using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Nexus.Core;

public class HttpRequest
{
    public string Method { get; init; } = "GET";
    public string Target { get; init; } = "/";
    public string Path => Target.Split('?')[0];
    public Dictionary<string, string> Headers { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public byte[] Body { get; init; } = [];
    public Dictionary<string, string> Query => ParseQuery(Target);
    public JsonObject Json
    {
        get { try { return JsonNode.Parse(Body.Length == 0 ? "{}" : Encoding.UTF8.GetString(Body)) as JsonObject ?? []; } catch { return []; } }
    }

    static Dictionary<string, string> ParseQuery(string target)
    {
        var d = new Dictionary<string, string>();
        var i = target.IndexOf('?');
        if (i < 0) return d;
        foreach (var kv in target[(i + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var p = kv.Split('=', 2);
            d[Uri.UnescapeDataString(p[0])] = p.Length > 1 ? Uri.UnescapeDataString(p[1].Replace('+', ' ')) : "";
        }
        return d;
    }

    /// Reads one HTTP/1.1 request (Content-Length bodies only), capped at 4 MB.
    public static async Task<HttpRequest?> Read(Stream s, CancellationToken ct)
    {
        var buf = new List<byte>(4096);
        var one = new byte[8192];
        int headerEnd = -1;
        while (headerEnd < 0)
        {
            var n = await s.ReadAsync(one, ct);
            if (n == 0) return null;
            buf.AddRange(one.AsSpan(0, n).ToArray());
            headerEnd = IndexOf(buf, "\r\n\r\n"u8.ToArray());
            if (buf.Count > 64 * 1024 && headerEnd < 0) return null;
        }
        var head = Encoding.ASCII.GetString(buf.GetRange(0, headerEnd).ToArray()).Split("\r\n");
        var first = head[0].Split(' ');
        if (first.Length < 2) return null;
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in head.Skip(1)) { var c = line.IndexOf(':'); if (c > 0) headers[line[..c].Trim()] = line[(c + 1)..].Trim(); }
        var length = headers.TryGetValue("Content-Length", out var cl) && int.TryParse(cl, out var l) ? Math.Min(l, 4 << 20) : 0;
        var body = new List<byte>(buf.Skip(headerEnd + 4));
        while (body.Count < length)
        {
            var n = await s.ReadAsync(one, ct);
            if (n == 0) break;
            body.AddRange(one.AsSpan(0, n).ToArray());
        }
        return new HttpRequest { Method = first[0].ToUpperInvariant(), Target = first[1], Headers = headers, Body = body.Take(length).ToArray() };
    }

    static int IndexOf(List<byte> hay, byte[] needle)
    {
        for (var i = 0; i + needle.Length <= hay.Count; i++)
        {
            var ok = true;
            for (var j = 0; j < needle.Length && ok; j++) ok = hay[i + j] == needle[j];
            if (ok) return i;
        }
        return -1;
    }

    public static async Task Reply(Stream s, int status, byte[] body, string contentType, string? extraHeader = null)
    {
        var reason = status switch { 200 => "OK", 201 => "Created", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 409 => "Conflict", _ => "Error" };
        var head = $"HTTP/1.1 {status} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\n{extraHeader}Connection: close\r\n\r\n";
        await s.WriteAsync(Encoding.ASCII.GetBytes(head));
        await s.WriteAsync(body);
        await s.FlushAsync();
    }
}

/// Tiny HTTP server on a TcpListener (no admin URL ACLs needed, works on any interface).
public class MiniHttpServer(IPAddress address, int port, Func<HttpRequest, Stream, Task> handler)
{
    TcpListener? listener;
    CancellationTokenSource? cts;
    public int Port { get; private set; }
    public bool IsRunning => listener != null;

    public bool Start()
    {
        try
        {
            listener = new TcpListener(address, port);
            listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            cts = new CancellationTokenSource();
            _ = Loop(cts.Token);
            return true;
        }
        catch { listener = null; return false; }
    }

    public void Stop() { cts?.Cancel(); try { listener?.Stop(); } catch { } listener = null; }

    async Task Loop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && listener != null)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(ct); } catch { break; }
            _ = Task.Run(async () =>
            {
                using (client)
                {
                    try
                    {
                        client.ReceiveTimeout = 10_000;
                        var s = client.GetStream();
                        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                        timeout.CancelAfter(TimeSpan.FromSeconds(20));
                        if (await HttpRequest.Read(s, timeout.Token) is { } req) await handler(req, s);
                    }
                    catch { }
                }
            }, ct);
        }
    }
}

/// Local REST API on 127.0.0.1 with a bearer token (api.json). Same routes and JSON shapes as Nexus for Mac.
public class ApiServer(NexusEngine engine)
{
    MiniHttpServer? server;
    public string Token { get; private set; } = "";
    public int Port => server?.Port ?? 0;
    public RemoteServer? Remote { get; set; }

    public void Start(int port)
    {
        Stop();
        Token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        server = new MiniHttpServer(IPAddress.Loopback, port, Handle);
        if (!server.Start()) { server = null; return; }
        File.WriteAllText(Path.Combine(Paths.AppSupport, "api.json"), Json.Str(new { port = server.Port, token = Token, url = $"http://127.0.0.1:{server.Port}" }));
    }

    public void Stop() { server?.Stop(); server = null; }

    async Task Handle(HttpRequest r, Stream s)
    {
        var auth = r.Headers.GetValueOrDefault("Authorization", "");
        if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(auth), Encoding.UTF8.GetBytes("Bearer " + Token)))
        {
            await HttpRequest.Reply(s, 401, Encoding.UTF8.GetBytes("{\"error\":\"missing or invalid token (see %APPDATA%\\\\Nexus\\\\api.json)\"}"), "application/json", "WWW-Authenticate: Bearer\r\n");
            return;
        }
        var (status, obj) = await Route(r);
        await HttpRequest.Reply(s, status, Encoding.UTF8.GetBytes(obj.ToJsonString(Json.Pretty)), "application/json");
    }

    public Task<(int, JsonNode)> Route(string method, string target, byte[] body) =>
        Route(new HttpRequest { Method = method.ToUpperInvariant(), Target = target, Body = body });

    static JsonNode N(object? o) => JsonSerializer.SerializeToNode(o, Json.Options) ?? JsonValue.Create("")!;
    static string? S(JsonObject j, string k) => j.TryGetPropertyValue(k, out var v) && v is JsonValue jv && jv.TryGetValue<string>(out var s) ? s : null;
    static bool B(JsonObject j, string k) => j.TryGetPropertyValue(k, out var v) && v is JsonValue jv && jv.TryGetValue<bool>(out var b) && b;

    public async Task<(int, JsonNode)> Route(HttpRequest r)
    {
        var e = engine;
        var parts = r.Path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var j = r.Json;
        try
        {
            switch (r.Method, parts)
            {
                case ("GET", ["v1", "status"]):
                    {
                        var snap = e.Monitor.Snapshot;
                        return (200, N(new
                        {
                            status = e.Status.ToString(), paused = e.Paused, files = e.Store.FileCount(), review = e.Store.ReviewCount(), rules = e.Store.Rules().Count,
                            runningTasks = e.Queue.RunningCount, insights = e.Store.Insights().Count, diskFreeGB = (int)snap.DiskFreeGB, llm = await e.Llm.ProviderName(),
                            platform = "windows", machine = Platform.Current.MachineName,
                            focus = e.Focus is { } f ? new { project = e.Store.Project(f.ProjectId)?.Name ?? "", endsAt = Time.Iso(f.EndsAt) } : null,
                        }));
                    }
                case ("POST", ["v1", "command"]):
                    {
                        var plan = await e.Plan(S(j, "text") ?? "");
                        if (B(j, "confirm") || !plan.RequiresConfirmation)
                        {
                            var res = await e.Execute(plan);
                            return (200, N(new { executed = true, message = res.Message, details = res.Details, files = res.Files.Take(200).Select(f => f.Path), batchId = res.BatchId }));
                        }
                        return (200, N(new
                        {
                            executed = false, understood = plan.Understood, requiresConfirmation = true,
                            steps = plan.Steps.Select(p => new { intent = p.Step.Intent.Label, text = p.Step.Text, note = p.Note ?? "", preview = p.Preview }),
                        }));
                    }
                case ("GET", ["v1", "rules"]): return (200, N(e.Store.Rules().Select(RuleJson)));
                case ("POST", ["v1", "rules"]):
                    {
                        var result = await e.CompileRule(S(j, "text") ?? "");
                        if (result.Rule is not { } rule) return (400, N(new { error = "could not compile", warnings = result.Warnings }));
                        if (B(j, "dryRun")) return (200, N(new { rule = RuleJson(rule), explanation = result.Explanation, warnings = result.Warnings }));
                        rule.Enabled = !j.ContainsKey("enabled") || B(j, "enabled");
                        e.Store.SaveRule(rule); e.RestartWatcher();
                        return (201, N(new { rule = RuleJson(rule), explanation = result.Explanation, warnings = result.Warnings }));
                    }
                case ("POST", ["v1", "rules", var id, "run"]):
                    {
                        var rule = e.Store.Rule(id) ?? e.Store.Rules().FirstOrDefault(x => x.Name.Contains(id, StringComparison.OrdinalIgnoreCase));
                        if (rule == null) return (404, N(new { error = "rule not found" }));
                        var job = e.Queue.Enqueue(new Job { Name = $"Run rule: {rule.Name}", Kind = JobKind.file, Priority = JobPriority.high, Spec = new JobSpec { Operation = JobOperation.runRule, RuleId = rule.Id } });
                        return (200, N(new { jobId = job.Id }));
                    }
                case ("DELETE", ["v1", "rules", var did]): e.Store.DeleteRule(did); return (200, N(new { deleted = did }));
                case ("POST", ["v1", "simulate"]):
                    {
                        if (S(j, "path") is not { } p || e.Simulate(Paths.Expand(p)) is not { } rep) return (400, N(new { error = "path not readable" }));
                        return (200, N(new
                        {
                            file = rep.File.Path, docType = rep.File.DocType ?? "", topics = rep.File.Topics, conflicts = rep.Conflicts,
                            rules = rep.Evaluations.Select(ev => new
                            {
                                rule = ev.Rule.Name, fired = ev.Fired, triggerMatched = ev.TriggerMatched, blockedByStop = ev.SkippedByStop,
                                conditions = ev.ConditionResults.Select(c => new { condition = c.Condition.Summary, passed = c.Passed, actual = c.Actual }), actions = ev.PlannedActions,
                            }),
                        }));
                    }
                case ("GET", ["v1", "tasks"]):
                    return (200, N(e.Store.Jobs(int.TryParse(r.Query.GetValueOrDefault("limit"), out var lim) ? lim : 50).Select(x => new
                    {
                        id = x.Id, name = x.Name, kind = x.Kind.ToString(), status = x.Status.ToString(), priority = x.Priority.ToString(), created = Time.Iso(x.CreatedAt),
                        result = x.ResultSummary ?? "", error = x.Error ?? "", log = x.Log.TakeLast(20),
                    })));
                case ("POST", ["v1", "tasks"]):
                    {
                        if (!Enum.TryParse<JobOperation>(S(j, "operation"), out var op)) return (400, N(new { error = "operation required", valid = Enum.GetNames<JobOperation>() }));
                        var ps = j["params"] is JsonObject po ? po.ToDictionary(kv => kv.Key, kv => kv.Value?.ToString() ?? "") : [];
                        var job = e.Queue.Enqueue(new Job { Name = S(j, "name") ?? op.ToString(), Kind = JobKind.system, Priority = JobPriority.high, Spec = new JobSpec { Operation = op, Path = S(j, "path"), Command = S(j, "command"), Params = ps } });
                        return (201, N(new { jobId = job.Id }));
                    }
                case ("POST", ["v1", "tasks", var tid, "retry"]): e.Queue.Retry(tid); return (200, N(new { retried = tid }));
                case ("POST", ["v1", "tasks", var cid, "cancel"]): e.Queue.CancelJob(cid); return (200, N(new { cancelled = cid }));
                case ("GET", ["v1", "schedule"]): return (200, N(e.Scheduler.Upcoming().Select(u => new { at = Time.Iso(u.at), name = u.name })));
                case ("GET", ["v1", "insights"]):
                    return (200, N(e.Store.Insights().Select(i => new { id = i.Id, kind = i.Kind.ToString(), title = i.Title, detail = i.Detail, severity = i.Severity.ToString(), command = i.Command ?? "" })));
                case ("POST", ["v1", "insights", var iid, "dismiss"]): e.Store.DismissInsight(iid); return (200, N(new { dismissed = iid }));
                case ("GET", ["v1", "search"]):
                    {
                        var q = new CommandParser(new NLRuleCompiler()).Query(r.Query.GetValueOrDefault("q", ""));
                        return (200, N(e.Resolve(q, []).Take(200).Select(f => new { path = f.Path, docType = f.DocType ?? "", tags = f.Tags, topics = f.Topics, project = f.ProjectId ?? "" })));
                    }
                case ("GET", ["v1", "projects"]):
                    return (200, N(e.Store.Projects().Select(p => { var st = e.Store.ProjectStats(p.Id); return new { id = p.Id, name = p.Name, files = st.count, bytes = st.size, deadline = p.Deadline is { } d ? Time.Iso(d) : "", keywords = p.Keywords }; })));
                case ("POST", ["v1", "projects"]):
                    {
                        var p = new Project
                        {
                            Name = S(j, "name") ?? "Untitled", Folders = j["folders"]?.AsArray().Select(x => x!.ToString()).ToList() ?? [],
                            Keywords = j["keywords"]?.AsArray().Select(x => x!.ToString()).ToList() ?? [], Tags = j["tags"]?.AsArray().Select(x => x!.ToString()).ToList() ?? [],
                        };
                        if (j["dueInDays"] is JsonValue dv && dv.TryGetValue<double>(out var days)) p.Deadline = DateTime.Now.AddDays(days);
                        e.Store.SaveProject(p); e.RebuildProjectVectors();
                        return (201, N(new { id = p.Id }));
                    }
                case ("GET", ["v1", "report"]): return (200, N(new { markdown = e.Reports.Markdown(r.Query.GetValueOrDefault("type", "weekly")) }));
                case ("POST", ["v1", "remote", "pairing"]):
                    if (Remote is not { IsRunning: true }) return (409, N(new { error = "Enable Nexus Remote first" }));
                    return (200, N(new { code = Remote.BeginPairing(), port = Remote.Port, name = Remote.MachineName }));
                case ("GET", ["v1", "remote", "devices"]): return (200, N((Remote?.Devices ?? []).Select(d => new { id = d.Id, name = d.Name })));
                case ("GET", ["v1", "review"]):
                    return (200, N(e.Store.ReviewItems().Select(i => new { id = i.Id, path = i.Path, destination = i.SuggestedDestination ?? "", tags = i.SuggestedTags, confidence = i.Confidence, reasons = i.Reasons, alternatives = i.Alternatives })));
                case ("POST", ["v1", "review", var rid, var verb]) when verb is "approve" or "reject":
                    {
                        if (e.Store.ReviewItems().FirstOrDefault(i => i.Id == rid) is not { } item) return (404, N(new { error = "review item not found" }));
                        if (verb == "approve") await e.Approve(item, S(j, "destination") is { } d ? Paths.Expand(d) : null, j["tags"]?.AsArray().Select(x => x!.ToString()).ToList());
                        else e.Reject(item);
                        return (200, N(new Dictionary<string, string> { [verb] = item.Id }));
                    }
                case ("GET", ["v1", "files"]):
                    {
                        if (r.Query.GetValueOrDefault("path") is { } path && e.Store.FileByPath(Paths.Expand(path)) is { } f)
                            return (200, N(new
                            {
                                id = f.Id, path = f.Path, kind = f.Kind.ToString(), docType = f.DocType ?? "", topics = f.Topics, tags = f.Tags, project = f.ProjectId ?? "",
                                status = f.Status.ToString(), confidence = f.Confidence, entities = f.Entities.Select(x => $"{x.Kind}:{x.Value}"), suggestions = e.DebugSuggestions(f),
                            }));
                        return (404, N(new { error = "not indexed" }));
                    }
                case ("GET", ["v1", "events"]):
                    return (200, N(e.Store.Events(int.TryParse(r.Query.GetValueOrDefault("limit"), out var el) ? el : 50).Select(x => new { kind = x.Kind.ToString(), message = x.Message, undone = x.Undone, batch = x.BatchId ?? "" })));
                case ("POST", ["v1", "events"]):
                    {
                        var name = S(j, "name") ?? "custom";
                        var payload = j["payload"] is JsonObject po ? po.ToDictionary(kv => kv.Key, kv => kv.Value?.ToString() ?? "") : new Dictionary<string, string>();
                        payload["connectorEvent"] = name.Contains('.') ? name : "custom." + name;
                        payload.TryAdd("source", "API");
                        e.FireEventRules(TriggerKind.connectorEvent, payload);
                        return (200, N(new { accepted = payload["connectorEvent"] }));
                    }
                case ("GET", ["v1", "settings"]): return (200, N(e.Settings));
                case ("POST", ["v1", "settings"]):
                    {
                        var current = JsonSerializer.SerializeToNode(e.Settings, Json.Options)!.AsObject();
                        foreach (var (k, v) in j) current[k] = v?.DeepClone();
                        var updated = current.Deserialize<NexusSettings>(Json.Options);
                        if (updated == null) return (400, N(new { error = "invalid settings" }));
                        e.UpdateSettings(updated);
                        return (200, N(new { ok = true }));
                    }
                case ("POST", ["v1", "undo"]): return (200, N(new { undone = e.UndoLast() }));
                case ("POST", ["v1", "pause"]): e.SetPaused(true); return (200, N(new { paused = true }));
                case ("POST", ["v1", "resume"]): e.SetPaused(false); return (200, N(new { paused = false }));
                case ("POST", ["v1", "ingest"]):
                    {
                        if (S(j, "path") is not { } p) return (400, N(new { error = "path required" }));
                        e.EnqueueIngest(Paths.Expand(p), TriggerKind.manual);
                        return (200, N(new { queued = Paths.Expand(p) }));
                    }
                default: return (404, N(new { error = $"unknown endpoint {r.Method} {r.Path}" }));
            }
        }
        catch (Exception ex) { return (500, N(new { error = ex.Message })); }
    }

    static object RuleJson(Rule r) => new
    {
        id = r.Id, name = r.Name, enabled = r.Enabled, summary = r.Summary, hits = r.HitCount, priority = r.Priority,
        lastTriggered = r.LastTriggeredAt is { } d ? Time.Iso(d) : "", naturalLanguage = r.NaturalLanguage ?? "",
    };
}
