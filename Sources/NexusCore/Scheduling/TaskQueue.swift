import Foundation

/// Handle given to running jobs for logging and cooperative cancellation.
public final class JobContext {
    public let jobId: String
    private let store: NexusStore
    private let lock = NSLock()
    private var _cancelled = false
    public init(jobId: String, store: NexusStore) { self.jobId = jobId; self.store = store }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    public func log(_ line: String) {
        guard var j = store.job(id: jobId) else { return }
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        j.log.append("[\(ts)] \(line)")
        if j.log.count > 400 { j.log.removeFirst(j.log.count - 400) }
        store.saveJob(j)
    }
}

/// Persistent priority queue. Jobs survive restarts; failures retry with exponential backoff.
public final class TaskQueue {
    public typealias Runner = (Job, JobContext) async throws -> String

    let store: NexusStore
    public var runner: Runner?
    public var maxConcurrent = 2
    /// When true (battery / thermal pressure) only high & focus priority jobs start.
    public var isThrottled: () -> Bool = { false }
    public var isPaused: () -> Bool = { false }
    public var onActivityChange: ((Int) -> Void)?

    private var running: [String: (Task<Void, Never>, JobContext)] = [:]
    private let queue = DispatchQueue(label: "app.nexus.taskqueue")
    private var timer: DispatchSourceTimer?

    public init(store: NexusStore) { self.store = store }

    private let countLock = NSLock()
    private var _runningCount = 0
    /// Safe to read from any thread, including from inside queue callbacks.
    public var runningCount: Int { countLock.lock(); defer { countLock.unlock() }; return _runningCount }
    private func syncCount() { countLock.lock(); _runningCount = running.count; countLock.unlock() }

    public func start() {
        store.recoverInterruptedJobs()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    @discardableResult
    public func enqueue(_ job: Job) -> Job {
        var j = job
        if j.scheduledFor > Date() { j.status = .scheduled }
        store.saveJob(j)
        queue.async { [weak self] in self?.pump() }
        return j
    }

    public func cancel(_ id: String) {
        queue.async {
            if let (task, ctx) = self.running[id] { ctx.cancel(); task.cancel() }
            if var j = self.store.job(id: id), [.queued, .scheduled, .running].contains(j.status) {
                j.status = .cancelled
                j.finishedAt = Date()
                self.store.saveJob(j)
            }
        }
    }

    public func retry(_ id: String) {
        guard var j = store.job(id: id) else { return }
        j.status = .queued
        j.scheduledFor = Date()
        j.error = nil
        j.attempts = 0
        j.log.append("— manual retry —")
        enqueue(j)
    }

    public func runNow(_ id: String) {
        guard var j = store.job(id: id) else { return }
        j.scheduledFor = Date()
        j.status = .queued
        j.priority = max(j.priority, .high)
        enqueue(j)
    }

    private func pump() {
        guard runner != nil, !isPaused() else { return }
        let slots = maxConcurrent - running.count
        guard slots > 0 else { return }
        let throttled = isThrottled()
        for var job in store.dueJobs(limit: slots + 10) where running[job.id] == nil {
            if running.count >= maxConcurrent { break }
            if throttled && job.priority < .high { continue }
            job.status = .running
            job.startedAt = Date()
            job.attempts += 1
            store.saveJob(job)
            store.log(ActivityEvent(kind: .jobStarted, message: "Started: \(job.name)", jobId: job.id))
            let ctx = JobContext(jobId: job.id, store: store)
            let jobCopy = job
            let pri: TaskPriority = job.priority >= .high ? .userInitiated : .utility
            let task: Task<Void, Never> = Task.detached(priority: pri) { [weak self] in
                guard let self else { return }
                await self.execute(jobCopy, ctx)
            }
            running[job.id] = (task, ctx)
            syncCount()
        }
        onActivityChange?(running.count)
    }

    private func execute(_ job: Job, _ ctx: JobContext) async {
        do {
            guard let runner else { throw LLMError("no runner") }
            let summary = try await runner(job, ctx)
            if var j = store.job(id: job.id), j.status != .cancelled {
                j.status = ctx.isCancelled ? .cancelled : .completed
                j.finishedAt = Date()
                j.resultSummary = summary
                store.saveJob(j)
                store.log(ActivityEvent(kind: .jobCompleted, message: "\(job.name): \(summary)", jobId: job.id))
            }
        } catch {
            if var j = store.job(id: job.id), j.status != .cancelled {
                j.error = error.localizedDescription == "The operation couldn’t be completed." ? String(describing: error) : error.localizedDescription
                j.log.append("✖︎ \(j.error ?? "")")
                if j.attempts < j.maxAttempts {
                    let delay = pow(2, Double(j.attempts)) * 30
                    j.status = .scheduled
                    j.scheduledFor = Date().addingTimeInterval(delay)
                    j.log.append("Retrying in \(Int(delay))s (attempt \(j.attempts + 1)/\(j.maxAttempts))")
                } else {
                    j.status = .failed
                    j.finishedAt = Date()
                    store.log(ActivityEvent(kind: .jobFailed, message: "\(job.name) failed: \(j.error ?? "")", jobId: job.id))
                }
                store.saveJob(j)
            }
        }
        queue.async { [weak self] in
            self?.running[job.id] = nil
            self?.syncCount()
            self?.onActivityChange?(self?.running.count ?? 0)
            self?.pump()
        }
    }
}

/// Turns schedules (once / cron / conditional) and time-based rules into queued jobs.
public final class Scheduler {
    let store: NexusStore
    let queue: TaskQueue
    public var systemSnapshot: () -> SystemSnapshot = { SystemMonitor.sample() }
    /// Called for rules whose trigger is time/threshold based and is due now.
    public var fireRule: ((Rule, [String: String]) -> Void)?
    /// Periodic maintenance hooks (insights, taxonomy, snapshots, sweeps).
    public var maintenance: [(name: String, interval: TimeInterval, run: () -> Void)] = []

    private var timer: DispatchSourceTimer?
    private var lastMaintenance: [String: Date] = [:]
    private let dq = DispatchQueue(label: "app.nexus.scheduler", qos: .utility)

    public init(store: NexusStore, queue: TaskQueue) { self.store = store; self.queue = queue }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: dq)
        t.schedule(deadline: .now() + 3, repeating: 30, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func tickNow() { dq.async { self.tick() } }

    func tick(now: Date = Date()) {
        for var s in store.schedules() where s.enabled {
            switch s.mode {
            case .once:
                guard let at = s.runAt, at <= now, s.lastRunAt == nil else { continue }
                enqueue(s, now: now)
                s.lastRunAt = now
                s.enabled = false
                s.nextRunAt = nil
                store.saveSchedule(s)
            case .recurring:
                guard let cronText = s.cron, let cron = CronExpression(cronText) else { continue }
                if s.nextRunAt == nil { s.nextRunAt = cron.next(after: now.addingTimeInterval(-1)); store.saveSchedule(s); continue }
                guard let next = s.nextRunAt, next <= now else { continue }
                enqueue(s, now: now)
                s.lastRunAt = now
                s.nextRunAt = cron.next(after: now)
                store.saveSchedule(s)
            case .conditional:
                if let last = s.lastRunAt, now.timeIntervalSince(last) < Double(s.cooldownMinutes) * 60 { continue }
                guard !s.conditions.isEmpty, s.conditions.allSatisfy({ holds($0, now: now) }) else { continue }
                enqueue(s, now: now)
                s.lastRunAt = now
                store.saveSchedule(s)
            }
        }

        // Rules with schedule / threshold triggers
        for rule in store.rules() where rule.enabled {
            let key = "rule-next:\(rule.id)"
            switch rule.trigger.kind {
            case .schedule:
                guard let cronText = rule.trigger.cron, let cron = CronExpression(cronText) else { continue }
                guard let nextText = store.kv(key), let next = Double(nextText).map(Date.init(timeIntervalSince1970:)) else {
                    if let n = cron.next(after: now) { store.setKV(key, String(n.timeIntervalSince1970)) }
                    continue
                }
                if next <= now {
                    if let n = cron.next(after: now) { store.setKV(key, String(n.timeIntervalSince1970)) }
                    fireRule?(rule, ["scheduledFor": ISO8601DateFormatter().string(from: next)])
                }
            case .folderCountAbove, .folderSizeAbove:
                if let last = rule.lastTriggeredAt, now.timeIntervalSince(last) < Double(max(rule.cooldownMinutes, 30)) * 60 { continue }
                guard let folder = rule.trigger.folders.first.map(Paths.expand) else { continue }
                // count checks every 5 min, size scans (expensive) every 30 min
                let checkKey = "rule-check:\(rule.id)"
                let interval: TimeInterval = rule.trigger.kind == .folderCountAbove ? 300 : 1800
                if let lastCheck = store.kv(checkKey).flatMap(Double.init), now.timeIntervalSince1970 - lastCheck < interval { continue }
                store.setKV(checkKey, String(now.timeIntervalSince1970))
                let exceeded: Bool
                if rule.trigger.kind == .folderCountAbove {
                    exceeded = Double(SystemMonitor.topLevelCount(folder)) > (rule.trigger.threshold ?? 50)
                } else {
                    exceeded = Double(SystemMonitor.folderStats(folder).size) / 1_000_000_000 > (rule.trigger.threshold ?? 10)
                }
                if exceeded { fireRule?(rule, ["folder": folder]) }
            default: continue
            }
        }

        for m in maintenance {
            if let last = lastMaintenance[m.name], now.timeIntervalSince(last) < m.interval { continue }
            lastMaintenance[m.name] = now
            m.run()
        }
    }

    func holds(_ c: SystemCondition, now: Date) -> Bool {
        let cal = Calendar.current
        switch c.kind {
        case .folderCountAbove: return Double(SystemMonitor.topLevelCount(Paths.expand(c.folder ?? "~/Downloads"))) > c.number
        case .folderSizeAboveGB: return Double(SystemMonitor.folderStats(Paths.expand(c.folder ?? "~/Downloads")).size) / 1_000_000_000 > c.number
        case .hourAtLeast: return Double(cal.component(.hour, from: now)) >= c.number
        case .hourBefore: return Double(cal.component(.hour, from: now)) < c.number
        case .weekdayIs: return Double(cal.component(.weekday, from: now)) == c.number
        case .diskFreeBelowGB: return systemSnapshot().diskFreeGB < c.number
        case .onACPower: return systemSnapshot().onACPower == (c.number >= 1)
        case .idleMinutesAtLeast: return systemSnapshot().idleSeconds / 60 >= c.number
        }
    }

    func enqueue(_ s: Schedule, now: Date) {
        queue.enqueue(Job(name: s.name, kind: s.jobKind, priority: s.priority, spec: s.job, scheduleId: s.id, scheduledFor: now))
    }

    /// Upcoming occurrences across schedules and scheduled rules (for the timeline view).
    public func upcoming(limit: Int = 30, horizonDays: Int = 14, now: Date = Date()) -> [(date: Date, name: String, scheduleId: String?, ruleId: String?)] {
        var out: [(Date, String, String?, String?)] = []
        let horizon = now.addingTimeInterval(Double(horizonDays) * 86400)
        for s in store.schedules() where s.enabled {
            switch s.mode {
            case .once: if let at = s.runAt, at >= now.addingTimeInterval(-60) { out.append((at, s.name, s.id, nil)) }
            case .recurring:
                guard let cron = s.cron.flatMap(CronExpression.init) else { continue }
                var t = now
                for _ in 0..<5 { guard let n = cron.next(after: t), n < horizon else { break }; out.append((n, s.name, s.id, nil)); t = n }
            case .conditional: out.append((now, "\(s.name) (when conditions hold)", s.id, nil))
            }
        }
        for r in store.rules() where r.enabled && r.trigger.kind == .schedule {
            guard let cron = r.trigger.cron.flatMap(CronExpression.init) else { continue }
            var t = now
            for _ in 0..<5 { guard let n = cron.next(after: t), n < horizon else { break }; out.append((n, r.name, nil, r.id)); t = n }
        }
        return out.sorted { $0.0 < $1.0 }.prefix(limit).map { (date: $0.0, name: $0.1, scheduleId: $0.2, ruleId: $0.3) }
    }
}
