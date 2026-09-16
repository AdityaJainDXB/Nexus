import SwiftUI
import Charts
import NexusCore

struct InsightsView: View {
    @EnvironmentObject var app: AppState
    @State private var reportMarkdown: String?
    @State private var reportType = "weekly"
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Insights", subtitle: "Digital hygiene, storage trends and automation effectiveness.") {
                    HStack {
                        Button { scan() } label: { Label(scanning ? "Scanning…" : "Scan now", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle()).disabled(scanning)
                        Menu {
                            Button("Weekly report") { report("weekly") }
                            Button("Monthly report") { report("monthly") }
                            Button("Storage report") { report("storage") }
                            Button("Today’s new files") { report("daily") }
                        } label: { Label("Reports", systemImage: "chart.bar.doc.horizontal") }.menuStyle(.borderlessButton).frame(width: 110)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Suggestions")
                    if app.insights.isEmpty {
                        Card { HStack { Image(systemName: "leaf.fill").foregroundStyle(Theme.success); Text("No suggestions right now. Nexus scans every few hours and whenever disk space drops.").foregroundStyle(.secondary) } }
                    }
                    ForEach(app.insights) { i in Card { InsightRow(insight: i) } }
                }

                chartsSection
            }
            .padding(28)
        }
        .sheet(isPresented: Binding(get: { reportMarkdown != nil }, set: { if !$0 { reportMarkdown = nil } })) {
            ReportSheet(markdown: reportMarkdown ?? "", type: reportType).preferredColorScheme(app.settings.appearance.colorScheme)
        }
    }

    var chartsSection: some View {
        let store = app.engine.store
        let byKind = store.storageByKind()
        let overTime = store.kindsOverTime(days: 56)
        let hits = store.ruleHits(since: Date().addingTimeInterval(-30 * 86400))
        let ruleData = app.rules.map { ($0.name, hits[$0.id] ?? 0, (hits[$0.id] ?? 0) * $0.estimatedSecondsSaved / 60) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(8)
        let folders = store.snapshotFolders()
        let byProject = store.storageByProject().prefix(8)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Trends")
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading) {
                        Text("Storage by type").font(.headline)
                        Chart(byKind.prefix(10), id: \.0) { item in
                            BarMark(x: .value("Size", Double(item.1) / 1_000_000), y: .value("Type", item.0))
                                .foregroundStyle(Theme.gradient).cornerRadius(4)
                                .annotation(position: .trailing) { Text(formatBytes(item.1)).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .chartXAxisLabel("MB").frame(height: 220)
                    }
                }
                Card {
                    VStack(alignment: .leading) {
                        Text("Storage by project").font(.headline)
                        Chart(Array(byProject), id: \.0) { item in
                            SectorMarkCompat(value: Double(item.1), label: item.0.flatMap { id in app.projects.first { $0.id == id }?.name } ?? "Unassigned")
                        }
                        .frame(height: 220)
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading) {
                        Text("New files by type (8 weeks)").font(.headline)
                        Chart(overTime, id: \.day) { row in
                            BarMark(x: .value("Day", row.day, unit: .day), y: .value("Files", row.count)).foregroundStyle(by: .value("Type", row.kind))
                        }
                        .frame(height: 200)
                    }
                }
                Card {
                    VStack(alignment: .leading) {
                        Text("Automation hits per rule (30 days)").font(.headline)
                        if ruleData.isEmpty { Text("Rules haven't run yet.").foregroundStyle(.secondary).frame(height: 200) }
                        else {
                            Chart(Array(ruleData), id: \.0) { r in
                                BarMark(x: .value("Hits", r.1), y: .value("Rule", r.0)).foregroundStyle(Theme.accent2.gradient)
                                    .annotation(position: .trailing) { Text("\(r.2)m saved").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .frame(height: 200)
                        }
                    }
                }
            }
            if !folders.isEmpty {
                Card {
                    VStack(alignment: .leading) {
                        Text("Folder size evolution").font(.headline)
                        Chart {
                            ForEach(folders, id: \.self) { folder in
                                ForEach(store.snapshots(folder: folder), id: \.day) { s in
                                    LineMark(x: .value("Day", s.day), y: .value("GB", Double(s.size) / 1_000_000_000))
                                        .foregroundStyle(by: .value("Folder", Paths.abbreviate(folder)))
                                        .interpolationMethod(.catmullRom)
                                    PointMark(x: .value("Day", s.day), y: .value("GB", Double(s.size) / 1_000_000_000)).foregroundStyle(by: .value("Folder", Paths.abbreviate(folder)))
                                }
                            }
                        }
                        .chartYAxisLabel("GB").frame(height: 200)
                    }
                }
            }
            let top = store.topNodes(type: .topic, limit: 24)
            if !top.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your knowledge graph — top topics").font(.headline)
                        FlowLayout {
                            ForEach(top, id: \.0) { t in
                                Button { PaletteController.shared.show(prefill: "find everything about \(t.0)") } label: {
                                    Text("\(t.0) \(t.1)").font(.system(size: 11 + min(8, CGFloat(t.1) / 3)))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Theme.accent.opacity(0.08 + min(0.3, Double(t.1) / 60)), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    func scan() {
        scanning = true
        app.engine.queue.enqueue(Job(name: "Scan for insights", kind: .ai, priority: .high, spec: JobSpec(operation: .scanInsights)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { scanning = false }
    }

    func report(_ type: String) {
        reportType = type
        reportMarkdown = app.engine.reports.markdown(type: type)
    }
}

/// Pie charts (SectorMark) need macOS 14; show a bar on 13.
struct SectorMarkCompat: ChartContent {
    let value: Double
    let label: String
    var body: some ChartContent {
        if #available(macOS 14.0, *) {
            SectorMark(angle: .value("Size", value), innerRadius: .ratio(0.55), angularInset: 1.5).foregroundStyle(by: .value("Project", label)).cornerRadius(4)
        } else {
            BarMark(x: .value("Size", value), y: .value("Project", label)).foregroundStyle(by: .value("Project", label))
        }
    }
}

struct ReportSheet: View {
    @Environment(\.dismiss) var dismiss
    let markdown: String
    let type: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(type.capitalized) report").font(.title2.weight(.bold))
                Spacer()
                Button { export(pdf: false) } label: { Label("Export Markdown", systemImage: "doc.plaintext") }.buttonStyle(GhostButtonStyle())
                Button { export(pdf: true) } label: { Label("Export PDF", systemImage: "doc.richtext") }.buttonStyle(PrimaryButtonStyle())
            }
            ScrollView {
                Text((try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown))
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(22)
        .frame(width: 760, height: 640)
    }

    func export(pdf: Bool) {
        let name = "Nexus \(type) report \(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]))"
        guard let url = Panels.save(name: name + (pdf ? ".pdf" : ".md"), types: [pdf ? "pdf" : "md"]) else { return }
        if pdf { try? ReportGenerator.pdf(markdown: markdown, to: url) } else { try? markdown.write(to: url, atomically: true, encoding: .utf8) }
        Panels.reveal([url.path])
    }
}
