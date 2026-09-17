import SwiftUI

enum RTheme {
    static let cyan = Color(red: 0.22, green: 0.886, blue: 1)
    static let violet = Color(red: 0.56, green: 0.486, blue: 1)
    static let green = Color(red: 0.24, green: 0.96, blue: 0.63)
    static let amber = Color(red: 1, green: 0.784, blue: 0.341)
    static let red = Color(red: 1, green: 0.36, blue: 0.48)
    static let space = Color(red: 0.027, green: 0.039, blue: 0.07)
    static let panel = Color(red: 0.05, green: 0.07, blue: 0.125)
    static let gradient = LinearGradient(colors: [cyan, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct GridBackground: View {
    var body: some View {
        ZStack {
            RTheme.space
            Canvas { ctx, size in
                var p = Path()
                for x in stride(from: 0, through: size.width, by: 24) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: 24) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(p, with: .color(RTheme.cyan.opacity(0.05)), lineWidth: 0.5)
            }
            RadialGradient(colors: [RTheme.cyan.opacity(0.14), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

struct CornerBrackets: Shape {
    var inset: CGFloat = 4, length: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path(); let a = r.insetBy(dx: inset, dy: inset); let l = min(length, a.width / 4, a.height / 4)
        p.move(to: CGPoint(x: a.minX, y: a.minY + l)); p.addLine(to: CGPoint(x: a.minX, y: a.minY)); p.addLine(to: CGPoint(x: a.minX + l, y: a.minY))
        p.move(to: CGPoint(x: a.maxX - l, y: a.minY)); p.addLine(to: CGPoint(x: a.maxX, y: a.minY)); p.addLine(to: CGPoint(x: a.maxX, y: a.minY + l))
        p.move(to: CGPoint(x: a.maxX, y: a.maxY - l)); p.addLine(to: CGPoint(x: a.maxX, y: a.maxY)); p.addLine(to: CGPoint(x: a.maxX - l, y: a.maxY))
        p.move(to: CGPoint(x: a.minX + l, y: a.maxY)); p.addLine(to: CGPoint(x: a.minX, y: a.maxY)); p.addLine(to: CGPoint(x: a.minX, y: a.maxY - l))
        return p
    }
}

extension View {
    func hudCard() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTheme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RTheme.cyan.opacity(0.16)))
            .overlay(CornerBrackets().stroke(RTheme.cyan.opacity(0.5), lineWidth: 1.1))
    }
}

struct HUDLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(RTheme.cyan).frame(width: 3, height: 10)
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(RTheme.gradient.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(RTheme.space)
    }
}
