# Nexus — the agentic desktop brain for macOS

Nexus lives in your menu bar and on a desktop hotbar. It understands the *contents* of your files, files them where
they belong, runs your automations in the background, answers questions from your documents, and responds to your
voice. It does all of this on-device, and every change is reversible.

> Hold **⌥⇧Space** anywhere: "move this week's invoices from Downloads to Finance and tag them tax" → Nexus reads the plan back → say **"run it"**.

## Build & run

Requirements: macOS 13+ (Apple Silicon recommended), Xcode 16+ / Swift 6 toolchain.

```bash
./scripts/build-app.sh
```

```bash
open dist/Nexus.app
```

- Onboarding asks for inbox folders (default `~/Downloads`, `~/Desktop`), library folders (`~/Documents`), access
  permissions, autopilot thresholds and starter rules.
- For **whole-Mac mode**, grant *Full Disk Access* in **System Access** (sidebar) → Open Settings…
- Voice needs Microphone + Speech Recognition (prompted on first use).
- The on-device LLM uses Apple Intelligence when available, otherwise a local Ollama server, otherwise heuristics.

Development:

```bash
swift test
```

```bash
swift build && .build/debug/Nexus
```

Set `NEXUS_HOME=/some/dir` to run with an isolated database, for example while testing.

## What's inside

| | |
|---|---|
| **Surfaces** | Menu bar extra · desktop hotbar (floating or desktop layer) · global command palette · main window (Today, Review Queue, Files, Projects, Rules, Tasks & Schedule, Insights, Activity, Connectors, System Access, Developer) · Settings |
| **Voice** | Push-to-talk or tap, on-device recognition, live level orb, auto-send on pause, spoken previews with "run it / cancel", spoken results |
| **File brain** | PDF/Office/code/image OCR/audio extraction · doc type, topics, entities · FTS5 + sentence-embedding search · knowledge graph |
| **Automation** | English → rules · visual flow builder · simulator & folder tests · conflict detection · 17 triggers, 17 condition fields, 31 actions |
| **Autopilot** | Confidence gating (auto / review / ignore) that learns from approvals, edits and manual moves; habit → rule suggestions |
| **Assistant** | Ask your files (RAG with citations) · "file this" / "summarize this" · brief me · meeting prep · focus mode |
| **Engine** | Persistent priority task queue with retries · once/cron/conditional schedules · battery-aware |
| **Safety** | Undo journal · Trash-only deletes · runaway guard · protected paths · dry run · sandboxed scripts/plugins · Keychain secrets |
| **Extensibility** | Local REST API + `nexusctl` CLI · inbound webhooks · plugins · Calendar/Reminders, GitHub, Slack, Notion, Obsidian, Mail, Shortcuts |

## Keyboard & voice

| Shortcut | Action |
|---|---|
| **⌥⇧Space** (hold / tap) | Talk to Nexus from any app |
| **⇧⌘K** | Command palette from anywhere (⌘K inside Nexus) |
| ⌘D (palette) · ⇧⌘D (app) | Dictate a command |
| ↩ · ⌘↩ · ↑↓ · ⌘1–6 · ⌘Z · ⌘R · esc/⌘. | Palette: go · confirm · select · quick actions · undo · reveal · cancel |
| ⌘1–⌘9 · ⌘N / ⇧⌘N / ⌥⌘N · ⇧⌘F | Sections · new rule/project/schedule · search files |
| ⌥⌘Z · ⌥⌘O · ⌥⌘R · ⌥⌘P · ⌥⌘F | Undo automation · organize Downloads · scan insights · pause · focus |
| ↑↓ ↩ ⇧↩ E Space | Review Queue: navigate, approve, reject, edit, open |
| ⌘/ | Full cheat sheet |

Standard macOS shortcuts (⌘Z text undo, ⌘, Settings, ⇧⌘P Page Setup, ⌘? Help) are not repurposed.

## CLI

```bash
nexusctl status
nexusctl run "find everything about hydroponics from this month"
nexusctl run "organize Downloads" --yes
nexusctl rule add "If a PDF in Downloads contains 'MYP3' → move to School, tag science"
nexusctl compile "When external drive 'Backup' is connected → sync Projects and School folders"
nexusctl simulate ~/Downloads/report.pdf
nexusctl event custom.deploy '{"title":"v1.2"}'
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md): components and how they communicate
- [Data model](docs/DATA_MODEL.md): entities, relationships, schema
- [Natural language → rules](docs/NL_RULES.md): 15 real compiler outputs
- [MVP scope](docs/MVP.md): v0.1 must-haves and later
- [Code skeletons](docs/CODE_SKELETONS.md): watcher, rule engine, scheduler, palette handler
- [UI wireframes](docs/UI_WIREFRAMES.md): every surface
- [Features & USP](docs/FEATURES_AND_USP.md): where Nexus beats Siri, plus a roadmap

## Layout

```
Sources/NexusCore/   agent core: Database, Models, Core, Intelligence, Watchers, Rules, Scheduling, Commands, Insights, Connectors, API, Engine
Sources/Nexus/       SwiftUI app: NexusApp, Palette (palette, voice, hotbar), Support (state, design system, system access), Views
Sources/nexusctl/    CLI
Tests/NexusCoreTests compiler, cron, rule engine, parser, end-to-end ingest → rule → undo
scripts/             build-app.sh (bundle + icon + ad-hoc sign), make-icon.swift
```
