import SwiftUI
import NexusCore

struct ProjectsView: View {
    @EnvironmentObject var app: AppState
    @State private var editing: Project?
    @State private var showArchived = false

    var visible: [Project] { app.projects.filter { showArchived || !$0.archived } }

    var body: some View {
        if let id = app.selectedProjectId, let p = app.projects.first(where: { $0.id == id }) {
            ProjectDetailView(project: p, onBack: { app.selectedProjectId = nil }, onEdit: { editing = p })
                .sheet(item: $editing) { ProjectEditor(project: $0).environmentObject(app).preferredColorScheme(app.settings.appearance.colorScheme) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Projects", subtitle: "Files, deadlines, rules and context — grouped the way you think.") {
                        HStack {
                            Toggle("Archived", isOn: $showArchived).toggleStyle(.switch).controlSize(.small)
                            Button { editing = Project(name: "", color: NexusEngine.palette.randomElement()!) } label: { Label("New project", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    if visible.isEmpty {
                        EmptyStateView(symbol: "square.stack.3d.up", title: "No projects yet",
                                       message: "Projects are first-class: give Nexus a name, a few keywords and folders, and it will associate related files automatically — even ones sitting in Downloads.")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(visible) { p in ProjectCard(project: p).onTapGesture { app.selectedProjectId = p.id } }
                    }
                }
                .padding(28)
            }
            .sheet(item: $editing) { ProjectEditor(project: $0).environmentObject(app).preferredColorScheme(app.settings.appearance.colorScheme) }
            .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in editing = Project(name: "", color: NexusEngine.palette.randomElement()!) }
        }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var app: AppState
    let project: Project
    var body: some View {
        let stats = app.engine.store.projectStats(project.id)
        let activity = app.engine.store.projectActivity(project.id)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: project.color).opacity(0.2)).frame(width: 36, height: 36)
                        Image(systemName: project.icon).foregroundStyle(Color(hex: project.color))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(project.keywords.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if app.focus?.projectId == project.id { Pill(text: "Focus", symbol: "scope", color: Theme.accent2) }
                    if project.archived { Pill(text: "Archived") }
                }
                HStack(spacing: 16) {
                    metric("\(stats.count)", "files")
                    metric(formatBytes(stats.size), "storage")
                    if let d = project.deadline { metric(relativeTime(d), "deadline", color: d.timeIntervalSinceNow < 3 * 86400 ? Theme.warning : .primary) }
                }
                Sparkline(values: activity, color: Color(hex: project.color)).frame(height: 32)
                Text("Activity, last 14 days").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
    func metric(_ v: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject var app: AppState
    let project: Project
    let onBack: () -> Void
    let onEdit: () -> Void
    @State private var tab = 0
    @State private var summary: String?
    @State private var summarizing = false

    var files: [FileRecord] { app.engine.store.files(limit: 1000, projectId: project.id, orderBy: "modified DESC") }
    var rules: [Rule] { app.rules.filter { r in r.projectId == project.id || r.actions.contains { ($0.project ?? $0.target).lowercased() == project.name.lowercased() } } }
    var jobs: [Job] { app.jobs.filter { $0.spec.params["projectId"] == project.id || $0.name.contains(project.name) } }

    var body: some View {
        let stats = app.engine.store.projectStats(project.id)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { onBack() } label: { Label("Projects", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: project.color).opacity(0.2)).frame(width: 56, height: 56)
                    Image(systemName: project.icon).font(.system(size: 24)).foregroundStyle(Color(hex: project.color))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.system(size: 26, weight: .bold, design: .rounded))
                    HStack(spacing: 10) {
                        Text("\(stats.count) files · \(formatBytes(stats.size))").foregroundStyle(.secondary)
                        if let d = project.deadline { Pill(text: "Due \(DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none))", symbol: "calendar", color: d.timeIntervalSinceNow < 3 * 86400 ? Theme.warning : Theme.accent2) }
                        ForEach(project.tags.prefix(4), id: \.self) { TagChip(text: $0) }
                    }
                    .font(.callout)
                }
                Spacer()
                Button("Edit") { onEdit() }.buttonStyle(GhostButtonStyle())
            }
            HStack(spacing: 8) {
                Button { if let f = project.folders.first { Panels.reveal([Paths.expand(f)]) } else { Panels.reveal(files.prefix(30).map(\.path)) } } label: { Label("Show all files", systemImage: "folder") }.buttonStyle(GhostButtonStyle())
                Button { cleanup() } label: { Label("Run cleanup", systemImage: "wand.and.stars") }.buttonStyle(GhostButtonStyle())
                Button { summarize() } label: { Label(summarizing ? "Summarizing…" : "Generate summary", systemImage: "sparkles") }.buttonStyle(GhostButtonStyle()).disabled(summarizing)
                Button { app.engine.startFocus(projectId: project.id, minutes: 90); app.reloadAll() } label: { Label("Focus 90 min", systemImage: "scope") }.buttonStyle(PrimaryButtonStyle())
                Spacer()
                Button { var p = project; p.archived.toggle(); app.engine.store.saveProject(p) } label: { Label(project.archived ? "Unarchive" : "Archive", systemImage: "archivebox") }.buttonStyle(GhostButtonStyle())
            }
            if let summary {
                Card { HStack(alignment: .top) { Image(systemName: "sparkles").foregroundStyle(Theme.accent); Text(summary).font(.callout).textSelection(.enabled) } }
            }
            Picker("", selection: $tab) {
                Text("Files").tag(0); Text("Timeline").tag(1); Text("Rules").tag(2); Text("Tasks").tag(3); Text("Notes & links").tag(4)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 460)

            Group {
                switch tab {
                case 0: fileList
                case 1: timeline
                case 2: ruleList
                case 3: jobList
                default: notes
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(28)
    }

    var fileList: some View {
        List(files) { f in
            HStack(spacing: 10) {
                FileIconView(path: f.path, size: 20)
                Text(f.name).lineLimit(1)
                Spacer()
                if let d = f.docType { Pill(text: d) }
                ForEach(f.tags.prefix(2), id: \.self) { TagChip(text: $0) }
                Text(relativeTime(f.modifiedAt)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            }
            .contextMenu { Button("Reveal") { Panels.reveal([f.path]) }; Button("Open") { Panels.open(f.path) } }
        }
        .scrollContentBackground(.hidden)
    }

    var timeline: some View {
        let grouped = Dictionary(grouping: files) { Calendar.current.startOfDay(for: $0.modifiedAt) }.sorted { $0.key > $1.key }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(grouped.prefix(30), id: \.key) { day, items in
                    HStack(alignment: .top, spacing: 14) {
                        VStack { Circle().fill(Color(hex: project.color)).frame(width: 9, height: 9); Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DateFormatter.localizedString(from: day, dateStyle: .full, timeStyle: .none)).font(.system(size: 12, weight: .semibold))
                            ForEach(items.prefix(8)) { f in Text("• \(f.name)").font(.system(size: 12)).foregroundStyle(.secondary) }
                            if items.count > 8 { Text("+\(items.count - 8) more").font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                }
            }
        }
    }

    var ruleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rules.isEmpty { Text("No project-specific rules. Try: “If a PDF contains '\(project.keywords.first ?? project.name)' → add to project \(project.name)”").foregroundStyle(.secondary) }
            ForEach(rules) { r in
                Card(padding: 12) {
                    HStack { Image(systemName: "bolt.fill").foregroundStyle(Theme.accent); VStack(alignment: .leading) { Text(r.name).font(.headline); Text(r.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); Text("\(r.hitCount) hits").font(.caption) }
                }
            }
            Button { PaletteController.shared.show(prefill: "Create rule: if a file contains '\(project.keywords.first ?? project.name)' → add to project \(project.name)") } label: { Label("New project rule", systemImage: "plus") }.buttonStyle(GhostButtonStyle())
        }
    }

    var jobList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if jobs.isEmpty { Text("No tasks for this project yet.").foregroundStyle(.secondary) }
            ForEach(jobs.prefix(20)) { j in JobRow(job: j) }
        }
    }

    var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(project.notes.isEmpty ? "No notes" : project.notes).textSelection(.enabled).foregroundStyle(project.notes.isEmpty ? .secondary : .primary)
            ForEach(project.links) { l in Link(destination: URL(string: l.url) ?? URL(fileURLWithPath: "/")) { Label(l.title, systemImage: "link") } }
            ForEach(project.folders, id: \.self) { f in Button { Panels.reveal([Paths.expand(f)]) } label: { Label(f, systemImage: "folder") }.buttonStyle(.plain).foregroundStyle(Theme.accent2) }
        }
    }

    func cleanup() {
        guard let folder = project.folders.first.map(Paths.expand) else { app.showToast("Add a folder to this project first"); return }
        app.engine.queue.enqueue(Job(name: "Cleanup \(project.name)", kind: .file, priority: .high, spec: JobSpec(operation: .sortFolder, path: folder, params: ["projectId": project.id])))
        app.showToast("Cleaning up \(project.name) in the background")
    }

    func summarize() {
        summarizing = true
        Task {
            let plan = await app.engine.plan("summarize project \(project.name)")
            let r = await app.engine.execute(plan)
            summary = r.message
            summarizing = false
        }
    }
}

struct ProjectEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State var project: Project
    @State private var keywords = ""
    @State private var tags = ""
    @State private var hasDeadline = false
    @State private var newLinkTitle = ""
    @State private var newLinkURL = ""
    let icons = ["folder.fill", "flask.fill", "leaf.fill", "car.fill", "printer.fill", "hammer.fill", "graduationcap.fill", "chart.bar.fill", "chevron.left.forwardslash.chevron.right", "paintbrush.fill", "music.note", "globe", "cpu", "book.fill", "briefcase.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project.name.isEmpty ? "New project" : "Edit project").font(.title2.weight(.bold))
            Form {
                TextField("Name", text: $project.name)
                HStack {
                    Text("Color")
                    ForEach(NexusEngine.palette, id: \.self) { c in
                        Circle().fill(Color(hex: c)).frame(width: 18, height: 18).overlay(Circle().stroke(.white, lineWidth: project.color == c ? 2 : 0)).onTapGesture { project.color = c }
                    }
                }
                Picker("Icon", selection: $project.icon) { ForEach(icons, id: \.self) { Image(systemName: $0).tag($0) } }
                TextField("Keywords (comma separated)", text: $keywords)
                TextField("Tags applied to project files", text: $tags)
                Toggle("Deadline", isOn: $hasDeadline)
                if hasDeadline { DatePicker("Due", selection: Binding(get: { project.deadline ?? Date().addingTimeInterval(7 * 86400) }, set: { project.deadline = $0 })) }
                Section("Folders") {
                    ForEach(project.folders, id: \.self) { f in HStack { Text(f).font(.system(.body, design: .monospaced)); Spacer(); Button { project.folders.removeAll { $0 == f } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) } }
                    Button("Add folder…") { if let f = Panels.chooseFolder() { project.folders.append(Paths.abbreviate(f)) } }
                }
                Section("Notes & links") {
                    TextEditor(text: $project.notes).frame(height: 60)
                    ForEach(project.links) { l in Text("\(l.title) — \(l.url)").font(.caption) }
                    HStack { TextField("Title", text: $newLinkTitle); TextField("URL (Notion, Obsidian, GitHub…)", text: $newLinkURL); Button("Add") { guard !newLinkURL.isEmpty else { return }; project.links.append(ProjectLink(title: newLinkTitle.isEmpty ? newLinkURL : newLinkTitle, url: newLinkURL)); newLinkTitle = ""; newLinkURL = "" } }
                }
            }
            .formStyle(.grouped)
            HStack {
                if app.projects.contains(where: { $0.id == project.id }) {
                    Button("Delete", role: .destructive) { app.engine.store.deleteProject(project.id); app.selectedProjectId = nil; dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(project.name.trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560, height: 640)
        .onAppear {
            keywords = project.keywords.joined(separator: ", ")
            tags = project.tags.joined(separator: ", ")
            hasDeadline = project.deadline != nil
        }
    }

    func save() {
        project.keywords = keywords.split(separator: ",").map { $0.trimmed }.filter { !$0.isEmpty }
        project.tags = tags.split(separator: ",").map { $0.trimmed }.filter { !$0.isEmpty }
        if !hasDeadline { project.deadline = nil }
        app.engine.store.saveProject(project)
        for f in project.folders {
            app.engine.queue.enqueue(Job(name: "Classify \(Paths.abbreviate(Paths.expand(f)))", kind: .ai, priority: .normal, spec: JobSpec(operation: .classifyFolder, path: Paths.expand(f))))
        }
        dismiss()
    }
}
