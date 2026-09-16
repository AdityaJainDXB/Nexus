import SwiftUI
import NexusCore

struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var settings = NexusSettings()
    @State private var candidates: [FolderDiscovery.Candidate] = []
    @State private var starterRules: [String: Bool] = [
        "Screenshots on Desktop → move to ~/Pictures/Screenshots/{year}-{month}": true,
        "If a DMG in Downloads is older than 7 days → move to trash": false,
        "Invoices from Downloads → move to Finance/Invoices/{year}, tag finance": true,
        "If code file language is Python and folder is Downloads → move to Dev/Python, tag snippet": false,
        "Every Sunday 9 AM: archive old screenshots, generate storage report": true,
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: folders
                case 2: accessStep
                case 3: intelligence
                default: rules
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
            Divider()
            HStack {
                HStack(spacing: 6) { ForEach(0..<5) { Circle().fill($0 == step ? Theme.accent : Color.primary.opacity(0.15)).frame(width: 6, height: 6) } }
                Spacer()
                Button("Skip setup") { app.markOnboardingSeen(); dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                if step > 0 { Button("Back") { withAnimation { step -= 1 } }.buttonStyle(GhostButtonStyle()) }
                Button(step == 4 ? "Start Nexus" : "Continue") { step == 4 ? finish() : withAnimation { step += 1 } }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(18)
        }
        .frame(width: 680, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            settings = app.settings
            candidates = FolderDiscovery.candidates()
        }
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.gradient).frame(width: 64, height: 64)
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 30)).foregroundStyle(.white)
            }
            Text("Meet Nexus").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("A calm, local-first co-pilot for your Mac. Nexus reads and understands your files, files them where they belong, runs your automations, and only speaks up when it matters.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                bullet("lock.shield", "Private by design", "Classification, OCR, search and the language model all run on this Mac. Nothing is uploaded.")
                bullet("arrow.uturn.backward.circle", "Always reversible", "Every move, rename and tag is journaled. Undo anything, anytime.")
                bullet("command", "Press \(settings.paletteHotkey.label) anywhere", "Type what you want: “move invoices from Downloads to Finance and tag them tax”.")
            }
        }
    }

    var folders: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your folder map").font(.system(size: 24, weight: .bold))
            Text("Nexus found where you already keep things. It learns these folders and files new items into them — it never reorganizes them on its own.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates) { c in
                        let key = Paths.abbreviate(c.path)
                        Toggle(isOn: Binding(get: { settings.libraryRoots.contains(key) }, set: { on in
                            if on { settings.libraryRoots.append(key) } else { settings.libraryRoots.removeAll { $0 == key } }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.label)  ·  \(key)").font(.system(size: 12.5, weight: .semibold))
                                Text(c.subfolders.isEmpty ? "No subfolders yet" : c.subfolders.prefix(7).joined(separator: " · ") + (c.subfolders.count > 7 ? " · …" : ""))
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(8).hudPanel(cornerRadius: 8)
                    }
                }
            }
            folderList(title: "Inbox folders — new files here get sorted", folders: $settings.watchedFolders)
        }
    }

    var accessStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Give Nexus the access it needs").font(.system(size: 24, weight: .bold))
            Text("Full Disk Access turns Nexus into a whole-Mac assistant. You can grant the rest later in System Access.").foregroundStyle(.secondary)
            SystemAccessView(compact: true).frame(height: 300)
        }
    }

    var intelligence: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How autonomous should Nexus be?").font(.system(size: 24, weight: .bold, design: .rounded))
            Toggle(isOn: $settings.autopilotEnabled) {
                VStack(alignment: .leading) {
                    Text("Autopilot filing").font(.headline)
                    Text("High-confidence files are filed automatically; medium-confidence ones wait in the Review Queue; low-confidence ones are left alone.").font(.caption).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 4) {
                Text("Act automatically above \(Int(settings.autoThreshold * 100))% confidence").font(.subheadline)
                Slider(value: $settings.autoThreshold, in: 0.7...0.99)
                Text("Ask me above \(Int(settings.reviewThreshold * 100))%").font(.subheadline)
                Slider(value: $settings.reviewThreshold, in: 0.3...0.8)
            }
            Toggle("Read text in images & scanned PDFs (on-device OCR)", isOn: $settings.enableOCR).toggleStyle(.switch)
            Toggle("Start in dry-run mode (preview everything, change nothing)", isOn: $settings.dryRun).toggleStyle(.switch)
            HStack {
                Image(systemName: "cpu").foregroundStyle(Theme.accent)
                Text("Language model: \(app.llmName)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var rules: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start with a few automations").font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Written in plain English — edit or delete them anytime in Rules.").foregroundStyle(.secondary)
            ForEach(starterRules.keys.sorted(), id: \.self) { key in
                Toggle(isOn: Binding(get: { starterRules[key] ?? false }, set: { starterRules[key] = $0 })) {
                    Text(key).font(.system(size: 12.5, design: .monospaced))
                }.toggleStyle(.checkbox)
            }
        }
    }

    func bullet(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func folderList(title: String, folders: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button { if let f = Panels.chooseFolder(prompt: "Add") { folders.wrappedValue.append(Paths.abbreviate(f)) } } label: { Label("Add", systemImage: "plus") }.buttonStyle(GhostButtonStyle())
            }
            ForEach(folders.wrappedValue, id: \.self) { f in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.accent2)
                    Text(f).font(.system(size: 12.5, design: .monospaced))
                    Spacer()
                    Button { folders.wrappedValue.removeAll { $0 == f } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    func finish() {
        settings.onboardingComplete = true
        app.saveSettings(settings)
        let compiler = NLRuleCompiler(libraryRoot: settings.libraryRoots.first ?? "~/Documents")
        for (text, on) in starterRules where on {
            if let rule = compiler.compile(text).rule { app.engine.store.saveRule(rule) }
        }
        app.engine.queue.enqueue(Job(name: "Learn folder structure", kind: .ai, priority: .high, spec: JobSpec(operation: .learnTaxonomy)))
        for f in settings.watchedFoldersExpanded {
            app.engine.queue.enqueue(Job(name: "Classify \(Paths.abbreviate(f))", kind: .ai, priority: .normal, spec: JobSpec(operation: .classifyFolder, path: f)))
        }
        app.engine.queue.enqueue(Job(name: "Scan for insights", kind: .ai, priority: .low, spec: JobSpec(operation: .scanInsights), scheduledFor: Date().addingTimeInterval(90)))
        app.reloadAll()
        dismiss()
    }
}
