import Foundation

// MARK: - Triggers

public enum TriggerKind: String, Codable, CaseIterable, Identifiable {
    case fileAdded, fileModified, downloadCompleted
    case schedule, manual
    case appLaunched, appQuit
    case volumeMounted, volumeUnmounted
    case diskSpaceBelow, folderCountAbove, folderSizeAbove
    case idle, wake, focusStarted, focusEnded
    case connectorEvent

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .fileAdded: return "New file in folder"
        case .fileModified: return "File changed"
        case .downloadCompleted: return "Download finished"
        case .schedule: return "Time / schedule"
        case .manual: return "Manually / on demand"
        case .appLaunched: return "App opened"
        case .appQuit: return "App closed"
        case .volumeMounted: return "Drive connected"
        case .volumeUnmounted: return "Drive ejected"
        case .diskSpaceBelow: return "Disk space low"
        case .folderCountAbove: return "Folder file count above"
        case .folderSizeAbove: return "Folder size above"
        case .idle: return "Mac idle"
        case .wake: return "Mac woke up"
        case .focusStarted: return "Focus started"
        case .focusEnded: return "Focus ended"
        case .connectorEvent: return "Connector event"
        }
    }
    public var symbol: String {
        switch self {
        case .fileAdded, .fileModified: return "doc.badge.plus"
        case .downloadCompleted: return "arrow.down.circle"
        case .schedule: return "clock"
        case .manual: return "hand.tap"
        case .appLaunched, .appQuit: return "app.badge"
        case .volumeMounted, .volumeUnmounted: return "externaldrive"
        case .diskSpaceBelow: return "internaldrive"
        case .folderCountAbove, .folderSizeAbove: return "folder.badge.gearshape"
        case .idle: return "moon.zzz"
        case .wake: return "sun.max"
        case .focusStarted, .focusEnded: return "scope"
        case .connectorEvent: return "puzzlepiece.extension"
        }
    }
    public var isFileTrigger: Bool { [.fileAdded, .fileModified, .downloadCompleted].contains(self) }
}

public struct Trigger: Codable, Hashable {
    public var kind: TriggerKind
    public var folders: [String]
    public var recursive: Bool
    public var cron: String?
    public var appName: String?
    public var volumeName: String?
    public var threshold: Double?        // GB for disk/folder size, count for folderCount, minutes for idle
    public var connectorEvent: String?   // e.g. "github.issueAssigned", "mail.attachment"

    public init(kind: TriggerKind, folders: [String] = [], recursive: Bool = false, cron: String? = nil,
                appName: String? = nil, volumeName: String? = nil, threshold: Double? = nil, connectorEvent: String? = nil) {
        self.kind = kind; self.folders = folders; self.recursive = recursive; self.cron = cron
        self.appName = appName; self.volumeName = volumeName; self.threshold = threshold; self.connectorEvent = connectorEvent
    }

    public var summary: String {
        switch kind {
        case .fileAdded, .fileModified, .downloadCompleted:
            let f = folders.isEmpty ? "any watched folder" : folders.map { Paths.abbreviate($0) }.joined(separator: ", ")
            return "\(kind.label): \(f)"
        case .schedule: return "Schedule: \(cron.map { CronExpression.describe($0) } ?? "—")"
        case .appLaunched, .appQuit: return "\(kind.label): \(appName ?? "any")"
        case .volumeMounted, .volumeUnmounted: return "\(kind.label): \(volumeName ?? "any")"
        case .diskSpaceBelow: return "Disk free < \(Int(threshold ?? 25)) GB"
        case .folderCountAbove: return "\(folders.first.map { Paths.abbreviate($0) } ?? "folder") has > \(Int(threshold ?? 50)) files"
        case .folderSizeAbove: return "\(folders.first.map { Paths.abbreviate($0) } ?? "folder") > \(Int(threshold ?? 10)) GB"
        case .idle: return "Idle for \(Int(threshold ?? 15)) min"
        case .connectorEvent: return "Connector: \(connectorEvent ?? "—")"
        default: return kind.label
        }
    }
}

// MARK: - Conditions

public enum ConditionField: String, Codable, CaseIterable, Identifiable {
    case name, ext, kind, content, anyText, sizeMB, ageDays, folder, docType, language, tag, project, topic, entity, sourceURL, hour, weekday
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .name: return "Filename"
        case .ext: return "Extension"
        case .kind: return "File type"
        case .content: return "Content"
        case .anyText: return "Name or content"
        case .sizeMB: return "Size (MB)"
        case .ageDays: return "Age (days)"
        case .folder: return "Folder"
        case .docType: return "Document type"
        case .language: return "Code language"
        case .tag: return "Tag"
        case .project: return "Project"
        case .topic: return "Topic"
        case .entity: return "Mentions (person/org)"
        case .sourceURL: return "Downloaded from"
        case .hour: return "Hour of day"
        case .weekday: return "Weekday (1=Sun)"
        }
    }
    public var isNumeric: Bool { [.sizeMB, .ageDays, .hour, .weekday].contains(self) }
}

public enum ConditionOp: String, Codable, CaseIterable, Identifiable {
    case contains, notContains, equals, notEquals, startsWith, endsWith, matches, greaterThan, lessThan, isAnyOf, exists
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .equals: return "is"
        case .notEquals: return "is not"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .matches: return "matches regex"
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .isAnyOf: return "is any of"
        case .exists: return "is set"
        }
    }
}

public struct Condition: Codable, Hashable, Identifiable {
    public var id: String
    public var field: ConditionField
    public var op: ConditionOp
    public var value: String
    public init(id: String = newID(), _ field: ConditionField, _ op: ConditionOp, _ value: String) {
        self.id = id; self.field = field; self.op = op; self.value = value
    }
    public var summary: String {
        op == .exists ? "\(field.label) is set" : "\(field.label) \(op.label) “\(value)”"
    }
}

public enum MatchMode: String, Codable, CaseIterable { case all, any }

public struct ConditionGroup: Codable, Hashable {
    public var match: MatchMode
    public var conditions: [Condition]
    public init(match: MatchMode = .all, conditions: [Condition] = []) { self.match = match; self.conditions = conditions }
}

// MARK: - Actions

public enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case move, copy, rename, tag, removeTag, addToProject, createProject, setCategory, trash, compress, createFolder
    case notify, createTask, createReminder, createCalendarEvent, summarize, openFile, revealInFinder
    case runShell, runAppleScript, runShortcut, runPlugin, webhook
    case syncFolder, archiveOld, sortFolder, findDuplicates, generateReport
    case githubIssue, obsidianNote, slackMessage, notionPage

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .move: return "Move to"
        case .copy: return "Copy to"
        case .rename: return "Rename"
        case .tag: return "Add tags"
        case .removeTag: return "Remove tags"
        case .addToProject: return "Add to project"
        case .createProject: return "Create / update project"
        case .setCategory: return "Set category"
        case .trash: return "Move to Trash"
        case .compress: return "Compress (zip)"
        case .createFolder: return "Create folder"
        case .notify: return "Send notification"
        case .createTask: return "Create Nexus task"
        case .createReminder: return "Create reminder"
        case .createCalendarEvent: return "Create calendar event"
        case .summarize: return "Summarize (AI)"
        case .openFile: return "Open file"
        case .revealInFinder: return "Reveal in Finder"
        case .runShell: return "Run shell script"
        case .runAppleScript: return "Run AppleScript"
        case .runShortcut: return "Run Shortcut"
        case .runPlugin: return "Run plugin"
        case .webhook: return "Call webhook"
        case .syncFolder: return "Sync folder to"
        case .archiveOld: return "Archive old files"
        case .sortFolder: return "Auto-sort folder"
        case .findDuplicates: return "Find duplicates"
        case .generateReport: return "Generate report"
        case .githubIssue: return "Create GitHub issue"
        case .obsidianNote: return "Append Obsidian note"
        case .slackMessage: return "Post to Slack"
        case .notionPage: return "Create Notion page"
        }
    }
    public var symbol: String {
        switch self {
        case .move: return "arrow.right.doc.on.clipboard"
        case .copy: return "doc.on.doc"
        case .rename: return "character.cursor.ibeam"
        case .tag, .removeTag: return "tag"
        case .addToProject, .createProject: return "square.stack.3d.up"
        case .setCategory: return "folder.badge.questionmark"
        case .trash: return "trash"
        case .compress: return "doc.zipper"
        case .createFolder: return "folder.badge.plus"
        case .notify: return "bell"
        case .createTask: return "checklist"
        case .createReminder: return "list.bullet.circle"
        case .createCalendarEvent: return "calendar.badge.plus"
        case .summarize: return "sparkles"
        case .openFile: return "arrow.up.forward.app"
        case .revealInFinder: return "magnifyingglass"
        case .runShell: return "terminal"
        case .runAppleScript: return "applescript"
        case .runShortcut: return "square.2.layers.3d"
        case .runPlugin: return "puzzlepiece.extension"
        case .webhook: return "network"
        case .syncFolder: return "arrow.triangle.2.circlepath"
        case .archiveOld: return "archivebox"
        case .sortFolder: return "wand.and.stars"
        case .findDuplicates: return "square.on.square"
        case .generateReport: return "chart.bar.doc.horizontal"
        case .githubIssue: return "chevron.left.forwardslash.chevron.right"
        case .obsidianNote: return "note.text"
        case .slackMessage: return "bubble.left.and.bubble.right"
        case .notionPage: return "doc.richtext"
        }
    }
    /// Actions that operate on the triggering file (vs. global actions like syncFolder).
    public var isFileScoped: Bool {
        [.move, .copy, .rename, .tag, .removeTag, .addToProject, .setCategory, .trash, .compress, .summarize, .openFile, .revealInFinder].contains(self)
    }
    /// Whether the action changes the file system (counted by the runaway guard, requires undo journal).
    public var isMutating: Bool { [.move, .copy, .rename, .trash, .compress, .syncFolder, .archiveOld, .sortFolder].contains(self) }
}

public struct RuleAction: Codable, Hashable, Identifiable {
    public var id: String
    public var kind: ActionKind
    /// Destination folder / rename pattern / script / message / URL depending on kind.
    /// Supports template tokens: {name} {basename} {ext} {year} {month} {day} {date} {project} {docType} {category} {counter}
    public var target: String
    public var tags: [String]
    public var project: String?          // project name (resolved at run time)
    public var params: [String: String]  // e.g. days=30, title=..., minutesBefore=...
    public init(id: String = newID(), kind: ActionKind, target: String = "", tags: [String] = [], project: String? = nil, params: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.target = target; self.tags = tags; self.project = project; self.params = params
    }
    public var summary: String {
        switch kind {
        case .tag, .removeTag: return "\(kind.label): \(tags.map { "#\($0)" }.joined(separator: " "))"
        case .addToProject: return "Add to project “\(project ?? target)”"
        case .move, .copy, .syncFolder: return "\(kind.label) \(Paths.abbreviate(target))"
        case .archiveOld: return "Archive files older than \(params["days"] ?? "30") days → \(Paths.abbreviate(target))"
        case .rename: return "Rename to \(target)"
        default: return target.isEmpty ? kind.label : "\(kind.label): \(target)"
        }
    }
}

// MARK: - Rule

public struct NodePosition: Codable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Rule: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var trigger: Trigger
    public var conditions: ConditionGroup
    public var actions: [RuleAction]
    public var priority: Int             // higher runs first
    public var stopProcessing: Bool      // don't evaluate lower-priority rules after this one fires
    public var requireConfirmation: Bool // put result in review queue instead of executing
    public var cooldownMinutes: Int      // for event triggers (volume mounted, low disk...)
    public var naturalLanguage: String?
    public var projectId: String?
    public var hitCount: Int
    public var lastTriggeredAt: Date?
    public var createdAt: Date
    public var layout: [String: NodePosition] // node id -> canvas position (visual builder)
    public var estimatedSecondsSaved: Int     // per hit, used for "time saved" insights

    public init(id: String = newID(), name: String, enabled: Bool = true, trigger: Trigger,
                conditions: ConditionGroup = ConditionGroup(), actions: [RuleAction] = [], priority: Int = 50,
                stopProcessing: Bool = false, requireConfirmation: Bool = false, cooldownMinutes: Int = 0,
                naturalLanguage: String? = nil, projectId: String? = nil, hitCount: Int = 0,
                lastTriggeredAt: Date? = nil, createdAt: Date = Date(), layout: [String: NodePosition] = [:],
                estimatedSecondsSaved: Int = 20) {
        self.id = id; self.name = name; self.enabled = enabled; self.trigger = trigger; self.conditions = conditions
        self.actions = actions; self.priority = priority; self.stopProcessing = stopProcessing
        self.requireConfirmation = requireConfirmation; self.cooldownMinutes = cooldownMinutes
        self.naturalLanguage = naturalLanguage; self.projectId = projectId; self.hitCount = hitCount
        self.lastTriggeredAt = lastTriggeredAt; self.createdAt = createdAt; self.layout = layout
        self.estimatedSecondsSaved = estimatedSecondsSaved
    }

    public var summary: String {
        let conds = conditions.conditions.map(\.summary).joined(separator: conditions.match == .all ? " AND " : " OR ")
        let acts = actions.map(\.summary).joined(separator: " → ")
        return "\(trigger.summary)\(conds.isEmpty ? "" : " · if \(conds)") → \(acts)"
    }
}
