import Foundation

public func newID() -> String { UUID().uuidString.lowercased() }

// MARK: - Files

public enum FileStatus: String, Codable, CaseIterable {
    case indexed      // known, no action needed / not yet decided
    case review       // waiting in the Review Queue
    case filed        // moved/tagged by a rule or autopilot
    case ignored      // low confidence, logged only
    case missing      // no longer on disk
}

public enum FileKind: String, Codable, CaseIterable {
    case pdf, document, spreadsheet, presentation, text, code, image, screenshot, audio, video, archive, installer, cad, folder, other
}

public enum EntityKind: String, Codable, CaseIterable {
    case person, organization, place, date, project, course, money, url, email
}

public struct Entity: Codable, Hashable {
    public var kind: EntityKind
    public var value: String
    public init(kind: EntityKind, value: String) { self.kind = kind; self.value = value }
}

public struct FileRecord: Codable, Identifiable, Hashable {
    public var id: String
    public var path: String
    public var kind: FileKind
    public var size: Int64
    public var createdAt: Date
    public var modifiedAt: Date
    public var indexedAt: Date
    public var contentHash: String?
    public var docType: String?          // invoice, lab report, spec, screenshot, ...
    public var language: String?         // code language or natural language
    public var topics: [String]
    public var entities: [Entity]
    public var snippet: String           // first ~400 chars of extracted text
    public var summary: String?
    public var tags: [String]
    public var projectId: String?
    public var category: String?
    public var confidence: Double
    public var status: FileStatus
    public var sourceURL: String?        // kMDItemWhereFroms (download origin)
    public var perceptualHash: UInt64?   // images only (near-duplicate detection)

    public var name: String { (path as NSString).lastPathComponent }
    public var ext: String { (path as NSString).pathExtension.lowercased() }
    public var folder: String { (path as NSString).deletingLastPathComponent }

    public init(id: String = newID(), path: String, kind: FileKind = .other, size: Int64 = 0,
                createdAt: Date = Date(), modifiedAt: Date = Date(), indexedAt: Date = Date(),
                contentHash: String? = nil, docType: String? = nil, language: String? = nil,
                topics: [String] = [], entities: [Entity] = [], snippet: String = "", summary: String? = nil,
                tags: [String] = [], projectId: String? = nil, category: String? = nil,
                confidence: Double = 0, status: FileStatus = .indexed, sourceURL: String? = nil,
                perceptualHash: UInt64? = nil) {
        self.id = id; self.path = path; self.kind = kind; self.size = size
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.indexedAt = indexedAt
        self.contentHash = contentHash; self.docType = docType; self.language = language
        self.topics = topics; self.entities = entities; self.snippet = snippet; self.summary = summary
        self.tags = tags; self.projectId = projectId; self.category = category
        self.confidence = confidence; self.status = status; self.sourceURL = sourceURL
        self.perceptualHash = perceptualHash
    }
}

public struct Tag: Codable, Identifiable, Hashable {
    public var name: String
    public var color: String
    public var createdAt: Date
    public var id: String { name }
    public init(name: String, color: String = "#8E8E93", createdAt: Date = Date()) {
        self.name = name; self.color = color; self.createdAt = createdAt
    }
}

public struct Category: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var destination: String       // folder files of this category are routed to
    public var keywords: [String]
    public var docTypes: [String]
    public var learned: Bool             // discovered by the taxonomy learner vs. user defined
    public init(id: String = newID(), name: String, destination: String, keywords: [String] = [], docTypes: [String] = [], learned: Bool = false) {
        self.id = id; self.name = name; self.destination = destination
        self.keywords = keywords; self.docTypes = docTypes; self.learned = learned
    }
}

// MARK: - Projects

public struct ProjectLink: Codable, Hashable, Identifiable {
    public var id: String = newID()
    public var title: String
    public var url: String
    public init(title: String, url: String) { self.title = title; self.url = url }
}

public struct Project: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var color: String
    public var icon: String              // SF Symbol name
    public var folders: [String]
    public var keywords: [String]
    public var tags: [String]
    public var deadline: Date?
    public var notes: String
    public var links: [ProjectLink]
    public var archived: Bool
    public var createdAt: Date
    public var lastActivityAt: Date?

    public init(id: String = newID(), name: String, color: String = "#5E5CE6", icon: String = "folder.fill",
                folders: [String] = [], keywords: [String] = [], tags: [String] = [], deadline: Date? = nil,
                notes: String = "", links: [ProjectLink] = [], archived: Bool = false, createdAt: Date = Date(),
                lastActivityAt: Date? = nil) {
        self.id = id; self.name = name; self.color = color; self.icon = icon; self.folders = folders
        self.keywords = keywords; self.tags = tags; self.deadline = deadline; self.notes = notes
        self.links = links; self.archived = archived; self.createdAt = createdAt; self.lastActivityAt = lastActivityAt
    }
}

// MARK: - Jobs (tasks) & schedules

public enum JobKind: String, Codable, CaseIterable { case file, ai, script, integration, system }
public enum JobStatus: String, Codable, CaseIterable { case scheduled, queued, running, completed, failed, cancelled }
public enum JobPriority: Int, Codable, CaseIterable, Comparable {
    case low = 0, normal = 1, high = 2, focus = 3
    public static func < (a: JobPriority, b: JobPriority) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["Low", "Normal", "High", "Focus"][rawValue] }
}

public enum JobOperation: String, Codable, CaseIterable {
    case ingestFile          // extract + classify + rules for one path
    case classifyFolder      // (re)index a folder
    case runRule             // run one rule against its trigger folders
    case runActions          // run explicit actions against `paths`
    case runCommand          // natural-language command
    case summarizeFolder
    case generateReport
    case findDuplicates
    case archiveOld          // move files older than N days to an archive folder
    case sortFolder          // autopilot-sort every file in a folder
    case scanInsights
    case syncFolder
    case runShell
    case runShortcut
    case learnTaxonomy
    case prewarmProject
}

public struct JobSpec: Codable, Hashable {
    public var operation: JobOperation
    public var path: String?
    public var paths: [String]
    public var ruleId: String?
    public var actions: [RuleAction]
    public var command: String?
    public var params: [String: String]
    public init(operation: JobOperation, path: String? = nil, paths: [String] = [], ruleId: String? = nil,
                actions: [RuleAction] = [], command: String? = nil, params: [String: String] = [:]) {
        self.operation = operation; self.path = path; self.paths = paths; self.ruleId = ruleId
        self.actions = actions; self.command = command; self.params = params
    }
}

public struct Job: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: JobKind
    public var status: JobStatus
    public var priority: JobPriority
    public var spec: JobSpec
    public var scheduleId: String?
    public var createdAt: Date
    public var scheduledFor: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var attempts: Int
    public var maxAttempts: Int
    public var log: [String]
    public var resultSummary: String?
    public var error: String?

    public var duration: TimeInterval? {
        guard let s = startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(s)
    }

    public init(id: String = newID(), name: String, kind: JobKind, status: JobStatus = .queued, priority: JobPriority = .normal,
                spec: JobSpec, scheduleId: String? = nil, createdAt: Date = Date(), scheduledFor: Date = Date(),
                maxAttempts: Int = 3) {
        self.id = id; self.name = name; self.kind = kind; self.status = status; self.priority = priority
        self.spec = spec; self.scheduleId = scheduleId; self.createdAt = createdAt; self.scheduledFor = scheduledFor
        self.attempts = 0; self.maxAttempts = maxAttempts; self.log = []
    }
}

public enum ScheduleMode: String, Codable, CaseIterable { case once, recurring, conditional }

public enum SystemConditionKind: String, Codable, CaseIterable {
    case folderCountAbove, folderSizeAboveGB, hourAtLeast, hourBefore, weekdayIs, diskFreeBelowGB, onACPower, idleMinutesAtLeast
}

public struct SystemCondition: Codable, Hashable, Identifiable {
    public var id: String = newID()
    public var kind: SystemConditionKind
    public var folder: String?
    public var number: Double
    public init(kind: SystemConditionKind, folder: String? = nil, number: Double = 0) {
        self.kind = kind; self.folder = folder; self.number = number
    }
}

public struct Schedule: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var mode: ScheduleMode
    public var cron: String?             // recurring
    public var runAt: Date?              // once
    public var conditions: [SystemCondition] // conditional (all must hold)
    public var jobKind: JobKind
    public var job: JobSpec
    public var priority: JobPriority
    public var enabled: Bool
    public var cooldownMinutes: Int      // conditional: min gap between runs
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var createdAt: Date
    public var naturalLanguage: String?

    public init(id: String = newID(), name: String, mode: ScheduleMode, cron: String? = nil, runAt: Date? = nil,
                conditions: [SystemCondition] = [], jobKind: JobKind = .file, job: JobSpec, priority: JobPriority = .normal,
                enabled: Bool = true, cooldownMinutes: Int = 60, createdAt: Date = Date(), naturalLanguage: String? = nil) {
        self.id = id; self.name = name; self.mode = mode; self.cron = cron; self.runAt = runAt
        self.conditions = conditions; self.jobKind = jobKind; self.job = job; self.priority = priority
        self.enabled = enabled; self.cooldownMinutes = cooldownMinutes; self.createdAt = createdAt
        self.naturalLanguage = naturalLanguage
    }
}

// MARK: - Activity log (with undo journal)

public enum EventKind: String, Codable, CaseIterable {
    case fileIndexed, fileMoved, fileCopied, fileRenamed, fileTagged, fileTrashed, fileCompressed
    case ruleFired, jobStarted, jobCompleted, jobFailed, review, insight, command, system, connector, focus, undo, error, guardTripped
}

public struct UndoRecord: Codable, Hashable {
    public enum Op: String, Codable { case move, copy, rename, tag, untag, project, trash, createFile }
    public var op: Op
    public var from: String?
    public var to: String?
    public var tags: [String]
    public var fileId: String?
    public var previousProjectId: String?
    public init(op: Op, from: String? = nil, to: String? = nil, tags: [String] = [], fileId: String? = nil, previousProjectId: String? = nil) {
        self.op = op; self.from = from; self.to = to; self.tags = tags; self.fileId = fileId; self.previousProjectId = previousProjectId
    }
}

public struct ActivityEvent: Codable, Identifiable, Hashable {
    public var id: String
    public var timestamp: Date
    public var kind: EventKind
    public var message: String
    public var fileId: String?
    public var ruleId: String?
    public var jobId: String?
    public var batchId: String?          // groups ops so a whole command/rule run can be undone at once
    public var undo: UndoRecord?
    public var undone: Bool
    public init(id: String = newID(), timestamp: Date = Date(), kind: EventKind, message: String, fileId: String? = nil,
                ruleId: String? = nil, jobId: String? = nil, batchId: String? = nil, undo: UndoRecord? = nil, undone: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.message = message; self.fileId = fileId
        self.ruleId = ruleId; self.jobId = jobId; self.batchId = batchId; self.undo = undo; self.undone = undone
    }
}

// MARK: - Insights & review

public enum InsightKind: String, Codable, CaseIterable {
    case staleDownloads, duplicates, similarScreenshots, folderGrowth, inactiveProject, lowDisk, patternRule
    case projectAssociation, largeFiles, reviewBacklog, ruleConflict, deadlineSoon, weeklyDigest
}

public enum InsightSeverity: Int, Codable, CaseIterable, Comparable {
    case info = 0, suggestion = 1, warning = 2, critical = 3
    public static func < (a: InsightSeverity, b: InsightSeverity) -> Bool { a.rawValue < b.rawValue }
}

public struct Insight: Codable, Identifiable, Hashable {
    public var id: String
    public var key: String               // dedupe key, e.g. "stale:~/Downloads"
    public var kind: InsightKind
    public var title: String
    public var detail: String
    public var severity: InsightSeverity
    public var createdAt: Date
    public var dismissed: Bool
    public var command: String?          // one-click fix, expressed as a palette command
    public var ruleDraft: Rule?          // suggested automation
    public var filePaths: [String]
    public var metric: Double?
    public init(id: String = newID(), key: String, kind: InsightKind, title: String, detail: String,
                severity: InsightSeverity = .suggestion, createdAt: Date = Date(), dismissed: Bool = false,
                command: String? = nil, ruleDraft: Rule? = nil, filePaths: [String] = [], metric: Double? = nil) {
        self.id = id; self.key = key; self.kind = kind; self.title = title; self.detail = detail
        self.severity = severity; self.createdAt = createdAt; self.dismissed = dismissed; self.command = command
        self.ruleDraft = ruleDraft; self.filePaths = filePaths; self.metric = metric
    }
}

public enum ReviewStatus: String, Codable, CaseIterable { case pending, approved, rejected }

public struct ReviewItem: Codable, Identifiable, Hashable {
    public var id: String
    public var fileId: String
    public var path: String
    public var suggestedDestination: String?
    public var suggestedTags: [String]
    public var suggestedProjectId: String?
    public var suggestedCategory: String?
    public var confidence: Double
    public var reasons: [String]
    public var status: ReviewStatus
    public var createdAt: Date
    public var resolvedAt: Date?
    public var ruleId: String?           // set when a rule requires confirmation
    public var alternatives: [String]    // other candidate destinations
    public init(id: String = newID(), fileId: String, path: String, suggestedDestination: String? = nil,
                suggestedTags: [String] = [], suggestedProjectId: String? = nil, suggestedCategory: String? = nil,
                confidence: Double, reasons: [String] = [], status: ReviewStatus = .pending, createdAt: Date = Date(),
                ruleId: String? = nil, alternatives: [String] = []) {
        self.ruleId = ruleId; self.alternatives = alternatives
        self.id = id; self.fileId = fileId; self.path = path; self.suggestedDestination = suggestedDestination
        self.suggestedTags = suggestedTags; self.suggestedProjectId = suggestedProjectId
        self.suggestedCategory = suggestedCategory; self.confidence = confidence; self.reasons = reasons
        self.status = status; self.createdAt = createdAt
    }
}

// MARK: - Knowledge graph

public enum NodeType: String, Codable, CaseIterable { case file, project, person, organization, topic, date, tag, place }

public struct GraphEdge: Codable, Hashable {
    public var srcType: NodeType
    public var srcId: String
    public var dstType: NodeType
    public var dstId: String
    public var relation: String          // "mentions", "belongsTo", "taggedWith", "about", "dated"
    public var weight: Double
    public init(srcType: NodeType, srcId: String, dstType: NodeType, dstId: String, relation: String, weight: Double = 1) {
        self.srcType = srcType; self.srcId = srcId; self.dstType = dstType; self.dstId = dstId
        self.relation = relation; self.weight = weight
    }
}

/// A move the *user* made by hand (not Nexus). Feeds pattern detection ("want a rule for that?").
public struct ObservedMove: Codable, Hashable {
    public var fromFolder: String
    public var toFolder: String
    public var ext: String
    public var keywords: [String]
    public var timestamp: Date
    public init(fromFolder: String, toFolder: String, ext: String, keywords: [String], timestamp: Date = Date()) {
        self.fromFolder = fromFolder; self.toFolder = toFolder; self.ext = ext; self.keywords = keywords; self.timestamp = timestamp
    }
}
