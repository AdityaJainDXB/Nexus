import SwiftUI
import AppKit
import NexusCore
import QuickLookThumbnailing

// MARK: - Theme

enum Theme {
    // Sci-tech palette: ion cyan + plasma violet on deep space navy. Tuned for ≥4.5:1 text contrast.
    static let accent = Color(light: "#0A84B8", dark: "#39E2FF")
    static let accent2 = Color(light: "#5B4BDB", dark: "#8F7CFF")
    static let success = Color(light: "#0F9D63", dark: "#3DF5A0")
    static let warning = Color(light: "#B7791F", dark: "#FFC857")
    static let danger = Color(light: "#D12F4E", dark: "#FF5C7A")
    static let cardStroke = Color(light: "#0A84B8", dark: "#39E2FF").opacity(0.18)
    static let subtle = Color.primary.opacity(0.04)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let mono = Font.system(.caption, design: .monospaced)
    static let space = Color(light: "#EEF3F8", dark: "#070A12")
    static let panel = Color(light: "#FFFFFF", dark: "#0D1220")

    static func severity(_ s: InsightSeverity) -> Color {
        switch s { case .info: return .secondary; case .suggestion: return accent; case .warning: return warning; case .critical: return danger }
    }
    static func status(_ s: JobStatus) -> Color {
        switch s { case .completed: return success; case .failed: return danger; case .running: return accent2; case .cancelled: return .secondary; default: return warning }
    }
    static func jobKindSymbol(_ k: JobKind) -> String {
        switch k { case .file: return "doc"; case .ai: return "sparkles"; case .script: return "terminal"; case .integration: return "link"; case .system: return "gearshape" }
    }
    static func kindSymbol(_ k: FileKind) -> String {
        switch k {
        case .pdf: return "doc.richtext"; case .document: return "doc.text"; case .spreadsheet: return "tablecells"; case .presentation: return "rectangle.on.rectangle"
        case .text: return "text.alignleft"; case .code: return "chevron.left.forwardslash.chevron.right"; case .image: return "photo"; case .screenshot: return "camera.viewfinder"
        case .audio: return "waveform"; case .video: return "film"; case .archive: return "archivebox"; case .installer: return "shippingbox"; case .cad: return "cube.transparent"; case .folder: return "folder"; case .other: return "doc"
        }
    }
    static func eventSymbol(_ k: EventKind) -> String {
        switch k {
        case .fileIndexed: return "doc.viewfinder"; case .fileMoved: return "arrow.right.doc.on.clipboard"; case .fileCopied: return "doc.on.doc"
        case .fileRenamed: return "character.cursor.ibeam"; case .fileTagged: return "tag"; case .fileTrashed: return "trash"; case .fileCompressed: return "doc.zipper"
        case .ruleFired: return "bolt.fill"; case .jobStarted: return "play.circle"; case .jobCompleted: return "checkmark.circle"; case .jobFailed: return "xmark.octagon"
        case .review: return "tray.full"; case .insight: return "lightbulb"; case .command: return "command"; case .system: return "gearshape"
        case .connector: return "link"; case .focus: return "scope"; case .undo: return "arrow.uturn.backward"; case .error: return "exclamationmark.triangle"; case .guardTripped: return "hand.raised"
        }
    }
}

extension Color {
    /// Dynamic color that follows the effective appearance.
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hudPanel()
    }
}

/// HUD panel: translucent surface, hairline cyan stroke and corner brackets.
struct HUDPanel: ViewModifier {
    var cornerRadius: CGFloat = 12
    var glow = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency { Theme.panel } else { Rectangle().fill(.ultraThinMaterial); Theme.panel.opacity(0.55) }
                    LinearGradient(colors: [Theme.accent.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
            .overlay(CornerBrackets(inset: 4, length: 10).stroke(Theme.accent.opacity(0.55), lineWidth: 1.2).allowsHitTesting(false))
            .shadow(color: glow ? Theme.accent.opacity(0.25) : .clear, radius: 14)
    }
}

extension View {
    func hudPanel(cornerRadius: CGFloat = 12, glow: Bool = false) -> some View { modifier(HUDPanel(cornerRadius: cornerRadius, glow: glow)) }
}

struct CornerBrackets: Shape {
    var inset: CGFloat
    var length: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = r.insetBy(dx: inset, dy: inset)
        let l = min(length, a.width / 4, a.height / 4)
        p.move(to: CGPoint(x: a.minX, y: a.minY + l)); p.addLine(to: CGPoint(x: a.minX, y: a.minY)); p.addLine(to: CGPoint(x: a.minX + l, y: a.minY))
        p.move(to: CGPoint(x: a.maxX - l, y: a.minY)); p.addLine(to: CGPoint(x: a.maxX, y: a.minY)); p.addLine(to: CGPoint(x: a.maxX, y: a.minY + l))
        p.move(to: CGPoint(x: a.maxX, y: a.maxY - l)); p.addLine(to: CGPoint(x: a.maxX, y: a.maxY)); p.addLine(to: CGPoint(x: a.maxX - l, y: a.maxY))
        p.move(to: CGPoint(x: a.minX + l, y: a.maxY)); p.addLine(to: CGPoint(x: a.minX, y: a.maxY)); p.addLine(to: CGPoint(x: a.minX, y: a.maxY - l))
        return p
    }
}

/// Deep-space backdrop with a faint engineering grid and a soft ion glow.
struct GridBackdrop: View {
    var body: some View {
        ZStack {
            Theme.space
            Canvas { ctx, size in
                let step: CGFloat = 28
                var minor = Path()
                for x in stride(from: 0, through: size.width, by: step) { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: step) { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(minor, with: .color(Theme.accent.opacity(0.045)), lineWidth: 0.5)
                var major = Path()
                for x in stride(from: 0, through: size.width, by: step * 5) { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: step * 5) { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(major, with: .color(Theme.accent.opacity(0.08)), lineWidth: 0.6)
            }
            RadialGradient(colors: [Theme.accent.opacity(0.12), .clear], center: .topTrailing, startRadius: 10, endRadius: 650)
            RadialGradient(colors: [Theme.accent2.opacity(0.10), .clear], center: .bottomLeading, startRadius: 10, endRadius: 600)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Rectangle().fill(Theme.accent).frame(width: 3, height: 10)
                    Text(title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).tracking(1.2)
                }
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NEXUS // \(title.uppercased())").font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.accent).tracking(1.5)
                Text(title).font(.system(size: 26, weight: .semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.bottom, 6)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle; self.trailing = EmptyView() }
}

struct TagChip: View {
    let text: String
    var color: Color = Theme.accent
    var removable: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text("#" + text).font(.system(size: 11, weight: .medium))
            if let removable { Button(action: removable) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }
}

struct Pill: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

struct ConfidenceBadge: View {
    let value: Double
    var color: Color { value >= 0.85 ? Theme.success : value >= 0.55 ? Theme.warning : Theme.danger }
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(width: 46, height: 5)
                Capsule().fill(color).frame(width: 46 * value, height: 5)
            }
            Text("\(Int(value * 100))%").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
    }
}

struct Sparkline: View {
    let values: [Int]
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            let maxV = max(1, values.max() ?? 1)
            let step = g.size.width / CGFloat(max(1, values.count - 1))
            let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: g.size.height - CGFloat($0.element) / CGFloat(maxV) * (g.size.height - 2) - 1) }
            ZStack {
                Path { p in
                    guard let f = points.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: g.size.height))
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = points.first else { return }
                    p.move(to: f)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var symbol: String
    var tint: Color = Theme.accent
    var footnote: String? = nil
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
                    Text(title.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(.secondary)
                }
                Text(value).font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
                if let footnote { Text(footnote).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(Theme.gradient)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct StatusDot: View {
    let status: EngineStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    var color: Color {
        switch status { case .idle: return Theme.success; case .working: return Theme.accent2; case .attention: return Theme.warning; case .paused: return .secondary }
    }
    var body: some View {
        ZStack {
            // The pulse animation is scoped with .animation(value:) so it can never leak into
            // neighbouring text layout (a repeatForever inside withAnimation makes siblings jitter).
            Circle().fill(color.opacity(0.35)).frame(width: 16, height: 16)
                .scaleEffect(animate ? 1.3 : 0.6).opacity(status == .working && !reduceMotion ? (animate ? 0 : 1) : 0)
                .animation(status == .working && !reduceMotion ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default, value: animate)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear { animate = true }
        .accessibilityElement()
        .accessibilityLabel("Status: \(status.rawValue)")
    }
}

struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct FileIconView: View {
    let path: String
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

struct ThumbnailView: View {
    let path: String
    var size: CGSize = CGSize(width: 180, height: 140)
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                FileIconView(path: path, size: min(size.width, size.height) * 0.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: path) {
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = rep.nsImage }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.gradient.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: Theme.accent.opacity(configuration.isPressed ? 0.1 : 0.3), radius: 8)
            .foregroundStyle(Color(light: "#FFFFFF", dark: "#04121A"))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.cardStroke))
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Helpers

enum Panels {
    static func chooseFolder(prompt: String = "Choose") -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.canCreateDirectories = true; p.prompt = prompt
        return p.runModal() == .OK ? p.url?.path : nil
    }
    static func chooseFile(prompt: String = "Choose") -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = false; p.prompt = prompt
        return p.runModal() == .OK ? p.url?.path : nil
    }
    static func save(name: String, types: [String]) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        return p.runModal() == .OK ? p.url : nil
    }
    static func reveal(_ paths: [String]) { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
    static func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    static func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

extension TimeInterval {
    var shortDuration: String {
        if self < 1 { return "<1s" }
        if self < 60 { return "\(Int(self))s" }
        if self < 3600 { return "\(Int(self / 60))m \(Int(self.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(self / 3600))h \(Int((self / 60).truncatingRemainder(dividingBy: 60)))m"
    }
}
