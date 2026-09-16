import SwiftUI
import NexusCore

struct ConnectorsView: View {
    @EnvironmentObject var app: AppState
    @State private var statuses: [ConnectorStatus] = []
    @State private var githubToken = ""
    @State private var slackHook = ""
    @State private var notionToken = ""
    @State private var notionDB = ""
    @State private var plugins: [PluginManifest] = []
    @State private var pluginOutput: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Connectors & Plugins", subtitle: "Opt-in integrations. Secrets are stored in your Keychain, never in the Nexus database.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                    ForEach(statuses) { s in connectorCard(s) }
                }
                pluginsSection
            }
            .padding(28)
        }
        .onAppear { refresh() }
    }

    func refresh() {
        statuses = app.engine.connectors.statuses()
        plugins = app.engine.plugins.plugins()
        notionDB = app.engine.store.kv("notion.database") ?? ""
    }

    func connectorCard(_ s: ConnectorStatus) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: s.symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.headline)
                        Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Pill(text: s.connected ? "Connected" : "Off", color: s.connected ? Theme.success : .secondary)
                }
                if !s.events.isEmpty { Text("Triggers: " + s.events.joined(separator: ", ")).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary) }
                if !s.actions.isEmpty { Text("Actions: " + s.actions.joined(separator: ", ")).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                config(s.id)
            }
        }
    }

    @ViewBuilder func config(_ id: String) -> some View {
        switch id {
        case "calendar":
            Button("Grant Calendar & Reminders access") { Task { _ = await app.engine.connectors.eventKit.requestAccess(); refresh() } }.buttonStyle(GhostButtonStyle())
        case "github":
            SecureField("Personal access token (repo scope)", text: $githubToken).textFieldStyle(.roundedBorder)
            TextField("Default repo (owner/name)", text: Binding(get: { app.settings.githubRepo }, set: { var s = app.settings; s.githubRepo = $0; app.saveSettings(s) })).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save token") { Keychain.set(githubToken, for: "github.token"); githubToken = ""; refresh() }.buttonStyle(GhostButtonStyle())
                if Keychain.get("github.token") != nil { Button("Disconnect") { Keychain.set(nil, for: "github.token"); refresh() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
        case "slack":
            SecureField("Incoming webhook URL", text: $slackHook).textFieldStyle(.roundedBorder)
            Button("Save") { Keychain.set(slackHook, for: "slack.webhook"); slackHook = ""; refresh() }.buttonStyle(GhostButtonStyle())
        case "notion":
            SecureField("Integration token", text: $notionToken).textFieldStyle(.roundedBorder)
            TextField("Database ID", text: $notionDB).textFieldStyle(.roundedBorder)
            Button("Save") {
                if !notionToken.isEmpty { Keychain.set(notionToken, for: "notion.token") }
                app.engine.store.setKV("notion.database", notionDB)
                notionToken = ""; refresh()
            }.buttonStyle(GhostButtonStyle())
        case "obsidian":
            HStack {
                Text(app.settings.obsidianVault.isEmpty ? "No vault selected" : app.settings.obsidianVault).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Choose vault…") { if let f = Panels.chooseFolder() { var s = app.settings; s.obsidianVault = Paths.abbreviate(f); app.saveSettings(s); refresh() } }.buttonStyle(GhostButtonStyle())
            }
        case "mail":
            Text("1. Install the bridge  2. Mail ▸ Settings ▸ Rules ▸ Add Rule ▸ Perform “Run AppleScript” ▸ Nexus Save Attachments").font(.caption).foregroundStyle(.secondary)
            Button("Install Mail bridge") {
                do { let url = try app.engine.connectors.installMailBridge(); Panels.reveal([url.path]); app.showToast("Mail bridge installed") }
                catch { app.showToast("Could not install: \(error.localizedDescription)") }
                refresh()
            }.buttonStyle(GhostButtonStyle())
        case "shortcuts":
            Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }.buttonStyle(GhostButtonStyle())
        case "cloud":
            let folders = app.engine.connectors.cloudFolders()
            ForEach(folders, id: \.self) { f in
                HStack {
                    Text(Paths.abbreviate(f)).font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    let watched = app.settings.libraryRootsExpanded.contains(f)
                    Button(watched ? "Learning" : "Learn & search") { var s = app.settings; if !watched { s.libraryRoots.append(Paths.abbreviate(f)) }; app.saveSettings(s) }.buttonStyle(GhostButtonStyle()).disabled(watched)
                }
            }
        default: EmptyView()
        }
    }

    var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Plugins", subtitle: "Folders in ~/Library/Application Support/Nexus/Plugins with a plugin.json. Run inside a Seatbelt sandbox limited to declared paths.",
                          trailing: AnyView(Button("Reveal folder") { Panels.reveal([Paths.plugins.path]) }.buttonStyle(GhostButtonStyle())))
            if plugins.isEmpty { Text("No plugins installed.").foregroundStyle(.secondary) }
            ForEach(plugins) { p in
                Card(padding: 12) {
                    HStack(alignment: .top) {
                        Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.accent2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(p.name) \(p.version)").font(.headline)
                            Text(p.description).font(.caption).foregroundStyle(.secondary)
                            Text("read: \(p.permissions.read.joined(separator: ", ")) · write: \(p.permissions.write.joined(separator: ", ")) · network: \(p.permissions.network ? "yes" : "no")")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Run on file…") {
                            guard let path = Panels.chooseFile() else { return }
                            Task {
                                let rec = app.engine.store.file(path: path) ?? app.engine.index(path)?.0
                                let (ok, out) = await app.engine.runPlugin(named: p.name, file: rec, info: ["manual": "1"])
                                pluginOutput = (ok ? "✓ " : "✗ ") + out
                            }
                        }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
            if let pluginOutput { Text(pluginOutput).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}

struct DeveloperView: View {
    @EnvironmentObject var app: AppState
    @State private var cliStatus: String?

    var token: String { app.api.token }
    var port: Int { app.settings.apiPort }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Developer", subtitle: "Local API, CLI, scripts and safety switches for power users.")
                HStack(alignment: .top, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Local API").font(.headline); Spacer(); Pill(text: app.settings.apiEnabled ? "127.0.0.1:\(port)" : "Off", color: app.settings.apiEnabled ? Theme.success : .secondary) }
                            Toggle("Enable API", isOn: Binding(get: { app.settings.apiEnabled }, set: { var s = app.settings; s.apiEnabled = $0; app.saveSettings(s) })).toggleStyle(.switch)
                            HStack {
                                Text("Token").foregroundStyle(.secondary)
                                Text(String(token.prefix(10)) + "…").font(.caption.monospaced())
                                Button("Copy") { Panels.copy(token) }.buttonStyle(GhostButtonStyle())
                            }
                            code("""
                            curl -s -H "Authorization: Bearer $(jq -r .token ~/Library/Application\\ Support/Nexus/api.json)" \\
                              -d '{"text":"find invoices from last month"}' http://127.0.0.1:\(port)/v1/command
                            """)
                            Text("Endpoints: GET /v1/status · POST /v1/command · GET|POST /v1/rules · POST /v1/rules/:id/run · POST /v1/simulate · GET|POST /v1/tasks · GET /v1/schedule · GET /v1/insights · GET /v1/search?q= · GET /v1/projects · GET /v1/report?type= · POST /v1/undo · POST /v1/events · POST /v1/ingest")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Command-line tool").font(.headline)
                            code("""
                            nexusctl status
                            nexusctl run "move all invoices from Downloads to Finance and tag them tax"
                            nexusctl rule add "If a PDF in Downloads contains 'MYP3' → move to School"
                            nexusctl simulate ~/Downloads/report.pdf
                            nexusctl tasks · nexusctl insights · nexusctl undo
                            nexusctl event custom.deploy '{"title":"v1.2"}'
                            """)
                            Button("Install nexusctl to ~/.local/bin") { installCLI() }.buttonStyle(GhostButtonStyle())
                            if let cliStatus { Text(cliStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Safety").font(.headline)
                            Toggle("Dry-run mode (log what would happen, change nothing)", isOn: binding(\.dryRun)).toggleStyle(.switch)
                            Toggle("Sandbox scripts & plugins (sandbox-exec)", isOn: binding(\.scriptSandbox)).toggleStyle(.switch)
                            Stepper("Runaway guard: max \(app.settings.maxOpsPerMinute) file operations / minute", value: binding(\.maxOpsPerMinute), in: 10...2000, step: 10)
                            Text("Protected (never modified): " + Paths.protectedPrefixes.map(Paths.abbreviate).joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Data").font(.headline)
                            row("Database", Paths.database.path)
                            row("Reports", Paths.reports.path)
                            row("Scripts", Paths.scripts.path)
                            row("Plugins", Paths.plugins.path)
                            HStack {
                                Button("Reveal data folder") { Panels.reveal([Paths.appSupport.path]) }.buttonStyle(GhostButtonStyle())
                                Button("Relearn folders") { app.runCommand("learn my folders") }.buttonStyle(GhostButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    func binding<T>(_ kp: WritableKeyPath<NexusSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: kp] }, set: { var s = app.settings; s[keyPath: kp] = $0; app.saveSettings(s) })
    }

    func code(_ s: String) -> some View {
        Text(s).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary).frame(width: 70, alignment: .leading); Text(Paths.abbreviate(v)).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled) }
    }

    func installCLI() {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nexusctl").path,
                          (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent } ?? "") + "/nexusctl"]
        guard let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { cliStatus = "nexusctl binary not found next to Nexus"; return }
        let bin = NSHomeDirectory() + "/.local/bin"
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let dest = bin + "/nexusctl"
        try? FileManager.default.removeItem(atPath: dest)
        do {
            try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: src)
            cliStatus = "Linked \(Paths.abbreviate(dest)). Make sure ~/.local/bin is on your PATH."
        } catch { cliStatus = error.localizedDescription }
    }
}
