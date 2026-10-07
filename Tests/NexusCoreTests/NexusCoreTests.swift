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

    /// On battery, background jobs still run (one at a time) instead of waiting for AC power.
    func testBatteryRunsJobsSerially() async throws {
        let store = try NexusStore(path: tmp.appendingPathComponent("q.sqlite").path)
        let queue = TaskQueue(store: store)
        let lock = NSLock(); var active = 0, peak = 0
        queue.isThrottled = { true }
        queue.runner = { _, _ in
            lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
            try await Task.sleep(nanoseconds: 150_000_000)
            lock.lock(); active -= 1; lock.unlock()
            return "ok"
        }
        let jobs = (0..<3).map { i in queue.enqueue(Job(name: "index \(i)", kind: .ai, priority: .low, spec: JobSpec(operation: .scanInsights))) }
        queue.start()
        for _ in 0..<100 where !jobs.allSatisfy({ store.job(id: $0.id)?.status == .completed }) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(jobs.allSatisfy { store.job(id: $0.id)?.status == .completed })
        XCTAssertEqual(peak, 1)
    }

    /// Before first-run setup is finished, confident suggestions wait in the Review Queue instead of moving files.
    func testNoAutomaticMovesBeforeSetup() async throws {
        let inbox = tmp.appendingPathComponent("Downloads")
        let finance = tmp.appendingPathComponent("Library/Finance/Invoices")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finance, withIntermediateDirectories: true)
        try "INVOICE #1 amount due $10 invoice".write(to: finance.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let dup = inbox.appendingPathComponent("old copy.txt")
        try FileManager.default.copyItem(at: finance.appendingPathComponent("old.txt"), to: dup)

        let store = try NexusStore(path: tmp.appendingPathComponent("gate.sqlite").path)
        var settings = NexusSettings()
        settings.watchedFolders = [inbox.path]
        settings.libraryRoots = [tmp.appendingPathComponent("Library").path]
        settings.llmProvider = .off
        store.saveSettings(settings)
        store.setKV("seeded", "1")
        let engine = NexusEngine(store: store)
        engine.index(finance.appendingPathComponent("old.txt").path)

        await engine.ingest(dup.path, trigger: .fileAdded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dup.path), "duplicate must not be removed before setup")

        settings.onboardingComplete = true
        engine.updateSettings(settings)
        setenv("NEXUS_TRASH_DIR", tmp.appendingPathComponent("Trash").path, 1)
        await engine.ingest(dup.path, trigger: .fileAdded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dup.path), "duplicate is removed once setup is done")
    }

    func testRunawayGuard() {
        let g = RunawayGuard(limitPerMinute: 3)
        XCTAssertTrue(g.allow()); XCTAssertTrue(g.allow()); XCTAssertTrue(g.allow())
        XCTAssertFalse(g.allow())
    }
}

// MARK: - Formula 1 module

final class F1Tests: XCTestCase {
    private func service() -> F1Service {
        let s = F1Service()
        s.fixtures = Bundle.module.url(forResource: "fixtures/f1", withExtension: nil)
        return s
    }

    func testReadsLiveTiming() async throws {
        let f1 = service()
        let latest = await f1.latestSession()
        let session = try XCTUnwrap(latest)
        XCTAssertEqual(session.type, "Race")
        XCTAssertEqual(session.circuit, "Baku")

        let liveData = await f1.live()
        let live = try XCTUnwrap(liveData)
        XCTAssertFalse(live.rows.isEmpty)
        XCTAssertEqual(live.rows.map(\.position), live.rows.map(\.position).sorted())
        XCTAssertEqual(live.rows[0].gap, "LEADER")
        XCTAssertFalse(live.rows[0].driver.team.isEmpty)
        XCTAssertTrue(live.rows.contains { ["SOFT", "MEDIUM", "HARD"].contains($0.compound ?? "") })
        XCTAssertNotNil(live.weather)
        XCTAssertFalse(live.messages.isEmpty)
        XCTAssertTrue(F1Service.liveText(live, favourite: live.rows[0].driver.acronym).contains("Baku"))
    }

    func testFormatsLapTimes() {
        XCTAssertEqual(F1Row.format(108.488), "1:48.488")
        XCTAssertEqual(F1Row.format(58.9), "58.900")
    }

    func testReadsScheduleAndStandings() async throws {
        let f1 = service()
        let upcoming = await f1.nextRace()
        let next = try XCTUnwrap(upcoming)
        XCTAssertTrue(next.name.contains("Grand Prix"))
        XCTAssertEqual(next.sessions.last?.name, "Race")

        let drivers = await f1.driverStandings()
        let teams = await f1.constructorStandings()
        XCTAssertEqual(drivers.first?.position, 1)
        XCTAssertGreaterThanOrEqual(drivers[0].points, drivers[1].points)
        XCTAssertTrue(F1Service.standingsText(drivers, teams).contains(drivers[0].code))

        let (race, order) = await f1.lastResults()
        XCTAssertFalse(order.isEmpty)
        XCTAssertTrue(F1Service.resultsText(race, order).contains("P1"))
    }

    func testParsesF1Commands() {
        let parser = CommandParser(compiler: NLRuleCompiler())
        func kind(_ text: String) -> String? {
            if case .f1(let k)? = parser.parse(text).first?.intent { return k }
            return nil
        }
        XCTAssertEqual(kind("f1"), "auto")
        XCTAssertEqual(kind("f1 live timing"), "auto")
        XCTAssertEqual(kind("f1 standings"), "standings")
        XCTAssertEqual(kind("next race"), "next")
        XCTAssertEqual(kind("when is the next grand prix"), "next")
        XCTAssertEqual(kind("who won the last f1 race"), "results")
        XCTAssertEqual(kind("who is leading the race"), "auto")
        XCTAssertNil(kind("organize Downloads"))
        XCTAssertNil(kind("find my f1 telemetry notes"))
    }
}

// MARK: - Updater

final class UpdaterTests: XCTestCase {
    private var tmp: URL!
    private var store: NexusStore!

    override func setUp() {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nexus-upd-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("NEXUS_HOME", tmp.appendingPathComponent("support").path, 1)
        store = try! NexusStore(path: tmp.appendingPathComponent("u.sqlite").path)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func updater(_ current: String) -> Updater {
        let u = Updater(store: store, currentVersion: current)
        u.apiOverride = Bundle.module.url(forResource: "fixtures/release-latest", withExtension: "json")
        return u
    }

    func testComparesVersions() {
        XCTAssertEqual(Updater.compare("1.0.1", "1.0.0"), 1)
        XCTAssertEqual(Updater.compare("1.2.0", "1.10.0"), -1)
        XCTAssertEqual(Updater.compare("1.2.10", "1.2.9"), 1)
        XCTAssertEqual(Updater.compare("1.0.0", "1.0.0"), 0)
        XCTAssertEqual(Updater.compare("v1.1.0", "1.1"), 0)
        XCTAssertEqual(Updater.compare("1.0.0", "1.0.0-beta"), 1)
    }

    func testOffersNewerReleaseWithTheMacAsset() async throws {
        let u = updater("1.0.0")
        let found = await u.check()
        let release = try XCTUnwrap(found)
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.assetName, "Nexus-1.2.0.dmg")        // the .dmg, not the Windows installer
        XCTAssertEqual(u.state.stage, .available)
        XCTAssertNotNil(u.lastChecked)
        XCTAssertEqual(release.highlights.count, 2)
        XCTAssertFalse(release.highlights[0].contains("*"))       // markdown is stripped…
        XCTAssertFalse(release.highlights[0].contains("`"))
        XCTAssertTrue(release.highlights[0].hasPrefix("• Formula 1 module"))
        XCTAssertLessThanOrEqual(release.highlights[0].count, 122) // …and long lines are cut
    }

    func testUpToDateAndSkipping() async throws {
        let latest = await updater("1.2.0").check()
        XCTAssertNil(latest)
        let u = updater("1.0.0")
        u.skip("1.2.0")
        let auto = await u.check(automatic: true)
        XCTAssertNil(auto)                                 // not offered automatically…
        let manual = await u.check()
        XCTAssertNotNil(manual)                            // …but still available on demand
        u.unskip()
        let again = await u.check(automatic: true)
        XCTAssertNotNil(again)
    }

    func testChecksOffContactNothing() async {
        let u = updater("1.0.0")
        u.apiOverride = URL(fileURLWithPath: "/does/not/exist.json")
        let result = await u.check(automatic: true, enabled: false)
        XCTAssertNil(result)
        XCTAssertEqual(u.state.stage, .idle)
        XCTAssertNil(u.lastChecked)
    }

    func testFailedCheckIsReported() async {
        let u = updater("1.0.0")
        u.apiOverride = URL(fileURLWithPath: "/does/not/exist.json")
        let result = await u.check()
        XCTAssertNil(result)
        XCTAssertEqual(u.state.stage, .failed)
        XCTAssertTrue(u.state.message?.contains("Couldn't check") ?? false)
    }
}

// MARK: - Updater: download, verify, install (real files, real disk image)

final class UpdaterInstallTests: XCTestCase {
    private var tmp: URL!
    private var store: NexusStore!

    override func setUp() {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nexus-upi-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("NEXUS_HOME", tmp.appendingPathComponent("support").path, 1)
        store = try! NexusStore(path: tmp.appendingPathComponent("u.sqlite").path)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func release(file: URL, name: String, sums: URL?) -> ReleaseInfo {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        return ReleaseInfo(version: "9.9.9", name: "Nexus 9.9.9", notes: "- test", url: "https://example.invalid",
                           assetURL: file.absoluteString, assetName: name, assetSize: size, checksumsURL: sums?.absoluteString, publishedAt: Date())
    }

    func testDownloadVerifiesChecksum() async throws {
        let payload = tmp.appendingPathComponent("served.dmg")
        try Data((0..<400_000).map { UInt8($0 % 251) }).write(to: payload)
        let sha = try Updater.sha256(of: payload)
        let sums = tmp.appendingPathComponent("SHA256SUMS.txt")
        try "\(sha)  Nexus-9.9.9.dmg\n".write(to: sums, atomically: true, encoding: .utf8)

        let u = Updater(store: store, currentVersion: "1.0.0")
        let path = await u.download(release(file: payload, name: "Nexus-9.9.9.dmg", sums: sums))
        XCTAssertNotNil(path)
        XCTAssertEqual(u.state.stage, .ready)
        XCTAssertEqual(try Updater.sha256(of: URL(fileURLWithPath: path!)), sha)
    }

    func testTamperedDownloadIsRejectedAndDeleted() async throws {
        let payload = tmp.appendingPathComponent("served2.dmg")
        try Data(repeating: 7, count: 200_000).write(to: payload)
        let sums = tmp.appendingPathComponent("SHA256SUMS2.txt")
        try "\(String(repeating: "0", count: 64))  Nexus-bad.dmg\n".write(to: sums, atomically: true, encoding: .utf8)

        let u = Updater(store: store, currentVersion: "1.0.0")
        let path = await u.download(release(file: payload, name: "Nexus-bad.dmg", sums: sums))
        XCTAssertNil(path)
        XCTAssertEqual(u.state.stage, .failed)
        XCTAssertTrue(u.state.message?.contains("checksum") ?? false)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: Paths.appSupport.appendingPathComponent("Updates").path)) ?? []
        XCTAssertFalse(leftovers.contains("Nexus-bad.dmg"))
    }

    /// Builds a real .dmg containing a tiny "Nexus.app", then installs it over an older copy.
    func testInstallSwapsTheApp() throws {
        let fm = FileManager.default
        func makeApp(at dir: URL, marker: String) throws {
            let app = dir.appendingPathComponent("Nexus.app/Contents")
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            try marker.write(to: app.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        }
        let src = tmp.appendingPathComponent("dmgsrc")
        try makeApp(at: src, marker: "NEW 9.9.9")
        let dmg = tmp.appendingPathComponent("Nexus-9.9.9.dmg")
        let (made, out) = Shell.run("/usr/bin/hdiutil", ["create", "-srcfolder", src.path, "-volname", "Nexus", "-format", "UDZO", "-quiet", dmg.path], timeout: 300)
        XCTAssertEqual(made, 0, out)

        let apps = tmp.appendingPathComponent("Applications")
        try makeApp(at: apps, marker: "OLD 1.0.0")
        let target = apps.appendingPathComponent("Nexus.app").path

        let u = Updater(store: store, currentVersion: "1.0.0")
        XCTAssertTrue(u.install(dmg.path, appPath: target, relaunch: false))
        XCTAssertEqual(try String(contentsOfFile: target + "/Contents/version.txt", encoding: .utf8), "NEW 9.9.9")
        XCTAssertFalse(fm.fileExists(atPath: target + ".old"), "backup should be cleaned up")
        let hidden = (try fm.contentsOfDirectory(atPath: apps.path)).filter { $0.hasPrefix(".Nexus-update") }
        XCTAssertTrue(hidden.isEmpty, "staging copy should be gone")
    }

    func testInstallLeavesTheOldAppWhenTheImageIsBad() throws {
        let fm = FileManager.default
        let apps = tmp.appendingPathComponent("Applications")
        let old = apps.appendingPathComponent("Nexus.app/Contents")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try "OLD".write(to: old.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        let junk = tmp.appendingPathComponent("junk.dmg")
        try Data(repeating: 1, count: 4096).write(to: junk)

        let u = Updater(store: store, currentVersion: "1.0.0")
        XCTAssertFalse(u.install(junk.path, appPath: apps.appendingPathComponent("Nexus.app").path, relaunch: false))
        XCTAssertEqual(u.state.stage, .failed)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("version.txt"), encoding: .utf8), "OLD")
    }
}

// MARK: - Power policy

final class PowerPolicyTests: XCTestCase {
    private func snapshot(ac: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState = .nominal) -> SystemSnapshot {
        SystemSnapshot(diskFreeGB: 100, diskTotalGB: 500, idleSeconds: 0, onACPower: ac, lowPowerMode: lowPower, thermalState: thermal, mountedVolumes: [])
    }

    /// Battery and Low Power Mode slow background work down; only real overheating pauses it.
    /// (Pausing in Low Power Mode meant library indexing never ran, so search found nothing.)
    func testLowPowerModeThrottlesButDoesNotPause() {
        XCTAssertFalse(snapshot(ac: true, lowPower: false).shouldThrottle)
        XCTAssertTrue(snapshot(ac: false, lowPower: false).shouldThrottle)
        XCTAssertTrue(snapshot(ac: true, lowPower: true).shouldThrottle)
        XCTAssertFalse(snapshot(ac: false, lowPower: true).underPressure)
        XCTAssertTrue(snapshot(ac: true, lowPower: false, thermal: .serious).underPressure)
        XCTAssertTrue(snapshot(ac: true, lowPower: false, thermal: .critical).shouldThrottle)
    }
}
