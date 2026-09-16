import SwiftUI
import NexusCore
import UniformTypeIdentifiers

struct RulesView: View {
    @EnvironmentObject var app: AppState
    @State private var selectedId: String?
    @State private var draft: Rule?
    @State private var search = ""
    @State private var mode = 0

    var filtered: [Rule] { app.rules.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.naturalLanguage ?? "").localizedCaseInsensitiveContains(search) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Rules").font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    Button { newRule() } label: { Image(systemName: "plus") }.buttonStyle(GhostButtonStyle()).help("New rule")
                }
                TextField("Search rules", text: $search).textFieldStyle(.roundedBorder)
                if !app.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.conflicts) { c in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.caption)
                                Text(c.message).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8).background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                List(selection: $selectedId) {
                    ForEach(filtered) { r in RuleRow(rule: r, conflicted: app.conflicts.contains { $0.ruleA == r.id || $0.ruleB == r.id }).tag(r.id) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Button { mode = 2; draft = draft ?? Rule(name: "Simulation", trigger: Trigger(kind: .fileAdded)); selectedId = nil } label: { Label("Simulate a file against all rules", systemImage: "play.rectangle.on.rectangle") }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(18)
            .frame(width: 320)
            Divider()
            if let draftBinding = Binding($draft) {
                RuleEditor(rule: draftBinding, mode: $mode, isNew: !app.rules.contains { $0.id == draft?.id }, onSaved: { selectedId = $0 }, onDeleted: { draft = nil; selectedId = nil })
                    .id(draft?.id)
            } else {
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: "Describe it, Nexus builds it",
                               message: "Write rules in plain English — “If a PDF in Downloads contains ‘lab report’ → move to School/Science/Reports, tag MYP3” — then refine them visually and test them before they touch a single file.")
                    .overlay(alignment: .bottom) { Button { newRule() } label: { Label("New rule", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle()).padding(.bottom, 80) }
            }
        }
        .onChange(of: selectedId) { id in if let id, let r = app.rules.first(where: { $0.id == id }) { draft = r; if mode == 2 { mode = 0 } } }
        .onAppear { consumeDraft() }
        .onChange(of: app.ruleDraft) { _ in consumeDraft() }
        .onReceive(NotificationCenter.default.publisher(for: .simulatePath)) { _ in mode = 2; if draft == nil { draft = Rule(name: "Simulation", trigger: Trigger(kind: .fileAdded)) } }
    }

    func consumeDraft() {
        guard let d = app.ruleDraft else { return }
        draft = d
        selectedId = app.rules.contains { $0.id == d.id } ? d.id : nil
        mode = app.rules.contains { $0.id == d.id } ? 2 : 0
        app.ruleDraft = nil
    }

    func newRule() {
        selectedId = nil
        mode = 0
        draft = Rule(name: "New rule", trigger: Trigger(kind: .fileAdded, folders: ["~/Downloads"]), naturalLanguage: "")
    }
}

struct RuleRow: View {
    @EnvironmentObject var app: AppState
    let rule: Rule
    let conflicted: Bool
    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; app.engine.store.saveRule(r) })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: rule.trigger.kind.symbol).font(.system(size: 10)).foregroundStyle(Theme.accent2)
                    Text(rule.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if conflicted { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.warning) }
                }
                Text("\(rule.hitCount) hit\(rule.hitCount == 1 ? "" : "s")\(rule.lastTriggeredAt.map { " · last \(relativeTime($0))" } ?? " · never run")")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(rule.enabled ? 1 : 0.55)
        .padding(.vertical, 3)
    }
}

// MARK: - Editor

struct RuleEditor: View {
    @EnvironmentObject var app: AppState
    @Binding var rule: Rule
    @Binding var mode: Int
    let isNew: Bool
    let onSaved: (String) -> Void
    let onDeleted: () -> Void
    @State private var nlText = ""
    @State private var compiling = false
    @State private var explanation: [String] = []
    @State private var warnings: [String] = []
    @State private var dirty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Rule name", text: $rule.name).textFieldStyle(.plain).font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
                Picker("", selection: $mode) { Text("Simple").tag(0); Text("Visual").tag(1); Text("Simulate").tag(2) }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
            }
            Text(rule.summary).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)

            Group {
                switch mode {
                case 0: simple
                case 1: FlowBuilderView(rule: $rule)
                default: RuleSimulatorView(rule: rule, isNew: isNew)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if mode != 2 {
                HStack(spacing: 10) {
                    Toggle("Enabled", isOn: $rule.enabled).toggleStyle(.switch)
                    Toggle("Ask before acting", isOn: $rule.requireConfirmation).toggleStyle(.checkbox).help("Results go to the Review Queue")
                    Toggle("Stop other rules", isOn: $rule.stopProcessing).toggleStyle(.checkbox)
                    Stepper("Priority \(rule.priority)", value: $rule.priority, in: 0...100, step: 5).frame(width: 130)
                    Spacer()
                    if !isNew {
                        Button(role: .destructive) { app.engine.store.deleteRule(rule.id); onDeleted() } label: { Image(systemName: "trash") }.buttonStyle(GhostButtonStyle())
                        Button { var copy = rule; copy.id = newID(); copy.name += " copy"; copy.hitCount = 0; app.engine.store.saveRule(copy); onSaved(copy.id) } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(GhostButtonStyle()).help("Duplicate")
                        Button { app.engine.queue.enqueue(Job(name: "Run rule: \(rule.name)", kind: .file, priority: .high, spec: JobSpec(operation: .runRule, ruleId: rule.id))); app.showToast("Running “\(rule.name)”") } label: { Label("Run now", systemImage: "play.fill") }.buttonStyle(GhostButtonStyle())
                    }
                    Button { mode = 2 } label: { Label("Test", systemImage: "play.rectangle") }.buttonStyle(GhostButtonStyle())
                    Button(isNew ? "Create rule" : "Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .padding(22)
        .onAppear { nlText = rule.naturalLanguage ?? "" }
    }

    // MARK: Simple mode

    var simple: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "text.bubble").foregroundStyle(Theme.accent)
                            Text("Describe the rule").font(.headline)
                            Spacer()
                            Menu("Examples") {
                                ForEach(RuleExamples.all, id: \.self) { ex in Button(ex) { nlText = ex; build() } }
                            }.menuStyle(.borderlessButton).frame(width: 90)
                        }
                        TextEditor(text: $nlText)
                            .font(.system(size: 13.5))
                            .frame(height: 64)
                            .scrollContentBackground(.hidden)
                            .padding(6).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button { build() } label: { Label(compiling ? "Building…" : "Build rule", systemImage: "wand.and.stars") }.buttonStyle(PrimaryButtonStyle()).disabled(compiling || nlText.trimmed.isEmpty)
                            Text("Deterministic parser first; the on-device model helps with unusual phrasing.").font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(explanation, id: \.self) { e in Label(e, systemImage: "checkmark").font(.caption).foregroundStyle(Theme.success) }
                        ForEach(warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning) }
                    }
                }
                TriggerEditor(trigger: $rule.trigger)
                ConditionsEditor(group: $rule.conditions)
                ActionsEditor(actions: $rule.actions)
            }
        }
    }

    func build() {
        compiling = true
        Task {
            let result = await app.engine.compileRule(nlText)
            compiling = false
            explanation = result.explanation
            warnings = result.warnings
            if var r = result.rule {
                r.id = rule.id
                r.enabled = rule.enabled
                r.hitCount = rule.hitCount
                r.createdAt = rule.createdAt
                if !isNew && !rule.name.isEmpty && rule.name != "New rule" { r.name = rule.name }
                rule = r
            }
        }
    }

    func save() {
        if rule.naturalLanguage == nil || rule.naturalLanguage!.isEmpty { rule.naturalLanguage = nlText.isEmpty ? nil : nlText }
        if let p = rule.actions.first(where: { $0.kind == .addToProject }), let name = p.project ?? Optional(p.target), let proj = app.engine.resolveProject(named: name, create: true) {
            rule.projectId = proj.id
        }
        app.engine.store.saveRule(rule)
        onSaved(rule.id)
        app.showToast("Saved “\(rule.name)”. Want to test it? Switch to Simulate.")
    }
}

enum RuleExamples {
    static let all = [
        "If a PDF in Downloads contains 'lab report' → move to School/Science/Reports, tag MYP3, add to project Science Fair",
        "If code file language is Python and folder is Downloads → move to Dev/Python, tag snippet",
        "Any PDF with 'MYP3' goes to School and gets tag science",
        "Invoices from Downloads → move to Finance/{year}, tag tax, rename to {date} Invoice",
        "Screenshots older than 30 days in Desktop → move to ~/Pictures/Screenshots/{year}/{month}",
        "When Chrome download finishes and filename contains 'syllabus' → copy to School/Syllabi and create a calendar reminder",
        "When external drive 'Backup' is connected → sync Projects and School folders",
        "When disk < 25GB → find large duplicate files and suggest cleanup",
        "When Downloads has > 50 files and it's after 8 PM → auto-sort",
        "When F1 TV app opens, prepare Media/F1 folder",
        "Every Sunday 9 AM: archive old screenshots, generate storage report",
        "When a new GitHub issue is assigned to me → create a task and a project folder",
        "When I get an email with 'lab report' attachment → save to School/Science/Reports and add deadline to Calendar",
        "Move STL files from Downloads to 3D Printing/Models and tag print-queue",
        "If a DMG in Downloads is older than 7 days → move to trash",
    ]
}

// MARK: - Structured editors

struct TriggerEditor: View {
    @Binding var trigger: Trigger
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("When", systemImage: trigger.kind.symbol).font(.headline).foregroundStyle(Theme.accent2)
                Picker("Trigger", selection: $trigger.kind) { ForEach(TriggerKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) } }.frame(width: 320)
                switch trigger.kind {
                case .fileAdded, .fileModified, .downloadCompleted:
                    FolderChips(folders: $trigger.folders)
                    Toggle("Include subfolders", isOn: $trigger.recursive).toggleStyle(.checkbox)
                case .schedule:
                    HStack {
                        TextField("Cron", text: Binding(get: { trigger.cron ?? "" }, set: { trigger.cron = $0 })).font(.system(.body, design: .monospaced)).frame(width: 160)
                        Text(trigger.cron.map(CronExpression.describe) ?? "e.g. 0 9 * * 0").font(.caption).foregroundStyle(.secondary)
                    }
                case .appLaunched, .appQuit:
                    TextField("App name or bundle id", text: Binding(get: { trigger.appName ?? "" }, set: { trigger.appName = $0 })).frame(width: 280)
                case .volumeMounted, .volumeUnmounted:
                    TextField("Drive name (blank = any)", text: Binding(get: { trigger.volumeName ?? "" }, set: { trigger.volumeName = $0.isEmpty ? nil : $0 })).frame(width: 280)
                case .diskSpaceBelow, .folderSizeAbove, .folderCountAbove, .idle:
                    if trigger.kind != .diskSpaceBelow && trigger.kind != .idle { FolderChips(folders: $trigger.folders) }
                    HStack {
                        Text(trigger.kind == .folderCountAbove ? "Files" : trigger.kind == .idle ? "Minutes" : "GB")
                        TextField("", value: Binding(get: { trigger.threshold ?? 25 }, set: { trigger.threshold = $0 }), format: .number).frame(width: 80)
                    }
                case .connectorEvent:
                    Picker("Event", selection: Binding(get: { trigger.connectorEvent ?? "" }, set: { trigger.connectorEvent = $0 })) {
                        ForEach(["github.issueAssigned", "github.prReviewRequested", "mail.attachment", "notion.pageTagged", "calendar.eventStarting", "custom.webhook"], id: \.self) { Text($0).tag($0) }
                    }.frame(width: 320)
                default: EmptyView()
                }
            }
        }
    }
}

struct FolderChips: View {
    @Binding var folders: [String]
    var body: some View {
        FlowLayout {
            ForEach(folders, id: \.self) { f in
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").font(.system(size: 10))
                    Text(Paths.abbreviate(Paths.expand(f))).font(.system(size: 11.5, design: .monospaced))
                    Button { folders.removeAll { $0 == f } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.accent2.opacity(0.14), in: Capsule()).foregroundStyle(Theme.accent2)
            }
            Button { if let f = Panels.chooseFolder(prompt: "Add") { folders.append(Paths.abbreviate(f)) } } label: { Label("Folder", systemImage: "plus") }.buttonStyle(GhostButtonStyle())
        }
    }
}

struct ConditionsEditor: View {
    @Binding var group: ConditionGroup
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("If", systemImage: "line.3.horizontal.decrease.circle").font(.headline).foregroundStyle(Theme.warning)
                    Picker("", selection: $group.match) { Text("all of").tag(MatchMode.all); Text("any of").tag(MatchMode.any) }.labelsHidden().frame(width: 90)
                    Text("these conditions match").foregroundStyle(.secondary)
                    Spacer()
                    Button { group.conditions.append(Condition(.anyText, .contains, "")) } label: { Label("Condition", systemImage: "plus") }.buttonStyle(GhostButtonStyle())
                }
                if group.conditions.isEmpty { Text("No conditions — the rule applies to every file from the trigger.").font(.caption).foregroundStyle(.tertiary) }
                ForEach($group.conditions) { $c in
                    HStack {
                        Picker("", selection: $c.field) { ForEach(ConditionField.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 160)
                        Picker("", selection: $c.op) { ForEach(ConditionOp.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 140)
                        TextField(placeholder(c.field), text: $c.value).textFieldStyle(.roundedBorder)
                        Button { group.conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    func placeholder(_ f: ConditionField) -> String {
        switch f {
        case .ext: return "pdf"; case .kind: return "image, pdf, code, screenshot…"; case .docType: return "invoice, lab report, syllabus…"
        case .sizeMB: return "MB"; case .ageDays: return "days"; case .hour: return "0-23"; case .folder: return "~/Downloads"; case .language: return "Python"
        default: return "value (use a|b for alternatives)"
        }
    }
}

struct ActionsEditor: View {
    @EnvironmentObject var app: AppState
    @Binding var actions: [RuleAction]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Then", systemImage: "bolt.fill").font(.headline).foregroundStyle(Theme.accent)
                    Spacer()
                    Menu { ForEach(ActionKind.allCases) { k in Button { actions.append(RuleAction(kind: k)) } label: { Label(k.label, systemImage: k.symbol) } } } label: { Label("Action", systemImage: "plus") }
                        .menuStyle(.borderlessButton).frame(width: 90)
                }
                Text("Templates: {name} {basename} {ext} {year} {month} {date} {project} {docType} {language} {topic}").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                ForEach(Array(actions.enumerated()), id: \.element.id) { idx, _ in
                    ActionRow(action: $actions[idx], index: idx, count: actions.count,
                              move: { dir in let n = idx + dir; guard n >= 0, n < actions.count else { return }; actions.swapAt(idx, n) },
                              remove: { actions.remove(at: idx) })
                }
            }
        }
    }
}

struct ActionRow: View {
    @EnvironmentObject var app: AppState
    @Binding var action: RuleAction
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14)
            Picker("", selection: $action.kind) { ForEach(ActionKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) } }.labelsHidden().frame(width: 190)
            fields
            Spacer(minLength: 4)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == 0)
            Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index == count - 1)
            Button { remove() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var fields: some View {
        switch action.kind {
        case .tag, .removeTag:
            TextField("tags, comma separated", text: Binding(get: { action.tags.joined(separator: ", ") }, set: { action.tags = $0.split(separator: ",").map { $0.trimmed }.filter { !$0.isEmpty } })).textFieldStyle(.roundedBorder)
        case .addToProject:
            Picker("", selection: Binding(get: { action.project ?? action.target }, set: { action.project = $0; action.target = $0 })) {
                Text("Choose…").tag("")
                ForEach(app.projects) { Text($0.name).tag($0.name) }
                if let p = action.project, !app.projects.contains(where: { $0.name == p }) { Text("\(p) (new)").tag(p) }
            }.labelsHidden()
        case .move, .copy, .syncFolder, .createFolder:
            HStack {
                TextField("destination", text: $action.target).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button { if let f = Panels.chooseFolder() { action.target = Paths.abbreviate(f) } } label: { Image(systemName: "folder") }.buttonStyle(.plain)
            }
            if action.kind == .syncFolder { TextField("source", text: Binding(get: { action.params["source"] ?? "" }, set: { action.params["source"] = $0 })).textFieldStyle(.roundedBorder).frame(width: 160) }
        case .archiveOld:
            TextField("folder", text: Binding(get: { action.params["folder"] ?? "" }, set: { action.params["folder"] = $0 })).textFieldStyle(.roundedBorder).frame(width: 140)
            TextField("days", text: Binding(get: { action.params["days"] ?? "30" }, set: { action.params["days"] = $0 })).textFieldStyle(.roundedBorder).frame(width: 50)
            TextField("archive to", text: $action.target).textFieldStyle(.roundedBorder)
        case .trash, .compress, .summarize, .openFile, .revealInFinder, .findDuplicates:
            Text(action.kind == .trash ? "Recoverable from Trash; undoable" : "No options").font(.caption).foregroundStyle(.tertiary)
        case .generateReport:
            Picker("", selection: Binding(get: { action.params["type"] ?? "weekly" }, set: { action.params["type"] = $0 })) { ForEach(["daily", "weekly", "monthly", "storage"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 110)
        case .runShell:
            TextField("zsh command or script path ($NEXUS_FILE available)", text: $action.target).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        default:
            TextField(placeholder, text: $action.target).textFieldStyle(.roundedBorder)
        }
    }

    var placeholder: String {
        switch action.kind {
        case .rename: return "{date} {basename}"
        case .notify: return "message"
        case .runShortcut: return "Shortcut name"
        case .runAppleScript: return "script or path"
        case .runPlugin: return "plugin name"
        case .webhook: return "https://…"
        case .createReminder, .createTask, .createCalendarEvent: return "title"
        case .githubIssue: return "issue title"
        case .obsidianNote: return "note path in vault"
        case .slackMessage: return "message"
        case .setCategory: return "category"
        case .sortFolder: return "folder"
        default: return "value"
        }
    }
}
