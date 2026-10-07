using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Nexus.Core;

// Formula 1 module: live timing, race control, weather, schedule and standings.
// Sources (public, no API key, no account): OpenF1 (live timing) and the Jolpica/Ergast mirror (schedule + standings).

public record F1Session(long SessionKey, long MeetingKey, string Name, string Type, string Location, string Country, string Circuit, DateTime StartUtc, DateTime EndUtc, int Year)
{
    public DateTime StartLocal => StartUtc.ToLocalTime();
    public DateTime EndLocal => EndUtc.ToLocalTime();
    public bool IsLive(DateTime? nowUtc = null) { var n = nowUtc ?? DateTime.UtcNow; return n >= StartUtc.AddMinutes(-5) && n <= EndUtc.AddMinutes(15); }
    public string Title => $"{Location} · {Name}";
}

public record F1Driver(int Number, string Acronym, string FullName, string Team, string Colour);

public record F1Row(int Position, F1Driver Driver, double? GapToLeader, double? Interval, double? LastLap, double? BestLap, int Lap, string? Compound, int? TyreAge, bool InPit)
{
    public string Gap => Position == 1 ? "LEADER" : GapToLeader is { } g ? (g >= 60 ? $"+{g / 60:0}L" : $"+{g:0.000}") : "—";
    public string Int => Position == 1 ? "—" : Interval is { } i ? $"+{i:0.000}" : "—";
    public string Last => LastLap is { } l ? Format(l) : "—";
    public string Best => BestLap is { } b ? Format(b) : "—";
    public string Tyre => Compound is { Length: > 0 } c ? $"{char.ToUpperInvariant(c[0])}{(TyreAge is { } a ? " " + a : "")}" : "—";
    public static string Format(double seconds) => seconds >= 60 ? $"{(int)(seconds / 60)}:{seconds % 60:00.000}" : $"{seconds:0.000}";
}

public record F1Message(DateTime Utc, string Category, string? Flag, string Text)
{
    public string Time => Utc.ToLocalTime().ToString("HH:mm");
}

public record F1Weather(double AirTemp, double TrackTemp, double Humidity, double WindSpeed, bool Raining)
{
    public string Summary => $"Air {AirTemp:0.#}° · Track {TrackTemp:0.#}° · {(Raining ? "rain" : "dry")} · wind {WindSpeed:0.#} m/s · humidity {Humidity:0}%";
}

public record F1Live(F1Session Session, List<F1Row> Rows, List<F1Message> Messages, F1Weather? Weather, string Status, int? Lap, int? TotalLaps)
{
    public bool Running => Session.IsLive();
}

public record F1Standing(int Position, string Code, string Name, string Team, double Points, int Wins);
public record F1Race(string Name, string Circuit, string Locality, string Country, DateTime StartUtc, int Round, List<(string name, DateTime startUtc)> Sessions)
{
    public DateTime StartLocal => StartUtc.ToLocalTime();
    public string Countdown => CountdownAt(DateTime.UtcNow);
    public string CountdownAt(DateTime nowUtc)
    {
        var d = StartUtc - nowUtc;
        if (d.TotalSeconds <= 0) return "under way";
        if (d.TotalDays >= 1) return $"in {(int)d.TotalDays}d {d.Hours}h";
        return d.TotalHours >= 1 ? $"in {(int)d.TotalHours}h {d.Minutes}m" : $"in {(int)d.TotalMinutes}m";
    }
}

/// Polls OpenF1 / Jolpica politely and caches everything; every call degrades to a cached or empty result when offline.
public class F1Service
{
    public const string OpenF1 = "https://api.openf1.org/v1/";
    public const string Jolpica = "https://api.jolpi.ca/ergast/f1/";

    readonly HttpClient http;
    readonly Dictionary<string, (DateTime at, JsonNode? data)> cache = new();
    readonly SemaphoreSlim gate = new(3, 3);
    public Func<DateTime> Now { get; set; } = () => DateTime.UtcNow;
    public string? BaseOverride { get; set; }           // tests point this at a local folder of fixtures
    public Exception? LastError { get; private set; }

    public F1Service(HttpClient? client = null)
    {
        http = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(12) };
        http.DefaultRequestHeaders.UserAgent.TryParseAdd("Nexus/1.0 (+https://github.com/AdityaJainDXB/Nexus)");
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    async Task<JsonNode?> Get(string url, TimeSpan ttl)
    {
        lock (cache) if (cache.TryGetValue(url, out var hit) && Now() - hit.at < ttl) return hit.data;
        await gate.WaitAsync();
        try
        {
            lock (cache) if (cache.TryGetValue(url, out var hit2) && Now() - hit2.at < ttl) return hit2.data;
            JsonNode? node;
            if (BaseOverride is { Length: > 0 } dir)
            {
                var file = Path.Combine(dir, Fixture(url));
                node = File.Exists(file) ? JsonNode.Parse(File.ReadAllText(file)) : null;
            }
            else
            {
                using var r = await http.GetAsync(url);
                if (!r.IsSuccessStatusCode) throw new HttpRequestException($"{(int)r.StatusCode} from {new Uri(url).Host}");
                node = JsonNode.Parse(await r.Content.ReadAsStringAsync());
            }
            lock (cache) cache[url] = (Now(), node);
            LastError = null;
            return node;
        }
        catch (Exception ex)
        {
            LastError = ex;
            lock (cache) return cache.TryGetValue(url, out var stale) ? stale.data : null;   // stale beats nothing
        }
        finally { gate.Release(); }
    }

    /// Fixture file name for a URL (tests): "intervals_session_key=latest.json"
    public static string Fixture(string url)
    {
        var u = new Uri(url);
        var name = u.AbsolutePath.TrimEnd('/').Split('/').Last();
        if (name.EndsWith(".json")) name = name[..^5];
        var q = u.Query.TrimStart('?').Replace("&", "_").Replace(">", "gt").Replace("=", "-");
        return (q.Length == 0 ? name : $"{name}_{q}") + ".json";
    }

    static double? Num(JsonNode? n) => n is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
    static int? Int(JsonNode? n) => n is JsonValue v && v.TryGetValue<double>(out var d) ? (int)d : null;
    static string Str(JsonNode? n) => n?.GetValue<string>() ?? "";
    static DateTime Utc(JsonNode? n) => DateTime.TryParse(Str(n), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d) ? d : DateTime.MinValue;

    // MARK: live timing

    public async Task<F1Session?> LatestSession()
    {
        if (await Get(OpenF1 + "sessions?session_key=latest", TimeSpan.FromMinutes(2)) is not JsonArray a || a.Count == 0) return null;
        var s = a[^1]!;
        return new F1Session((long)(Num(s["session_key"]) ?? 0), (long)(Num(s["meeting_key"]) ?? 0), Str(s["session_name"]), Str(s["session_type"]),
            Str(s["location"]), Str(s["country_name"]), Str(s["circuit_short_name"]), Utc(s["date_start"]), Utc(s["date_end"]), Int(s["year"]) ?? 0);
    }

    public async Task<Dictionary<int, F1Driver>> Drivers(long sessionKey)
    {
        var outMap = new Dictionary<int, F1Driver>();
        if (await Get($"{OpenF1}drivers?session_key={sessionKey}", TimeSpan.FromMinutes(30)) is not JsonArray a) return outMap;
        foreach (var d in a)
        {
            var n = Int(d?["driver_number"]);
            if (n is not { } num) continue;
            outMap[num] = new F1Driver(num, Str(d?["name_acronym"]), Str(d?["full_name"]), Str(d?["team_name"]), Str(d?["team_colour"]));
        }
        return outMap;
    }

    /// Full live picture: order, gaps, last/best laps, tyres, flags, weather.
    public async Task<F1Live?> Live()
    {
        if (await LatestSession() is not { } session) return null;
        var key = session.SessionKey;
        var fast = session.IsLive(Now()) ? TimeSpan.FromSeconds(4) : TimeSpan.FromMinutes(10);
        var drivers = await Drivers(key);

        var positions = new Dictionary<int, (int pos, DateTime at)>();
        if (await Get($"{OpenF1}position?session_key={key}", fast) is JsonArray pos)
            foreach (var p in pos)
            {
                var n = Int(p?["driver_number"]); var place = Int(p?["position"]); var at = Utc(p?["date"]);
                if (n is { } num && place is { } pl && (!positions.TryGetValue(num, out var prev) || at >= prev.at)) positions[num] = (pl, at);
            }

        var gaps = new Dictionary<int, (double? gap, double? interval, DateTime at)>();
        if (await Get($"{OpenF1}intervals?session_key={key}", fast) is JsonArray iv)
            foreach (var i in iv)
            {
                var n = Int(i?["driver_number"]); var at = Utc(i?["date"]);
                if (n is { } num && (!gaps.TryGetValue(num, out var prev) || at >= prev.at)) gaps[num] = (Num(i?["gap_to_leader"]), Num(i?["interval"]), at);
            }

        var last = new Dictionary<int, (double? lap, double? best, int number, bool pitOut)>();
        if (await Get($"{OpenF1}laps?session_key={key}", session.IsLive(Now()) ? TimeSpan.FromSeconds(8) : TimeSpan.FromMinutes(10)) is JsonArray laps)
            foreach (var l in laps)
            {
                var n = Int(l?["driver_number"]); var num = Int(l?["lap_number"]) ?? 0; var dur = Num(l?["lap_duration"]);
                if (n is not { } d) continue;
                last.TryGetValue(d, out var prev);
                var best = dur is { } x && (prev.best == null || x < prev.best) ? x : prev.best;
                if (num >= prev.number) last[d] = (dur ?? prev.lap, best, num, l?["is_pit_out_lap"]?.GetValue<bool>() ?? false);
                else last[d] = (prev.lap, best, prev.number, prev.pitOut);
            }

        var stints = new Dictionary<int, (string compound, int age)>();
        if (await Get($"{OpenF1}stints?session_key={key}", TimeSpan.FromSeconds(30)) is JsonArray st)
            foreach (var s in st)
            {
                var n = Int(s?["driver_number"]);
                if (n is not { } d) continue;
                var lapStart = Int(s?["lap_start"]) ?? 0;
                var age = (Int(s?["tyre_age_at_start"]) ?? 0) + Math.Max(0, (last.TryGetValue(d, out var li) ? li.number : lapStart) - lapStart);
                if (!stints.TryGetValue(d, out var prev) || lapStart >= 0) stints[d] = (Str(s?["compound"]), age);
            }

        var messages = new List<F1Message>();
        if (await Get($"{OpenF1}race_control?session_key={key}", TimeSpan.FromSeconds(10)) is JsonArray rc)
            foreach (var m in rc) messages.Add(new F1Message(Utc(m?["date"]), Str(m?["category"]), m?["flag"]?.GetValue<string>(), Str(m?["message"])));
        messages = messages.OrderByDescending(m => m.Utc).Take(40).ToList();

        F1Weather? weather = null;
        if (await Get($"{OpenF1}weather?session_key={key}", TimeSpan.FromSeconds(30)) is JsonArray w && w.Count > 0)
        {
            var x = w[^1]!;
            weather = new F1Weather(Num(x["air_temperature"]) ?? 0, Num(x["track_temperature"]) ?? 0, Num(x["humidity"]) ?? 0, Num(x["wind_speed"]) ?? 0, (Num(x["rainfall"]) ?? 0) > 0);
        }

        var rows = positions.Where(p => drivers.ContainsKey(p.Key)).Select(p =>
        {
            var d = drivers[p.Key];
            gaps.TryGetValue(p.Key, out var g);
            last.TryGetValue(p.Key, out var l);
            stints.TryGetValue(p.Key, out var s);
            return new F1Row(p.Value.pos, d, g.gap, g.interval, l.lap, l.best, l.number, s.compound, s.age, l.pitOut);
        }).OrderBy(r => r.Position).ToList();

        var flag = messages.FirstOrDefault(m => m.Category.Equals("Flag", StringComparison.OrdinalIgnoreCase));
        var status = !session.IsLive(Now()) ? (Now() > session.EndUtc ? "FINISHED" : "NOT STARTED")
            : messages.Any(m => m.Text.Contains("CHEQUERED", StringComparison.OrdinalIgnoreCase)) ? "CHEQUERED FLAG"
            : flag?.Flag is { Length: > 0 } f && !f.Equals("CLEAR", StringComparison.OrdinalIgnoreCase) ? f.ToUpperInvariant() : "GREEN";
        var lap = rows.Count > 0 ? rows.Max(r => r.Lap) : (int?)null;
        return new F1Live(session, rows, messages, weather, status, lap == 0 ? null : lap, null);
    }

    // MARK: schedule & standings

    public async Task<F1Race?> NextRace()
    {
        var node = await Get(Jolpica + "current/next.json", TimeSpan.FromHours(1));
        var race = node?["MRData"]?["RaceTable"]?["Races"]?.AsArray().FirstOrDefault();
        if (race == null) return null;
        var sessions = new List<(string, DateTime)>();
        void Add(string label, string key)
        {
            if (race[key] is { } s && DateTime.TryParse($"{Str(s["date"])}T{Str(s["time"])}", CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var at))
                sessions.Add((label, at));
        }
        Add("Practice 1", "FirstPractice"); Add("Practice 2", "SecondPractice"); Add("Practice 3", "ThirdPractice");
        Add("Sprint Qualifying", "SprintQualifying"); Add("Sprint", "Sprint"); Add("Qualifying", "Qualifying");
        var start = DateTime.TryParse($"{Str(race["date"])}T{Str(race["time"])}", CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var r) ? r : DateTime.MinValue;
        sessions.Add(("Race", start));
        return new F1Race(Str(race["raceName"]), Str(race["Circuit"]?["circuitName"]), Str(race["Circuit"]?["Location"]?["locality"]),
            Str(race["Circuit"]?["Location"]?["country"]), start, int.TryParse(Str(race["round"]), out var rd) ? rd : 0, sessions.OrderBy(s => s.Item2).ToList());
    }

    public async Task<List<F1Standing>> DriverStandings()
    {
        var node = await Get(Jolpica + "current/driverStandings.json", TimeSpan.FromHours(3));
        var list = node?["MRData"]?["StandingsTable"]?["StandingsLists"]?.AsArray().FirstOrDefault()?["DriverStandings"]?.AsArray();
        return list?.Select(s => new F1Standing(
            int.TryParse(Str(s?["position"]), out var p) ? p : 0,
            Str(s?["Driver"]?["code"]),
            $"{Str(s?["Driver"]?["givenName"])} {Str(s?["Driver"]?["familyName"])}".Trim(),
            Str(s?["Constructors"]?.AsArray().FirstOrDefault()?["name"]),
            double.TryParse(Str(s?["points"]), CultureInfo.InvariantCulture, out var pts) ? pts : 0,
            int.TryParse(Str(s?["wins"]), out var w) ? w : 0)).ToList() ?? [];
    }

    public async Task<List<F1Standing>> ConstructorStandings()
    {
        var node = await Get(Jolpica + "current/constructorStandings.json", TimeSpan.FromHours(3));
        var list = node?["MRData"]?["StandingsTable"]?["StandingsLists"]?.AsArray().FirstOrDefault()?["ConstructorStandings"]?.AsArray();
        return list?.Select(s => new F1Standing(
            int.TryParse(Str(s?["position"]), out var p) ? p : 0,
            Str(s?["Constructor"]?["constructorId"]),
            Str(s?["Constructor"]?["name"]),
            Str(s?["Constructor"]?["nationality"]),
            double.TryParse(Str(s?["points"]), CultureInfo.InvariantCulture, out var pts) ? pts : 0,
            int.TryParse(Str(s?["wins"]), out var w) ? w : 0)).ToList() ?? [];
    }

    public async Task<(string name, List<F1Standing> order)> LastResults()
    {
        var node = await Get(Jolpica + "current/last/results.json", TimeSpan.FromHours(1));
        var race = node?["MRData"]?["RaceTable"]?["Races"]?.AsArray().FirstOrDefault();
        var results = race?["Results"]?.AsArray();
        var order = results?.Select(r => new F1Standing(
            int.TryParse(Str(r?["position"]), out var p) ? p : 0,
            Str(r?["Driver"]?["code"]),
            $"{Str(r?["Driver"]?["givenName"])} {Str(r?["Driver"]?["familyName"])}".Trim(),
            Str(r?["Constructor"]?["name"]),
            double.TryParse(Str(r?["points"]), CultureInfo.InvariantCulture, out var pts) ? pts : 0,
            Str(r?["position"]) == "1" ? 1 : 0)).ToList() ?? [];
        return (Str(race?["raceName"]), order);
    }

    // MARK: text for the palette, voice and the iPhone app

    public async Task<string> Summary(string kind = "auto", string? favourite = null)
    {
        try
        {
            if (kind is "standings" or "championship") return StandingsText(await DriverStandings(), await ConstructorStandings());
            if (kind is "results" or "last") { var (name, order) = await LastResults(); return ResultsText(name, order); }
            if (kind is "next" or "schedule") return NextText(await NextRace());

            var live = await Live();
            if (live is { Running: true, Rows.Count: > 0 }) return LiveText(live, favourite);
            if (live is { Rows.Count: > 0 } finished && Now() - finished.Session.EndUtc < TimeSpan.FromHours(6))
                return $"{finished.Session.Title} finished — " + string.Join(", ", finished.Rows.Take(3).Select(r => $"P{r.Position} {r.Driver.Acronym}")) + ". " + NextText(await NextRace());
            return NextText(await NextRace()) + " " + StandingsText(await DriverStandings(), []);
        }
        catch (Exception ex) { return "Couldn't reach the F1 timing service (" + ex.Message + ")."; }
    }

    public static string LiveText(F1Live live, string? favourite = null)
    {
        var top = live.Rows.Take(5).Select(r => r.Position == 1 ? $"P1 {r.Driver.Acronym}" : $"P{r.Position} {r.Driver.Acronym} {r.Gap}");
        var text = $"{live.Session.Title} is live{(live.Lap is { } l ? $", lap {l}" : "")} · {live.Status}. " + string.Join(", ", top) + ".";
        if (favourite is { Length: > 0 } fav && live.Rows.FirstOrDefault(r => r.Driver.Acronym.Equals(fav, StringComparison.OrdinalIgnoreCase) || r.Driver.FullName.Contains(fav, StringComparison.OrdinalIgnoreCase)) is { } row)
            text += $" {row.Driver.Acronym} is P{row.Position}{(row.Position > 1 ? $" ({row.Gap})" : "")}, last lap {row.Last}.";
        return text;
    }

    public static string NextText(F1Race? race) =>
        race == null ? "No upcoming race found." :
        $"Next: {race.Name} at {race.Circuit}, {race.Locality} — lights out {race.StartLocal:ddd d MMM, HH:mm} ({race.Countdown}).";

    public static string StandingsText(List<F1Standing> drivers, List<F1Standing> teams)
    {
        if (drivers.Count == 0) return "";
        var d = "Championship: " + string.Join(", ", drivers.Take(3).Select(s => $"{s.Position}. {s.Code} {s.Points:0.#}"));
        return teams.Count == 0 ? d + "." : d + " · Teams: " + string.Join(", ", teams.Take(3).Select(s => $"{s.Position}. {s.Name} {s.Points:0.#}")) + ".";
    }

    public static string ResultsText(string race, List<F1Standing> order) =>
        order.Count == 0 ? "No results yet." : $"{race}: " + string.Join(", ", order.Take(5).Select(s => $"P{s.Position} {s.Code}")) + ".";
}
