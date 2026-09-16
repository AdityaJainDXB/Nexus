import SwiftUI
import NexusCore

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @EnvironmentObject var app: AppState
    @EnvironmentObject var voice: VoiceController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.selectedIndex) { i in if let i { proxy.scrollTo("row\(i)", anchor: .center) } }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 720, height: 480)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow)
                Theme.space.opacity(0.55)
                GridBackdrop().opacity(0.5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        .overlay(CornerBrackets(inset: 6, length: 16).stroke(Theme.accent.opacity(0.7), lineWidth: 1.5).allowsHitTesting(false))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _ in focused = true }
    }

    // MARK: Input

    var inputBar: some View {
        HStack(spacing: 12) {
            Group {
                if model.phase == .planning || model.phase == .executing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkle").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.gradient)
                }
            }
            .frame(width: 22)
            .accessibilityHidden(true)
            TextField(voice.isActive ? "Listening…" : "Ask or say what you need — find, organize, automate…", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 21))
                .focused($focused)
                .onSubmit { model.submit() }
                .onChange(of: model.text) { _ in if !voice.isActive { model.textChanged() } }
                .accessibilityLabel("Command")
            MicButton(size: 34)
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: States

    @ViewBuilder var content: some View {
        if voice.isActive || voice.phase == .speaking {
            VoicePanel(model: model)
        }
        if let error = voice.error, !voice.isActive {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warning)
        }
        if let result = model.result, model.phase == .done {
            resultView(result)
        } else if let plan = model.plan, model.phase == .preview {
            previewView(plan)
        } else if model.text.trimmed.isEmpty && !voice.isActive {
            emptyState
        } else if !voice.isActive {
            suggestions
        }
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            let ctx = ContextCapture.selection
            if !ctx.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(Theme.accent)
                    Text(ctx.count == 1 ? "Context: \((ctx[0] as NSString).lastPathComponent)" : "Context: \(ctx.count) selected items")
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button("File this") { model.text = "file this"; model.textChanged(); model.submit() }.buttonStyle(GhostButtonStyle())
                    Button("Summarize this") { model.text = "summarize this"; model.textChanged(); model.submit() }.buttonStyle(GhostButtonStyle())
                }
                .padding(10)
                .hudPanel()
            }
            VoiceHintCard()
            SectionHeader(title: "Quick actions")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(PaletteModel.quickActions.enumerated()), id: \.offset) { i, qa in
                    Button { model.runQuickAction(i) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: qa.symbol).foregroundStyle(Theme.accent).frame(width: 16)
                            Text(qa.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("⌘\(i + 1)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(RowBackground(selected: model.selectedIndex == i))
                    }
                    .buttonStyle(.plain)
                    .id("row\(i)")
                }
            }
            let recents = Array(app.recentCommands.prefix(5))
            if !recents.isEmpty {
                SectionHeader(title: "Recent")
                VStack(spacing: 2) {
                    ForEach(Array(recents.enumerated()), id: \.offset) { j, c in
                        let idx = PaletteModel.quickActions.count + j
                        Button { model.text = c; model.textChanged(); model.submit() } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(c).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(RowBackground(selected: model.selectedIndex == idx))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id("row\(idx)")
                    }
                }
            }
            if let top = app.insights.first {
                SectionHeader(title: "Nexus noticed")
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(Theme.severity(top.severity))
                    Text(top.title).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    if let cmd = top.command {
                        Button("Fix") { model.text = cmd; model.textChanged(); model.submit() }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }

    var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: model.localSteps.count > 1 ? "\(model.localSteps.count)-step plan" : "Understood as")
            ForEach(Array(model.localSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.16)).frame(width: 28, height: 28)
                        Image(systemName: step.intent.symbol).foregroundStyle(Theme.accent).font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if model.localSteps.count > 1 { Text("\(i + 1).").foregroundStyle(.secondary) }
                            Text(step.intent.label).font(.system(size: 13, weight: .semibold))
                            if step.intent.isMutating { Pill(text: "Changes files", color: Theme.warning) }
                        }
                        Text(describe(step.intent)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
            if model.localSteps.contains(where: { if case .unknown = $0.intent { return true }; return false }) {
                Text("Nexus will ask the on-device model to interpret this.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func describe(_ intent: CommandIntent) -> String {
        switch intent {
        case .find(let q): return "Files where " + queryText(q)
        case .fileActions(let q, let actions): return actions.map(\.summary).joined(separator: " → ") + " for " + (q.useLastResults ? "the previous results" : queryText(q))
        case .summarizeFolder(let f): return Paths.abbreviate(f)
        case .summarizeQuery(let q): return queryText(q)
        case .summarizeProject(let p): return p
        case .createRule(let t): return t
        case .schedule(let c, let when):
            switch when {
            case .once(let d): return "“\(c)” at \(DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short))"
            case .cron(let cron): return "“\(c)” — \(CronExpression.describe(cron))"
            }
        case .organize(let f): return "Apply rules and learned folders to \(Paths.abbreviate(f))"
        case .archive(let f, let d, let k): return "\(k ?? "file")s older than \(d) days in \(Paths.abbreviate(f))"
        case .report(let t): return "\(t.capitalized) report (Markdown, exportable to PDF)"
        case .createProject(let n, let k, _, let d): return "\(n)\(k.isEmpty ? "" : " · keywords: \(k.joined(separator: ", "))")\(d.map { " · due \(DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none))" } ?? "")"
        case .focus(let p, let m): return "\(p) for \(m) min — silence non-critical notifications, route files"
        case .classify(let f): return "Index & classify \(Paths.abbreviate(f)) in the background"
        case .unknown(let t): return t
        default: return intent.label
        }
    }

    func queryText(_ q: FileQuery) -> String {
        var parts = q.conditions.map(\.summary)
        if !q.folders.isEmpty { parts.insert("in " + q.folders.map(Paths.abbreviate).joined(separator: ", "), at: 0) }
        return parts.isEmpty ? "all indexed files" : parts.joined(separator: " · ")
    }

    func previewView(_ plan: CommandPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "eye").foregroundStyle(Theme.accent2)
                Text("Preview — nothing has changed yet").font(.system(size: 13, weight: .semibold))
                Spacer()
                if plan.usedLLM { Pill(text: "Interpreted on-device", symbol: "sparkles", color: Theme.accent) }
                if app.settings.dryRun { Pill(text: "Dry run", color: Theme.warning) }
            }
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: s.step.intent.symbol).foregroundStyle(Theme.accent)
                            Text("\(plan.steps.count > 1 ? "\(i + 1). " : "")\(s.step.intent.label)").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if let note = s.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(s.preview.prefix(6), id: \.self) { line in
                            Text(line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if s.preview.count > 6 || s.files.count > 8 { Text("…and more").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Run") { model.submit() }.buttonStyle(PrimaryButtonStyle())
                Button("Cancel") { model.cancelPreview() }.buttonStyle(GhostButtonStyle())
                if voice.phase == .confirming {
                    Label("Say “run it” or “cancel”", systemImage: "waveform").font(.caption).foregroundStyle(Theme.accent2)
                }
                Spacer()
                Text("Every change is logged and undoable").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func resultView(_ r: CommandResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.system(size: 18)).accessibilityHidden(true)
                Text(r.message).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            ForEach(r.details.prefix(5), id: \.self) { d in Label(d, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning) }
            if !r.files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(r.files.prefix(40).enumerated()), id: \.element.id) { i, f in
                        HStack(spacing: 10) {
                            FileIconView(path: f.path, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(Paths.abbreviate(f.folder)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            ForEach(f.tags.prefix(2), id: \.self) { TagChip(text: $0) }
                            if let d = f.docType { Pill(text: d) }
                            IconButton(symbol: "magnifyingglass", label: "Reveal \(f.name) in Finder") { Panels.reveal([f.path]) }
                            IconButton(symbol: "arrow.up.forward.square", label: "Open \(f.name)") { Panels.open(f.path) }
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(RowBackground(selected: model.selectedIndex == i))
                        .id("row\(i)")
                    }
                }
                if r.files.count > 40 { Text("\(r.files.count - 40) more — refine your query or open Files").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                if r.batchId != nil && model.plan?.requiresConfirmation == true {
                    Button { model.undo() } label: { Label("Undo  ⌘Z", systemImage: "arrow.uturn.backward") }.buttonStyle(GhostButtonStyle())
                }
                if !r.files.isEmpty {
                    Button { model.revealResults() } label: { Label("Reveal  ⌘R", systemImage: "folder") }.buttonStyle(GhostButtonStyle())
                }
                if let rule = r.createdRule {
                    Button { app.ruleDraft = rule; app.openMainWindow(.rules); PaletteController.shared.hide() } label: { Label("Test rule", systemImage: "play.rectangle") }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            StatusDot(status: app.status)
            Text(app.focus.map { f in "Focus · \(app.projects.first { $0.id == f.projectId }?.name ?? "")" } ?? "\(app.fileCount) files · \(app.llmName)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if voice.isActive {
                KeyHint(keys: voice.mode == .hold ? "release" : "pause", label: "Send")
                KeyHint(keys: "esc", label: "Stop")
            } else {
                KeyHint(keys: "↩", label: model.phase == .preview ? "Run" : model.phase == .done ? "Open" : "Go")
                KeyHint(keys: "⌘D", label: "Speak")
                KeyHint(keys: "↑↓", label: "Select")
                KeyHint(keys: "esc", label: "Close")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }
}

struct RowBackground: View {
    let selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.22) : Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? Theme.accent.opacity(0.6) : .clear))
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(label).accessibilityLabel(label)
    }
}

/// The microphone button — primary affordance for voice, shows live input level.
struct MicButton: View {
    @EnvironmentObject var voice: VoiceController
    @EnvironmentObject var app: AppState
    var size: CGFloat = 34
    var body: some View {
        Button { if !PaletteController.shared.isVisible { PaletteController.shared.show(listen: true) } else { voice.toggleFromUI() } } label: {
            ZStack {
                Circle().fill(voice.isActive ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
                if voice.isActive {
                    Circle().stroke(Theme.accent2.opacity(0.6), lineWidth: 2).scaleEffect(1 + voice.level * 0.35)
                }
                Image(systemName: voice.isActive ? "waveform" : "mic.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(voice.isActive ? Color.white : Color.primary)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Speak a command (\(app.settings.voiceHotkey.label) anywhere, ⌘D in the palette)")
        .accessibilityLabel(voice.isActive ? "Stop listening" : "Speak a command")
    }
}

struct VoiceHintCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 12) {
            MicButton(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Just say it").font(.system(size: 13, weight: .semibold))
                Text(app.settings.voiceHotkey == .off
                     ? "Press ⌘D and speak, e.g. “move invoices from Downloads to Finance”."
                     : "Hold \(app.settings.voiceHotkey.label) anywhere to talk, release to send. Tap it for hands-free.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Live listening UI: level-reactive orb, transcript and mode hint. Honors Reduce Motion.
struct VoicePanel: View {
    @ObservedObject var model: PaletteModel
    @EnvironmentObject var voice: VoiceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Theme.accent.opacity(0.12 - Double(i) * 0.03))
                        .frame(width: 60 + CGFloat(i) * 22, height: 60 + CGFloat(i) * 22)
                        .scaleEffect(reduceMotion ? 1 : 1 + voice.level * (0.15 + CGFloat(i) * 0.12))
                }
                Circle().fill(Theme.gradient).frame(width: 54, height: 54)
                Image(systemName: voice.phase == .speaking ? "speaker.wave.2.fill" : "waveform").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 120, height: 120)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: voice.level)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent2)
                Text(voice.transcript.isEmpty ? placeholder : voice.transcript)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if reduceMotion {
                    ProgressView(value: Double(voice.level)).frame(width: 160).accessibilityLabel("Input level")
                }
                HStack(spacing: 6) {
                    Image(systemName: voice.onDevice ? "lock.fill" : "network").font(.system(size: 9))
                    Text(voice.onDevice ? "Recognized on this Mac" : "On-device recognition unavailable for this language").font(.system(size: 10.5))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(voice.transcript)")
    }

    var title: String {
        switch voice.phase {
        case .confirming: return "Waiting for “run it” or “cancel”"
        case .speaking: return "Nexus"
        default: return voice.mode == .hold ? "Listening — release to send" : "Listening — pause to send"
        }
    }
    var placeholder: String {
        voice.phase == .confirming ? "Run it?" : "Try “find everything about hydroponics from this month”"
    }
}
