# Where Nexus beats Siri — features & USPs

**Positioning:** Siri answers questions and flips settings. **Nexus does the work — on your files, across your
Mac, privately, and reversibly.** It's an agent with memory of *your* documents, not a voice remote.

## Where Siri falls short (and what Nexus does instead)

| Siri today | Nexus |
|---|---|
| Can't read your documents ("what's the deadline in my syllabus?") | **Ask your files:** on-device retrieval + LLM answers with numbered citations — ✅ |
| No notion of "this" — the file you're looking at | **Context awareness:** "file this", "summarize this", "tag these as science" use the Finder selection or the front app's document — ✅ |
| One-shot commands, no multi-step plans | **Multi-step plans with pronouns:** "find F1 files from this year, tag them, add them to a project" — ✅ |
| Acts immediately or not at all | **Preview → confirm → undo.** Spoken read-back ("Move 7 files… run it?"), batch undo from anywhere — ✅ |
| No background automation on file events | **Always-on rules** for downloads, drives, apps, disk space, idle, schedules, GitHub, Mail — ✅ |
| Doesn't learn how *you* organize | **Personal taxonomy:** learns from approvals, edits and manual moves; proposes rules for repeated habits — ✅ |
| Forgets everything between requests | **Knowledge graph:** files ↔ projects ↔ people ↔ topics ↔ dates; "related files" — ✅ |
| Cloud round-trips for many requests | **On-device:** Vision OCR, NaturalLanguage, sentence embeddings, Apple's on-device model or Ollama — ✅ |
| No project or deadline awareness | **Projects & Focus:** auto-association, calendar-inferred focus, routing, pre-warming — ✅ |
| Interrupts constantly or not at all | **Calm notifications:** batched digests, quiet hours, focus holds, only critical items break through — ✅ |
| Not scriptable | **Local API + CLI + sandboxed plugins + inbound webhooks** — ✅ |

## Killer features in this build

1. **Push-to-talk file agent.** Hold ⌥⇧Space in any app: "move the invoices from this week into Finance and tag them
   tax". Release; Nexus reads the plan back; say "run it".
2. **Ask your files.** "When is the invoice due and how much?" → "Due 2026-10-01, $420.00 [1]" with the source.
3. **"This" works everywhere.** Select files in Finder or open a PDF in Preview, press the hotkey: *File this* /
   *Summarize this*.
4. **Autopilot with a conscience.** Confidence-gated filing: automatic at ≥85%, a one-key Review card at ≥55%,
   otherwise it leaves things alone. Everything is journaled and undoable.
5. **Rules you can write in English and test before they run.** Simulator, test-on-folder, conflict detection, and a
   visual flow builder.
6. **Habit → automation.** "You moved PDFs with ‘lab’ to School 5 times. Want a rule?"
7. **Meeting prep.** Ten minutes before a calendar event, related files are gathered into an Insight and a notification.
8. **Morning briefing.** "Brief me": today's events, deadlines, what was filed, what needs you — spoken.
9. **Digital hygiene radar.** Duplicates, near-identical screenshots, stale downloads, folder growth, inactive
   projects, low disk — each with a one-click fix.
10. **Desktop hotbar + menu bar + palette.** Always one keystroke or one word away, never in the way.
11. **Runaway guard + protected paths + sandboxed scripts.** An agent you can trust with full disk access.

## Roadmap ideas (USP amplifiers)

- **Screen memory (opt-in):** OCR the active window every N minutes, stored locally with a retention window.
  "What was that API key format I saw this morning?" / "Find the chart from yesterday's Zoom."
- **Download provenance graph:** link each file to the page, email or Slack message it came from. "Where did I get this?"
- **Smart renaming:** "IMG_4412.jpg" → "2026-09-12 Hydroponics setup — grow tent.jpg" from OCR, EXIF and topics.
- **Version detective:** detect `final_v2_REAL.docx` chains; keep the latest, archive the rest, show a diff.
- **Semantic dedupe:** not just identical bytes — the same document exported twice (PDF vs DOCX), or re-downloads.
- **Deadline extraction everywhere:** syllabi, rubrics and invoices → Calendar with a link back to the source file.
- **Workspace snapshots:** "Set up for Science Fair" opens the right folders, docs, apps and Notion pages, and
  starts focus; "Pack up" archives and closes them.
- **Explain my Mac storage** in plain English, with a safe cleanup plan and a one-tap undo.
- **Voice macros:** "Nexus, when I say *wrap up*: compress today's screenshots, commit notes to Obsidian, generate
  the daily report."
- **Proactive privacy guard:** flag documents containing passports, bank or card numbers sitting in Downloads or
  Desktop, and offer to move them into an encrypted disk image.
- **Cross-device inbox:** share sheet on iPhone → Nexus inbox → filed on the Mac by the same rules.
- **App Intents / Shortcuts / Spotlight actions:** let Siri *delegate* to Nexus ("Hey Siri, ask Nexus to file my
  invoices").
- **Team rule packs:** signed, shareable rule templates (e.g. an "IB MYP student" pack or a "Freelancer invoices" pack).
