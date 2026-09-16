import SwiftUI
import NexusCore

struct ReviewQueueView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: String?
    @State private var editing: ReviewItem?
    @FocusState private var focused: Bool

    var items: [ReviewItem] { app.reviewItems }
    var current: ReviewItem? { items.first { $0.id == selected } ?? items.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Review Queue", subtitle: "Medium-confidence suggestions. Your decisions train autopilot.") {
                HStack(spacing: 8) {
                    let high = items.filter { $0.confidence >= 0.75 }
                    if !high.isEmpty {
                        Button("Approve \(high.count) above 75%") { Task { for i in high { await app.engine.approve(i) }; app.reloadAll() } }.buttonStyle(GhostButtonStyle())
                    }
                    Button { app.runCommand("organize Downloads") } label: { Label("Sort Downloads", systemImage: "wand.and.stars") }.buttonStyle(PrimaryButtonStyle())
                }
            }
            if items.isEmpty {
                EmptyStateView(symbol: "checkmark.seal", title: "Inbox zero", message: "Nothing needs your judgement right now. New files that Nexus isn't sure about will appear here.")
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(items) { item in
                                    ReviewCard(item: item, isSelected: item.id == current?.id,
                                               approve: { approve(item) }, reject: { reject(item) }, edit: { editing = item })
                                        .id(item.id)
                                        .onTapGesture { selected = item.id }
                                }
                            }
                            .padding(.bottom, 20)
                        }
                        .onChange(of: selected) { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .frame(maxWidth: .infinity)
                    if let c = current, let file = app.engine.store.file(id: c.fileId) {
                        ReviewInspector(item: c, file: file).frame(width: 300)
                    }
                }
                HStack(spacing: 16) {
                    KeyHint(keys: "↑ ↓", label: "Navigate")
                    KeyHint(keys: "↩", label: "Approve")
                    KeyHint(keys: "⇧↩", label: "Reject")
                    KeyHint(keys: "E", label: "Edit")
                    KeyHint(keys: "Space", label: "Open")
                }
            }
        }
        .padding(28)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .background(KeyCatcher { key, shift in handleKey(key, shift: shift) })
        .sheet(item: $editing) { item in ReviewEditSheet(item: item).environmentObject(app).preferredColorScheme(app.settings.appearance.colorScheme) }
    }

    func handleKey(_ key: KeyCatcher.Key, shift: Bool) -> Bool {
        guard editing == nil, let c = current, let idx = items.firstIndex(where: { $0.id == c.id }) else { return false }
        switch key {
        case .down: selected = items[min(items.count - 1, idx + 1)].id; return true
        case .up: selected = items[max(0, idx - 1)].id; return true
        case .enter: shift ? reject(c) : approve(c); return true
        case .char("e"): editing = c; return true
        case .space: Panels.open(c.path); return true
        default: return false
        }
    }

    func advance(from item: ReviewItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let next = idx + 1 < items.count ? items[idx + 1] : (idx > 0 ? items[idx - 1] : nil)
            selected = next?.id
        }
    }

    func approve(_ item: ReviewItem) {
        advance(from: item)
        withAnimation(.spring(response: 0.3)) { app.reviewItems.removeAll { $0.id == item.id } }
        Task { await app.engine.approve(item) }
    }

    func reject(_ item: ReviewItem) {
        advance(from: item)
        withAnimation(.spring(response: 0.3)) { app.reviewItems.removeAll { $0.id == item.id } }
        app.engine.reject(item)
    }
}

struct ReviewCard: View {
    @EnvironmentObject var app: AppState
    let item: ReviewItem
    let isSelected: Bool
    let approve: () -> Void
    let reject: () -> Void
    let edit: () -> Void

    var body: some View {
        let file = app.engine.store.file(id: item.fileId)
        HStack(alignment: .top, spacing: 14) {
            ThumbnailView(path: item.path, size: CGSize(width: 64, height: 64))
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text((item.path as NSString).lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    ConfidenceBadge(value: item.confidence)
                }
                if let snippet = file?.summary ?? file?.snippet, !snippet.isEmpty {
                    Text(snippet).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let dest = item.suggestedDestination {
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent2)
                        Text(Paths.abbreviate(dest)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent2).lineLimit(1)
                    }
                    ForEach(item.suggestedTags, id: \.self) { TagChip(text: $0) }
                    if let pid = item.suggestedProjectId, let p = app.projects.first(where: { $0.id == pid }) { Pill(text: p.name, symbol: "square.stack.3d.up", color: Color(hex: p.color)) }
                    if let t = item.suggestedCategory { Pill(text: t) }
                }
                Text(item.reasons.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                HStack(spacing: 8) {
                    Button { approve() } label: { Label("Approve", systemImage: "checkmark") }.buttonStyle(PrimaryButtonStyle())
                    Button { edit() } label: { Label("Edit", systemImage: "slider.horizontal.3") }.buttonStyle(GhostButtonStyle())
                    Button { reject() } label: { Label("Reject", systemImage: "xmark") }.buttonStyle(GhostButtonStyle())
                    Spacer()
                    Text(relativeTime(item.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.cardStroke), lineWidth: isSelected ? 1.5 : 1))
        .scaleEffect(isSelected ? 1 : 0.99)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

struct ReviewInspector: View {
    @EnvironmentObject var app: AppState
    let item: ReviewItem
    let file: FileRecord
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                ThumbnailView(path: file.path, size: CGSize(width: 268, height: 180)).frame(maxWidth: .infinity)
                Text(file.name).font(.headline).lineLimit(2)
                Text(Paths.abbreviate(file.folder)).font(.caption).foregroundStyle(.secondary)
                Divider()
                infoRow("Type", file.docType ?? file.kind.rawValue)
                infoRow("Size", formatBytes(file.size))
                if let src = file.sourceURL { infoRow("From", URL(string: src)?.host ?? src) }
                if !file.topics.isEmpty { infoRow("Topics", file.topics.joined(separator: ", ")) }
                let people = file.entities.filter { [.person, .organization, .course].contains($0.kind) }.prefix(5)
                if !people.isEmpty { infoRow("Mentions", people.map(\.value).joined(separator: ", ")) }
                if !item.alternatives.isEmpty {
                    Divider()
                    Text("Other candidates").font(.caption).foregroundStyle(.secondary)
                    ForEach(item.alternatives, id: \.self) { alt in
                        Button { Task { await app.engine.approve(item, destination: alt); app.reloadAll() } } label: {
                            HStack { Image(systemName: "folder"); Text(Paths.abbreviate(alt)).lineLimit(1); Spacer() }.font(.system(size: 11.5))
                        }.buttonStyle(.plain).foregroundStyle(Theme.accent2)
                    }
                }
            }
        }
    }
    func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading); Text(v).font(.caption).lineLimit(3); Spacer() }
    }
}

struct ReviewEditSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let item: ReviewItem
    @State private var destination = ""
    @State private var tags = ""
    @State private var projectId = ""
    @State private var makeRule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit suggestion").font(.title2.weight(.bold))
            Text((item.path as NSString).lastPathComponent).foregroundStyle(.secondary)
            HStack {
                TextField("Destination folder", text: $destination).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button("Choose…") { if let f = Panels.chooseFolder() { destination = Paths.abbreviate(f) } }
            }
            TextField("Tags (comma separated)", text: $tags).textFieldStyle(.roundedBorder)
            Picker("Project", selection: $projectId) {
                Text("None").tag("")
                ForEach(app.projects) { Text($0.name).tag($0.id) }
            }
            Toggle("Always do this for similar files (create a rule)", isOn: $makeRule)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { apply() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 520, height: 330)
        .onAppear {
            destination = item.suggestedDestination.map(Paths.abbreviate) ?? ""
            tags = item.suggestedTags.joined(separator: ", ")
            projectId = item.suggestedProjectId ?? ""
        }
    }

    func apply() {
        let tagList = tags.split(separator: ",").map { $0.trimmed }.filter { !$0.isEmpty }
        let dest = destination.trimmed.isEmpty ? nil : Paths.expand(destination)
        Task {
            await app.engine.approve(item, destination: dest, tags: tagList, projectId: projectId.isEmpty ? nil : projectId)
            if makeRule, let file = app.engine.store.file(id: item.fileId) {
                var sentence = "If a \(file.ext.isEmpty ? "file" : file.ext.uppercased()) in \(Paths.abbreviate(file.folder.isEmpty ? "~/Downloads" : (item.path as NSString).deletingLastPathComponent))"
                if let d = file.docType, !["photo", "code"].contains(d) { sentence = "If a \(d) in \(Paths.abbreviate((item.path as NSString).deletingLastPathComponent))" }
                var actions: [String] = []
                if let dest { actions.append("move to \(Paths.abbreviate(dest))") }
                if !tagList.isEmpty { actions.append("tag \(tagList.joined(separator: " "))") }
                if let p = app.projects.first(where: { $0.id == projectId }) { actions.append("add to project \(p.name)") }
                if let rule = await app.engine.compileRule(sentence + " → " + actions.joined(separator: ", ")).rule {
                    app.engine.store.saveRule(rule)
                    app.showToast("Created rule “\(rule.name)”")
                }
            }
            app.reloadAll()
        }
        dismiss()
    }
}

/// Captures key presses for keyboard-first views without stealing text field input.
struct KeyCatcher: NSViewRepresentable {
    enum Key: Equatable { case up, down, left, right, enter, space, delete, escape, char(Character) }
    let handler: (Key, Bool) -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let coord = context.coordinator
        coord.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard v.window?.isKeyWindow == true, !(v.window?.firstResponder is NSTextView) else { return event }
            let shift = event.modifierFlags.contains(.shift)
            if event.modifierFlags.contains(.command) { return event }
            let key: Key?
            switch Int(event.keyCode) {
            case 126: key = .up
            case 125: key = .down
            case 123: key = .left
            case 124: key = .right
            case 36, 76: key = .enter
            case 49: key = .space
            case 51, 117: key = .delete
            case 53: key = .escape
            default: key = event.charactersIgnoringModifiers?.lowercased().first.map { .char($0) }
            }
            if let key, coord.handler(key, shift) { return nil }
            return event
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.handler = handler }
    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { if let m = coordinator.monitor { NSEvent.removeMonitor(m) } }
    final class Coordinator { var monitor: Any?; var handler: (Key, Bool) -> Bool; init(handler: @escaping (Key, Bool) -> Bool) { self.handler = handler } }
}
