import SwiftUI
import NexusCore

struct FilesView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var files: [FileRecord] = []
    @State private var selectedId: String?
    @State private var kindFilter: FileKind?
    @State private var statusFilter: FileStatus?
    @State private var projectFilter = ""
    @State private var loading = false
    @State private var sortOrder = [KeyPathComparator(\FileRecord.modifiedAt, order: .reverse)]
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Files", subtitle: "Everything Nexus understands — search by meaning, not just names.")
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Try “invoices from last month” or “hydroponics in the last 3 months”", text: $query)
                            .textFieldStyle(.plain).onSubmit { search() }.focused($searchFocused)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    Picker("", selection: $kindFilter) {
                        Text("All types").tag(FileKind?.none)
                        ForEach(FileKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(FileKind?.some($0)) }
                    }.labelsHidden().frame(width: 120)
                    Picker("", selection: $statusFilter) {
                        Text("Any status").tag(FileStatus?.none)
                        ForEach(FileStatus.allCases.filter { $0 != .missing }, id: \.self) { Text($0.rawValue.capitalized).tag(FileStatus?.some($0)) }
                    }.labelsHidden().frame(width: 110)
                    Picker("", selection: $projectFilter) {
                        Text("All projects").tag("")
                        ForEach(app.projects) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(width: 130)
                }
                Table(filtered, selection: $selectedId, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { f in
                        HStack(spacing: 8) {
                            FileIconView(path: f.path, size: 18)
                            Text(f.name).lineLimit(1)
                        }
                    }.width(min: 200, ideal: 280)
                    TableColumn("Type") { f in Text(f.docType ?? f.kind.rawValue).foregroundStyle(.secondary) }.width(90)
                    TableColumn("Tags") { f in HStack(spacing: 3) { ForEach(f.tags.prefix(3), id: \.self) { TagChip(text: $0) } } }.width(min: 80, ideal: 140)
                    TableColumn("Project") { f in Text(f.projectId.flatMap { id in app.projects.first { $0.id == id }?.name } ?? "—").foregroundStyle(.secondary) }.width(110)
                    TableColumn("Status") { f in Pill(text: f.status.rawValue, color: f.status == .review ? Theme.warning : f.status == .filed ? Theme.success : .secondary) }.width(70)
                    TableColumn("Size", value: \.size) { f in Text(formatBytes(f.size)).foregroundStyle(.secondary) }.width(70)
                    TableColumn("Modified", value: \.modifiedAt) { f in Text(relativeTime(f.modifiedAt)).foregroundStyle(.secondary) }.width(90)
                }
                .onChange(of: sortOrder) { order in files.sort(using: order) }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Reveal in Finder") { Panels.reveal(ids.compactMap { id in files.first { $0.id == id }?.path }) }
                    Button("Open") { ids.compactMap { id in files.first { $0.id == id }?.path }.forEach(Panels.open) }
                    Button("Simulate rules") { if let id = ids.first, let f = files.first(where: { $0.id == id }) { app.selection = .rules; NotificationCenter.default.post(name: .simulatePath, object: f.path) } }
                }
                HStack {
                    Text("\(filtered.count) files").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { if let f = Panels.chooseFolder(prompt: "Index") { app.engine.queue.enqueue(Job(name: "Classify \(Paths.abbreviate(f))", kind: .ai, priority: .high, spec: JobSpec(operation: .classifyFolder, path: f))); app.showToast("Indexing \(Paths.abbreviate(f)) in the background") } } label: { Label("Index a folder…", systemImage: "plus.viewfinder") }.buttonStyle(GhostButtonStyle())
                }
            }
            .padding(28)
            if let id = selectedId, let f = files.first(where: { $0.id == id }) {
                Divider()
                FileInspector(file: f).frame(width: 340)
            }
        }
        .onAppear { if files.isEmpty { load() } }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
        .onChange(of: app.fileCount) { _ in if query.isEmpty { load() } }
    }

    var filtered: [FileRecord] {
        files.filter { f in
            (kindFilter == nil || f.kind == kindFilter) && (statusFilter == nil || f.status == statusFilter) && (projectFilter.isEmpty || f.projectId == projectFilter)
        }
    }

    func load() { files = app.engine.store.files(limit: 2000).sorted(using: sortOrder) }

    func search() {
        let q = query.trimmed
        guard !q.isEmpty else { load(); return }
        loading = true
        Task.detached {
            let engine = await AppState.shared.engine
            let compiler = NLRuleCompiler(libraryRoot: engine.settings.libraryRoots.first ?? "~/Documents", knownProjects: engine.store.projects().map(\.name))
            let fq = CommandParser(compiler: compiler).query(q)
            let results = engine.resolve(fq, previous: [])
            await MainActor.run { files = results; loading = false }
        }
    }
}

extension Notification.Name { static let simulatePath = Notification.Name("NexusSimulatePath") }

struct FileInspector: View {
    @EnvironmentObject var app: AppState
    @State var file: FileRecord
    @State private var newTag = ""
    @State private var related: [(FileRecord, Double, [String])] = []
    @State private var summarizing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ThumbnailView(path: file.path, size: CGSize(width: 300, height: 200)).frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                Text(file.name).font(.headline).textSelection(.enabled)
                Text(Paths.abbreviate(file.path)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button { Panels.reveal([file.path]) } label: { Label("Reveal", systemImage: "folder") }.buttonStyle(GhostButtonStyle())
                    Button { Panels.open(file.path) } label: { Label("Open", systemImage: "arrow.up.forward.square") }.buttonStyle(GhostButtonStyle())
                    Button { NotificationCenter.default.post(name: .simulatePath, object: file.path); app.selection = .rules } label: { Label("Rules", systemImage: "play.rectangle") }.buttonStyle(GhostButtonStyle())
                }

                section("Summary") {
                    if let s = file.summary { Text(s).font(.callout).textSelection(.enabled) }
                    else if !file.snippet.isEmpty { Text(file.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(6) }
                    Button { summarize() } label: { Label(summarizing ? "Summarizing…" : (file.summary == nil ? "Summarize on-device" : "Re-summarize"), systemImage: "sparkles") }
                        .buttonStyle(GhostButtonStyle()).disabled(summarizing)
                }

                section("Understanding") {
                    grid("Document", file.docType ?? "—")
                    grid("Kind", file.kind.rawValue)
                    if let l = file.language { grid("Language", l) }
                    grid("Size", formatBytes(file.size))
                    grid("Created", DateFormatter.localizedString(from: file.createdAt, dateStyle: .medium, timeStyle: .short))
                    if let s = file.sourceURL { grid("Downloaded", URL(string: s)?.host ?? s) }
                    if !file.topics.isEmpty { FlowLayout { ForEach(file.topics, id: \.self) { Pill(text: $0, color: Theme.accent2) } } }
                }

                let entities = file.entities.filter { $0.kind != .url }
                if !entities.isEmpty {
                    section("Entities") {
                        ForEach(EntityKind.allCases, id: \.self) { kind in
                            let values = entities.filter { $0.kind == kind }.map(\.value)
                            if !values.isEmpty { grid(kind.rawValue.capitalized, values.prefix(6).joined(separator: ", ")) }
                        }
                    }
                }

                section("Tags & project") {
                    FlowLayout {
                        ForEach(file.tags, id: \.self) { t in TagChip(text: t) { applyTag(t, remove: true) } }
                    }
                    HStack {
                        TextField("Add tag", text: $newTag).textFieldStyle(.roundedBorder).onSubmit { applyTag(newTag, remove: false); newTag = "" }
                    }
                    Picker("Project", selection: Binding(get: { file.projectId ?? "" }, set: { setProject($0) })) {
                        Text("None").tag("")
                        ForEach(app.projects) { Text($0.name).tag($0.id) }
                    }
                }

                section("Related (knowledge graph)") {
                    if related.isEmpty { Text("No strong connections yet").font(.caption).foregroundStyle(.tertiary) }
                    ForEach(related, id: \.0.id) { r in
                        HStack(alignment: .top, spacing: 8) {
                            FileIconView(path: r.0.path, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.0.name).font(.system(size: 12)).lineLimit(1)
                                Text(r.2.prefix(3).joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Button { Panels.reveal([r.0.path]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(18)
        }
        .task(id: file.id) { related = app.engine.related(to: file) }
        .onChange(of: app.fileCount) { _ in if let f = app.engine.store.file(id: file.id) { file = f } }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary).tracking(0.5)
            content()
        }
    }

    func grid(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading); Text(v).font(.caption).textSelection(.enabled); Spacer() }
    }

    func applyTag(_ t: String, remove: Bool) {
        let tag = t.trimmed
        guard !tag.isEmpty else { return }
        Task {
            let (after, _) = await app.engine.executor.run(actions: [RuleAction(kind: remove ? .removeTag : .tag, tags: [tag])], file: file)
            if let after { file = after }
        }
    }

    func setProject(_ id: String) {
        guard let p = app.projects.first(where: { $0.id == id }) else {
            var f = file; f.projectId = nil; app.engine.store.upsertFile(f); file = f; return
        }
        Task {
            let (after, _) = await app.engine.executor.run(actions: [RuleAction(kind: .addToProject, target: p.name, project: p.name)], file: file)
            if let after { file = after }
        }
    }

    func summarize() {
        summarizing = true
        Task {
            var f = file
            f.summary = await app.engine.summarize(file: f)
            app.engine.store.upsertFile(f)
            file = f
            summarizing = false
        }
    }
}

struct InsightRow: View {
    @EnvironmentObject var app: AppState
    let insight: Insight
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.severity(insight.severity).opacity(0.15)).frame(width: 30, height: 30)
                Image(systemName: symbol).foregroundStyle(Theme.severity(insight.severity)).font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if !compact || insight.kind == .patternRule { Text(insight.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(compact ? 2 : 8) }
                HStack(spacing: 8) {
                    if let cmd = insight.command {
                        Button(fixLabel) { app.runCommand(cmd) }.buttonStyle(PrimaryButtonStyle())
                    }
                    if let draft = insight.ruleDraft {
                        Button("Create rule") { app.engine.store.saveRule(draft); app.engine.store.dismissInsight(insight.id); app.showToast("Rule “\(draft.name)” created") }.buttonStyle(PrimaryButtonStyle())
                        Button("Edit first") { app.ruleDraft = draft }.buttonStyle(GhostButtonStyle())
                    }
                    if insight.kind == .projectAssociation, let pid = insight.key.split(separator: ":").last.map(String.init), let p = app.projects.first(where: { $0.id == pid }) {
                        Button("Link \(insight.filePaths.count) files") { link(to: p) }.buttonStyle(PrimaryButtonStyle())
                    }
                    if !insight.filePaths.isEmpty && !compact {
                        Button("Reveal files") { Panels.reveal(Array(insight.filePaths.prefix(40))) }.buttonStyle(GhostButtonStyle())
                    }
                    Button("Dismiss") { app.engine.store.dismissInsight(insight.id) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    var fixLabel: String {
        switch insight.kind {
        case .staleDownloads: return "Sort now"
        case .duplicates: return "Clean up"
        case .similarScreenshots: return "Keep newest"
        case .lowDisk, .folderGrowth: return "Find space"
        case .deadlineSoon: return "Start focus"
        case .reviewBacklog: return "Review"
        case .inactiveProject: return "Summarize"
        case .ruleConflict: return "Open rules"
        default: return "Fix"
        }
    }

    var symbol: String {
        switch insight.kind {
        case .staleDownloads: return "tray.and.arrow.down"
        case .duplicates: return "square.on.square"
        case .similarScreenshots: return "camera.on.rectangle"
        case .folderGrowth: return "chart.line.uptrend.xyaxis"
        case .inactiveProject: return "moon.zzz"
        case .lowDisk: return "internaldrive"
        case .patternRule: return "wand.and.rays"
        case .projectAssociation: return "link"
        case .largeFiles: return "externaldrive.badge.exclamationmark"
        case .reviewBacklog: return "tray.full"
        case .ruleConflict: return "exclamationmark.triangle"
        case .deadlineSoon: return "calendar.badge.exclamationmark"
        case .weeklyDigest: return "newspaper"
        }
    }

    func link(to p: Project) {
        Task {
            let batch = newID()
            for path in insight.filePaths {
                if let f = app.engine.store.file(path: path) {
                    _ = await app.engine.executor.run(actions: [RuleAction(kind: .addToProject, target: p.name, project: p.name)], file: f, batchId: batch)
                }
            }
            app.engine.store.dismissInsight(insight.id)
            app.showToast("Linked \(insight.filePaths.count) files to \(p.name)")
        }
    }
}
