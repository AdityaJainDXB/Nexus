using System.Globalization;

namespace Nexus.Core;

/// Standard 5-field cron: minute hour day-of-month month day-of-week (0/7 = Sunday).
public class CronExpression
{
    public HashSet<int> Minutes { get; } = [];
    public HashSet<int> Hours { get; } = [];
    public HashSet<int> DaysOfMonth { get; } = [];
    public HashSet<int> Months { get; } = [];
    public HashSet<int> DaysOfWeek { get; } = [];
    bool domRestricted, dowRestricted;

    static readonly Dictionary<string, string> Macros = new() { ["@hourly"] = "0 * * * *", ["@daily"] = "0 0 * * *", ["@midnight"] = "0 0 * * *", ["@weekly"] = "0 0 * * 0", ["@monthly"] = "0 0 1 * *", ["@yearly"] = "0 0 1 1 *", ["@annually"] = "0 0 1 1 *" };
    static readonly Dictionary<string, int> MonthNames = new() { ["jan"] = 1, ["feb"] = 2, ["mar"] = 3, ["apr"] = 4, ["may"] = 5, ["jun"] = 6, ["jul"] = 7, ["aug"] = 8, ["sep"] = 9, ["oct"] = 10, ["nov"] = 11, ["dec"] = 12 };
    static readonly Dictionary<string, int> DayNames = new() { ["sun"] = 0, ["mon"] = 1, ["tue"] = 2, ["wed"] = 3, ["thu"] = 4, ["fri"] = 5, ["sat"] = 6 };

    CronExpression() { }

    public static CronExpression? Parse(string expression)
    {
        var expr = Macros.GetValueOrDefault(expression.Trim().ToLowerInvariant(), expression);
        var parts = expr.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 5) return null;
        var c = new CronExpression();
        if (!Field(parts[0], 0, 59, [], c.Minutes) || !Field(parts[1], 0, 23, [], c.Hours) || !Field(parts[2], 1, 31, [], c.DaysOfMonth)
            || !Field(parts[3], 1, 12, MonthNames, c.Months) || !Field(parts[4], 0, 7, DayNames, c.DaysOfWeek)) return null;
        if (c.DaysOfWeek.Remove(7)) c.DaysOfWeek.Add(0);
        c.domRestricted = parts[2] != "*";
        c.dowRestricted = parts[4] != "*";
        return c;
    }

    static bool Field(string s, int lo, int hi, Dictionary<string, int> names, HashSet<int> into)
    {
        foreach (var item in s.ToLowerInvariant().Split(','))
        {
            var range = item; var step = 1;
            var slash = item.IndexOf('/');
            if (slash >= 0) { range = item[..slash]; if (!int.TryParse(item[(slash + 1)..], out step) || step <= 0) return false; }
            int? Val(string v) => int.TryParse(v, out var n) ? n : names.TryGetValue(v.Length >= 3 ? v[..3] : v, out var x) ? x : null;
            int a = lo, b = hi;
            if (range == "*") { }
            else if (range.Contains('-'))
            {
                var p = range.Split('-');
                if (Val(p[0]) is not { } x || Val(p[1]) is not { } y) return false;
                a = x; b = y;
            }
            else
            {
                if (Val(range) is not { } x) return false;
                a = x; b = slash >= 0 ? hi : x;
            }
            if (a < lo || b > hi || a > b) return false;
            for (var i = a; i <= b; i += step) into.Add(i);
        }
        return into.Count > 0;
    }

    bool DayOk(DateTime t)
    {
        var dom = DaysOfMonth.Contains(t.Day);
        var dow = DaysOfWeek.Contains((int)t.DayOfWeek);
        return domRestricted && dowRestricted ? dom || dow : dom && dow;
    }

    public bool Matches(DateTime d) => Minutes.Contains(d.Minute) && Hours.Contains(d.Hour) && Months.Contains(d.Month) && DayOk(d);

    /// First matching minute strictly after `date`.
    public DateTime? Next(DateTime date)
    {
        var t = new DateTime(date.Year, date.Month, date.Day, date.Hour, date.Minute, 0, date.Kind).AddMinutes(1);
        var limit = date.AddYears(4);
        while (t < limit)
        {
            if (!Months.Contains(t.Month)) { t = new DateTime(t.Year, t.Month, 1).AddMonths(1); continue; }
            if (!DayOk(t)) { t = t.Date.AddDays(1); continue; }
            if (!Hours.Contains(t.Hour)) { t = t.Date.AddHours(t.Hour + 1); continue; }
            if (Minutes.Contains(t.Minute)) return t;
            t = t.AddMinutes(1);
        }
        return null;
    }

    public static string Describe(string expression)
    {
        if (Parse(expression) is not { } c) return expression;
        string[] days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
        string? Clock() => c.Hours.Count == 1 && c.Minutes.Count == 1 ? DateTime.Today.AddHours(c.Hours.First()).AddMinutes(c.Minutes.First()).ToString("h:mm tt", CultureInfo.InvariantCulture) : null;
        if (c.Minutes.Count == 60 && c.Hours.Count == 24) return "Every minute";
        if (c.Hours.Count == 24 && !c.domRestricted && !c.dowRestricted)
        {
            if (c.Minutes.Count == 1) return $"Every hour at :{c.Minutes.First():00}";
            var sorted = c.Minutes.OrderBy(x => x).ToList();
            if (sorted.Count > 1) return $"Every {sorted[1] - sorted[0]} minutes";
        }
        if (Clock() is not { } t) return expression;
        if (!c.domRestricted && !c.dowRestricted) return $"Every day at {t}";
        if (c.dowRestricted && !c.domRestricted)
        {
            if (c.DaysOfWeek.SetEquals([1, 2, 3, 4, 5])) return $"Weekdays at {t}";
            if (c.DaysOfWeek.SetEquals([0, 6])) return $"Weekends at {t}";
            return $"Every {string.Join(", ", c.DaysOfWeek.OrderBy(x => x).Select(d => days[d]))} at {t}";
        }
        if (c.domRestricted && !c.dowRestricted && c.DaysOfMonth.Count == 1) return $"Monthly on day {c.DaysOfMonth.First()} at {t}";
        return expression;
    }
}

/// Natural-language time phrases → cron or a one-off date.
public abstract record TimeResult
{
    public sealed record CronAt(string Cron) : TimeResult;
    public sealed record Once(DateTime At) : TimeResult;
}

public static class NLTime
{
    static readonly (string name, int day)[] Weekdays = [("sunday", 0), ("monday", 1), ("tuesday", 2), ("wednesday", 3), ("thursday", 4), ("friday", 5), ("saturday", 6),
        ("sun", 0), ("mon", 1), ("tue", 2), ("wed", 3), ("thu", 4), ("fri", 5), ("sat", 6)];

    public static (int h, int m)? ParseClock(string text)
    {
        var t = text.ToLowerInvariant();
        if (t.Contains("noon")) return (12, 0);
        if (t.Contains("midnight")) return (0, 0);
        if (t.Captures(@"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)") is { } m)
        {
            var h = int.Parse(m[1]); var min = m[2].Length > 0 ? int.Parse(m[2]) : 0;
            var pm = m[3].StartsWith('p');
            if (h == 12) h = pm ? 12 : 0; else if (pm) h += 12;
            return h < 24 && min < 60 ? (h, min) : null;
        }
        if ((t.Captures(@"\bat\s+(\d{1,2}):(\d{2})\b") ?? t.Captures(@"\b(\d{1,2}):(\d{2})\b")) is { } m2)
        {
            int h = int.Parse(m2[1]), min = int.Parse(m2[2]);
            return h < 24 && min < 60 ? (h, min) : null;
        }
        if (t.Captures(@"\bat\s+(\d{1,2})\b") is { } m3 && int.Parse(m3[1]) < 24) return (int.Parse(m3[1]), 0);
        return null;
    }

    public static TimeResult? Parse(string text, DateTime? nowOpt = null)
    {
        var now = nowOpt ?? DateTime.Now;
        var t = " " + text.ToLowerInvariant() + " ";
        var clock = ParseClock(t);
        DateTime Add(string unit, int n) => unit.StartsWith('d') ? now.AddDays(n) : unit.StartsWith('h') ? now.AddHours(n) : now.AddMinutes(n);

        if (!t.Contains("every") && t.Captures(@"\bin\s+(\d+)\s*(minute|min|hour|hr|day)s?\b") is { } rel) return new TimeResult.Once(Add(rel[2], int.Parse(rel[1])));
        if (t.Captures(@"every\s+(\d+)\s*(minute|min|hour|hr)s?") is { } ev && int.Parse(ev[1]) > 0)
            return ev[2].StartsWith('h') ? new TimeResult.CronAt($"0 */{ev[1]} * * *") : new TimeResult.CronAt($"*/{ev[1]} * * * *");
        if (t.Contains("every hour") || t.Contains("hourly")) return new TimeResult.CronAt("0 * * * *");

        var (h, mi) = clock ?? (9, 0);
        if (t.Contains("every weekday") || t.Contains("on weekdays") || t.Contains("weekdays at")) return new TimeResult.CronAt($"{mi} {h} * * 1-5");
        if (t.Contains("every weekend") || t.Contains("on weekends")) return new TimeResult.CronAt($"{mi} {h} * * 0,6");
        if (t.Contains("every day") || t.Contains("daily") || t.Contains("every night") || t.Contains("every morning") || t.Contains("each day") || t.Contains("nightly"))
        {
            var (hh, mm) = clock ?? (t.Contains("night") ? (22, 0) : (9, 0));
            return new TimeResult.CronAt($"{mm} {hh} * * *");
        }
        if (t.Contains("every week") || t.Contains("weekly"))
            return new TimeResult.CronAt($"{mi} {h} * * {Weekdays.Where(w => t.Contains(w.name)).Select(w => w.day).FirstOrDefault()}");
        if (t.Contains("every month") || t.Contains("monthly"))
        {
            var day = t.Captures(@"(\d{1,2})(?:st|nd|rd|th)") is { } dm ? int.Parse(dm[1]) : 1;
            return new TimeResult.CronAt($"{mi} {h} {day} * *");
        }
        if (t.Contains("every") || t.Contains("each"))
        {
            var days = Weekdays.Where(w => t.Contains(" " + w.name) || t.Contains(" " + w.name + "s ")).Select(w => w.day).Distinct().OrderBy(d => d).ToList();
            if (days.Count > 0) return new TimeResult.CronAt($"{mi} {h} * * {string.Join(",", days)}");
        }

        var baseDay = now.Date;
        var explicitDay = false;
        if (t.Contains("tomorrow")) { baseDay = baseDay.AddDays(1); explicitDay = true; }
        else if (Weekdays.Where(w => t.Contains("on " + w.name) || t.Contains("next " + w.name) || t.Contains("this " + w.name)).Select(w => (int?)w.day).FirstOrDefault() is { } wd)
        {
            var delta = (wd - (int)now.DayOfWeek + 7) % 7;
            if (delta == 0) delta = 7;
            baseDay = baseDay.AddDays(delta);
            explicitDay = true;
        }
        else if (t.Captures(@"in\s+(\d+)\s*(minute|min|hour|hr|day)s?") is { } rel2) return new TimeResult.Once(Add(rel2[2], int.Parse(rel2[1])));
        var tonight = t.Contains("tonight");
        if (clock != null || explicitDay || tonight)
        {
            var (hh, mm) = clock ?? (tonight ? (22, 0) : (9, 0));
            var d = baseDay.AddHours(hh).AddMinutes(mm);
            if (d <= now && !explicitDay) d = d.AddDays(1);
            return new TimeResult.Once(d);
        }
        return null;
    }
}
