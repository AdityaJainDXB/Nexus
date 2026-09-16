import SwiftUI
import NexusCore

struct ActivityView: View {
    @EnvironmentObject var app: AppState
    @State private var filter: EventKind?
    @State private var hideIndexing = true
    @State private var search = ""

    var events: [ActivityEvent] {
        app.events.filter { e in
            (filter == nil || e.kind == filter) && (!hideIndexing || ![.fileIndexed, .jobStarted].contains(e.kind)) &&
            (search.isEmpty || e.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Activity", subtitle: "A complete, undoable journal of everything Nexus did.") {
                Button { app.runCommand("undo") } label: { Label("Undo last batch", systemImage: "arrow.uturn.backward") }.buttonStyle(PrimaryButtonStyle())
            }
            HStack {
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("", selection: $filter) {
                    Text("All events").tag(EventKind?.none)
                    ForEach(EventKind.allCases, id: \.self) { Text($0.rawValue).tag(EventKind?.some($0)) }
                }.labelsHidden().frame(width: 160)
                Toggle("Hide indexing", isOn: $hideIndexing).toggleStyle(.checkbox)
                Spacer()
            }
            List(events) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Theme.eventSymbol(e.kind))
                        .foregroundStyle(e.kind == .error || e.kind == .jobFailed || e.kind == .guardTripped ? Theme.danger : e.kind == .ruleFired ? Theme.accent : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.message).font(.system(size: 12.5)).strikethrough(e.undone).foregroundStyle(e.undone ? .secondary : .primary).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(DateFormatter.localizedString(from: e.timestamp, dateStyle: .short, timeStyle: .medium)).font(.caption2).foregroundStyle(.tertiary)
                            if let rid = e.ruleId, let r = app.rules.first(where: { $0.id == rid }) { Pill(text: r.name, symbol: "bolt", color: Theme.accent) }
                            if e.undone { Pill(text: "undone") }
                        }
                    }
                    Spacer()
                    if let batch = e.batchId, e.undo != nil, !e.undone {
                        Button("Undo") {
                            let n = app.engine.executor.undo(batchId: batch)
                            app.showToast(n > 0 ? "Undid \(n) operation\(n == 1 ? "" : "s")" : "Nothing to undo")
                        }.buttonStyle(GhostButtonStyle())
                    }
                    if let fid = e.fileId, let f = app.engine.store.file(id: fid), e.kind != .fileTrashed {
                        Button { Panels.reveal([f.path]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            .scrollContentBackground(.hidden)
        }
        .padding(28)
    }
}
