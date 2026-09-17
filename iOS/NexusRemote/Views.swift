import SwiftUI

// MARK: - Pairing

struct PairingView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var code = ""
    @State private var selectedHost: String?
    @State private var selectedName = ""
    @State private var manualHost = ""
    @State private var working = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(RTheme.gradient).frame(width: 64, height: 64)
                            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 30)).foregroundStyle(RTheme.space)
                        }
                        Text("NEXUS // REMOTE").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(RTheme.cyan)
                        Text("Command your Mac from your phone").font(.system(size: 28, weight: .bold))
                        Text("On your Mac open Nexus → Connectors → turn on “Allow iPhone control”, then click Pair iPhone.")
                            .foregroundStyle(.secondary)
                    }
                    HUDLabel(text: "Macs on this network")
                    VStack(spacing: 8) {
                        if client.discovered.isEmpty {
                            HStack { ProgressView(); Text("Looking for Nexus…").foregroundStyle(.secondary) }.hudCard()
                        }
                        ForEach(client.discovered) { mac in
                            Button {
                                Task { working = true; selectedHost = await client.resolve(mac); selectedName = mac.name; working = false; codeFocused = true }
                            } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer").foregroundStyle(RTheme.cyan)
                                    Text(mac.name).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedName == mac.name { Image(systemName: "checkmark.circle.fill").foregroundStyle(RTheme.green) }
                                }.hudCard()
                            }
                        }
                        DisclosureGroup("Enter address manually") {
                            TextField("Mac IP address (e.g. 192.168.1.20)", text: $manualHost)
                                .textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation)
                                .padding(10).background(RTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                                .onChange(of: manualHost) { _, v in selectedHost = v.isEmpty ? nil : v; selectedName = v }
                                .onSubmit { codeFocused = true }
                                .accessibilityIdentifier("manualHost")
                        }
                        .tint(RTheme.cyan)
                        .padding(.horizontal, 4)
                    }
                    if selectedHost != nil || !manualHost.isEmpty {
                        HUDLabel(text: "Pairing code")
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .focused($codeFocused)
                            .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }
                            .hudCard()
                            .accessibilityIdentifier("pairCode")
                        Button {
                            Task {
                                working = true
                                _ = await client.pair(host: selectedHost ?? manualHost, code: code)
                                working = false
                            }
                        } label: {
                            HStack { if working { ProgressView().tint(RTheme.space) }; Text("Pair with \(selectedName.isEmpty ? manualHost : selectedName)") }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GradientButtonStyle())
                        .disabled(code.count != 6 || working)
                        .accessibilityIdentifier("pairButton")
                    }
                    if let e = client.lastError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(RTheme.amber) }
                    Label("End-to-end encrypted. Your files never leave your Mac.", systemImage: "lock.shield.fill").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(GridBackground())
            .onAppear { client.startBrowsing() }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var client: RemoteClient
    @EnvironmentObject var model: RemoteModel
    @Binding var tab: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Circle().fill(client.connected ? (model.paused ? .gray : RTheme.green) : RTheme.red).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.macName).font(.headline)
                            Text(client.connected ? "\(model.stateText) · \(model.files) files understood" : "Not connected").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.loading { ProgressView() }
                    }
                    .hudCard()

                    Button { tab = 1 } label: {
                        HStack(spacing: 14) {
                            ZStack { Circle().fill(RTheme.gradient).frame(width: 52, height: 52); Image(systemName: "mic.fill").font(.title2).foregroundStyle(RTheme.space) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Tell your Mac what to do").font(.headline).foregroundStyle(.primary)
                                Text("“Organize Downloads” · “Brief me” · “Clean up duplicates”").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.hudCard()
                    }
                    .accessibilityIdentifier("openCommand")

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        stat("Review", "\(model.review.count)", "tray.full", RTheme.amber) { tab = 2 }
                        stat("Insights", "\(model.insights.count)", "lightbulb", RTheme.cyan) { tab = 3 }
                        stat("Rules", "\(model.status["rules"] as? Int ?? 0)", "bolt", RTheme.violet) {}
                        stat("Disk free", "\(model.status["diskFreeGB"] as? Int ?? 0) GB", "internaldrive", RTheme.green) {}
                    }

                    if let f = model.focusProject {
                        HStack { Image(systemName: "scope").foregroundStyle(RTheme.violet); Text("Focus · \(f)"); Spacer()
                            Button("End") { Task { _ = await model.command("end focus", confirm: true) } }.buttonStyle(.bordered) }.hudCard()
                    }

                    HUDLabel(text: "Quick actions")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        quick("Organize Downloads", "wand.and.stars", "organize Downloads")
                        quick("Clean duplicates", "trash.square", "clean up duplicates")
                        quick("Weekly report", "chart.bar.doc.horizontal", "generate weekly report")
                        quick("Brief me", "sun.max", "brief me")
                    }

                    HUDLabel(text: "Recent on your Mac")
                    VStack(alignment: .leading, spacing: 8) {
                        if model.events.isEmpty { Text("No activity yet").foregroundStyle(.secondary) }
                        ForEach(Array(model.events.prefix(8).enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: (e["kind"] as? String) == "error" ? "exclamationmark.triangle" : "bolt.fill").font(.caption).foregroundStyle(RTheme.cyan)
                                Text(e["message"] as? String ?? "").font(.footnote).lineLimit(2)
                            }
                        }
                    }.hudCard()
                    if let err = model.error { Label(err, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(RTheme.amber) }
                }
                .padding(16)
            }
            .background(GridBackground())
            .navigationTitle("Nexus")
            .refreshable { await model.refreshAll() }
        }
    }

    func stat(_ title: String, _ value: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title.uppercased(), systemImage: symbol).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            }.hudCard()
        }
    }

    func quick(_ title: String, _ symbol: String, _ command: String) -> some View {
        NavigationLink { CommandView(prefill: command) } label: {
            HStack { Image(systemName: symbol).foregroundStyle(RTheme.cyan); Text(title).font(.subheadline).foregroundStyle(.primary); Spacer() }
                .padding(12).background(RTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Command

struct CommandView: View {
    @EnvironmentObject var model: RemoteModel
    @EnvironmentObject var voice: PhoneVoice
    var prefill: String? = nil
    @State private var text = ""
    @State private var plan: RemoteModel.Plan?
    @State private var result: RemoteModel.Plan?
    @State private var working = false
    @State private var fromVoice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 14) {
                        Button { fromVoice = true; voice.onFinal = { t in text = t; Task { await plan(t) } }; voice.toggle() } label: {
                            ZStack {
                                ForEach(0..<3) { i in
                                    Circle().fill(RTheme.cyan.opacity(0.10 - Double(i) * 0.025))
                                        .frame(width: 110 + CGFloat(i) * 34, height: 110 + CGFloat(i) * 34)
                                        .scaleEffect(voice.listening ? 1 + voice.level * (0.12 + CGFloat(i) * 0.1) : 1)
                                }
                                Circle().fill(RTheme.gradient).frame(width: 96, height: 96)
                                Image(systemName: voice.listening ? "waveform" : "mic.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(RTheme.space)
                            }
                            .frame(height: 190)
                            .animation(.easeOut(duration: 0.12), value: voice.level)
                        }
                        .accessibilityLabel(voice.listening ? "Stop listening" : "Speak a command")
                        Text(voice.listening ? (voice.transcript.isEmpty ? "Listening…" : voice.transcript) : "Tap and speak — or type below")
                            .font(voice.listening ? .title3 : .subheadline).foregroundStyle(voice.listening ? .primary : .secondary).multilineTextAlignment(.center)
                        if let e = voice.error { Text(e).font(.footnote).foregroundStyle(RTheme.amber) }
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        TextField("e.g. move invoices from Downloads to Finance", text: $text, axis: .vertical)
                            .lineLimit(1...3)
                            .submitLabel(.go)
                            .onSubmit { fromVoice = false; Task { await plan(text) } }
                            .accessibilityIdentifier("commandField")
                        Button { fromVoice = false; Task { await plan(text) } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || working)
                            .accessibilityIdentifier("sendCommand")
                    }
                    .hudCard()

                    if working { HStack { ProgressView(); Text("Your Mac is on it…").foregroundStyle(.secondary) } }

                    if let plan, plan.needsConfirm {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Preview — nothing changed yet", systemImage: "eye").font(.headline).foregroundStyle(RTheme.cyan)
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(i + 1). \(s["intent"] as? String ?? "")").font(.subheadline.weight(.semibold))
                                    if let n = s["note"] as? String, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
                                    ForEach((s["preview"] as? [String] ?? []).prefix(5), id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }
                            HStack {
                                Button("Run on Mac") { Task { await run() } }.buttonStyle(GradientButtonStyle()).accessibilityIdentifier("runPlan")
                                Button("Cancel") { self.plan = nil }.buttonStyle(.bordered)
                            }
                        }.hudCard()
                    }

                    if let result, let msg = result.message {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(RTheme.green).font(.headline)
                            Text(msg).font(.body).textSelection(.enabled).accessibilityIdentifier("resultMessage")
                            ForEach(result.files.prefix(8), id: \.self) { f in
                                Label((f as NSString).lastPathComponent, systemImage: "doc").font(.caption).lineLimit(1)
                            }
                            Button { Task { let m = await model.undo(); self.result = .init(steps: [], needsConfirm: false, message: m, files: []) } } label: {
                                Label("Undo on Mac", systemImage: "arrow.uturn.backward")
                            }.buttonStyle(.bordered)
                        }.hudCard()
                    }
                    if let e = model.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(RTheme.amber).font(.footnote) }
                }
                .padding(16)
            }
            .background(GridBackground())
            .navigationTitle("Command")
            .onAppear { if let prefill, text.isEmpty { text = prefill; Task { await plan(prefill) } } }
        }
    }

    func plan(_ t: String) async {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        working = true; result = nil; plan = nil
        let p = await model.command(trimmed, confirm: false)
        working = false
        if let p, p.needsConfirm {
            plan = p
            if fromVoice { voice.speak((p.steps.compactMap { $0["note"] as? String }.first ?? "Ready") + ". Tap run on Mac to confirm.") }
        } else {
            result = p
            if fromVoice, let m = p?.message { voice.speak(m) }
        }
    }

    func run() async {
        working = true
        let r = await model.command(text, confirm: true)
        working = false; plan = nil; result = r
        if fromVoice, let m = r?.message { voice.speak(m) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Review

struct ReviewView: View {
    @EnvironmentObject var model: RemoteModel
    var body: some View {
        NavigationStack {
            List {
                if model.review.isEmpty {
                    ContentUnavailableView("Inbox zero", systemImage: "checkmark.seal", description: Text("Nothing on your Mac needs a decision."))
                        .listRowBackground(Color.clear)
                }
                ForEach(Array(model.review.enumerated()), id: \.offset) { _, item in
                    let id = item["id"] as? String ?? ""
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(((item["path"] as? String ?? "") as NSString).lastPathComponent).font(.headline).lineLimit(1)
                            Spacer()
                            Text("\(Int((item["confidence"] as? Double ?? 0) * 100))%").font(.caption.monospaced()).foregroundStyle(RTheme.amber)
                        }
                        Label(((item["destination"] as? String ?? "") as NSString).abbreviatingWithTildeInPath, systemImage: "arrow.right")
                            .font(.caption.monospaced()).foregroundStyle(RTheme.cyan).lineLimit(2)
                        HStack {
                            Button { Task { await model.approve(id) } } label: { Label("Approve", systemImage: "checkmark") }.buttonStyle(GradientButtonStyle())
                            Button { Task { await model.reject(id) } } label: { Label("Reject", systemImage: "xmark") }.buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(RTheme.panel)
                    .swipeActions(edge: .leading) { Button { Task { await model.approve(id) } } label: { Label("Approve", systemImage: "checkmark") }.tint(RTheme.green) }
                    .swipeActions(edge: .trailing) { Button(role: .destructive) { Task { await model.reject(id) } } label: { Label("Reject", systemImage: "xmark") } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(GridBackground())
            .navigationTitle("Review")
            .refreshable { await model.refreshAll() }
        }
    }
}

// MARK: - Insights

struct InsightsView: View {
    @EnvironmentObject var model: RemoteModel
    @State private var message: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(RTheme.green).hudCard() }
                    if model.insights.isEmpty { ContentUnavailableView("All tidy", systemImage: "leaf", description: Text("Nexus will tell you when something needs attention.")) }
                    ForEach(Array(model.insights.enumerated()), id: \.offset) { _, i in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(i["title"] as? String ?? "").font(.headline)
                            Text(i["detail"] as? String ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                            if let cmd = i["command"] as? String, !cmd.isEmpty, !cmd.hasPrefix("open ") {
                                Button {
                                    Task { let r = await model.command(cmd, confirm: true); message = r?.message }
                                } label: { Label("Fix on Mac", systemImage: "wand.and.stars") }.buttonStyle(GradientButtonStyle())
                            }
                        }.hudCard()
                    }
                }
                .padding(16)
            }
            .background(GridBackground())
            .navigationTitle("Insights")
            .refreshable { await model.refreshAll() }
        }
    }
}

// MARK: - More

struct MoreView: View {
    @EnvironmentObject var client: RemoteClient
    @EnvironmentObject var model: RemoteModel
    @State private var undoMessage: String?
    var body: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    LabeledContent("Connected to", value: client.macName)
                    LabeledContent("Language model", value: model.status["llm"] as? String ?? "—")
                    Toggle("Pause automations", isOn: Binding(get: { model.paused }, set: { v in Task { await model.setPaused(v) } }))
                    Button { Task { undoMessage = await model.undo() } } label: { Label("Undo last automation", systemImage: "arrow.uturn.backward") }
                    if let undoMessage { Text(undoMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Projects") {
                    if model.projects.isEmpty { Text("No projects").foregroundStyle(.secondary) }
                    ForEach(Array(model.projects.enumerated()), id: \.offset) { _, p in
                        NavigationLink { CommandView(prefill: "summarize project \(p["name"] as? String ?? "")") } label: {
                            VStack(alignment: .leading) {
                                Text(p["name"] as? String ?? "").font(.headline)
                                Text("\(p["files"] as? Int ?? 0) files").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Tasks") {
                    ForEach(Array(model.tasks.prefix(12).enumerated()), id: \.offset) { _, t in
                        HStack {
                            Image(systemName: (t["status"] as? String) == "failed" ? "xmark.octagon.fill" : (t["status"] as? String) == "completed" ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle((t["status"] as? String) == "failed" ? RTheme.red : RTheme.green)
                            VStack(alignment: .leading) {
                                Text(t["name"] as? String ?? "").font(.subheadline).lineLimit(1)
                                Text(t["result"] as? String ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Section {
                    Button("Unpair this iPhone", role: .destructive) { client.unpair() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(GridBackground())
            .navigationTitle("More")
            .refreshable { await model.refreshAll() }
        }
    }
}
