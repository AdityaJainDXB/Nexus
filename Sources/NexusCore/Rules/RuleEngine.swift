import Foundation

/// Everything a rule can look at when it's evaluated.
public struct RuleContext {
    public var file: FileRecord?
    public var content: String
    public var projectName: String?
    public var trigger: TriggerKind
    public var info: [String: String]    // appName, volumeName, bundleId, connector payload...
    public var now: Date

    public init(file: FileRecord?, content: String = "", projectName: String? = nil, trigger: TriggerKind, info: [String: String] = [:], now: Date = Date()) {
        self.file = file; self.content = content; self.projectName = projectName; self.trigger = trigger; self.info = info; self.now = now
    }
}

public struct ConditionResult: Hashable {
    public var condition: Condition
    public var passed: Bool
    public var actual: String
}

public struct RuleEvaluation: Identifiable {
    public var id: String { rule.id }
    public var rule: Rule
    public var triggerMatched: Bool
    public var conditionResults: [ConditionResult]
    public var fired: Bool
    public var skippedByStop: Bool
    public var plannedActions: [String]
}

public struct SimulationReport {
    public var file: FileRecord
    public var evaluations: [RuleEvaluation]
    public var conflicts: [String]
    public var firedCount: Int { evaluations.filter(\.fired).count }
}

public struct RuleConflict: Identifiable, Hashable {
    public enum Kind: String { case contradictory, redundant, shadowed }
    public var id: String { "\(kind.rawValue):\(ruleA):\(ruleB)" }
    public var kind: Kind
    public var ruleA: String
    public var ruleB: String
    public var message: String
}

public final class RuleEngine {
    public init() {}

    // MARK: Trigger matching

    public func triggerMatches(_ rule: Rule, _ ctx: RuleContext) -> Bool {
        let t = rule.trigger
        if t.kind == .manual { return true }
        if ctx.trigger == .manual { return t.kind.isFileTrigger } // "run now" / simulation: any file rule applies
        // A completed download is also a new file.
        let kindOK = t.kind == ctx.trigger || (t.kind == .fileAdded && ctx.trigger == .downloadCompleted)
        guard kindOK else { return false }
        switch t.kind {
        case .fileAdded, .fileModified, .downloadCompleted:
            guard let f = ctx.file else { return false }
            if t.folders.isEmpty { return true }
            return t.folders.contains { Paths.isInside(f.path, Paths.expand($0), recursive: t.recursive) }
        case .appLaunched, .appQuit:
            guard let want = t.appName?.lowercased(), !want.isEmpty else { return true }
            return (ctx.info["appName"] ?? "").lowercased() == want || (ctx.info["bundleId"] ?? "").lowercased() == want
                || (ctx.info["appName"] ?? "").lowercased().contains(want)
        case .volumeMounted, .volumeUnmounted:
            guard let want = t.volumeName?.lowercased(), !want.isEmpty else { return true }
            return (ctx.info["volumeName"] ?? "").lowercased() == want
        case .diskSpaceBelow:
            return (Double(ctx.info["freeGB"] ?? "") ?? .infinity) < (t.threshold ?? 25)
        case .connectorEvent:
            return t.connectorEvent == nil || t.connectorEvent == ctx.info["connectorEvent"]
        case .idle:
            return (Double(ctx.info["idleMinutes"] ?? "") ?? 0) >= (t.threshold ?? 15)
        default:
            return true
        }
    }

    // MARK: Conditions

    public func evaluate(_ c: Condition, _ ctx: RuleContext) -> ConditionResult {
        let f = ctx.file
        let v = c.value.trimmed
        func str(_ s: String?) -> ConditionResult {
            let a = s ?? ""
            return ConditionResult(condition: c, passed: compare(a, c.op, v), actual: String(a.prefix(80)))
        }
        func list(_ items: [String]) -> ConditionResult {
            let passed: Bool
            switch c.op {
            case .notContains, .notEquals:
                let positive: ConditionOp = c.op == .notContains ? .contains : .equals
                passed = !items.contains { compare($0, positive, v) }
            case .exists: passed = !items.isEmpty
            default: passed = items.contains { compare($0, c.op, v) }
            }
            return ConditionResult(condition: c, passed: passed, actual: items.prefix(5).joined(separator: ", "))
        }
        func num(_ n: Double?) -> ConditionResult {
            guard let n else { return ConditionResult(condition: c, passed: false, actual: "—") }
            let target = Double(v) ?? 0
            let passed: Bool
            switch c.op {
            case .greaterThan: passed = n > target
            case .lessThan: passed = n < target
            case .equals: passed = abs(n - target) < 0.0001
            case .notEquals: passed = abs(n - target) >= 0.0001
            case .isAnyOf: passed = v.split(separator: ",").compactMap { Double($0.trimmed) }.contains(n)
            default: passed = compare(String(format: "%g", n), c.op, v)
            }
            return ConditionResult(condition: c, passed: passed, actual: String(format: "%.1f", n))
        }
        let cal = Calendar.current
        switch c.field {
        case .name: return str(f?.name)
        case .ext:
            let normalized = Condition(id: c.id, c.field, c.op, v.replacingOccurrences(of: ".", with: ""))
            let a = f?.ext ?? ""
            return ConditionResult(condition: c, passed: compare(a, normalized.op, normalized.value), actual: a)
        case .kind:
            let k = f?.kind.rawValue ?? ""
            var kinds = [k]
            if k == "screenshot" { kinds.append("image") }
            if ["pdf", "document", "text", "spreadsheet", "presentation"].contains(k) { kinds.append("document") }
            return list(kinds)
        case .content: return str(ctx.content)
        case .anyText: return str((f?.name ?? "") + "\n" + ctx.content)
        case .sizeMB: return num(f.map { Double($0.size) / 1_048_576 })
        case .ageDays: return num(f.map { ctx.now.timeIntervalSince(min($0.createdAt, $0.modifiedAt)) / 86400 })
        case .folder:
            let folder = f?.folder ?? ""
            let passed: Bool
            switch c.op {
            case .equals: passed = folder == Paths.expand(v)
            case .notEquals: passed = folder != Paths.expand(v)
            case .contains where v.contains("/") || v.hasPrefix("~"): passed = Paths.isInside(folder, Paths.expand(v))
            default: passed = compare(folder, c.op, v)
            }
            return ConditionResult(condition: c, passed: passed, actual: Paths.abbreviate(folder))
        case .docType: return str(f?.docType)
        case .language: return str(f?.language)
        case .tag: return list(f?.tags ?? (ctx.info["tag"] ?? "").split(separator: ",").map { $0.trimmed })
        case .project: return str(ctx.projectName)
        case .topic: return list(f?.topics ?? [])
        case .entity: return list((f?.entities ?? []).map(\.value))
        case .sourceURL: return str(f?.sourceURL)
        case .hour: return num(Double(cal.component(.hour, from: ctx.now)))
        case .weekday: return num(Double(cal.component(.weekday, from: ctx.now)))
        }
    }

    func compare(_ actual: String, _ op: ConditionOp, _ expected: String) -> Bool {
        let a = actual.lowercased(), e = expected.lowercased()
        switch op {
        case .contains:
            // "a|b" means any of the alternatives
            return e.split(separator: "|").contains { a.contains($0.trimmed) }
        case .notContains: return !e.split(separator: "|").contains { a.contains($0.trimmed) }
        case .equals: return a == e || (e.contains("*") && a.glob(e))
        case .notEquals: return a != e
        case .startsWith: return a.hasPrefix(e)
        case .endsWith: return a.hasSuffix(e)
        case .matches: return actual.regexMatches(expected)
        case .isAnyOf: return e.split(separator: ",").map { $0.trimmed }.contains(a)
        case .exists: return !a.isEmpty
        case .greaterThan: return (Double(a) ?? 0) > (Double(e) ?? 0)
        case .lessThan: return (Double(a) ?? 0) < (Double(e) ?? 0)
        }
    }

    public func conditionsPass(_ group: ConditionGroup, _ ctx: RuleContext) -> (Bool, [ConditionResult]) {
        let results = group.conditions.map { evaluate($0, ctx) }
        if results.isEmpty { return (true, []) }
        let ok = group.match == .all ? results.allSatisfy(\.passed) : results.contains(where: \.passed)
        return (ok, results)
    }

    // MARK: Evaluation

    /// Evaluates rules in priority order; honours `stopProcessing`.
    public func evaluate(rules: [Rule], ctx: RuleContext, includeDisabled: Bool = false) -> [RuleEvaluation] {
        var out: [RuleEvaluation] = []
        var stopped = false
        for rule in rules.sorted(by: { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority > $1.priority })
        where rule.enabled || includeDisabled {
            let trig = triggerMatches(rule, ctx)
            let (ok, results) = trig ? conditionsPass(rule.conditions, ctx) : (false, [])
            let fired = trig && ok && !stopped && rule.enabled
            out.append(RuleEvaluation(rule: rule, triggerMatched: trig, conditionResults: results, fired: fired,
                                      skippedByStop: trig && ok && stopped,
                                      plannedActions: rule.actions.map { Templates.describe($0, file: ctx.file, projectName: ctx.projectName) }))
            if fired && rule.stopProcessing { stopped = true }
        }
        return out
    }

    public func firingRules(rules: [Rule], ctx: RuleContext) -> [Rule] {
        evaluate(rules: rules, ctx: ctx).filter(\.fired).map(\.rule)
    }

    public func simulate(rules: [Rule], file: FileRecord, content: String, projectName: String?) -> SimulationReport {
        let ctx = RuleContext(file: file, content: content, projectName: projectName, trigger: .manual)
        let evals = evaluate(rules: rules, ctx: ctx, includeDisabled: true)
        var conflicts: [String] = []
        let moves = evals.filter(\.fired).flatMap { e in e.rule.actions.filter { $0.kind == .move }.map { (e.rule.name, Templates.expand($0.target, file: file, projectName: projectName)) } }
        if Set(moves.map(\.1)).count > 1 {
            conflicts.append("Conflicting moves: " + moves.map { "\($0.0) → \(Paths.abbreviate($0.1))" }.joined(separator: "; ") + ". Only the first move applies; later file actions follow the file.")
        }
        let tagAdds = Set(evals.filter(\.fired).flatMap { $0.rule.actions.filter { $0.kind == .tag }.flatMap(\.tags) })
        let tagRemoves = Set(evals.filter(\.fired).flatMap { $0.rule.actions.filter { $0.kind == .removeTag }.flatMap(\.tags) })
        if !tagAdds.intersection(tagRemoves).isEmpty { conflicts.append("Tags both added and removed: \(tagAdds.intersection(tagRemoves).joined(separator: ", "))") }
        for e in evals where e.skippedByStop { conflicts.append("“\(e.rule.name)” would match but is blocked by a higher-priority rule that stops processing.") }
        return SimulationReport(file: file, evaluations: evals, conflicts: conflicts)
    }

    // MARK: Static conflict analysis

    public func analyzeConflicts(_ rules: [Rule]) -> [RuleConflict] {
        let enabled = rules.filter(\.enabled).sorted { $0.priority > $1.priority }
        var out: [RuleConflict] = []
        for i in 0..<enabled.count {
            for j in (i + 1)..<max(i + 1, enabled.count) where j < enabled.count {
                let a = enabled[i], b = enabled[j]
                guard a.trigger.kind == b.trigger.kind || (a.trigger.kind.isFileTrigger && b.trigger.kind.isFileTrigger) else { continue }
                guard foldersOverlap(a.trigger, b.trigger) else { continue }
                let condA = Set(a.conditions.conditions.map { "\($0.field.rawValue)|\($0.op.rawValue)|\($0.value.lowercased())" })
                let condB = Set(b.conditions.conditions.map { "\($0.field.rawValue)|\($0.op.rawValue)|\($0.value.lowercased())" })
                let actA = Set(a.actions.map { "\($0.kind.rawValue)|\($0.target.lowercased())|\($0.tags.sorted())" })
                let actB = Set(b.actions.map { "\($0.kind.rawValue)|\($0.target.lowercased())|\($0.tags.sorted())" })
                if condA == condB && actA == actB {
                    out.append(RuleConflict(kind: .redundant, ruleA: a.id, ruleB: b.id, message: "“\(a.name)” and “\(b.name)” are identical."))
                    continue
                }
                if a.stopProcessing && a.conditions.match == .all && condA.isSubset(of: condB) {
                    out.append(RuleConflict(kind: .shadowed, ruleA: a.id, ruleB: b.id, message: "“\(b.name)” can never run: “\(a.name)” matches first and stops processing."))
                    continue
                }
                let moveA = a.actions.first { $0.kind == .move }?.target, moveB = b.actions.first { $0.kind == .move }?.target
                if let ma = moveA, let mb = moveB, Paths.expand(ma) != Paths.expand(mb), !mutuallyExclusive(a.conditions, b.conditions) {
                    out.append(RuleConflict(kind: .contradictory, ruleA: a.id, ruleB: b.id,
                                            message: "“\(a.name)” and “\(b.name)” can match the same file but move it to different folders (\(Paths.abbreviate(ma)) vs \(Paths.abbreviate(mb)))."))
                }
            }
        }
        return out
    }

    func foldersOverlap(_ a: Trigger, _ b: Trigger) -> Bool {
        guard a.kind.isFileTrigger, b.kind.isFileTrigger else { return true }
        if a.folders.isEmpty || b.folders.isEmpty { return true }
        return a.folders.contains { fa in b.folders.contains { fb in
            let x = Paths.expand(fa), y = Paths.expand(fb)
            return x == y || (a.recursive && Paths.isInside(y, x)) || (b.recursive && Paths.isInside(x, y))
        } }
    }

    /// Conservative: two groups are exclusive if both require `ext`/`kind` equality with different values.
    func mutuallyExclusive(_ a: ConditionGroup, _ b: ConditionGroup) -> Bool {
        guard a.match == .all, b.match == .all else { return false }
        for field in [ConditionField.ext, .kind, .docType, .language] {
            let va = Set(a.conditions.filter { $0.field == field && [.equals, .isAnyOf].contains($0.op) }.flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmed.replacingOccurrences(of: ".", with: "") } })
            let vb = Set(b.conditions.filter { $0.field == field && [.equals, .isAnyOf].contains($0.op) }.flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmed.replacingOccurrences(of: ".", with: "") } })
            if !va.isEmpty && !vb.isEmpty && va.isDisjoint(with: vb) { return true }
        }
        return false
    }
}

// MARK: - Templates

public enum Templates {
    public static func expand(_ template: String, file: FileRecord?, projectName: String?, info: [String: String] = [:], now: Date = Date()) -> String {
        guard template.contains("{") else { return template.hasPrefix("~") || template.hasPrefix("/") ? Paths.expand(template) : template }
        let cal = Calendar.current
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let base = file.map { ($0.name as NSString).deletingPathExtension } ?? ""
        var s = template
        let date = file?.createdAt ?? now
        let vars: [String: String] = [
            "name": file?.name ?? "", "basename": base, "ext": file?.ext ?? "",
            "year": String(cal.component(.year, from: date)), "month": String(format: "%02d", cal.component(.month, from: date)),
            "day": String(format: "%02d", cal.component(.day, from: date)), "date": df.string(from: date), "today": df.string(from: now),
            "project": projectName ?? "Unsorted", "docType": (file?.docType ?? "Other").capitalized, "category": file?.category ?? "Other",
            "kind": (file?.kind.rawValue ?? "other").capitalized, "language": file?.language ?? "Other",
            "topic": file?.topics.first?.capitalized ?? "General",
        ]
        for (k, v) in info where s.contains("{\(k)}") { s = s.replacingOccurrences(of: "{\(k)}", with: v.replacingOccurrences(of: "/", with: "-")) }
        for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: v.replacingOccurrences(of: "/", with: "-")) }
        return s.hasPrefix("~") || s.hasPrefix("/") ? Paths.expand(s) : s
    }

    public static func describe(_ a: RuleAction, file: FileRecord?, projectName: String?) -> String {
        switch a.kind {
        case .move, .copy, .syncFolder: return "\(a.kind.label) \(Paths.abbreviate(expand(a.target, file: file, projectName: projectName)))"
        case .rename:
            let newName = expand(a.target, file: file, projectName: projectName)
            let withExt = (newName as NSString).pathExtension.isEmpty && !(file?.ext ?? "").isEmpty ? "\(newName).\(file!.ext)" : newName
            return "Rename to “\(withExt)”"
        default: return a.summary
        }
    }
}
