import XCTest
@testable import NexusCore

final class RuleCompilerTests: XCTestCase {
    let compiler = NLRuleCompiler(libraryRoot: "~/Documents", knownProjects: ["Science Fair"])

    func testLabReportRule() throws {
        let rule = try XCTUnwrap(compiler.compile("If a PDF in Downloads contains 'lab report' → move to School/Science/Reports, tag MYP3, add to project Science Fair.").rule)
        XCTAssertEqual(rule.trigger.kind, .fileAdded)
        XCTAssertEqual(rule.trigger.folders, [Paths.expand("~/Downloads")])
        XCTAssertTrue(rule.conditions.conditions.contains { $0.field == .ext && $0.value == "pdf" })
        XCTAssertTrue(rule.conditions.conditions.contains { $0.field == .anyText && $0.value == "lab report" })
        XCTAssertEqual(rule.actions.map(\.kind), [.move, .tag, .addToProject])
        XCTAssertEqual(rule.actions[0].target, Paths.expand("~/Documents/School/Science/Reports"))
        XCTAssertEqual(rule.actions[1].tags, ["MYP3"])
        XCTAssertEqual(rule.actions[2].project, "Science Fair")
    }

    func testPythonRule() throws {
        let rule = try XCTUnwrap(compiler.compile("If code file language is Python and folder is Downloads → move to Dev/Python, tag snippet.").rule)
        XCTAssertTrue(rule.conditions.conditions.contains { $0.field == .language && $0.value == "Python" })
        XCTAssertEqual(rule.actions.map(\.kind), [.move, .tag])
    }

    func testGoesToPhrasing() throws {
        let rule = try XCTUnwrap(compiler.compile("Create a rule: any PDF with 'MYP3' goes to School and gets tag science").rule)
        XCTAssertEqual(rule.actions.map(\.kind), [.move, .tag])
        XCTAssertEqual(rule.actions[1].tags, ["science"])
    }

    func testEventTriggers() throws {
        XCTAssertEqual(compiler.compile("When disk < 25GB → find large duplicate files and suggest cleanup").rule?.trigger.kind, .diskSpaceBelow)
        let drive = try XCTUnwrap(compiler.compile("When external drive 'Backup' is connected → sync Projects and School folders").rule)
        XCTAssertEqual(drive.trigger.volumeName, "Backup")
        XCTAssertEqual(drive.actions.filter { $0.kind == .syncFolder }.count, 2)
        let app = try XCTUnwrap(compiler.compile("When F1 TV app opens, prepare Media/F1 folder").rule)
        XCTAssertEqual(app.trigger.kind, .appLaunched)
        XCTAssertEqual(app.trigger.appName, "F1 TV")
        let count = try XCTUnwrap(compiler.compile("When Downloads has > 50 files and it's after 8 PM → auto-sort").rule)
        XCTAssertEqual(count.trigger.kind, .folderCountAbove)
        XCTAssertEqual(count.trigger.threshold, 50)
        XCTAssertTrue(count.conditions.conditions.contains { $0.field == .hour && $0.value == "19" })
    }

    func testQuotedAlternatives() throws {
        let rule = try XCTUnwrap(compiler.compile("If a PDF contains 'Science Fair' or 'hydroponics' → add to project Science Fair, tag science-fair").rule)
        XCTAssertEqual(rule.conditions.match, .all)
        XCTAssertTrue(rule.conditions.conditions.contains { $0.field == .anyText && $0.value == "Science Fair|hydroponics" })
    }

    func testScheduleRule() throws {
        let rule = try XCTUnwrap(compiler.compile("Every Sunday 9 AM: archive old screenshots, generate storage report").rule)
        XCTAssertEqual(rule.trigger.kind, .schedule)
        XCTAssertEqual(rule.trigger.cron, "0 9 * * 0")
        XCTAssertEqual(rule.actions.map(\.kind), [.archiveOld, .generateReport])
    }

    func testTrashRequiresConfirmation() throws {
        let r = compiler.compile("If a DMG in Downloads is older than 7 days → move to trash")
        XCTAssertEqual(r.rule?.requireConfirmation, true)
        XCTAssertTrue(r.rule?.conditions.conditions.contains { $0.field == .ageDays && $0.value == "7" } ?? false)
    }

    func testAllShippedExamplesCompile() {
        let examples = [
            "When Chrome download finishes and filename contains 'syllabus' → copy to School/Syllabi and create a calendar reminder",
            "When a new GitHub issue is assigned to me → create a task and a project folder",
            "When I get an email with 'lab report' attachment → save to School/Science/Reports and add deadline to Calendar",
            "When a Notion page is tagged MYP3 → mirror key metadata into Nexus project",
            "Invoices from Downloads → move to Finance/{year}, tag tax, rename to {date} Invoice",
            "Every night at 11pm: generate a markdown summary of today's new files per project",
            "Move STL files from Downloads to 3D Printing/Models and tag print-queue",
        ]
        for e in examples {
            let r = compiler.compile(e)
            XCTAssertNotNil(r.rule, e)
            XCTAssertFalse(r.warnings.contains { $0.hasPrefix("Didn’t understand") }, "\(e): \(r.warnings)")
        }
    }
}

final class CronTests: XCTestCase {
    func testNextWeekly() throws {
        let cal = Calendar(identifier: .gregorian)
        let cron = try XCTUnwrap(CronExpression("0 9 * * 0"))
        let wed = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
        let next = try XCTUnwrap(cron.next(after: wed, calendar: cal))
        let c = cal.dateComponents([.weekday, .hour, .minute, .day], from: next)
        XCTAssertEqual(c.weekday, 1); XCTAssertEqual(c.hour, 9); XCTAssertEqual(c.minute, 0); XCTAssertEqual(c.day, 20)
    }
    func testSteps() throws {
        let cron = try XCTUnwrap(CronExpression("*/15 * * * *"))
        XCTAssertEqual(cron.minutes, [0, 15, 30, 45])
        XCTAssertNil(CronExpression("61 * * * *"))
        XCTAssertEqual(CronExpression.describe("30 8 * * 1-5"), "Weekdays at 8:30 AM")
    }
    func testNaturalTime() {
        XCTAssertEqual(NLTime.parse("every weekday at 8:30am"), .cron("30 8 * * 1-5"))
        XCTAssertEqual(NLTime.parse("every 15 minutes"), .cron("*/15 * * * *"))
        if case .once(let d)? = NLTime.parse("tonight at 10 PM") {
            XCTAssertEqual(Calendar.current.component(.hour, from: d), 22)
        } else { XCTFail("tonight not parsed") }
    }
}

final class RuleEngineTests: XCTestCase {
    func testEvaluationAndStopProcessing() {
        let file = FileRecord(path: Paths.expand("~/Downloads/Invoice-2041.pdf"), kind: .pdf, size: 120_000, docType: "invoice", tags: ["tax"])
        var a = Rule(name: "A", trigger: Trigger(kind: .fileAdded, folders: ["~/Downloads"]),
                     conditions: ConditionGroup(conditions: [Condition(.ext, .equals, ".pdf"), Condition(.anyText, .contains, "amount due")]),
                     actions: [RuleAction(kind: .move, target: "~/Documents/Finance")], priority: 80)
        a.stopProcessing = true
        let b = Rule(name: "B", trigger: Trigger(kind: .fileAdded), conditions: ConditionGroup(conditions: [Condition(.docType, .equals, "invoice")]),
                     actions: [RuleAction(kind: .move, target: "~/Documents/Other")], priority: 10)
        let engine = RuleEngine()
        let ctx = RuleContext(file: file, content: "Total amount due: $40", trigger: .downloadCompleted)
        let evals = engine.evaluate(rules: [b, a], ctx: ctx)
        XCTAssertEqual(evals.first?.rule.name, "A")
        XCTAssertTrue(evals[0].fired)
        XCTAssertTrue(evals[1].skippedByStop)
        XCTAssertFalse(engine.analyzeConflicts([a, b]).isEmpty)
    }

    func testTemplates() {
        let f = FileRecord(path: "/tmp/scan.pdf", createdAt: Calendar.current.date(from: DateComponents(year: 2025, month: 3, day: 4))!, docType: "invoice")
        XCTAssertEqual(Templates.expand("/tmp/Finance/{year}/{month}", file: f, projectName: nil), "/tmp/Finance/2025/03")
        XCTAssertEqual(Templates.expand("{date} {docType}", file: f, projectName: nil), "2025-03-04 Invoice")
    }
}

final class CommandParserTests: XCTestCase {
    let parser = CommandParser(compiler: NLRuleCompiler(knownProjects: ["F1 Data Viz"]))

    func testMultiStep() {
        let steps = parser.parse("Find all files about F1 from this year, tag them F1, and add to project F1 Data Viz.")
        XCTAssertEqual(steps.count, 3)
        guard case .find = steps[0].intent, case .fileActions(let q1, let a1) = steps[1].intent, case .fileActions(let q2, let a2) = steps[2].intent else { return XCTFail("\(steps)") }
        XCTAssertTrue(q1.useLastResults && q2.useLastResults)
        XCTAssertEqual(a1.first?.tags, ["F1"])
        XCTAssertEqual(a2.first?.kind, .addToProject)
    }

    func testMoveAndTag() {
        let steps = parser.parse("Move all invoices from Downloads to Finance and tag them 'tax'.")
        XCTAssertEqual(steps.count, 2)
        guard case .fileActions(let q, let actions) = steps[0].intent else { return XCTFail() }
        XCTAssertEqual(q.folders, [Paths.expand("~/Downloads")])
        XCTAssertTrue(q.conditions.contains { $0.field == .docType && $0.value == "invoice" })
        XCTAssertEqual(actions.first?.kind, .move)
    }

    func testOtherIntents() {
        if case .summarizeFolder(let f) = parser.parse("Summarize what's in my STEM Projects folder")[0].intent { XCTAssertTrue(f.hasSuffix("STEM Projects")) } else { XCTFail() }
        if case .createRule = parser.parse("Create a rule: any PDF with 'MYP3' goes to School and gets tag science")[0].intent {} else { XCTFail() }
        if case .schedule(let c, _) = parser.parse("Run classification on Projects tonight at 10 PM")[0].intent { XCTAssertEqual(c, "Run classification on Projects") } else { XCTFail() }
        if case .organize = parser.parse("Organize Downloads")[0].intent {} else { XCTFail() }
        if case .undo = parser.parse("undo")[0].intent {} else { XCTFail() }
        if case .ask = parser.parse("When is my lab report due?")[0].intent {} else { XCTFail("question") }
        if case .find = parser.parse("which files mention hydroponics")[0].intent {} else { XCTFail("which files → search") }
        if case .briefing = parser.parse("brief me")[0].intent {} else { XCTFail("briefing") }
        if case .smartFile(let q) = parser.parse("file this")[0].intent { XCTAssertTrue(q.useContext) } else { XCTFail("file this") }
        if case .fileActions(let q, _) = parser.parse("tag these as science")[0].intent { XCTAssertTrue(q.useContext) } else { XCTFail("tag these") }
    }
}

final class ExecutorIntegrationTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nexus-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("NEXUS_HOME", tmp.appendingPathComponent("support").path, 1)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testIngestRuleMoveTagAndUndo() async throws {
        let inbox = tmp.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("lab-notes.txt")
        try "Lab report: hypothesis, procedure, materials and conclusion for the hydroponics experiment.".write(to: file, atomically: true, encoding: .utf8)

        let store = try NexusStore(path: tmp.appendingPathComponent("test.sqlite").path)
        var settings = NexusSettings()
        settings.watchedFolders = [inbox.path]
        settings.libraryRoots = [tmp.appendingPathComponent("Library").path]
        settings.llmProvider = .off
        store.saveSettings(settings)
        let engine = NexusEngine(store: store)

        let dest = tmp.appendingPathComponent("Library/School/Reports").path
        let rule = try XCTUnwrap(NLRuleCompiler(libraryRoot: tmp.appendingPathComponent("Library").path)
            .compile("If a file in \(inbox.path) contains 'hypothesis' → move to \(dest), tag science").rule)
        store.saveRule(rule)

        await engine.ingest(file.path, trigger: .fileAdded)
        let moved = (dest as NSString).appendingPathComponent("lab-notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        let rec = try XCTUnwrap(store.file(path: moved))
        XCTAssertEqual(rec.tags, ["science"])
        XCTAssertEqual(rec.docType, "lab report")
        XCTAssertEqual(store.rule(id: rule.id)?.hitCount, 1)
        XCTAssertEqual(store.searchFiles("hydroponics").first?.id, rec.id)

        let undone = engine.undoLast()
        XCTAssertEqual(undone, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store.file(id: rec.id)?.tags, [])
    }

    func testRunawayGuard() {
        let g = RunawayGuard(limitPerMinute: 3)
        XCTAssertTrue(g.allow()); XCTAssertTrue(g.allow()); XCTAssertTrue(g.allow())
        XCTAssertFalse(g.allow())
    }
}
