# Natural language → rules (15 worked examples)

Every example below is the **real output** of Nexus's compiler (`nexusctl compile "<sentence>"`), and the
test suite covers them (`Tests/NexusCoreTests`). Relative folders resolve under your first library root (`~/Documents`).
The compiler is deterministic. Only when it can't parse a sentence does the on-device model rewrite it into this grammar.

Structure: **Trigger** · **Conditions** (ALL unless you say "or") · **Actions** (run in order; file actions follow the file).

## Simple file rules

**1. “If a PDF in Downloads contains ‘lab report’ → move to School/Science/Reports, tag MYP3, add to project Science Fair”**
```yaml
trigger: fileAdded [~/Downloads]
if (all): anyText contains "lab report"; ext equals "pdf"
then: move → ~/Documents/School/Science/Reports; tag [MYP3]; addToProject "Science Fair"
```

**2. “If code file language is Python and folder is Downloads → move to Dev/Python, tag snippet”**
```yaml
trigger: fileAdded [~/Downloads]
if: language equals "Python"
then: move → ~/Documents/Dev/Python; tag [snippet]
```

**3. “Any PDF with ‘MYP3’ goes to School and gets tag science”** (the "goes to" phrasing works too)
```yaml
trigger: fileAdded [all watched folders]
if: anyText contains "MYP3"; ext equals "pdf"
then: move → ~/Documents/School; tag [science]
```

**4. “Invoices from Downloads → move to Finance/{year}, tag tax, rename to {date} Invoice”** (uses document understanding, not filenames)
```yaml
trigger: fileAdded [~/Downloads]
if: docType equals "invoice"
then: move → ~/Documents/Finance/{year}; tag [tax]; rename "{date} Invoice"   # → Finance/2026/2026-09-16 Invoice.pdf
```

**5. “Move STL files from Downloads to 3D Printing/Models and tag print-queue”** (imperative phrasing)
```yaml
trigger: fileAdded [~/Downloads]
if: ext isAnyOf "stl,3mf,obj"
then: move → ~/Documents/3D Printing/Models; tag [print-queue]
```

**6. “Screenshots older than 30 days in Desktop → move to ~/Pictures/Screenshots/{year}/{month}”** (age rules are also swept hourly)
```yaml
trigger: fileAdded [~/Desktop]
if: kind equals "screenshot"; ageDays > 30
then: move → ~/Pictures/Screenshots/{year}/{month}
```

## Project-aware rules

**7. “If a PDF contains ‘Science Fair’ or ‘hydroponics’ → add to project Science Fair, tag science-fair”**
```yaml
trigger: fileAdded [all watched folders]
if (all): anyText contains "Science Fair|hydroponics"; ext equals "pdf"
then: addToProject "Science Fair"; tag [science-fair]
projectId: <Science Fair>   # rule shows on the project dashboard
```

**8. “When I get an email with ‘lab report’ attachment → save to School/Science/Reports and add deadline to Calendar”**
```yaml
trigger: connectorEvent mail.attachment [Nexus/Inbox/Mail]   # Mail rule → AppleScript bridge
if: anyText contains "lab report"
then: move → ~/Documents/School/Science/Reports
      createCalendarEvent "Deadline: {basename}" (uses the first future date found inside the document)
```

## Multi-step & event-driven automations

**9. “When Chrome download finishes and filename contains ‘syllabus’ → copy to School/Syllabi and create a calendar reminder”**
```yaml
trigger: downloadCompleted [~/Downloads]
if: name contains "syllabus"
then: copy → ~/Documents/School/Syllabi; createReminder "Review {name}" due +1d
```

**10. “When external drive ‘Backup’ is connected → sync Projects and School folders”**
```yaml
trigger: volumeMounted "Backup"   cooldown: 30 min
then: syncFolder ~/Documents/Projects → /Volumes/Backup/Nexus Sync/Projects
      syncFolder ~/Documents/School   → /Volumes/Backup/Nexus Sync/School    # rsync -a, additive
```

**11. “When disk < 25GB → find large duplicate files and suggest cleanup”**
```yaml
trigger: diskSpaceBelow 25 GB   cooldown: 30 min
then: findDuplicates (large only); notify "Cleanup suggestions are ready in Insights"
```

**12. “When Downloads has > 50 files and it’s after 8 PM → auto-sort”** (conditional)
```yaml
trigger: folderCountAbove ~/Downloads > 50   # checked every 5 min
if: hour > 19
then: sortFolder ~/Downloads   # rules first, then learned destinations; uncertain files → Review
```

**13. “When F1 TV app opens, prepare Media/F1 folder”**
```yaml
trigger: appLaunched "F1 TV"
then: createFolder ~/Documents/Media/F1; revealInFinder ~/Documents/Media/F1
```

**14. “Every Sunday 9 AM: archive old screenshots, generate storage report”** (scheduled)
```yaml
trigger: schedule cron "0 9 * * 0"   # "Every Sunday at 9:00 AM"
then: archiveOld {folder: ~/Desktop, kind: screenshot, days: 30} → ~/Documents/Archive/Screenshots/{year}
      generateReport storage
```

**15. “When a new GitHub issue is assigned to me → create a task and a project folder”** (connector)
```yaml
trigger: connectorEvent github.issueAssigned   # polled every 5 min with your token
then: createTask "Follow up: {title}"; createFolder ~/Documents/Projects/{title}
```

### Bonus: safety defaults the compiler adds
- “If a DMG in Downloads is older than 7 days → move to trash” sets `requireConfirmation: true`, so each file goes to the Review Queue first.
- A rule with no folder and no conditions gets a warning ("would match every new file").
- Event rules get a 30-minute cooldown.

## Palette commands (not rules)
| You type or say | Steps |
|---|---|
| Move all invoices from Downloads to Finance and tag them ‘tax’ | fileActions(docType=invoice in ~/Downloads → move) → fileActions(them → tag tax) |
| Show me everything related to ‘hydroponics’ in the last 3 months | find(anyText≈hydroponics via FTS + embeddings, age < 90d) |
| Summarize what’s in my STEM Projects folder | summarizeFolder(~/Documents/STEM Projects) |
| Find all files about F1 from this year, tag them F1, and add to project F1 Data Viz | find → tag(them) → addToProject(them) |
| Run classification on Projects tonight at 10 PM | schedule(once 22:00, “Run classification on Projects”) |
| When is the invoice due and how much is it? | ask → “Due on 2026-10-01, $420.00 [1]” with sources |
| File this / summarize this | uses the Finder selection or the front app's document |
| Brief me | spoken daily briefing |
