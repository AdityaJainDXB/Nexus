import WidgetKit
import SwiftUI

// Nexus widgets. Built as a sandboxed WidgetKit extension inside Nexus.app/Contents/PlugIns.
// Data comes from a read-only JSON snapshot the app writes to ~/Library/Application Support/Nexus/widget/.

struct Snapshot: Codable {
    struct Item: Codable, Hashable { var title: String; var detail: String; var command: String? }
    var status: String = "idle"
    var paused = false
    var filesIndexed = 0
    var handledToday = 0
    var reviewCount = 0
    var insightCount = 0
    var automationsWeek = 0
    var minutesSaved = 0
    var focusProject: String?
    var focusEnds: Date?
    var model = "On-device"
    var insights: [Item] = []
    var upcoming: [Item] = []
    var recent: [Item] = []
    var updatedAt = Date()

    static func load() -> Snapshot {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let url = URL(fileURLWithPath: home + "/Library/Application Support/Nexus/widget/snapshot.json")
        guard let data = try? Data(contentsOf: url) else { return Snapshot() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    static let preview: Snapshot = {
        var s = Snapshot()
        s.status = "working"; s.filesIndexed = 1204; s.handledToday = 17; s.reviewCount = 3; s.insightCount = 2; s.automationsWeek = 64; s.minutesSaved = 42
        s.focusProject = "Science Fair"; s.focusEnds = Date().addingTimeInterval(2700)
        s.insights = [Item(title: "38 unsorted files in Downloads", detail: "older than 7 days", command: "organize Downloads"),
                      Item(title: "3 sets of duplicates · 1.2 GB", detail: "", command: "find duplicates")]
        s.upcoming = [Item(title: "Weekly report", detail: "Sun 9:00", command: nil)]
        s.recent = [Item(title: "Filed lab-report.pdf → Science", detail: "2m", command: nil), Item(title: "Tagged invoice #tax", detail: "5m", command: nil)]
        return s
    }()
}

struct Entry: TimelineEntry { let date: Date; let snap: Snapshot }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snap: context.isPreview ? .preview : .load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date(), snap: .load())], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

// MARK: - Style

enum W {
    static let cyan = Color(red: 0.22, green: 0.886, blue: 1)
    static let violet = Color(red: 0.56, green: 0.486, blue: 1)
    static let amber = Color(red: 1, green: 0.784, blue: 0.341)
    static let green = Color(red: 0.24, green: 0.96, blue: 0.63)
    static let space = Color(red: 0.027, green: 0.039, blue: 0.07)
    static let grad = LinearGradient(colors: [cyan, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static func url(_ path: String) -> URL { URL(string: "nexus://\(path)")! }
    static func cmd(_ c: String) -> URL { URL(string: "nexus://run?cmd=" + (c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))! }
    static func statusColor(_ s: String) -> Color { s == "working" ? cyan : s == "attention" ? amber : s == "paused" ? .gray : green }
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            W.space
            Canvas { ctx, size in
                var p = Path()
                for x in stride(from: 0, through: size.width, by: 18) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: 18) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(p, with: .color(W.cyan.opacity(0.06)), lineWidth: 0.5)
            }
            RadialGradient(colors: [W.cyan.opacity(0.18), .clear], center: .topTrailing, startRadius: 5, endRadius: 220)
        }
    }
}

extension View {
    @ViewBuilder func nexusBackground() -> some View {
        if #available(macOS 14.0, *) { containerBackground(for: .widget) { Backdrop() } } else { background(Backdrop()) }
    }
}

struct Header: View {
    let snap: Snapshot
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.hexagongrid.fill").foregroundStyle(W.grad)
            Text("NEXUS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(W.cyan)
            Spacer()
            Circle().fill(W.statusColor(snap.status)).frame(width: 6, height: 6)
            Text(snap.paused ? "PAUSED" : snap.status.uppercased()).font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

struct Stat: View {
    let value: String; let label: String; var tint: Color = W.cyan
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(tint).minimumScaleFactor(0.6).lineLimit(1)
            Text(label.uppercased()).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct Chip: View {
    let symbol: String; let title: String; let url: URL
    var body: some View {
        Link(destination: url) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(W.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Status widget

struct StatusView: View {
    @Environment(\.widgetFamily) var family
    let snap: Snapshot
    var body: some View {
        switch family {
        case .systemSmall: small
        default: medium
        }
    }

    var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(snap: snap)
            if let p = snap.focusProject {
                Text("FOCUS").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(W.violet)
                Text(p).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Stat(value: "\(snap.handledToday)", label: "today", tint: W.green)
                Spacer()
                Stat(value: "\(snap.reviewCount)", label: "review", tint: snap.reviewCount > 0 ? W.amber : .secondary)
            }
        }
        .foregroundStyle(.white)
        .widgetURL(W.url(snap.reviewCount > 0 ? "review" : "palette"))
    }

    var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(snap: snap)
            HStack(spacing: 14) {
                Stat(value: "\(snap.handledToday)", label: "handled today", tint: W.green)
                Stat(value: "\(snap.reviewCount)", label: "to review", tint: snap.reviewCount > 0 ? W.amber : .secondary)
                Stat(value: "\(snap.minutesSaved)m", label: "saved / wk", tint: W.cyan)
            }
            if let p = snap.focusProject, let end = snap.focusEnds {
                HStack(spacing: 4) {
                    Image(systemName: "scope").foregroundStyle(W.violet)
                    Text("Focus · \(p) · until \(end, style: .time)").font(.system(size: 10, design: .monospaced)).lineLimit(1)
                }
            } else if let r = snap.recent.first {
                Text(r.title).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Chip(symbol: "sparkle", title: "Ask", url: W.url("palette"))
                Chip(symbol: "mic.fill", title: "Speak", url: W.url("voice"))
                Chip(symbol: "wand.and.stars", title: "Organize", url: W.cmd("organize Downloads"))
                Chip(symbol: "tray.full", title: "Review", url: W.url("review"))
            }
        }
        .foregroundStyle(.white)
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NexusStatus", provider: Provider()) { entry in
            StatusView(snap: entry.snap).nexusBackground()
        }
        .configurationDisplayName("Nexus Status")
        .description("What Nexus handled today, what needs you, and quick actions.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Insights widget

struct InsightsView: View {
    @Environment(\.widgetFamily) var family
    let snap: Snapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Header(snap: snap)
            Text("NEXUS NOTICED").font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(W.cyan)
            if snap.insights.isEmpty {
                Text("All tidy. Nothing needs you.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(snap.insights.prefix(family == .systemLarge ? 4 : 2), id: \.self) { i in
                Link(destination: i.command.map(W.cmd) ?? W.url("insights")) {
                    HStack(alignment: .top, spacing: 6) {
                        Rectangle().fill(W.amber).frame(width: 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.title).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                            if !i.detail.isEmpty { Text(i.detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                        if i.command != nil { Text("FIX").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(W.cyan) }
                    }
                }
            }
            if family == .systemLarge {
                Text("COMING UP").font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(W.cyan).padding(.top, 4)
                ForEach(snap.upcoming.prefix(3), id: \.self) { u in
                    HStack { Text(u.title).font(.system(size: 11)); Spacer(); Text(u.detail).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary) }
                }
                Text("RECENT").font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(W.cyan).padding(.top, 4)
                ForEach(snap.recent.prefix(4), id: \.self) { r in
                    HStack { Text(r.title).font(.system(size: 10.5)).lineLimit(1); Spacer(); Text(r.detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .widgetURL(W.url("insights"))
    }
}

struct InsightsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NexusInsights", provider: Provider()) { entry in
            InsightsView(snap: entry.snap).nexusBackground()
        }
        .configurationDisplayName("Nexus Insights")
        .description("Digital-hygiene suggestions with one-click fixes, schedule and activity.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Voice widget

struct VoiceView: View {
    let snap: Snapshot
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(W.cyan.opacity(0.10)).frame(width: 86, height: 86)
                Circle().fill(W.cyan.opacity(0.16)).frame(width: 66, height: 66)
                Circle().fill(W.grad).frame(width: 50, height: 50)
                Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(W.space)
            }
            Text("TALK TO NEXUS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(W.cyan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(W.url("voice"))
    }
}

struct VoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NexusVoice", provider: Provider()) { entry in
            VoiceView(snap: entry.snap).nexusBackground()
        }
        .configurationDisplayName("Talk to Nexus")
        .description("One click to start a voice command.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct NexusWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        InsightsWidget()
        VoiceWidget()
    }
}
