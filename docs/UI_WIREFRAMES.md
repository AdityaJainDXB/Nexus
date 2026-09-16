# Nexus — UI wireframes (as implemented)

Visual language: **sci-tech HUD**. Deep-space navy with a faint engineering grid, an ion-cyan and plasma-violet
gradient, translucent panels with corner brackets, and monospaced telemetry labels (`NEXUS // TODAY`, `HANDLED TODAY`).
Dark by default, with Light and Match System options (all colors are dynamic). The design follows Apple HIG: standard
shortcuts aren't repurposed, Esc and ⌘. cancel, controls are labelled for VoiceOver, and Reduce Motion and Reduce
Transparency are honored.

---

## 0. Always-on surfaces

**Menu bar extra** (fixed 22×18 pt template glyph; a dot badge when something needs you — it never changes width)
```
┌ ● Nexus                          [⏸] ┐
│ Idle · 1,204 files indexed           │
│ [✦ Ask Nexus…        ⇧⌘K ] [🎙]      │
│ Hold ⌥⇧Space anywhere to talk        │
│ ┌Review 3┐ ┌Insights 2┐ ┌Running 1┐  │
│ QUICK ACTIONS  Organize · Report ·   │
│                Duplicates · Undo     │
│ NEXUS NOTICED  • 42 files in ~/Dow…  [Fix]
│ RECENT         ⚡ “Invoices → Fina…  2m │
│ [Open Nexus]          Settings…  Quit│
└──────────────────────────────────────┘
```

**Desktop hotbar** (600×56 pt HUD strip; drag anywhere; floating or on the desktop layer; right-click to change)
```
╭─────────────────────────────────────────────────────────────────────────────╮
│ (⬡•)  FOCUS · Hydroponics · 48m left            ⌘K │ (🎙) │ ✨  📥²  💡  ◎  ⏸ │
╰─────────────────────────────────────────────────────────────────────────────╯
  logo+status   live ticker (last action / transcript / focus)   mic  organize review insights focus pause
```

## 1. Command palette (⇧⌘K anywhere, ⌘K in app)

```
╔════════════════════════════════════════════════════════════════════╗
║ ✦  Ask or say what you need — find, organize, automate…      (🎙) ║
╟────────────────────────────────────────────────────────────────────╢
║ ◎ Context: Q3-report.pdf          [File this] [Summarize this]     ║  ← Finder selection / front document
║ ┌──────────────────────────────────────────────────────────────┐   ║
║ │ (🎙) Just say it — Hold ⌥⇧Space to talk, release to send.     │   ║
║ └──────────────────────────────────────────────────────────────┘   ║
║ ▍QUICK ACTIONS                                                     ║
║ [✨ Organize Downloads ⌘1] [📥 Show unsorted ⌘2] [📊 Weekly report ⌘3]║
║ [⧉ Find duplicates  ⌘4] [🗄 Archive shots  ⌘5] [↶ Undo last    ⌘6]║
║ ▍RECENT                                                            ║
║   ⟲ move all invoices from Downloads to Finance and tag them tax   ║
║ ▍NEXUS NOTICED   💡 38 unsorted files in ~/Downloads        [Fix]  ║
╟────────────────────────────────────────────────────────────────────╢
║ ● 1,204 files · Apple Intelligence     ↩ Go  ⌘D Speak  ↑↓ Select  esc ║
╚════════════════════════════════════════════════════════════════════╝
```
- **Typing:** the body shows "Understood as" steps (intent icon, label, "Changes files" pill, readable query).
- **↩:** plan. Read-only steps (find, ask, briefing) run immediately. Mutating plans show a **Preview**
  (per-file lines such as `acme.pdf: Move to ~/Documents/Finance`) with [Run] [Cancel].
- **Voice:** a level-reactive orb plus a live transcript ("Listening — release to send"). For previews Nexus speaks
  "Move 7 files… Say run it, or cancel" and listens for the answer.
- **Results:** message, file rows (icon, folder, tags, Reveal, Open), [Undo ⌘Z] [Reveal ⌘R] [Test rule].

## 2. File Review Queue (keyboard-first)

```
NEXUS // REVIEW QUEUE
Review Queue                                   [Approve 5 above 75%] [✨ Sort Downloads]
┌───────────────────────────────────────────────────────┐ ┌──────────────────────┐
│ [thumb] acme-2041.pdf                  ███████░ 78%   │ │  [ large preview ]   │
│         Invoice #2041 Bill To… Amount due $420…       │ │ acme-2041.pdf        │
│         → ~/Documents/Finance/Invoices/2026  #invoice │ │ Type    invoice      │
│         Looks like a invoice → Invoices · You filed 2…│ │ From    acme.com     │
│  [✓ Approve] [⚙ Edit] [✕ Reject]              2m ago  │ │ Mentions ACME, Aditya│
└═══════════════════════════════════════════════════════┘ │ Other candidates     │
┌───────────────────────────────────────────────────────┐ │  📁 ~/Documents/Tax  │
│ [thumb] lab-notes.docx …                       61%    │ └──────────────────────┘
└───────────────────────────────────────────────────────┘
 ↑↓ Navigate   ↩ Approve   ⇧↩ Reject   E Edit   Space Open
```
**Edit sheet:** destination (+Choose…), tags, project, and "Always do this for similar files" (creates a rule).

## 3. Rules builder

**List** (left, 320 pt): search, conflict banner (⚠ contradictory, shadowed or redundant), rows with an enable switch,
trigger glyph, name, "12 hits · last 2h ago", ⚠ marker. Bottom: "Simulate a file against all rules".

**Simple mode**
```
[Rule name ……………………………]                       (Simple | Visual | Simulate)
New file in folder: ~/Downloads · if … → Move to … → Add tags …   (mono summary)
┌ Describe the rule ─────────────────────────────── [Examples ▾] ┐
│ If a PDF in Downloads contains 'lab report' → move to …        │
│ [✨ Build rule]  ✓ New file in folder in ~/Downloads            │
│                  ✓ Only if Extension is “pdf”   ⚠ warnings…    │
└────────────────────────────────────────────────────────────────┘
┌ When ─ [New file in folder ▾]  (📁 ~/Downloads ✕) [+ Folder] ☐ Include subfolders ┐
┌ If  [all of ▾] these conditions match                         [+ Condition]       ┐
│ [Name or content ▾] [contains ▾] [lab report                ] ⊖                  │
┌ Then                                                          [+ Action ▾]        ┐
│ 1 [Move to ▾]   [~/Documents/School/Science/Reports] 📁   ˄ ˅ ⊖                   │
│ 2 [Add tags ▾]  [MYP3                              ]      ˄ ˅ ⊖                   │
[Enabled ◉] ☐ Ask before acting ☐ Stop other rules  Priority 50 ±   [🗑][⧉][▶ Run now][Test][Save ⌘S]
```

**Advanced mode (visual flow)**
```
┌ADD NODE─────┐ ┌ canvas (grid, zoom, auto-layout) ────────────────────────────┐ ┌INSPECTOR────────┐
│ ⚡ Trigger ▾ │ │ ┌TRIGGER───────┐   ┌CONDITION─────┐                          │ │ Field [Ext ▾]   │
│ ⏚ Condition▾│ │ │⤓ New file in │──▶│ Ext is “pdf” │─╮   ╭─────╮   ┌ACTION──────┐ │ │ Op    [is ▾]    │
│ ⚡ Action ▾  │ │ │  ~/Downloads │   └──────────────┘ ├──▶│ ALL │──▶│→ Move to … │ │ │ Value [pdf    ] │
│             │ │ └──────────────┘──▶┌CONDITION─────┐ │   ╰─────╯   └─────┬──────┘ │ │ [🗑 Delete]     │
│ Drag nodes… │ │                    │ contains lab…│─╯                  ▼        │ │                 │
└─────────────┘ │                    └──────────────┘             ┌ACTION──────┐  │ └─────────────────┘
                └──────────────────────────────────────────────── │# Add tags  │ ─┘
```

**Simulate mode:** a drop zone ("Drop a file to simulate all rules") and "Test on folder". The report shows how the
file was understood, then each rule in priority order: ✓ fires / ✋ blocked by stop / ○ not met, with ✓✗ per
condition (plus the actual value) and planned actions. A folder test lists "23 of 140 files would match".

## 4. Projects dashboard

```
NEXUS // PROJECTS                                      [☐ Archived] [+ New project]
┌──────────────────────────┐ ┌──────────────────────────┐ ┌──────────────────────────┐
│ [🧪] MYP Science Fair  ◎Focus│ [🏎] F1 Data Dashboard  │ │ [🖨] 3D Printer Calib.  │
│ hydroponics · nutrient   │ │ fastf1 · telemetry       │ │ gcode · PETG             │
│ 124 files  1.2 GB  in 3d │ │ 58 files  640 MB         │ │ 31 files  2.1 GB         │
│ ╱╲__╱╲___╱‾╲  (14 days)  │ │ ___╱‾‾╲____              │ │ ╲___________             │
└──────────────────────────┘ └──────────────────────────┘ └──────────────────────────┘
```
**Detail:** header (icon, name, files/size, due pill, tags, [Edit]); quick actions [Show all files]
[Run cleanup] [Generate summary] [Focus 90 min] [Archive]; AI summary card; tabs Files · Timeline (by day) · Rules ·
Tasks · Notes & links.

## 5. Tasks & Schedule

```
NEXUS // TASKS & SCHEDULE                                   [📅 New schedule]
(Timeline | Queue | Schedules)
┌ ⏰ Upcoming ───────────┐ ┌ ⚙ Running & queued ────┐ ┌ ✓ Recent ────────────────┐
│ Today                 │ │ ◌ Classify ~/Documents │ │ ✓ Weekly report   2.1s   │
│ 22:00 Run classific…📅│ │   Indexed 450 files…   │ │ ✗ Sync Backup  /Volumes… │
│ Sunday                │ │ ○ Scan for insights    │ │ ✓ “Invoices → Finance”   │
│ 09:00 Weekly report ⚡│ └────────────────────────┘ └──────────────────────────┘
```
**Queue:** a table (type icon, task, status pill, priority, duration, when, result) with a status filter. The
inspector shows attempts, result or error, [Retry] [Run now] [Cancel] and a monospaced log.
**Schedules:** cards for once / recurring (cron described in English) / conditional ("when folderCountAbove(~/Downloads)
50 AND hourAtLeast 20 · cooldown 720m"), next and last run, ▶ Run now, enable switch.

## 6. Insights & reports

```
NEXUS // INSIGHTS                                   [⟳ Scan now] [Reports ▾]
▍SUGGESTIONS
┌ 📥 38 unsorted files in ~/Downloads older than 7 days          [Sort now] [Reveal] Dismiss ┐
┌ 🪄 You moved PDFs with ‘lab’ from ~/Downloads to ~/Documents/School 5 times. Want a rule?  │
│    [Create rule] [Edit first] Dismiss                                                     ┘
┌ 🔗 These 12 files look like they belong to “Science Fair”      [Link 12 files] Dismiss     ┘
▍TRENDS
┌ Storage by type (bars) ───────┐ ┌ Storage by project (donut) ───┐
┌ New files by type, 8 weeks ───┐ ┌ Automation hits per rule (+min saved) ┐
┌ Folder size evolution (lines per watched folder) ──────────────────────┐
┌ Knowledge graph — top topics (tag cloud; click → search) ──────────────┐
```
**Report sheet:** Markdown preview with [Export Markdown] and [Export PDF].

## 7. Today · System Access · Settings

- **Today:** greeting and telemetry line; stat tiles (Handled today, Needs review, Automations this week, Time saved);
  a Focus card (progress ring or picker); Nexus noticed; review teaser; Coming up; Recent activity (Undo last).
- **System Access:** a card per permission (Full Disk Access, folders, Accessibility, Automation, Microphone, Speech,
  Calendar, Notifications) with a status pill, why it's needed, and [Allow…] / [Open Settings…]; plus the
  whole-Mac mode card.
- **Settings (⌘,):** General (login, Dock icon, hotbar mode, appearance, palette shortcut, notifications and quiet
  hours, report day), Voice (talk shortcut, auto-send, spoken confirmation, speak results, test mic), Folders,
  Intelligence (autopilot thresholds, OCR and speech, model provider), Taxonomy (categories table), Privacy (dry-run,
  sandbox, guard, reset index).
- **Keyboard & voice shortcuts (⌘/):** a two-column cheat sheet, voice first.
