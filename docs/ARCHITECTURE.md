# Nexus — Architecture

Nexus is a local-first, always-on agent for macOS. One signed app bundle contains the **agent core**
(`NexusCore`, a Swift library), the **SwiftUI shell** (`Nexus`: menu bar extra, desktop hotbar, command
palette, main window) and a **CLI** (`nexusctl`) that talks to the agent over a local API.

```
┌──────────────────────────── Nexus.app (single process, LSUIElement-style) ────────────────────────────┐
│                                                                                                        │
│  UI shell (MainActor)                                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌────────────────┐ ┌──────────────┐ ┌─────────────────────────────────────┐ │
│  │ Menu bar │ │ Hotbar   │ │ Command palette│ │ Voice        │ │ Main window: Today · Review · Files │ │
│  │ extra    │ │ (HUD)    │ │ ⌘K / ⇧⌘K       │ │ ⌥⇧Space PTT  │ │ Projects · Rules · Tasks · Insights │ │
│  └────┬─────┘ └────┬─────┘ └───────┬────────┘ └──────┬───────┘ └─────────────────┬───────────────────┘ │
│       └────────────┴───────────────┴────── AppState (ObservableObject bridge) ───┘                     │
│                                               │  subscribes to EventBus, debounced reloads             │
│  ─────────────────────────────────────────────┼──────────────────────────────────────────────────────  │
│  Agent core (NexusCore, background queues)    ▼                                                        │
│                                                                                                        │
│   FileWatcher (FSEvents, inode) ─┐                                   ┌─► RuleEngine ─► ActionExecutor ─┤
│   FileStabilizer (download done) ├─► EventBus ─► NexusEngine.ingest ─┼─► Autopilot (confidence gate)   │
│   SystemMonitor (apps, volumes,  │     (pub/sub)   extract→classify  └─► Review Queue / Insights       │
│     disk, idle, wake, power)     │                  →project match                                     │
│   Connectors (Calendar, GitHub,  │                  →FTS + embeddings + knowledge graph                │
│     Mail bridge, API events) ────┘                                                                     │
│                                                                                                        │
│   Scheduler (30 s tick: once/cron/conditional, threshold rules, maintenance) ─► TaskQueue (SQLite,     │
│     priorities, retries w/ backoff, battery/thermal throttling) ─► job runner                          │
│                                                                                                        │
│   Intelligence: ContentExtractor (PDFKit, Vision OCR, textutil, Speech) · Classifier (NaturalLanguage)  │
│     · TaxonomyLearner · ProjectMatcher · Embedder (NLEmbedding) · LLMRouter (Apple Foundation Models → │
│     Ollama → extractive fallback)                                                                      │
│                                                                                                        │
│   NexusStore (SQLite WAL: JSON documents + indexed columns, FTS5, vectors, graph edges, journal)       │
│   APIServer (127.0.0.1, bearer token) ◄──────── nexusctl · Shortcuts · scripts · inbound webhooks      │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | File | Responsibility |
|---|---|---|
| File watcher | `Sources/NexusCore/Watchers/Watchers.swift` | Recursive FSEvents with file-level events, extended data (inode) and `IgnoreSelf`, so Nexus's own moves never re-trigger rules. Paths are canonicalized (`/private/tmp` → `/tmp`). |
| File stabilizer | same file | Waits until a file's size is stable (downloads, exports) before ingesting. |
| System monitor | same file | App launch/quit, volume mount/unmount, wake, disk free, idle time, AC/battery, Low Power, thermal state. |
| Content extractor | `Intelligence/ContentExtractor.swift` | Text from PDF (with OCR fallback for scans), Office (`textutil`/`unzip`), code, images (Vision OCR), audio (on-device Speech), zip listings; SHA-256 content hash; 64-bit perceptual hash; download origin (`kMDItemWhereFroms`). |
| Classifier | `Intelligence/Classifier.swift` | Document type (weighted signatures), topics (noun lemmas), entities (people/orgs/places, dates, course codes, money, emails), language. |
| Taxonomy learner | `Intelligence/Learning.swift` | Learns folder profiles from your library, plus a personal memory of where each document type and keyword goes (from approvals and manual moves). |
| Project matcher | same | Noisy-OR of signals: project folder, name mention, keywords, tags, semantic similarity, deadline proximity. |
| LLM router | `Intelligence/LLM.swift` | Apple on-device model (FoundationModels), else Ollama, else heuristics. Used for summaries, reports, Q&A and rewriting unusual phrasing into the command grammar. |
| Rule engine | `Rules/RuleEngine.swift` | Trigger matching, condition evaluation, priority and stop-processing, simulation, static conflict analysis (contradictory / redundant / shadowed). |
| NL compiler | `Rules/NLRuleCompiler.swift` | Deterministic English → `Rule`. LLM fallback only when the parser can't. |
| Action executor | `Rules/ActionExecutor.swift` | 30+ actions, an undo journal (batches), runaway guard, protected paths, Finder tag sync, sandboxed scripts. |
| Scheduler | `Scheduling/TaskQueue.swift` | Once, cron and conditional schedules; schedule- and threshold-triggered rules; maintenance hooks. |
| Task queue | same | Persistent jobs, priority order, 2 concurrent, retries with exponential backoff, crash recovery, throttling. |
| Command parser | `Commands/CommandParser.swift` | Palette/voice/CLI text → ordered steps (multi-step, pronouns, "this" context, questions, schedules). |
| Engine | `Engine/NexusEngine.swift` | Orchestrates everything: ingest pipeline, autopilot, review, focus, plan/execute, Q&A, briefing, meeting prep, job runner. |
| Insights | `Insights/Insights.swift` | Hygiene scans, pattern detection ("you keep doing this by hand"), Markdown and PDF reports. |
| Connectors & plugins | `Connectors/Connectors.swift` | EventKit, GitHub, Slack, Notion, Obsidian, Mail bridge, cloud folders, webhooks, Seatbelt-sandboxed plugins. |
| API | `API/APIServer.swift` | Local REST on 127.0.0.1 with a bearer token in `api.json` (0600). |

## How components communicate

1. **Events (pub/sub).** Watchers, the monitor and connectors post `NexusEvent`s on the `EventBus`. The engine
   subscribes and turns them into ingest operations or event-rule jobs. The store posts `storeChanged(entity)`
   after every write, and `AppState` debounces those (350 ms) into SwiftUI reloads.
2. **Queues.**
   - *Ingest* is an in-memory `OperationQueue` (2 concurrent, utility QoS) for high-volume, low-latency file work.
   - *Jobs* live in the persistent `TaskQueue` (SQLite) for anything user-visible, long-running or retryable:
     schedules, event rules, classification, reports and syncs.
3. **Direct async calls** from the UI: `engine.plan()` → preview → `engine.execute()`.
4. **IPC.** `nexusctl`, Shortcuts, scripts and external webhooks use the local HTTP API; custom events arrive
   via `POST /v1/events` as `connectorEvent` triggers.

## Key flows

**New download →** FSEvents → stabilizer → `ingest` → extract → classify → project match → store (FTS, vector, graph)
→ file rules (priority order; `requireConfirmation` rules go to Review) → if nothing fired: focus routing
→ autopilot: score ≥ 85% files it automatically, ≥ 55% queues a Review card, anything lower is logged → a
notification digest (batched every 60 s; silenced during Focus or quiet hours).

**Voice →** Carbon hotkey (press/release) → `VoiceController` (on-device `SFSpeechRecognizer`, level meter, silence
detection) → palette `plan` → mutating plans are read aloud; you answer "run it" or "cancel" → `execute` →
the result is spoken.

**Learning loop →** approvals, edits, rejections and manual moves (detected via inode continuity) → `TaxonomyLearner`
memory → higher confidence next time → more happens automatically. A `PatternDetector` turns repeated manual moves
into suggested rules.

## Process model & safety

- A single process in v0.1 (menu bar app, launch at login via `SMAppService`). The engine has no UI dependencies,
  so v0.2 can move it into an XPC LaunchAgent without code changes to the core.
- **Nothing is permanently deleted.** Trash is used, and every mutating action writes an `UndoRecord` in a batch.
- **Runaway guard:** more than N file operations per minute pauses all automations.
- Protected paths (`/System`, `~/Library`, `~/.ssh`, …) are never mutated.
- Scripts and plugins run under `sandbox-exec` with read/write limited to declared paths and network off by default.
- Secrets live in the Keychain. The API binds to 127.0.0.1 and requires a token.
- Dry-run mode logs what would happen without changing anything.
- Battery-aware: on battery, Low Power or thermal pressure, only high-priority jobs run.
