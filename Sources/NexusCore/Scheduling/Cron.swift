import Foundation

/// Standard 5-field cron: minute hour day-of-month month day-of-week (0/7 = Sunday).
/// Supports `*`, lists, ranges, steps, month/day names and @hourly/@daily/@weekly/@monthly/@yearly.
public struct CronExpression: Equatable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    public let daysOfWeek: Set<Int>
    let domRestricted: Bool
    let dowRestricted: Bool

    private static let macros = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
                                 "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"]
    private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let dayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    public init?(_ expression: String) {
        let expr = Self.macros[expression.trimmed.lowercased()] ?? expression
        let parts = expr.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5,
              let mi = Self.field(parts[0], 0, 59, [:]),
              let h = Self.field(parts[1], 0, 23, [:]),
              let dom = Self.field(parts[2], 1, 31, [:]),
              let mo = Self.field(parts[3], 1, 12, Self.monthNames),
              var dow = Self.field(parts[4], 0, 7, Self.dayNames) else { return nil }
        if dow.contains(7) { dow.remove(7); dow.insert(0) }
        minutes = mi; hours = h; daysOfMonth = dom; months = mo; daysOfWeek = dow
        domRestricted = parts[2] != "*"
        dowRestricted = parts[4] != "*"
    }

    private static func field(_ s: String, _ lo: Int, _ hi: Int, _ names: [String: Int]) -> Set<Int>? {
        var out = Set<Int>()
        for item in s.lowercased().split(separator: ",") {
            var rangePart = String(item)
            var step = 1
            if let slash = item.firstIndex(of: "/") {
                rangePart = String(item[..<slash])
                guard let st = Int(item[item.index(after: slash)...]), st > 0 else { return nil }
                step = st
            }
            func value(_ v: String) -> Int? { Int(v) ?? names[String(v.prefix(3))] }
            var a = lo, b = hi
            if rangePart == "*" {
            } else if let dash = rangePart.firstIndex(of: "-") {
                guard let x = value(String(rangePart[..<dash])), let y = value(String(rangePart[rangePart.index(after: dash)...])) else { return nil }
                a = x; b = y
            } else {
                guard let x = value(rangePart) else { return nil }
                a = x; b = item.contains("/") ? hi : x
            }
            guard a >= lo, b <= hi, a <= b else { return nil }
            out.formUnion(stride(from: a, through: b, by: step))
        }
        return out.isEmpty ? nil : out
    }

    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard minutes.contains(c.minute!), hours.contains(c.hour!), months.contains(c.month!) else { return false }
        let domOK = daysOfMonth.contains(c.day!)
        let dowOK = daysOfWeek.contains(c.weekday! - 1)
        // Vixie cron semantics: if both are restricted, either may match.
        if domRestricted && dowRestricted { return domOK || dowOK }
        return domOK && dowOK
    }

    /// First matching minute strictly after `date` (searches up to ~4 years).
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var t = calendar.date(bySetting: .second, value: 0, of: date.addingTimeInterval(60)) else { return nil }
        if t <= date { t = t.addingTimeInterval(60) }
        let limit = date.addingTimeInterval(4 * 366 * 86400)
        while t < limit {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
            if !months.contains(c.month!) {
                t = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month], from: t))!)!
                continue
            }
            let domOK = daysOfMonth.contains(c.day!), dowOK = daysOfWeek.contains(c.weekday! - 1)
            let dayOK = (domRestricted && dowRestricted) ? (domOK || dowOK) : (domOK && dowOK)
            if !dayOK {
                t = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: t))!
                continue
            }
            if !hours.contains(c.hour!) {
                t = calendar.date(byAdding: .hour, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: t))!)!
                continue
            }
            if minutes.contains(c.minute!) { return t }
            t = t.addingTimeInterval(60)
        }
        return nil
    }

    /// Human-readable description for common shapes; falls back to the raw expression.
    public static func describe(_ expression: String) -> String {
        guard let c = CronExpression(expression) else { return expression }
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        func time() -> String? {
            guard c.hours.count == 1, c.minutes.count == 1 else { return nil }
            var comps = DateComponents(); comps.hour = c.hours.first; comps.minute = c.minutes.first
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return Calendar.current.date(from: comps).map { f.string(from: $0) }
        }
        if c.minutes.count == 60 && c.hours.count == 24 { return "Every minute" }
        if c.hours.count == 24 && !c.domRestricted && !c.dowRestricted {
            if c.minutes.count == 1 { return "Every hour at :\(String(format: "%02d", c.minutes.first!))" }
            let sorted = c.minutes.sorted()
            if sorted.count > 1 { return "Every \(sorted[1] - sorted[0]) minutes" }
        }
        guard let t = time() else { return expression }
        if !c.domRestricted && !c.dowRestricted { return "Every day at \(t)" }
        if c.dowRestricted && !c.domRestricted {
            if c.daysOfWeek == [1, 2, 3, 4, 5] { return "Weekdays at \(t)" }
            if c.daysOfWeek == [0, 6] { return "Weekends at \(t)" }
            return "Every \(c.daysOfWeek.sorted().map { days[$0] }.joined(separator: ", ")) at \(t)"
        }
        if c.domRestricted && !c.dowRestricted && c.daysOfMonth.count == 1 {
            return "Monthly on day \(c.daysOfMonth.first!) at \(t)"
        }
        return expression
    }
}

/// Natural-language time phrases → cron or a one-off date.
public enum NLTime {
    public enum Result: Hashable { case cron(String), once(Date) }

    static let weekdays: [(String, Int)] = [("sunday", 0), ("monday", 1), ("tuesday", 2), ("wednesday", 3), ("thursday", 4), ("friday", 5), ("saturday", 6),
                                            ("sun", 0), ("mon", 1), ("tue", 2), ("wed", 3), ("thu", 4), ("fri", 5), ("sat", 6)]

    /// Parses "9am", "9:30 pm", "21:00", "noon", "midnight".
    public static func parseClock(_ text: String) -> (Int, Int)? {
        let t = text.lowercased()
        if t.contains("noon") { return (12, 0) }
        if t.contains("midnight") { return (0, 0) }
        if let m = t.captures(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#) {
            var h = Int(m[1]) ?? 0
            let min = Int(m[2]) ?? 0
            let pm = m[3].hasPrefix("p")
            if h == 12 { h = pm ? 12 : 0 } else if pm { h += 12 }
            return h < 24 && min < 60 ? (h, min) : nil
        }
        if let m = t.captures(#"\bat\s+(\d{1,2}):(\d{2})\b"#) ?? t.captures(#"\b(\d{1,2}):(\d{2})\b"#) {
            let h = Int(m[1]) ?? 0, min = Int(m[2]) ?? 0
            return h < 24 && min < 60 ? (h, min) : nil
        }
        if let m = t.captures(#"\bat\s+(\d{1,2})\b"#), let h = Int(m[1]), h < 24 { return (h, 0) }
        return nil
    }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Result? {
        let t = " " + text.lowercased() + " "
        let clock = parseClock(t)

        if !t.contains("every"), let m = t.captures(#"\bin\s+(\d+)\s*(minute|min|hour|hr|day)s?\b"#), let n = Int(m[1]) {
            let unit: Calendar.Component = m[2].hasPrefix("d") ? .day : (m[2].hasPrefix("h") ? .hour : .minute)
            return .once(calendar.date(byAdding: unit, value: n, to: now)!)
        }
        if let m = t.captures(#"every\s+(\d+)\s*(minute|min|hour|hr)s?"#), let n = Int(m[1]), n > 0 {
            return m[2].hasPrefix("h") ? .cron("0 */\(n) * * *") : .cron("*/\(n) * * * *")
        }
        if t.contains("every hour") || t.contains("hourly") { return .cron("0 * * * *") }

        let (h, mi) = clock ?? (9, 0)
        if t.contains("every weekday") || t.contains("on weekdays") || t.contains("weekdays at") { return .cron("\(mi) \(h) * * 1-5") }
        if t.contains("every weekend") || t.contains("on weekends") { return .cron("\(mi) \(h) * * 0,6") }
        if t.contains("every day") || t.contains("daily") || t.contains("every night") || t.contains("every morning") || t.contains("each day") || t.contains("nightly") {
            let (hh, mm) = clock ?? (t.contains("night") ? (22, 0) : (9, 0))
            return .cron("\(mm) \(hh) * * *")
        }
        if t.contains("every week") || t.contains("weekly") {
            return .cron("\(mi) \(h) * * \(weekdays.first { t.contains($0.0) }?.1 ?? 0)")
        }
        if t.contains("every month") || t.contains("monthly") {
            let day = t.captures(#"(\d{1,2})(?:st|nd|rd|th)"#).flatMap { Int($0[1]) } ?? 1
            return .cron("\(mi) \(h) \(day) * *")
        }
        if t.contains("every") || t.contains("each") {
            let days = weekdays.filter { t.contains(" \($0.0)") || t.contains(" \($0.0)s ") }.map(\.1)
            if !days.isEmpty { return .cron("\(mi) \(h) * * \(Array(Set(days)).sorted().map(String.init).joined(separator: ","))") }
        }

        // One-off
        var base = calendar.startOfDay(for: now)
        var explicitDay = false
        if t.contains("tomorrow") { base = calendar.date(byAdding: .day, value: 1, to: base)!; explicitDay = true }
        else if let wd = weekdays.first(where: { t.contains("on \($0.0)") || t.contains("next \($0.0)") || t.contains("this \($0.0)") }) {
            let current = calendar.component(.weekday, from: now) - 1
            var delta = (wd.1 - current + 7) % 7
            if delta == 0 { delta = 7 }
            base = calendar.date(byAdding: .day, value: delta, to: base)!
            explicitDay = true
        } else if let m = t.captures(#"in\s+(\d+)\s*(minute|min|hour|hr|day)s?"#), let n = Int(m[1]) {
            let unit: Calendar.Component = m[2].hasPrefix("d") ? .day : (m[2].hasPrefix("h") ? .hour : .minute)
            return .once(calendar.date(byAdding: unit, value: n, to: now)!)
        }
        let tonight = t.contains("tonight")
        if clock != nil || explicitDay || tonight {
            let (hh, mm) = clock ?? (tonight ? (22, 0) : (9, 0))
            var d = calendar.date(bySettingHour: hh, minute: mm, second: 0, of: base)!
            if d <= now && !explicitDay { d = calendar.date(byAdding: .day, value: 1, to: d)! }
            return .once(d)
        }
        return nil
    }
}
