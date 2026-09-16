import SwiftUI
import NexusCore

struct TasksView: View {
    @EnvironmentObject var app: AppState
    @State private var tab = 0
    @State private var selectedJob: String?
    @State private var newSchedule = false
    @State private var statusFilter: JobStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Tasks & Schedule", subtitle: "A persistent, prioritized queue. Battery-aware; failed tasks retry with backoff.") {
                HStack {
                    Button { newSchedule = true } label: { Label("New schedule", systemImage: "calendar.badge.plus") }.buttonStyle(PrimaryButtonStyle())
                }
            }
            Picker("", selection: $tab) { Text("Timeline").tag(0); Text("Queue").tag(1); Text("Schedules").tag(2) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
            switch tab {
            case 0: timeline
            case 1: queue
            default: schedules
            }
        }
        .padding(28)
        .onReceive(NotificationCenter.default.publisher(for: .newSchedule)) { _ in newSchedule = true }
        .sheet(isPresented: $newSchedule) { ScheduleEditor().environmentObject(app).preferredColorScheme(app.settings.appearance.colorScheme) }
    }

    // MARK: Timeline

    var timeline: some View {
        let upcoming = app.engine.scheduler.upcoming(limit: 40)
        let running = app.jobs.filter { $0.status == .running || $0.status == .queued }
        let recent = app.jobs.filter { [.completed, .failed, .cancelled].contains($0.status) }.prefix(25)
        return ScrollView {
            HStack(alignment: .top, spacing: 16) {
                column("Upcoming", symbol: "clock", tint: Theme.accent2) {
                    if upcoming.isEmpty { placeholder("Nothing scheduled") }
                    let byDay = Dictionary(grouping: upcoming) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key < $1.key }
                    ForEach(byDay, id: \.key) { day, items in
                        Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInTomorrow(day) ? "Tomorrow" : DateFormatter.localizedString(from: day, dateStyle: .full, timeStyle: .none))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(Array(items.enumerated()), id: \.offset) { _, u in
                            HStack {
                                Text(DateFormatter.localizedString(from: u.date, dateStyle: .none, timeStyle: .short)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent2).frame(width: 62, alignment: .leading)
                                Text(u.name).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                Image(systemName: u.ruleId != nil ? "bolt" : "calendar").foregroundStyle(.tertiary).font(.caption)
                            }
                        }
                    }
                }
                column("Running & queued", symbol: "gearshape.2", tint: Theme.accent) {
                    if running.isEmpty { placeholder("Idle") }
                    ForEach(running) { j in JobRow(job: j).onTapGesture { selectedJob = j.id; tab = 1 } }
                }
                column("Recent", symbol: "checkmark.circle", tint: Theme.success) {
                    if recent.isEmpty { placeholder("No finished tasks yet") }
                    ForEach(Array(recent)) { j in JobRow(job: j).onTapGesture { selectedJob = j.id; tab = 1 } }
                }
            }
        }
    }

    func column<C: View>(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> C) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    func placeholder(_ s: String) -> some View { Text(s).font(.callout).foregroundStyle(.tertiary) }

    // MARK: Queue

    var queue: some View {
        let jobs = app.jobs.filter { statusFilter == nil || $0.status == statusFilter }
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading) {
                Picker("", selection: $statusFilter) {
                    Text("All").tag(JobStatus?.none)
                    ForEach(JobStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(JobStatus?.some($0)) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 520)
                Table(jobs, selection: $selectedJob) {
                    TableColumn("") { j in Image(systemName: Theme.jobKindSymbol(j.kind)).foregroundStyle(.secondary) }.width(20)
                    TableColumn("Task") { j in Text(j.name).lineLimit(1) }.width(min: 180, ideal: 260)
                    TableColumn("Status") { j in Pill(text: j.status.rawValue, color: Theme.status(j.status)) }.width(80)
                    TableColumn("Priority") { j in Text(j.priority.label).foregroundStyle(j.priority >= .high ? Theme.accent : .secondary) }.width(60)
                    TableColumn("Duration") { j in Text(j.duration?.shortDuration ?? "—").foregroundStyle(.secondary) }.width(70)
                    TableColumn("When") { j in Text(relativeTime(j.status == .scheduled ? j.scheduledFor : j.createdAt)).foregroundStyle(.secondary) }.width(80)
                    TableColumn("Result") { j in Text(j.error ?? j.resultSummary ?? "").foregroundStyle(j.error != nil ? Theme.danger : .secondary).lineLimit(1) }
                }
            }
            if let id = selectedJob, let job = app.jobs.first(where: { $0.id == id }) {
                JobInspector(job: job).frame(width: 340).padding(.leading, 14)
            }
        }
    }

    // MARK: Schedules

    var schedules: some View {
        ScrollView {
            VStack(spacing: 10) {
                if app.schedules.isEmpty { EmptyStateView(symbol: "calendar", title: "No schedules", message: "Create one-off, recurring (cron) or conditional schedules — or just type “every Sunday at 9am generate weekly report” in the palette.") }
                ForEach(app.schedules.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }) { s in
                    Card(padding: 14) {
                        HStack(spacing: 14) {
                            Image(systemName: s.mode == .once ? "1.circle" : s.mode == .recurring ? "repeat" : "questionmark.diamond").font(.system(size: 18)).foregroundStyle(Theme.accent2).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).font(.headline)
                                Text(describe(s)).font(.caption).foregroundStyle(.secondary)
                                if let nl = s.naturalLanguage { Text("“\(nl)”").font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let next = s.nextRunAt, s.enabled { Text("Next \(relativeTime(next))").font(.caption) }
                                if let last = s.lastRunAt { Text("Last \(relativeTime(last))").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Button { app.engine.queue.enqueue(Job(name: s.name, kind: s.jobKind, priority: .high, spec: s.job, scheduleId: s.id)) } label: { Image(systemName: "play.fill") }.buttonStyle(GhostButtonStyle()).help("Run now")
                            Toggle("", isOn: Binding(get: { s.enabled }, set: { var x = s; x.enabled = $0; x.nextRunAt = nil; app.engine.store.saveSchedule(x) })).toggleStyle(.switch).labelsHidden()
                            Button { app.engine.store.deleteSchedule(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    func describe(_ s: Schedule) -> String {
        let what = s.job.operation.rawValue + (s.job.command.map { ": \($0)" } ?? "") + (s.job.path.map { " · \($0)" } ?? "")
        switch s.mode {
        case .once: return "Once at \(s.runAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "—") · \(what)"
        case .recurring: return "\(s.cron.map(CronExpression.describe) ?? "—") · \(what)"
        case .conditional: return "When " + s.conditions.map { c in "\(c.kind.rawValue)\(c.folder.map { "(\($0))" } ?? "") \(Int(c.number))" }.joined(separator: " AND ") + " · cooldown \(s.cooldownMinutes)m · \(what)"
        }
    }
}

struct JobRow: View {
    let job: Job
    var body: some View {
        HStack(spacing: 8) {
            if job.status == .running { ProgressView().controlSize(.mini).frame(width: 16) }
            else { Image(systemName: job.status == .failed ? "xmark.octagon.fill" : job.status == .completed ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(Theme.status(job.status)).frame(width: 16) }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).font(.system(size: 12.5)).lineLimit(1)
                Text(job.error ?? job.resultSummary ?? job.status.rawValue).font(.system(size: 10.5)).foregroundStyle(job.error != nil ? Theme.danger : .secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: Theme.jobKindSymbol(job.kind)).font(.caption).foregroundStyle(.tertiary)
            Text(job.duration?.shortDuration ?? relativeTime(job.createdAt)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct JobInspector: View {
    @EnvironmentObject var app: AppState
    let job: Job
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: Theme.jobKindSymbol(job.kind)); Text(job.name).font(.headline).lineLimit(2) }
                HStack { Pill(text: job.status.rawValue, color: Theme.status(job.status)); Pill(text: job.priority.label); Pill(text: "attempt \(job.attempts)/\(job.maxAttempts)") }
                if let r = job.resultSummary { Text(r).font(.callout).textSelection(.enabled) }
                if let e = job.error { Text(e).font(.callout).foregroundStyle(Theme.danger).textSelection(.enabled) }
                Text("Operation: \(job.spec.operation.rawValue)").font(.caption).foregroundStyle(.secondary)
                if let p = job.spec.path { Text(p).font(.caption.monospaced()).foregroundStyle(.secondary) }
                HStack {
                    if [.failed, .cancelled, .completed].contains(job.status) { Button { app.engine.queue.retry(job.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle()) }
                    if [.queued, .scheduled].contains(job.status) { Button { app.engine.queue.runNow(job.id) } label: { Label("Run now", systemImage: "play.fill") }.buttonStyle(GhostButtonStyle()) }
                    if [.queued, .scheduled, .running].contains(job.status) { Button { app.engine.queue.cancel(job.id) } label: { Label("Cancel", systemImage: "stop.fill") }.buttonStyle(GhostButtonStyle()) }
                }
                Text("LOG").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ScrollView {
                    Text(job.log.isEmpty ? "No log output" : job.log.joined(separator: "\n"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct ScheduleEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var mode: ScheduleMode = .recurring
    @State private var naturalTime = "every Sunday at 9am"
    @State private var cron = "0 9 * * 0"
    @State private var runAt = Date().addingTimeInterval(3600)
    @State private var operation: JobOperation = .runCommand
    @State private var command = "organize Downloads"
    @State private var path = "~/Downloads"
    @State private var priority: JobPriority = .normal
    @State private var conditions: [SystemCondition] = [SystemCondition(kind: .folderCountAbove, folder: "~/Downloads", number: 50), SystemCondition(kind: .hourAtLeast, number: 20)]
    @State private var cooldown = 720

    let operations: [JobOperation] = [.runCommand, .sortFolder, .classifyFolder, .summarizeFolder, .generateReport, .findDuplicates, .archiveOld, .scanInsights, .runShell, .runShortcut, .syncFolder, .learnTaxonomy]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New schedule").font(.title2.weight(.bold))
            Form {
                TextField("Name", text: $name)
                Picker("Mode", selection: $mode) { Text("One-off").tag(ScheduleMode.once); Text("Recurring").tag(ScheduleMode.recurring); Text("Conditional").tag(ScheduleMode.conditional) }.pickerStyle(.segmented)
                switch mode {
                case .once:
                    DatePicker("Run at", selection: $runAt)
                case .recurring:
                    HStack {
                        TextField("In words", text: $naturalTime)
                        Button("→ cron") { if case .cron(let c)? = NLTime.parse(naturalTime) { cron = c } }
                    }
                    TextField("Cron (min hour dom mon dow)", text: $cron).font(.system(.body, design: .monospaced))
                    Text(CronExpression(cron) == nil ? "Invalid cron expression" : "\(CronExpression.describe(cron)) · next: \(CronExpression(cron)?.next(after: Date()).map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "—")")
                        .font(.caption).foregroundStyle(CronExpression(cron) == nil ? Theme.danger : .secondary)
                case .conditional:
                    ForEach($conditions) { $c in
                        HStack {
                            Picker("", selection: $c.kind) { ForEach(SystemConditionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 170)
                            if [.folderCountAbove, .folderSizeAboveGB].contains(c.kind) { TextField("Folder", text: Binding(get: { c.folder ?? "" }, set: { c.folder = $0 })).frame(width: 130) }
                            TextField("Value", value: $c.number, format: .number).frame(width: 60)
                            Button { conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    Button("Add condition") { conditions.append(SystemCondition(kind: .hourAtLeast, number: 9)) }
                    Stepper("Cooldown: \(cooldown) min", value: $cooldown, in: 5...10080, step: 30)
                }
                Picker("Task", selection: $operation) { ForEach(operations, id: \.self) { Text($0.rawValue).tag($0) } }
                if [.runCommand, .runShell, .runShortcut].contains(operation) { TextField(operation == .runCommand ? "Command (natural language)" : operation == .runShell ? "Shell command" : "Shortcut name", text: $command) }
                if [.sortFolder, .classifyFolder, .summarizeFolder, .syncFolder].contains(operation) { TextField("Folder", text: $path) }
                Picker("Priority", selection: $priority) { ForEach(JobPriority.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create") { save() }.buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(22)
        .frame(width: 560, height: 560)
    }

    func save() {
        let kind: JobKind = [.runShell].contains(operation) ? .script : [.generateReport, .summarizeFolder, .scanInsights, .learnTaxonomy, .classifyFolder].contains(operation) ? .ai : .file
        let spec = JobSpec(operation: operation, path: [.sortFolder, .classifyFolder, .summarizeFolder, .syncFolder].contains(operation) ? path : nil,
                           command: [.runCommand, .runShell, .runShortcut].contains(operation) ? command : nil,
                           params: operation == .generateReport ? ["type": "weekly"] : [:])
        var s = Schedule(name: name.isEmpty ? (command.isEmpty ? operation.rawValue : command) : name, mode: mode, jobKind: kind, job: spec, priority: priority, cooldownMinutes: cooldown)
        switch mode {
        case .once: s.runAt = runAt; s.nextRunAt = runAt
        case .recurring: s.cron = cron; s.nextRunAt = CronExpression(cron)?.next(after: Date()); s.naturalLanguage = naturalTime
        case .conditional: s.conditions = conditions
        }
        app.engine.store.saveSchedule(s)
        dismiss()
    }
}
