import SwiftUI
import NexusCore

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "waveform") }
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
            IntelligenceSettings().tabItem { Label("Intelligence", systemImage: "sparkles") }
            CategorySettings().tabItem { Label("Taxonomy", systemImage: "square.grid.3x3") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(16)
    }
}

private struct SettingsBinding {
    static func make<T>(_ app: AppState, _ kp: WritableKeyPath<NexusSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: kp] }, set: { var s = app.settings; s[keyPath: kp] = $0; app.saveSettings(s) })
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Form {
            Toggle("Launch Nexus at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.launchAtLogin = $0 }))
            Toggle("Show Dock icon", isOn: SettingsBinding.make(app, \.showDockIcon))
            Picker("Desktop hotbar", selection: SettingsBinding.make(app, \.hotbar)) {
                ForEach(HotbarMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Appearance", selection: SettingsBinding.make(app, \.appearance)) {
                ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Command palette shortcut", selection: SettingsBinding.make(app, \.paletteHotkey)) {
                ForEach(PaletteHotkey.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("⌘K also opens the palette whenever the Nexus window is focused.").font(.caption).foregroundStyle(.secondary)
            Section("Notifications") {
                Toggle("Notifications", isOn: SettingsBinding.make(app, \.notificationsEnabled))
                Stepper("Quiet hours start: \(app.settings.quietHoursStart):00", value: SettingsBinding.make(app, \.quietHoursStart), in: 0...23)
                Stepper("Quiet hours end: \(app.settings.quietHoursEnd):00", value: SettingsBinding.make(app, \.quietHoursEnd), in: 0...23)
                Text("During quiet hours and Focus, only critical notifications (low disk, paused automations) are shown. Routine activity is batched into a single digest.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Weekly report") {
                Picker("Day", selection: SettingsBinding.make(app, \.digestWeekday)) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
                Stepper("Hour: \(app.settings.digestHour):00", value: SettingsBinding.make(app, \.digestHour), in: 0...23)
            }
            Button("Show onboarding again") { app.showOnboarding = true; app.openMainWindow() }
        }
        .formStyle(.grouped)
    }
}

struct FolderSettings: View {
    @EnvironmentObject var app: AppState
    @State private var newPattern = ""
    var body: some View {
        Form {
            Section("Inbox folders — automations & autopilot") { folderEditor(\.watchedFolders) }
            Section("Library folders — learned from & searchable, never auto-reorganized") {
                folderEditor(\.libraryRoots)
                Button("Find my folders again") {
                    var st = app.settings
                    for c in FolderDiscovery.candidates() where c.recommended && !st.libraryRootsExpanded.contains(c.path) { st.libraryRoots.append(Paths.abbreviate(c.path)) }
                    app.saveSettings(st)
                    app.runCommand("learn my folders")
                }
            }
            Section("Ignored file patterns") {
                ForEach(app.settings.ignoredPatterns, id: \.self) { p in
                    HStack { Text(p).font(.system(.body, design: .monospaced)); Spacer(); Button { var s = app.settings; s.ignoredPatterns.removeAll { $0 == p }; app.saveSettings(s) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                }
                HStack { TextField("*.tmp", text: $newPattern); Button("Add") { var s = app.settings; s.ignoredPatterns.append(newPattern); app.saveSettings(s); newPattern = "" }.disabled(newPattern.isEmpty) }
            }
            Section("Hygiene thresholds") {
                Stepper("Downloads are stale after \(app.settings.staleDownloadDays) days", value: SettingsBinding.make(app, \.staleDownloadDays), in: 1...90)
                Stepper("Projects are inactive after \(app.settings.inactiveProjectDays) days", value: SettingsBinding.make(app, \.inactiveProjectDays), in: 7...365)
                Stepper("Low disk warning below \(Int(app.settings.lowDiskGB)) GB", value: SettingsBinding.make(app, \.lowDiskGB), in: 5...500, step: 5)
            }
        }
        .formStyle(.grouped)
    }

    func folderEditor(_ kp: WritableKeyPath<NexusSettings, [String]>) -> some View {
        Group {
            ForEach(app.settings[keyPath: kp], id: \.self) { f in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.accent2)
                    Text(f).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { var s = app.settings; s[keyPath: kp].removeAll { $0 == f }; app.saveSettings(s) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button("Add folder…") { if let f = Panels.chooseFolder(prompt: "Add") { var s = app.settings; s[keyPath: kp].append(Paths.abbreviate(f)); app.saveSettings(s) } }
        }
    }
}

struct IntelligenceSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Form {
            Section("Autopilot") {
                Toggle("File high-confidence suggestions automatically", isOn: SettingsBinding.make(app, \.autopilotEnabled))
                VStack(alignment: .leading) {
                    Text("Act automatically at ≥ \(Int(app.settings.autoThreshold * 100))%")
                    Slider(value: SettingsBinding.make(app, \.autoThreshold), in: 0.6...0.99)
                }
                VStack(alignment: .leading) {
                    Text("Send to Review Queue at ≥ \(Int(app.settings.reviewThreshold * 100))% (below: ignore & log)")
                    Slider(value: SettingsBinding.make(app, \.reviewThreshold), in: 0.2...0.85)
                }
            }
            Section("Understanding files") {
                Toggle("OCR text in images and scanned PDFs (Vision, on-device)", isOn: SettingsBinding.make(app, \.enableOCR))
                Toggle("Transcribe audio files (Speech, on-device)", isOn: SettingsBinding.make(app, \.enableSpeech))
                Stepper("Read up to \(app.settings.maxExtractKB) KB of text per file", value: SettingsBinding.make(app, \.maxExtractKB), in: 64...4096, step: 64)
            }
            LocalModelSection()
            Section("Language model") {
                Picker("Provider", selection: SettingsBinding.make(app, \.llmProvider)) { ForEach(LLMProviderChoice.allCases, id: \.self) { Text($0.label).tag($0) } }
                TextField("Ollama URL", text: SettingsBinding.make(app, \.ollamaURL))
                TextField("Ollama model", text: SettingsBinding.make(app, \.ollamaModel))
                HStack { Text("Active:"); Text(app.llmName).foregroundStyle(Theme.accent) }
                Text("Used for summaries, reports and interpreting unusual commands. Classification, rules and search work fully without a model.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Battery") {
                Toggle("Throttle background work on battery, Low Power Mode or thermal pressure", isOn: SettingsBinding.make(app, \.batteryAware))
            }
        }
        .formStyle(.grouped)
    }
}

struct CategorySettings: View {
    @EnvironmentObject var app: AppState
    @State private var categories: [NexusCore.Category] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Document types Nexus recognises and where they go. Nexus also learns destinations from your approvals and manual moves.").font(.caption).foregroundStyle(.secondary)
            Table(categories) {
                TableColumn("Category") { c in TextField("", text: binding(c, \.name)) }.width(130)
                TableColumn("Document types") { c in TextField("", text: Binding(get: { c.docTypes.joined(separator: ", ") }, set: { v in update(c) { $0.docTypes = v.split(separator: ",").map { $0.trimmed } } })) }.width(140)
                TableColumn("Destination") { c in TextField("", text: binding(c, \.destination)).font(.system(.body, design: .monospaced)) }
                TableColumn("") { c in Button { app.engine.store.deleteCategory(c.id); load() } label: { Image(systemName: "trash") }.buttonStyle(.plain) }.width(24)
            }
            HStack {
                Button("Add category") { app.engine.store.saveCategory(NexusCore.Category(name: "New", destination: "~/Documents/New", docTypes: [])); load() }
                Spacer()
                let learned = app.engine.taxonomy.docTypeMemory
                if !learned.isEmpty { Text("Learned preferences: \(learned.count) document types").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear { load() }
    }
    func load() { categories = app.engine.store.categories() }
    func binding(_ c: NexusCore.Category, _ kp: WritableKeyPath<NexusCore.Category, String>) -> Binding<String> {
        Binding(get: { c[keyPath: kp] }, set: { v in update(c) { $0[keyPath: kp] = v } })
    }
    func update(_ c: NexusCore.Category, _ f: (inout NexusCore.Category) -> Void) {
        var copy = c; f(&copy); app.engine.store.saveCategory(copy)
        if let i = categories.firstIndex(where: { $0.id == c.id }) { categories[i] = copy }
    }
}

struct PrivacySettings: View {
    @EnvironmentObject var app: AppState
    @State private var confirmReset = false
    var body: some View {
        Form {
            Section {
                Label("File contents, OCR, embeddings and the knowledge graph never leave this Mac.", systemImage: "lock.shield.fill")
                Label("Network is only used by connectors you enable (GitHub, Slack, Notion, webhooks) and by a local Ollama server.", systemImage: "network")
                Label("Every change is journaled and undoable. Nexus never permanently deletes files — it uses the Trash.", systemImage: "arrow.uturn.backward.circle")
            }
            Section("Safety") {
                Toggle("Dry-run mode", isOn: SettingsBinding.make(app, \.dryRun))
                Toggle("Sandbox scripts & plugins", isOn: SettingsBinding.make(app, \.scriptSandbox))
                Stepper("Runaway guard: \(app.settings.maxOpsPerMinute) ops/min", value: SettingsBinding.make(app, \.maxOpsPerMinute), in: 10...2000, step: 10)
            }
            Section("Data") {
                Button("Reveal Nexus data folder") { Panels.reveal([Paths.appSupport.path]) }
                Button("Reset index (keeps rules, projects & settings)", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the file index?", isPresented: $confirmReset) {
            Button("Reset index", role: .destructive) {
                let db = app.engine.store.db
                try? db.executeScript("DELETE FROM files; DELETE FROM files_fts; DELETE FROM file_tags; DELETE FROM embeddings; DELETE FROM graph_edges; DELETE FROM review_items;")
                app.reloadAll()
                for f in app.settings.watchedFoldersExpanded { app.engine.queue.enqueue(Job(name: "Classify \(Paths.abbreviate(f))", kind: .ai, priority: .normal, spec: JobSpec(operation: .classifyFolder, path: f))) }
            }
        } message: { Text("Nexus will re-read your inbox folders. Files on disk are not touched.") }
    }
}

struct VoiceSettings: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var voice: VoiceController
    var body: some View {
        Form {
            Section {
                Picker("Talk to Nexus shortcut", selection: SettingsBinding.make(app, \.voiceHotkey)) {
                    ForEach(VoiceHotkey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Hold to talk and release to send, or tap once for hands-free listening. Works from any app.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Conversation") {
                Toggle("Send automatically when I pause", isOn: SettingsBinding.make(app, \.voiceAutoSubmit))
                Toggle("Read previews aloud and accept “run it” / “cancel”", isOn: SettingsBinding.make(app, \.voiceConfirmBySpeech))
                Toggle("Speak results for voice commands", isOn: SettingsBinding.make(app, \.speakResponses))
            }
            Section("Try it") {
                HStack {
                    MicButton(size: 36)
                    Text(voice.isActive ? (voice.transcript.isEmpty ? "Listening…" : voice.transcript) : "Click the microphone and say “organize my Downloads”.")
                        .foregroundStyle(.secondary)
                }
                if let e = voice.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
                Text("Speech is recognized on this Mac when supported. Nexus needs Microphone and Speech Recognition permission.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LocalModelSection: View {
    @EnvironmentObject var app: AppState
    @State private var models: [URL] = []
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section("Offline AI (bundled local model)") {
            if LocalModelServer.runtimeURL == nil {
                Label("Runtime not bundled in this build", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
            if models.isEmpty {
                Text("No local models installed.").foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: SettingsBinding.make(app, \.localModelPath)) {
                    Text("Automatic").tag("")
                    ForEach(models, id: \.path) { m in
                        let size = (try? m.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { formatBytes(Int64($0)) } ?? ""
                        Text("\(LocalModelServer.displayName(m))  \(size)").tag(m.path)
                    }
                }
            }
            HStack {
                Button("Add GGUF model…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.init(filenameExtension: "gguf")!].compactMap { $0 }
                    if p.runModal() == .OK, let u = p.url {
                        let dest = LocalModelServer.userModelsDir.appendingPathComponent(u.lastPathComponent)
                        try? FileManager.default.copyItem(at: u, to: dest)
                        models = LocalModelServer.availableModels()
                    }
                }
                Button("Reveal models folder") { Panels.reveal([LocalModelServer.userModelsDir.path]) }
                Spacer()
                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    Task {
                        let t0 = Date()
                        do {
                            let r = try await LocalModelServer.shared.complete(system: "Reply in five words or fewer.", prompt: "Confirm you are running offline.", maxTokens: 20)
                            testResult = String(format: "✓ %.1fs — %@", Date().timeIntervalSince(t0), r.trimmed)
                        } catch { testResult = "✗ \(error)" }
                        testing = false
                    }
                }.disabled(models.isEmpty || testing)
            }
            if let testResult { Text(testResult).font(.caption.monospaced()).foregroundStyle(.secondary) }
            Text("Runs llama.cpp on this Mac (Metal). Starts on demand, unloads after 10 idle minutes. Works with no internet, no Apple Intelligence and no Ollama.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { models = LocalModelServer.availableModels() }
    }
}
