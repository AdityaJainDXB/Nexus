# Nexus v0.1 — MVP scope

✅ = implemented in this repository · 🔜 = next

## Must-haves (make Nexus useful on day one)

| Area | Feature | Status |
|---|---|---|
| Presence | Menu bar extra with status, quick actions and review count; fixed-width icon | ✅ |
| Presence | Desktop hotbar (floating or desktop layer): live ticker, mic, badges | ✅ |
| Command | Global palette (⇧⌘K, configurable), plan → preview → one confirm → undo | ✅ |
| Voice | Push-to-talk or tap hotkey (⌥⇧Space), on-device recognition, auto-send on pause, spoken confirmation ("run it"), spoken results | ✅ |
| File brain | Extraction: PDF (+OCR for scans), Office, code, images (OCR), zip; audio transcription opt-in | ✅ |
| File brain | Doc type, topics, entities, language, content hash, perceptual hash, download origin | ✅ |
| File brain | Full-text + semantic search; knowledge graph "related files" | ✅ |
| Automation | Watched inbox folders (FSEvents), download-completion detection | ✅ |
| Automation | Rules from English, structured editor, visual node builder, simulator, test-on-folder, conflict detection | ✅ |
| Automation | Confidence gating: auto (≥85%) / Review Queue (≥55%) / ignore; keyboard-first review | ✅ |
| Learning | Learns destinations from approvals, edits and manual moves; suggests rules from repeated moves | ✅ |
| Safety | Undo journal per batch, Trash-only deletes, runaway guard, protected paths, dry-run, sandboxed scripts | ✅ |
| Scheduling | Once / cron / conditional schedules, persistent queue, retries, battery-aware throttling | ✅ |
| Projects | Projects with folders/keywords/deadlines, auto-association, dashboard with sparkline, timeline, quick actions | ✅ |
| Focus | Manual or calendar-inferred focus: route files, pre-warm project, hold non-urgent notifications | ✅ |
| Insights | Stale downloads, duplicates, similar screenshots, growth, low disk, inactive projects, deadlines, charts | ✅ |
| Reports | Daily/weekly/monthly/storage Markdown reports, PDF export | ✅ |
| Assistant | Ask questions of your files (on-device RAG with citations), "brief me", meeting prep, "file/summarize this" | ✅ |
| Access | System Access center (Full Disk Access, Accessibility, Automation, Mic, Speech, Calendar), whole-Mac mode | ✅ |
| Extensibility | Local REST API + `nexusctl`, inbound events, sandboxed plugins | ✅ |
| Connectors | Calendar/Reminders, GitHub, Slack, Notion, Obsidian, Mail bridge, Shortcuts, webhooks, cloud folders | ✅ |

## Nice-to-haves (v0.2+)

| Feature | Why later |
|---|---|
| Move the engine to an XPC LaunchAgent (UI can quit, agent keeps running) | Architecture already separates the core |
| Developer ID signing + notarization, Sparkle updates, App Store–sandboxed variant | Distribution |
| Screen-context memory ("what was that chart I saw yesterday?") with opt-in OCR of the active window | Privacy UX needs care |
| Local vision model for image understanding beyond OCR (logos, diagrams, photos of whiteboards) | Model size and battery |
| Multi-Mac sync of rules/projects via iCloud (CloudKit, end-to-end encrypted) | Conflict handling |
| iPhone companion: share sheet → Nexus inbox; voice from Watch | Separate app |
| App Intents / Siri & Spotlight actions ("Hey Siri, ask Nexus…") | Complements the palette |
| Rule marketplace and sharing (signed templates) | Needs trust model |
| Natural-language rule *explanations* for LLM-generated rules, with a diff on edit | Polish |
| Branching flows (if/else nodes, loops over folders) in the visual builder | Builder v2 |
| Email/Slack thread understanding (not only attachments) | Connector depth |
| Time-machine view: scrub the Activity timeline and restore any state | Journal already stores what's needed |
