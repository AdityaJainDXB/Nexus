import SwiftUI
import NexusCore

/// Node-based editor. The graph is a projection of the Rule:
///   [Trigger] ──► [Condition]* ──► (ALL/ANY) ──► [Action 1] ──► [Action 2] …
/// Node positions persist in `rule.layout`.
struct FlowBuilderView: View {
    @Binding var rule: Rule
    @State private var selected: String? = "trigger"
    @State private var zoom: CGFloat = 1
    @State private var dragOffsets: [String: CGSize] = [:]

    static let nodeSize = CGSize(width: 200, height: 74)

    enum NodeKind { case trigger, condition(Condition), junction, action(RuleAction) }
    struct Node: Identifiable { let id: String; let kind: NodeKind; let position: CGPoint }

    var nodes: [Node] {
        var out: [Node] = []
        func pos(_ id: String, _ def: CGPoint) -> CGPoint {
            let p = rule.layout[id].map { CGPoint(x: $0.x, y: $0.y) } ?? def
            let d = dragOffsets[id] ?? .zero
            return CGPoint(x: p.x + d.width, y: p.y + d.height)
        }
        let conds = rule.conditions.conditions
        let rows = max(conds.count, rule.actions.count, 1)
        let midY = 60 + CGFloat(rows - 1) * 55
        out.append(Node(id: "trigger", kind: .trigger, position: pos("trigger", CGPoint(x: 130, y: midY))))
        for (i, c) in conds.enumerated() {
            out.append(Node(id: c.id, kind: .condition(c), position: pos(c.id, CGPoint(x: 390, y: 60 + CGFloat(i) * 110))))
        }
        if !conds.isEmpty { out.append(Node(id: "junction", kind: .junction, position: pos("junction", CGPoint(x: 580, y: midY)))) }
        for (i, a) in rule.actions.enumerated() {
            out.append(Node(id: a.id, kind: .action(a), position: pos(a.id, CGPoint(x: 780, y: 60 + CGFloat(i) * 110))))
        }
        return out
    }

    var edges: [(String, String)] {
        var e: [(String, String)] = []
        let conds = rule.conditions.conditions
        if conds.isEmpty {
            if let first = rule.actions.first { e.append(("trigger", first.id)) }
        } else {
            for c in conds { e.append(("trigger", c.id)); e.append((c.id, "junction")) }
            if let first = rule.actions.first { e.append(("junction", first.id)) }
        }
        for (a, b) in zip(rule.actions, rule.actions.dropFirst()) { e.append((a.id, b.id)) }
        return e
    }

    var body: some View {
        HStack(spacing: 12) {
            palette.frame(width: 150)
            GeometryReader { geo in
                let ns = nodes
                let lookup = Dictionary(uniqueKeysWithValues: ns.map { ($0.id, $0) })
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        GridBackground().frame(width: 1400, height: 1000)
                        ForEach(Array(edges.enumerated()), id: \.offset) { _, edge in
                            if let a = lookup[edge.0], let b = lookup[edge.1] {
                                EdgeShape(from: CGPoint(x: a.position.x + (a.id == "junction" ? 22 : Self.nodeSize.width / 2), y: a.position.y),
                                          to: CGPoint(x: b.position.x - (b.id == "junction" ? 22 : Self.nodeSize.width / 2), y: b.position.y))
                                    .stroke(LinearGradient(colors: [color(a).opacity(0.8), color(b).opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: rule.enabled ? [] : [5, 4]))
                            }
                        }
                        ForEach(ns) { node in
                            nodeView(node)
                                .position(node.position)
                                .gesture(DragGesture()
                                    .onChanged { v in dragOffsets[node.id] = v.translation; selected = node.id }
                                    .onEnded { v in
                                        let base = rule.layout[node.id].map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: node.position.x - v.translation.width, y: node.position.y - v.translation.height)
                                        rule.layout[node.id] = NodePosition(x: max(60, base.x + v.translation.width), y: max(40, base.y + v.translation.height))
                                        dragOffsets[node.id] = nil
                                    })
                                .onTapGesture { selected = node.id }
                        }
                    }
                    .frame(width: 1400, height: 1000)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: 1400 * zoom, height: 1000 * zoom, alignment: .topLeading)
                }
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    HStack {
                        Image(systemName: "minus.magnifyingglass")
                        Slider(value: $zoom, in: 0.5...1.4).frame(width: 110)
                        Image(systemName: "plus.magnifyingglass")
                        Button("Auto-layout") { rule.layout = [:] }.buttonStyle(GhostButtonStyle())
                    }
                    .font(.caption).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            inspector.frame(width: 270)
        }
        .frame(minHeight: 420)
    }

    // MARK: Nodes

    func color(_ n: Node) -> Color {
        switch n.kind { case .trigger: return Theme.accent2; case .condition, .junction: return Theme.warning; case .action: return Theme.accent }
    }

    @ViewBuilder func nodeView(_ node: Node) -> some View {
        let isSel = selected == node.id
        switch node.kind {
        case .junction:
            Text(rule.conditions.match == .all ? "ALL" : "ANY")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.warning.opacity(0.2)))
                .overlay(Circle().stroke(isSel ? Color.white : Theme.warning, lineWidth: isSel ? 2 : 1))
                .onTapGesture(count: 2) { rule.conditions.match = rule.conditions.match == .all ? .any : .all }
        default:
            let (title, subtitle, symbol) = labels(node)
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(color(node).opacity(0.2)).frame(width: 32, height: 32)
                    Image(systemName: symbol).foregroundStyle(color(node)).font(.system(size: 14, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color(node)).textCase(.uppercase)
                    Text(subtitle).font(.system(size: 11.5, weight: .medium)).lineLimit(2).foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isSel ? color(node) : Color.primary.opacity(0.1), lineWidth: isSel ? 2 : 1))
            .shadow(color: isSel ? color(node).opacity(0.35) : .black.opacity(0.4), radius: isSel ? 12 : 6, y: 3)
        }
    }

    func labels(_ node: Node) -> (String, String, String) {
        switch node.kind {
        case .trigger: return ("Trigger", rule.trigger.summary, rule.trigger.kind.symbol)
        case .condition(let c): return ("Condition", c.summary, "line.3.horizontal.decrease")
        case .action(let a): return ("Action", a.summary, a.kind.symbol)
        case .junction: return ("", "", "")
        }
    }

    // MARK: Palette

    var palette: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("ADD NODE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Menu { ForEach(TriggerKind.allCases) { k in Button { rule.trigger.kind = k; selected = "trigger" } label: { Label(k.label, systemImage: k.symbol) } } } label: {
                    Label("Trigger", systemImage: "bolt.horizontal").frame(maxWidth: .infinity, alignment: .leading)
                }.menuStyle(.borderlessButton)
                Menu { ForEach(ConditionField.allCases) { f in Button(f.label) { let c = Condition(f, f.isNumeric ? .greaterThan : .contains, ""); rule.conditions.conditions.append(c); selected = c.id } } } label: {
                    Label("Condition", systemImage: "line.3.horizontal.decrease.circle").frame(maxWidth: .infinity, alignment: .leading)
                }.menuStyle(.borderlessButton)
                Menu { ForEach(ActionKind.allCases) { k in Button { let a = RuleAction(kind: k); rule.actions.append(a); selected = a.id } label: { Label(k.label, systemImage: k.symbol) } } } label: {
                    Label("Action", systemImage: "bolt.fill").frame(maxWidth: .infinity, alignment: .leading)
                }.menuStyle(.borderlessButton)
                Divider()
                Text("Drag nodes to arrange. Double-click the junction to switch ALL/ANY. Actions run top to bottom.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Inspector

    @ViewBuilder var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("INSPECTOR").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                if selected == "trigger" {
                    TriggerEditor(trigger: $rule.trigger)
                } else if selected == "junction" {
                    Picker("Match", selection: $rule.conditions.match) { Text("All conditions").tag(MatchMode.all); Text("Any condition").tag(MatchMode.any) }.pickerStyle(.radioGroup)
                } else if let idx = rule.conditions.conditions.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Field", selection: $rule.conditions.conditions[idx].field) { ForEach(ConditionField.allCases) { Text($0.label).tag($0) } }
                        Picker("Operator", selection: $rule.conditions.conditions[idx].op) { ForEach(ConditionOp.allCases) { Text($0.label).tag($0) } }
                        TextField("Value", text: $rule.conditions.conditions[idx].value).textFieldStyle(.roundedBorder)
                        Button(role: .destructive) { rule.conditions.conditions.remove(at: idx); selected = "trigger" } label: { Label("Delete condition", systemImage: "trash") }.buttonStyle(GhostButtonStyle())
                    }
                } else if let idx = rule.actions.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 8) {
                        ActionRow(action: $rule.actions[idx], index: idx, count: rule.actions.count,
                                  move: { dir in let n = idx + dir; guard n >= 0, n < rule.actions.count else { return }; rule.actions.swapAt(idx, n) },
                                  remove: { rule.actions.remove(at: idx); selected = "trigger" })
                        .labelsHidden()
                    }
                } else {
                    Text("Select a node").foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EdgeShape: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        let dx = max(40, abs(to.x - from.x) * 0.5)
        p.addCurve(to: to, control1: CGPoint(x: from.x + dx, y: from.y), control2: CGPoint(x: to.x - dx, y: to.y))
        return p
    }
}

struct GridBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 24
            for x in stride(from: 0, through: size.width, by: spacing) {
                for y in stride(from: 0, through: size.height, by: spacing) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.08)))
                }
            }
        }
    }
}

// MARK: - Simulator

struct RuleSimulatorView: View {
    @EnvironmentObject var app: AppState
    let rule: Rule
    let isNew: Bool
    @State private var path: String?
    @State private var report: SimulationReport?
    @State private var folderResults: [(FileRecord, RuleEvaluation)] = []
    @State private var folder: String?
    @State private var running = false
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    dropZone
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Test this rule on a folder").font(.headline)
                        Text("Preview which files would match and exactly what would happen. Nothing is changed.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { if let f = Panels.chooseFolder(prompt: "Test") { testFolder(f) } } label: { Label("Choose folder…", systemImage: "folder") }.buttonStyle(GhostButtonStyle())
                            ForEach(rule.trigger.folders.prefix(2), id: \.self) { f in
                                Button(Paths.abbreviate(Paths.expand(f))) { testFolder(Paths.expand(f)) }.buttonStyle(GhostButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if running { ProgressView("Analyzing…").controlSize(.small) }
                if let report { reportView(report) }
                if let folder, !folderResults.isEmpty { folderView(folder) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulatePath)) { n in if let p = n.object as? String { simulate(p) } }
    }

    var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.viewfinder").font(.system(size: 26)).foregroundStyle(Theme.gradient)
            Text(path.map { ($0 as NSString).lastPathComponent } ?? "Drop a file to simulate all rules").font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
            Button("Choose file…") { if let f = Panels.chooseFile() { simulate(f) } }.buttonStyle(GhostButtonStyle())
        }
        .frame(width: 250, height: 130)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(dropTargeted ? Theme.accent : Color.primary.opacity(0.15)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { simulate(url.path) } }
            }
            return true
        }
    }

    func simulate(_ p: String) {
        path = p
        running = true
        let draft = rule
        let includeDraft = isNew || app.rules.contains { $0.id == draft.id }
        Task.detached {
            let engine = await AppState.shared.engine
            var rules = engine.store.rules().filter { $0.id != draft.id }
            if includeDraft && draft.name != "Simulation" { rules.append(draft) }
            let r = engine.simulate(path: p, rules: rules)
            await MainActor.run { report = r; running = false }
        }
    }

    func testFolder(_ f: String) {
        folder = f
        running = true
        let draft = rule
        Task.detached {
            let results = await AppState.shared.engine.testRule(draft, folder: f)
            await MainActor.run { folderResults = results; running = false }
        }
    }

    func reportView(_ r: SimulationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 12) {
                HStack(spacing: 12) {
                    ThumbnailView(path: r.file.path, size: CGSize(width: 54, height: 54))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.file.name).font(.headline)
                        Text("Understood as: \(r.file.docType ?? r.file.kind.rawValue)\(r.file.topics.isEmpty ? "" : " · " + r.file.topics.prefix(4).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Pill(text: "\(r.firedCount) rule\(r.firedCount == 1 ? "" : "s") would fire", color: r.firedCount > 0 ? Theme.success : .secondary)
                }
            }
            ForEach(r.conflicts, id: \.self) { c in Label(c, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning) }
            ForEach(Array(r.evaluations.enumerated()), id: \.offset) { i, e in
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            Image(systemName: e.fired ? "checkmark.circle.fill" : e.skippedByStop ? "hand.raised.fill" : "circle").foregroundStyle(e.fired ? Theme.success : e.skippedByStop ? Theme.warning : .secondary)
                            Text(e.rule.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(e.rule.id == rule.id ? Theme.accent : .primary)
                            if !e.rule.enabled { Pill(text: "disabled") }
                            Spacer()
                            Text(e.fired ? "fires" : e.skippedByStop ? "blocked by higher-priority rule" : e.triggerMatched ? "conditions not met" : "trigger doesn't apply").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(e.conditionResults, id: \.condition.id) { c in
                            HStack(spacing: 6) {
                                Image(systemName: c.passed ? "checkmark" : "xmark").foregroundStyle(c.passed ? Theme.success : Theme.danger).font(.system(size: 10, weight: .bold))
                                Text(c.condition.summary).font(.system(size: 11.5))
                                Text("actual: \(c.actual.isEmpty ? "—" : c.actual)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        if e.fired {
                            ForEach(e.plannedActions, id: \.self) { a in Label(a, systemImage: "arrow.turn.down.right").font(.system(size: 11.5)).foregroundStyle(Theme.accent2) }
                        }
                    }
                }
            }
        }
    }

    func folderView(_ f: String) -> some View {
        let matched = folderResults.filter(\.1.fired)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(matched.count) of \(folderResults.count) files in \(Paths.abbreviate(f)) would match").font(.headline)
                Spacer()
            }
            ForEach(folderResults.prefix(80), id: \.0.id) { file, e in
                HStack(spacing: 8) {
                    Image(systemName: e.fired ? "checkmark.circle.fill" : "circle").foregroundStyle(e.fired ? Theme.success : .secondary)
                    FileIconView(path: file.path, size: 16)
                    Text(file.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(e.fired ? e.plannedActions.joined(separator: " → ") : (e.conditionResults.first { !$0.passed }.map { "✗ \($0.condition.summary)" } ?? "")).font(.system(size: 10.5)).foregroundStyle(e.fired ? Theme.accent2 : .secondary).lineLimit(1)
                }
            }
        }
    }
}
