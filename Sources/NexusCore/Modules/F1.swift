import Foundation

// Formula 1 module: live timing, race control, schedule and standings.
// Public feeds, no key and no account: OpenF1 for live timing, the Jolpica/Ergast mirror for schedule and championships.

public struct F1Session: Hashable, Sendable {
    public var sessionKey: Int
    public var name: String
    public var type: String
    public var location: String
    public var country: String
    public var circuit: String
    public var start: Date
    public var end: Date
    public var year: Int

    public var title: String { "\(location) · \(name)" }
    public func isLive(_ now: Date = Date()) -> Bool { now >= start.addingTimeInterval(-300) && now <= end.addingTimeInterval(900) }
}

public struct F1Driver: Hashable, Sendable {
    public var number: Int
    public var acronym: String
    public var fullName: String
    public var team: String
    public var colour: String
}

public struct F1Row: Hashable, Identifiable, Sendable {
    public var id: Int { driver.number }
    public var position: Int
    public var driver: F1Driver
    public var gapToLeader: Double?
    public var interval: Double?
    public var lastLap: Double?
    public var bestLap: Double?
    public var lap: Int
    public var compound: String?
    public var tyreAge: Int?

    public var gap: String { position == 1 ? "LEADER" : gapToLeader.map { $0 >= 60 ? "+\(Int($0 / 60))L" : String(format: "+%.3f", $0) } ?? "—" }
    public var intervalText: String { position == 1 ? "—" : interval.map { String(format: "+%.3f", $0) } ?? "—" }
    public var last: String { lastLap.map(F1Row.format) ?? "—" }
    public var best: String { bestLap.map(F1Row.format) ?? "—" }
    public var tyre: String {
        guard let c = compound, let f = c.first else { return "—" }
        return tyreAge.map { "\(f.uppercased()) \($0)" } ?? String(f).uppercased()
    }

    public static func format(_ seconds: Double) -> String {
        seconds >= 60 ? String(format: "%d:%06.3f", Int(seconds / 60), seconds.truncatingRemainder(dividingBy: 60)) : String(format: "%.3f", seconds)
    }
}

public struct F1Message: Hashable, Identifiable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)-\(text)" }
    public var date: Date
    public var category: String
    public var flag: String?
    public var text: String
    public var time: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

public struct F1Weather: Hashable, Sendable {
    public var airTemp: Double, trackTemp: Double, humidity: Double, windSpeed: Double
    public var raining: Bool
    public var summary: String {
        String(format: "Air %.1f° · Track %.1f° · %@ · wind %.1f m/s · humidity %.0f%%", airTemp, trackTemp, raining ? "rain" : "dry", windSpeed, humidity)
    }
}

public struct F1Live: Sendable {
    public var session: F1Session
    public var rows: [F1Row]
    public var messages: [F1Message]
    public var weather: F1Weather?
    public var status: String
    public var lap: Int?
    public var running: Bool { session.isLive() }
}

public struct F1Standing: Hashable, Identifiable, Sendable {
    public var id: String { code + name }
    public var position: Int
    public var code: String
    public var name: String
    public var team: String
    public var points: Double
    public var wins: Int
}

public struct F1Race: Sendable {
    public var name: String
    public var circuit: String
    public var locality: String
    public var country: String
    public var start: Date
    public var round: Int
    public var sessions: [(name: String, start: Date)]

    public var countdown: String {
        let d = start.timeIntervalSinceNow
        if d <= 0 { return "under way" }
        if d >= 86400 { return "in \(Int(d / 86400))d \(Int(d.truncatingRemainder(dividingBy: 86400) / 3600))h" }
        if d >= 3600 { return "in \(Int(d / 3600))h \(Int(d.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "in \(max(1, Int(d / 60)))m"
    }
}

/// Polls the public feeds politely, caches everything and falls back to the last good answer when offline.
public final class F1Service: @unchecked Sendable {
    public static let openF1 = "https://api.openf1.org/v1/"
    public static let jolpica = "https://api.jolpi.ca/ergast/f1/"

    private let session: URLSession
    private var cache: [String: (at: Date, data: Any)] = [:]
    private let lock = NSLock()
    public var fixtures: URL?            // tests read recorded JSON instead of the network
    public private(set) var lastError: String?

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "Nexus/1.0 (+https://github.com/AdityaJainDXB/Nexus)"]
        session = URLSession(configuration: config)
    }

    private func get(_ url: String, ttl: TimeInterval) async -> Any? {
        lock.lock()
        if let hit = cache[url], Date().timeIntervalSince(hit.at) < ttl { lock.unlock(); return hit.data }
        lock.unlock()
        do {
            let data: Data
            if let fixtures {
                let file = fixtures.appendingPathComponent(Self.fixtureName(url))
                data = try Data(contentsOf: file)
            } else {
                guard let u = URL(string: url) else { return nil }
                let (d, response) = try await session.data(from: u)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw NSError(domain: "f1", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]) }
                data = d
            }
            let json = try JSONSerialization.jsonObject(with: data)
            lock.lock(); cache[url] = (Date(), json); lastError = nil; lock.unlock()
            return json
        } catch {
            lock.lock(); lastError = error.localizedDescription; let stale = cache[url]?.data; lock.unlock()
            return stale
        }
    }

    /// "sessions?session_key=latest" → "sessions_session_key-latest.json"
    public static func fixtureName(_ url: String) -> String {
        guard let u = URL(string: url) else { return "x.json" }
        var name = u.lastPathComponent
        if name.hasSuffix(".json") { name = String(name.dropLast(5)) }
        let q = (u.query ?? "").replacingOccurrences(of: "&", with: "_").replacingOccurrences(of: "=", with: "-")
        return (q.isEmpty ? name : "\(name)_\(q)") + ".json"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func date(_ s: Any?) -> Date {
        guard let str = s as? String else { return .distantPast }
        return iso.date(from: str) ?? ISO8601DateFormatter().date(from: str) ?? .distantPast
    }

    // MARK: live timing

    public func latestSession() async -> F1Session? {
        guard let a = await get(Self.openF1 + "sessions?session_key=latest", ttl: 120) as? [[String: Any]], let s = a.last else { return nil }
        return F1Session(sessionKey: s["session_key"] as? Int ?? 0, name: s["session_name"] as? String ?? "Session", type: s["session_type"] as? String ?? "",
                         location: s["location"] as? String ?? "", country: s["country_name"] as? String ?? "", circuit: s["circuit_short_name"] as? String ?? "",
                         start: Self.date(s["date_start"]), end: Self.date(s["date_end"]), year: s["year"] as? Int ?? 0)
    }

    public func drivers(_ key: Int) async -> [Int: F1Driver] {
        guard let a = await get("\(Self.openF1)drivers?session_key=\(key)", ttl: 1800) as? [[String: Any]] else { return [:] }
        var out: [Int: F1Driver] = [:]
        for d in a {
            guard let n = d["driver_number"] as? Int else { continue }
            out[n] = F1Driver(number: n, acronym: d["name_acronym"] as? String ?? "", fullName: d["full_name"] as? String ?? "",
                              team: d["team_name"] as? String ?? "", colour: d["team_colour"] as? String ?? "")
        }
        return out
    }

    public func live() async -> F1Live? {
        guard let session = await latestSession() else { return nil }
        let key = session.sessionKey
        let fast: TimeInterval = session.isLive() ? 4 : 600
        let drivers = await drivers(key)

        var positions: [Int: (pos: Int, at: Date)] = [:]
        if let a = await get("\(Self.openF1)position?session_key=\(key)", ttl: fast) as? [[String: Any]] {
            for p in a {
                guard let n = p["driver_number"] as? Int, let pos = p["position"] as? Int else { continue }
                let at = Self.date(p["date"])
                if positions[n] == nil || at >= positions[n]!.at { positions[n] = (pos, at) }
            }
        }
        var gaps: [Int: (gap: Double?, interval: Double?, at: Date)] = [:]
        if let a = await get("\(Self.openF1)intervals?session_key=\(key)", ttl: fast) as? [[String: Any]] {
            for i in a {
                guard let n = i["driver_number"] as? Int else { continue }
                let at = Self.date(i["date"])
                if gaps[n] == nil || at >= gaps[n]!.at { gaps[n] = (i["gap_to_leader"] as? Double, i["interval"] as? Double, at) }
            }
        }
        var laps: [Int: (last: Double?, best: Double?, number: Int)] = [:]
        if let a = await get("\(Self.openF1)laps?session_key=\(key)", ttl: session.isLive() ? 8 : 600) as? [[String: Any]] {
            for l in a {
                guard let n = l["driver_number"] as? Int else { continue }
                let number = l["lap_number"] as? Int ?? 0
                let duration = l["lap_duration"] as? Double
                let prev = laps[n]
                let best: Double? = {
                    guard let d = duration else { return prev?.best }
                    guard let b = prev?.best else { return d }
                    return min(b, d)
                }()
                if number >= (prev?.number ?? 0) { laps[n] = (duration ?? prev?.last, best, number) }
                else { laps[n] = (prev?.last, best, prev?.number ?? number) }
            }
        }
        var stints: [Int: (compound: String, age: Int)] = [:]
        if let a = await get("\(Self.openF1)stints?session_key=\(key)", ttl: 30) as? [[String: Any]] {
            for s in a {
                guard let n = s["driver_number"] as? Int else { continue }
                let lapStart = s["lap_start"] as? Int ?? 0
                let age = (s["tyre_age_at_start"] as? Int ?? 0) + max(0, (laps[n]?.number ?? lapStart) - lapStart)
                stints[n] = (s["compound"] as? String ?? "", age)
            }
        }
        var messages: [F1Message] = []
        if let a = await get("\(Self.openF1)race_control?session_key=\(key)", ttl: 10) as? [[String: Any]] {
            messages = a.map { F1Message(date: Self.date($0["date"]), category: $0["category"] as? String ?? "", flag: $0["flag"] as? String, text: $0["message"] as? String ?? "") }
                .sorted { $0.date > $1.date }
            messages = Array(messages.prefix(40))
        }
        var weather: F1Weather?
        if let a = await get("\(Self.openF1)weather?session_key=\(key)", ttl: 30) as? [[String: Any]], let w = a.last {
            weather = F1Weather(airTemp: w["air_temperature"] as? Double ?? 0, trackTemp: w["track_temperature"] as? Double ?? 0,
                                humidity: w["humidity"] as? Double ?? 0, windSpeed: w["wind_speed"] as? Double ?? 0, raining: (w["rainfall"] as? Double ?? 0) > 0)
        }

        let rows = positions.compactMap { number, value -> F1Row? in
            guard let driver = drivers[number] else { return nil }
            return F1Row(position: value.pos, driver: driver, gapToLeader: gaps[number]?.gap, interval: gaps[number]?.interval,
                         lastLap: laps[number]?.last, bestLap: laps[number]?.best, lap: laps[number]?.number ?? 0,
                         compound: stints[number]?.compound, tyreAge: stints[number]?.age)
        }.sorted { $0.position < $1.position }

        let flag = messages.first { $0.category.caseInsensitiveCompare("Flag") == .orderedSame }
        let status: String
        if !session.isLive() { status = Date() > session.end ? "FINISHED" : "NOT STARTED" }
        else if messages.contains(where: { $0.text.localizedCaseInsensitiveContains("CHEQUERED") }) { status = "CHEQUERED FLAG" }
        else if let f = flag?.flag, !f.isEmpty, f.caseInsensitiveCompare("CLEAR") != .orderedSame { status = f.uppercased() }
        else { status = "GREEN" }
        let lap = rows.map(\.lap).max()
        return F1Live(session: session, rows: rows, messages: messages, weather: weather, status: status, lap: lap == 0 ? nil : lap)
    }

    // MARK: schedule & standings

    public func nextRace() async -> F1Race? {
        guard let root = await get(Self.jolpica + "current/next.json", ttl: 3600) as? [String: Any],
              let table = (root["MRData"] as? [String: Any])?["RaceTable"] as? [String: Any],
              let race = (table["Races"] as? [[String: Any]])?.first else { return nil }
        func when(_ node: [String: Any]?) -> Date? {
            guard let d = node?["date"] as? String, let t = node?["time"] as? String else { return nil }
            return ISO8601DateFormatter().date(from: "\(d)T\(t)")
        }
        var sessions: [(String, Date)] = []
        for (label, key) in [("Practice 1", "FirstPractice"), ("Practice 2", "SecondPractice"), ("Practice 3", "ThirdPractice"),
                             ("Sprint Qualifying", "SprintQualifying"), ("Sprint", "Sprint"), ("Qualifying", "Qualifying")] {
            if let at = when(race[key] as? [String: Any]) { sessions.append((label, at)) }
        }
        let start = when(race) ?? .distantFuture
        sessions.append(("Race", start))
        let circuit = race["Circuit"] as? [String: Any]
        let location = circuit?["Location"] as? [String: Any]
        return F1Race(name: race["raceName"] as? String ?? "Grand Prix", circuit: circuit?["circuitName"] as? String ?? "",
                      locality: location?["locality"] as? String ?? "", country: location?["country"] as? String ?? "",
                      start: start, round: Int(race["round"] as? String ?? "") ?? 0, sessions: sessions.sorted { $0.1 < $1.1 })
    }

    private func standings(_ path: String, key: String, driver: Bool) async -> [F1Standing] {
        guard let root = await get(Self.jolpica + path, ttl: 10800) as? [String: Any],
              let table = (root["MRData"] as? [String: Any])?["StandingsTable"] as? [String: Any],
              let list = (table["StandingsLists"] as? [[String: Any]])?.first,
              let rows = list[key] as? [[String: Any]] else { return [] }
        return rows.map { r in
            let d = r["Driver"] as? [String: Any]
            let c = (r["Constructors"] as? [[String: Any]])?.first ?? r["Constructor"] as? [String: Any]
            return F1Standing(position: Int(r["position"] as? String ?? "") ?? 0,
                              code: driver ? (d?["code"] as? String ?? "") : (c?["constructorId"] as? String ?? ""),
                              name: driver ? "\(d?["givenName"] as? String ?? "") \(d?["familyName"] as? String ?? "")".trimmed : (c?["name"] as? String ?? ""),
                              team: driver ? (c?["name"] as? String ?? "") : (c?["nationality"] as? String ?? ""),
                              points: Double(r["points"] as? String ?? "") ?? 0, wins: Int(r["wins"] as? String ?? "") ?? 0)
        }
    }

    public func driverStandings() async -> [F1Standing] { await standings("current/driverStandings.json", key: "DriverStandings", driver: true) }
    public func constructorStandings() async -> [F1Standing] { await standings("current/constructorStandings.json", key: "ConstructorStandings", driver: false) }

    public func lastResults() async -> (race: String, order: [F1Standing]) {
        guard let root = await get(Self.jolpica + "current/last/results.json", ttl: 3600) as? [String: Any],
              let table = (root["MRData"] as? [String: Any])?["RaceTable"] as? [String: Any],
              let race = (table["Races"] as? [[String: Any]])?.first,
              let results = race["Results"] as? [[String: Any]] else { return ("", []) }
        let order = results.map { r -> F1Standing in
            let d = r["Driver"] as? [String: Any]
            return F1Standing(position: Int(r["position"] as? String ?? "") ?? 0, code: d?["code"] as? String ?? "",
                              name: "\(d?["givenName"] as? String ?? "") \(d?["familyName"] as? String ?? "")".trimmed,
                              team: (r["Constructor"] as? [String: Any])?["name"] as? String ?? "",
                              points: Double(r["points"] as? String ?? "") ?? 0, wins: (r["position"] as? String) == "1" ? 1 : 0)
        }
        return (race["raceName"] as? String ?? "", order)
    }

    // MARK: text for the palette, voice and iPhone

    public func summary(_ kind: String = "auto", favourite: String = "") async -> String {
        switch kind {
        case "standings", "championship":
            return Self.standingsText(await driverStandings(), await constructorStandings())
        case "results", "last":
            let (race, order) = await lastResults()
            return Self.resultsText(race, order)
        case "next", "schedule":
            return Self.nextText(await nextRace())
        default:
            guard let live = await live(), !live.rows.isEmpty else { return Self.nextText(await nextRace()) + " " + Self.standingsText(await driverStandings(), []) }
            if live.running { return Self.liveText(live, favourite: favourite) }
            if Date().timeIntervalSince(live.session.end) < 6 * 3600 {
                return "\(live.session.title) finished — " + live.rows.prefix(3).map { "P\($0.position) \($0.driver.acronym)" }.joined(separator: ", ") + ". " + Self.nextText(await nextRace())
            }
            return Self.nextText(await nextRace()) + " " + Self.standingsText(await driverStandings(), [])
        }
    }

    public static func liveText(_ live: F1Live, favourite: String = "") -> String {
        let top = live.rows.prefix(5).map { $0.position == 1 ? "P1 \($0.driver.acronym)" : "P\($0.position) \($0.driver.acronym) \($0.gap)" }
        var text = "\(live.session.title) is live\(live.lap.map { ", lap \($0)" } ?? "") · \(live.status). " + top.joined(separator: ", ") + "."
        if !favourite.isEmpty, let row = live.rows.first(where: { $0.driver.acronym.caseInsensitiveCompare(favourite) == .orderedSame || $0.driver.fullName.localizedCaseInsensitiveContains(favourite) }) {
            text += " \(row.driver.acronym) is P\(row.position)\(row.position > 1 ? " (\(row.gap))" : ""), last lap \(row.last)."
        }
        return text
    }

    public static func nextText(_ race: F1Race?) -> String {
        guard let race else { return "No upcoming race found." }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"
        return "Next: \(race.name) at \(race.circuit), \(race.locality) — lights out \(f.string(from: race.start)) (\(race.countdown))."
    }

    public static func standingsText(_ drivers: [F1Standing], _ teams: [F1Standing]) -> String {
        guard !drivers.isEmpty else { return "" }
        let d = "Championship: " + drivers.prefix(3).map { "\($0.position). \($0.code) \(Int($0.points))" }.joined(separator: ", ")
        guard !teams.isEmpty else { return d + "." }
        return d + " · Teams: " + teams.prefix(3).map { "\($0.position). \($0.name) \(Int($0.points))" }.joined(separator: ", ") + "."
    }

    public static func resultsText(_ race: String, _ order: [F1Standing]) -> String {
        order.isEmpty ? "No results yet." : "\(race): " + order.prefix(5).map { "P\($0.position) \($0.code)" }.joined(separator: ", ") + "."
    }
}
