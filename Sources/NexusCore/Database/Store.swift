import Foundation

/// Repository over SQLite. Entities are stored as JSON documents with indexed columns for querying,
/// plus an FTS5 index for full-text search and a vector table for semantic search.
public final class NexusStore {
    public let db: SQLiteDatabase
    /// Called after any write with the entity name ("files", "rules", ...).
    public var onChange: ((String) -> Void)?

    public static let schemaVersion = 1

    public init(path: String = Paths.database.path) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.executeScript("""
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS files(
            id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, ext TEXT, kind TEXT, size INTEGER, modified REAL,
            indexed REAL, status TEXT, project_id TEXT, doc_type TEXT, hash TEXT, phash INTEGER, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS files_status ON files(status);
        CREATE INDEX IF NOT EXISTS files_project ON files(project_id);
        CREATE INDEX IF NOT EXISTS files_hash ON files(hash);
        CREATE INDEX IF NOT EXISTS files_size ON files(size);
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(id UNINDEXED, name, content, topics, tags, entities, tokenize='porter unicode61');
        CREATE TABLE IF NOT EXISTS file_tags(file_id TEXT, tag TEXT, PRIMARY KEY(file_id, tag));
        CREATE INDEX IF NOT EXISTS file_tags_tag ON file_tags(tag);
        CREATE TABLE IF NOT EXISTS embeddings(file_id TEXT PRIMARY KEY, vector BLOB);
        CREATE TABLE IF NOT EXISTS tags(name TEXT PRIMARY KEY, color TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS categories(id TEXT PRIMARY KEY, name TEXT, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, name TEXT, archived INTEGER, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS rules(id TEXT PRIMARY KEY, enabled INTEGER, priority INTEGER, trigger_kind TEXT, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS rule_hits(rule_id TEXT, ts REAL);
        CREATE INDEX IF NOT EXISTS rule_hits_ts ON rule_hits(ts);
        CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, status TEXT, priority INTEGER, scheduled_for REAL, created REAL, schedule_id TEXT, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status, scheduled_for);
        CREATE TABLE IF NOT EXISTS schedules(id TEXT PRIMARY KEY, enabled INTEGER, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, ts REAL, kind TEXT, batch_id TEXT, file_id TEXT, rule_id TEXT, undone INTEGER, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE INDEX IF NOT EXISTS events_batch ON events(batch_id);
        CREATE TABLE IF NOT EXISTS insights(id TEXT PRIMARY KEY, key TEXT UNIQUE, dismissed INTEGER, created REAL, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS review_items(id TEXT PRIMARY KEY, file_id TEXT, status TEXT, created REAL, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS review_status ON review_items(status);
        CREATE TABLE IF NOT EXISTS graph_edges(src_type TEXT, src_id TEXT, dst_type TEXT, dst_id TEXT, relation TEXT, weight REAL,
            PRIMARY KEY(src_type, src_id, dst_type, dst_id, relation));
        CREATE INDEX IF NOT EXISTS graph_dst ON graph_edges(dst_type, dst_id);
        CREATE TABLE IF NOT EXISTS observed_moves(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_snapshots(folder TEXT, day TEXT, size INTEGER, count INTEGER, PRIMARY KEY(folder, day));
        CREATE TABLE IF NOT EXISTS command_history(id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, ts REAL);
        """)
        try db.execute("INSERT OR REPLACE INTO kv(key, value) VALUES('schema_version', ?)", [String(Self.schemaVersion)])
    }

    private func changed(_ entity: String) { onChange?(entity) }

    private func decode<T: Decodable>(_ rows: [SQLRow], _ t: T.Type) -> [T] {
        rows.compactMap { JSON.decode(T.self, $0.string("json")) }
    }

    // MARK: Settings / KV

    public func loadSettings() -> NexusSettings {
        JSON.decode(NexusSettings.self, kv("settings")) ?? NexusSettings()
    }
    public func saveSettings(_ s: NexusSettings) {
        setKV("settings", JSON.string(s)); changed("settings")
    }
    public func kv(_ key: String) -> String? {
        (try? db.query("SELECT value FROM kv WHERE key=?", [key]))?.first?.string("value")
    }
    public func setKV(_ key: String, _ value: String) {
        _ = try? db.execute("INSERT OR REPLACE INTO kv(key, value) VALUES(?, ?)", [key, value])
    }

    // MARK: Files

    public func upsertFile(_ f: FileRecord, content: String? = nil) {
        do {
            try db.transaction {
                // path is unique — if a record exists at this path with a different id, reuse its id
                var rec = f
                if let existing = try db.query("SELECT id FROM files WHERE path=?", [f.path]).first?.string("id"), existing != f.id {
                    rec.id = existing
                }
                try db.execute("""
                    INSERT INTO files(id, path, ext, kind, size, modified, indexed, status, project_id, doc_type, hash, phash, json)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET path=excluded.path, ext=excluded.ext, kind=excluded.kind, size=excluded.size,
                      modified=excluded.modified, indexed=excluded.indexed, status=excluded.status, project_id=excluded.project_id,
                      doc_type=excluded.doc_type, hash=excluded.hash, phash=excluded.phash, json=excluded.json
                    """, [rec.id, rec.path, rec.ext, rec.kind.rawValue, rec.size, rec.modifiedAt, rec.indexedAt, rec.status.rawValue,
                          rec.projectId, rec.docType, rec.contentHash, rec.perceptualHash.map { Int64(bitPattern: $0) }, JSON.string(rec)])
                try db.execute("DELETE FROM file_tags WHERE file_id=?", [rec.id])
                for t in Set(rec.tags) { try db.execute("INSERT OR IGNORE INTO file_tags(file_id, tag) VALUES(?,?)", [rec.id, t]) }
                let existingContent = content == nil ? (try db.query("SELECT content FROM files_fts WHERE id=?", [rec.id]).first?.string("content")) : nil
                try db.execute("DELETE FROM files_fts WHERE id=?", [rec.id])
                try db.execute("INSERT INTO files_fts(id, name, content, topics, tags, entities) VALUES(?,?,?,?,?,?)",
                               [rec.id, rec.name, content ?? existingContent ?? rec.snippet, rec.topics.joined(separator: " "),
                                rec.tags.joined(separator: " "), rec.entities.map(\.value).joined(separator: " ")])
            }
            changed("files")
        } catch { NSLog("Nexus store upsertFile: \(error)") }
    }

    public func file(id: String) -> FileRecord? {
        decode((try? db.query("SELECT json FROM files WHERE id=?", [id])) ?? [], FileRecord.self).first
    }
    public func file(path: String) -> FileRecord? {
        decode((try? db.query("SELECT json FROM files WHERE path=?", [path])) ?? [], FileRecord.self).first
    }
    public func files(limit: Int = 500, status: FileStatus? = nil, projectId: String? = nil, orderBy: String = "indexed DESC") -> [FileRecord] {
        var sql = "SELECT json FROM files WHERE status != 'missing'"
        var p: [SQLConvertible] = []
        if let status { sql += " AND status=?"; p.append(status.rawValue) }
        if let projectId { sql += " AND project_id=?"; p.append(projectId) }
        sql += " ORDER BY \(orderBy) LIMIT \(limit)"
        return decode((try? db.query(sql, p)) ?? [], FileRecord.self)
    }
    public func files(inFolder folder: String, recursive: Bool = false) -> [FileRecord] {
        let rows = (try? db.query("SELECT json FROM files WHERE path LIKE ? AND status != 'missing'", [folder + "/%"])) ?? []
        return decode(rows, FileRecord.self).filter { Paths.isInside($0.path, folder, recursive: recursive) }
    }
    public func files(withTag tag: String) -> [FileRecord] {
        decode((try? db.query("SELECT f.json FROM files f JOIN file_tags t ON t.file_id=f.id WHERE t.tag=? COLLATE NOCASE", [tag])) ?? [], FileRecord.self)
    }
    public func files(withHash hash: String) -> [FileRecord] {
        decode((try? db.query("SELECT json FROM files WHERE hash=? AND status != 'missing'", [hash])) ?? [], FileRecord.self)
    }
    public func fileContent(id: String) -> String? {
        (try? db.query("SELECT content FROM files_fts WHERE id=?", [id]))?.first?.string("content")
    }

    /// Full-text search (BM25 ranked). Plain words are AND-ed with prefix matching.
    public func searchFiles(_ text: String, since: Date? = nil, limit: Int = 200) -> [FileRecord] {
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { "\"\($0)\"*" }
        guard !tokens.isEmpty else { return since.map { d in files(limit: limit).filter { $0.modifiedAt >= d } } ?? files(limit: limit) }
        let match = tokens.joined(separator: " ")
        var sql = "SELECT f.json FROM files_fts s JOIN files f ON f.id = s.id WHERE files_fts MATCH ? AND f.status != 'missing'"
        var p: [SQLConvertible] = [match]
        if let since { sql += " AND f.modified >= ?"; p.append(since) }
        sql += " ORDER BY bm25(files_fts, 0, 4.0, 1.0, 3.0, 3.0, 2.0) LIMIT \(limit)"
        return decode((try? db.query(sql, p)) ?? [], FileRecord.self)
    }

    public func markMissing(path: String) {
        guard var f = file(path: path) else { return }
        f.status = .missing
        upsertFile(f)
    }
    public func deleteFile(id: String) {
        _ = try? db.transaction {
            try db.execute("DELETE FROM files WHERE id=?", [id])
            try db.execute("DELETE FROM files_fts WHERE id=?", [id])
            try db.execute("DELETE FROM file_tags WHERE file_id=?", [id])
            try db.execute("DELETE FROM embeddings WHERE file_id=?", [id])
        }
        changed("files")
    }
    public func fileCount(status: FileStatus? = nil) -> Int {
        status.map { db.scalarInt("SELECT COUNT(*) FROM files WHERE status=?", [$0.rawValue]) }
            ?? db.scalarInt("SELECT COUNT(*) FROM files WHERE status != 'missing'")
    }
    public func storageByKind() -> [(String, Int64, Int)] {
        ((try? db.query("SELECT kind, SUM(size) s, COUNT(*) c FROM files WHERE status != 'missing' GROUP BY kind ORDER BY s DESC")) ?? [])
            .map { ($0.string("kind") ?? "other", Int64($0.int("s")), $0.int("c")) }
    }
    public func storageByProject() -> [(String?, Int64, Int)] {
        ((try? db.query("SELECT project_id, SUM(size) s, COUNT(*) c FROM files WHERE status != 'missing' GROUP BY project_id ORDER BY s DESC")) ?? [])
            .map { ($0.string("project_id"), Int64($0.int("s")), $0.int("c")) }
    }
    public func kindsOverTime(days: Int = 56) -> [(day: Date, kind: String, count: Int)] {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let rows = (try? db.query("SELECT CAST(indexed/86400 AS INTEGER)*86400 d, kind, COUNT(*) c FROM files WHERE indexed >= ? GROUP BY d, kind ORDER BY d", [since])) ?? []
        return rows.map { (Date(timeIntervalSince1970: $0.double("d")), $0.string("kind") ?? "other", $0.int("c")) }
    }
    public func duplicateHashes(minSize: Int64 = 1) -> [String] {
        ((try? db.query("SELECT hash FROM files WHERE hash IS NOT NULL AND status != 'missing' AND size >= ? GROUP BY hash HAVING COUNT(*) > 1", [minSize])) ?? [])
            .compactMap { $0.string("hash") }
    }
    public func allTagsWithCounts() -> [(String, Int)] {
        ((try? db.query("SELECT tag, COUNT(*) c FROM file_tags t JOIN files f ON f.id=t.file_id WHERE f.status != 'missing' GROUP BY tag ORDER BY c DESC")) ?? [])
            .map { ($0.string("tag") ?? "", $0.int("c")) }
    }

    // MARK: Embeddings

    public func saveEmbedding(fileId: String, vector: [Float]) {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = try? db.execute("INSERT OR REPLACE INTO embeddings(file_id, vector) VALUES(?,?)", [fileId, data])
    }
    public func allEmbeddings() -> [(String, [Float])] {
        ((try? db.query("SELECT file_id, vector FROM embeddings")) ?? []).compactMap { r in
            guard let id = r.string("file_id"), let d = r.data("vector") else { return nil }
            let v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return (id, v)
        }
    }

    // MARK: Tags & categories

    public func tags() -> [Tag] {
        ((try? db.query("SELECT name, color, created FROM tags ORDER BY name")) ?? []).map {
            Tag(name: $0.string("name") ?? "", color: $0.string("color") ?? "#8E8E93", createdAt: Date(timeIntervalSince1970: $0.double("created")))
        }
    }
    public func ensureTags(_ names: [String]) {
        let palette = ["#FF6B6B", "#FFA94D", "#FFD43B", "#69DB7C", "#38D9A9", "#4DABF7", "#748FFC", "#DA77F2", "#F783AC"]
        for n in names where !n.isEmpty {
            let color = palette[abs(n.hashValue) % palette.count]
            _ = try? db.execute("INSERT OR IGNORE INTO tags(name, color, created) VALUES(?,?,?)", [n, color, Date()])
        }
    }
    public func categories() -> [Category] { decode((try? db.query("SELECT json FROM categories ORDER BY name")) ?? [], Category.self) }
    public func saveCategory(_ c: Category) {
        _ = try? db.execute("INSERT OR REPLACE INTO categories(id, name, json) VALUES(?,?,?)", [c.id, c.name, JSON.string(c)])
        changed("categories")
    }
    public func deleteCategory(_ id: String) { _ = try? db.execute("DELETE FROM categories WHERE id=?", [id]); changed("categories") }

    // MARK: Projects

    public func projects(includeArchived: Bool = true) -> [Project] {
        decode((try? db.query("SELECT json FROM projects \(includeArchived ? "" : "WHERE archived=0") ORDER BY name")) ?? [], Project.self)
    }
    public func project(id: String) -> Project? { decode((try? db.query("SELECT json FROM projects WHERE id=?", [id])) ?? [], Project.self).first }
    public func project(named name: String) -> Project? {
        let n = name.lowercased().trimmed
        let all = projects()
        return all.first { $0.name.lowercased() == n } ?? all.first { $0.name.lowercased().contains(n) || n.contains($0.name.lowercased()) }
    }
    public func saveProject(_ p: Project) {
        _ = try? db.execute("INSERT OR REPLACE INTO projects(id, name, archived, json) VALUES(?,?,?,?)", [p.id, p.name, p.archived, JSON.string(p)])
        changed("projects")
    }
    public func deleteProject(_ id: String) {
        _ = try? db.execute("DELETE FROM projects WHERE id=?", [id])
        _ = try? db.execute("UPDATE files SET project_id=NULL WHERE project_id=?", [id])
        changed("projects")
    }
    public func projectStats(_ id: String) -> (count: Int, size: Int64) {
        let r = (try? db.query("SELECT COUNT(*) c, COALESCE(SUM(size),0) s FROM files WHERE project_id=? AND status != 'missing'", [id]))?.first
        return (r?.int("c") ?? 0, Int64(r?.int("s") ?? 0))
    }
    /// Files indexed per day for the last `days` days (sparkline).
    public func projectActivity(_ id: String, days: Int = 14) -> [Int] {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86400)
        let rows = (try? db.query("SELECT indexed FROM files WHERE project_id=? AND indexed >= ?", [id, start])) ?? []
        var buckets = Array(repeating: 0, count: days)
        for r in rows {
            let i = Int((r.double("indexed") - start.timeIntervalSince1970) / 86400)
            if i >= 0 && i < days { buckets[i] += 1 }
        }
        return buckets
    }

    // MARK: Rules

    public func rules() -> [Rule] { decode((try? db.query("SELECT json FROM rules ORDER BY priority DESC")) ?? [], Rule.self) }
    public func rule(id: String) -> Rule? { decode((try? db.query("SELECT json FROM rules WHERE id=?", [id])) ?? [], Rule.self).first }
    public func saveRule(_ r: Rule) {
        _ = try? db.execute("INSERT OR REPLACE INTO rules(id, enabled, priority, trigger_kind, json) VALUES(?,?,?,?,?)",
                            [r.id, r.enabled, r.priority, r.trigger.kind.rawValue, JSON.string(r)])
        changed("rules")
    }
    public func deleteRule(_ id: String) { _ = try? db.execute("DELETE FROM rules WHERE id=?", [id]); changed("rules") }
    public func recordRuleHit(_ id: String) {
        guard var r = rule(id: id) else { return }
        r.hitCount += 1
        r.lastTriggeredAt = Date()
        _ = try? db.execute("INSERT INTO rule_hits(rule_id, ts) VALUES(?,?)", [id, Date()])
        saveRule(r)
    }
    public func ruleHits(since: Date) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in (try? db.query("SELECT rule_id, COUNT(*) c FROM rule_hits WHERE ts >= ? GROUP BY rule_id", [since])) ?? [] {
            if let id = r.string("rule_id") { out[id] = r.int("c") }
        }
        return out
    }

    // MARK: Jobs

    public func saveJob(_ j: Job) {
        _ = try? db.execute("INSERT OR REPLACE INTO jobs(id, status, priority, scheduled_for, created, schedule_id, json) VALUES(?,?,?,?,?,?,?)",
                            [j.id, j.status.rawValue, j.priority.rawValue, j.scheduledFor, j.createdAt, j.scheduleId, JSON.string(j)])
        changed("jobs")
    }
    public func job(id: String) -> Job? { decode((try? db.query("SELECT json FROM jobs WHERE id=?", [id])) ?? [], Job.self).first }
    public func jobs(status: [JobStatus]? = nil, limit: Int = 300) -> [Job] {
        var sql = "SELECT json FROM jobs"
        if let status, !status.isEmpty { sql += " WHERE status IN (\(status.map { "'\($0.rawValue)'" }.joined(separator: ",")))" }
        sql += " ORDER BY created DESC LIMIT \(limit)"
        return decode((try? db.query(sql)) ?? [], Job.self)
    }
    /// Next runnable jobs: queued and due, highest priority first.
    public func dueJobs(limit: Int) -> [Job] {
        decode((try? db.query("SELECT json FROM jobs WHERE status IN ('queued','scheduled') AND scheduled_for <= ? ORDER BY priority DESC, scheduled_for ASC LIMIT \(limit)", [Date()])) ?? [], Job.self)
    }
    public func pruneJobs(olderThan days: Int = 30) {
        _ = try? db.execute("DELETE FROM jobs WHERE status IN ('completed','cancelled') AND created < ?", [Date().addingTimeInterval(-Double(days) * 86400)])
    }
    public func recoverInterruptedJobs() {
        for var j in jobs(status: [.running]) { j.status = .queued; j.log.append("Recovered after restart"); saveJob(j) }
    }

    // MARK: Schedules

    public func schedules() -> [Schedule] { decode((try? db.query("SELECT json FROM schedules")) ?? [], Schedule.self) }
    public func saveSchedule(_ s: Schedule) {
        _ = try? db.execute("INSERT OR REPLACE INTO schedules(id, enabled, json) VALUES(?,?,?)", [s.id, s.enabled, JSON.string(s)])
        changed("schedules")
    }
    public func deleteSchedule(_ id: String) { _ = try? db.execute("DELETE FROM schedules WHERE id=?", [id]); changed("schedules") }

    // MARK: Events

    public func log(_ e: ActivityEvent) {
        _ = try? db.execute("INSERT OR REPLACE INTO events(id, ts, kind, batch_id, file_id, rule_id, undone, json) VALUES(?,?,?,?,?,?,?,?)",
                            [e.id, e.timestamp, e.kind.rawValue, e.batchId, e.fileId, e.ruleId, e.undone, JSON.string(e)])
        changed("events")
    }
    public func events(limit: Int = 300, kinds: [EventKind]? = nil, since: Date? = nil) -> [ActivityEvent] {
        var sql = "SELECT json FROM events WHERE 1=1"
        var p: [SQLConvertible] = []
        if let kinds, !kinds.isEmpty { sql += " AND kind IN (\(kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")))" }
        if let since { sql += " AND ts >= ?"; p.append(since) }
        sql += " ORDER BY ts DESC LIMIT \(limit)"
        return decode((try? db.query(sql, p)) ?? [], ActivityEvent.self)
    }
    public func events(batch: String) -> [ActivityEvent] {
        decode((try? db.query("SELECT json FROM events WHERE batch_id=? ORDER BY ts DESC", [batch])) ?? [], ActivityEvent.self)
    }
    public func lastUndoableBatch() -> String? {
        (try? db.query("SELECT batch_id FROM events WHERE batch_id IS NOT NULL AND undone=0 AND json LIKE '%\"undo\"%' ORDER BY ts DESC LIMIT 1"))?.first?.string("batch_id")
    }
    public func eventCount(kind: EventKind, since: Date) -> Int {
        db.scalarInt("SELECT COUNT(*) FROM events WHERE kind=? AND ts >= ?", [kind.rawValue, since])
    }

    // MARK: Insights

    public func upsertInsight(_ i: Insight) {
        // keep dismissal state if the same insight key reappears
        if let existing = (try? db.query("SELECT json FROM insights WHERE key=?", [i.key]))?.first.flatMap({ JSON.decode(Insight.self, $0.string("json")) }) {
            var merged = i
            merged.id = existing.id
            merged.dismissed = existing.dismissed
            merged.createdAt = existing.createdAt
            _ = try? db.execute("UPDATE insights SET json=?, dismissed=? WHERE key=?", [JSON.string(merged), merged.dismissed, i.key])
        } else {
            _ = try? db.execute("INSERT INTO insights(id, key, dismissed, created, json) VALUES(?,?,?,?,?)", [i.id, i.key, i.dismissed, i.createdAt, JSON.string(i)])
        }
        changed("insights")
    }
    public func insights(includeDismissed: Bool = false) -> [Insight] {
        decode((try? db.query("SELECT json FROM insights \(includeDismissed ? "" : "WHERE dismissed=0") ORDER BY created DESC")) ?? [], Insight.self)
            .sorted { $0.severity == $1.severity ? $0.createdAt > $1.createdAt : $0.severity > $1.severity }
    }
    public func dismissInsight(_ id: String) {
        guard var i = decode((try? db.query("SELECT json FROM insights WHERE id=?", [id])) ?? [], Insight.self).first else { return }
        i.dismissed = true
        _ = try? db.execute("UPDATE insights SET dismissed=1, json=? WHERE id=?", [JSON.string(i), id])
        changed("insights")
    }
    public func removeInsight(key: String) { _ = try? db.execute("DELETE FROM insights WHERE key=?", [key]); changed("insights") }
    public func insightKeys() -> Set<String> {
        Set(((try? db.query("SELECT key FROM insights")) ?? []).compactMap { $0.string("key") })
    }

    // MARK: Review queue

    public func saveReview(_ r: ReviewItem) {
        _ = try? db.execute("INSERT OR REPLACE INTO review_items(id, file_id, status, created, json) VALUES(?,?,?,?,?)",
                            [r.id, r.fileId, r.status.rawValue, r.createdAt, JSON.string(r)])
        changed("review")
    }
    public func reviewItems(status: ReviewStatus = .pending) -> [ReviewItem] {
        decode((try? db.query("SELECT json FROM review_items WHERE status=? ORDER BY created DESC", [status.rawValue])) ?? [], ReviewItem.self)
    }
    public func pendingReview(fileId: String) -> ReviewItem? {
        decode((try? db.query("SELECT json FROM review_items WHERE file_id=? AND status='pending'", [fileId])) ?? [], ReviewItem.self).first
    }
    public func reviewCount() -> Int { db.scalarInt("SELECT COUNT(*) FROM review_items WHERE status='pending'") }
    public func reviewDecisions(limit: Int = 500) -> [ReviewItem] {
        decode((try? db.query("SELECT json FROM review_items WHERE status != 'pending' ORDER BY created DESC LIMIT \(limit)")) ?? [], ReviewItem.self)
    }

    // MARK: Knowledge graph

    public func addEdges(_ edges: [GraphEdge]) {
        _ = try? db.transaction {
            for e in edges {
                try db.execute("""
                    INSERT INTO graph_edges(src_type, src_id, dst_type, dst_id, relation, weight) VALUES(?,?,?,?,?,?)
                    ON CONFLICT DO UPDATE SET weight = MAX(weight, excluded.weight)
                    """, [e.srcType.rawValue, e.srcId, e.dstType.rawValue, e.dstId, e.relation, e.weight])
            }
        }
    }
    public func removeEdges(srcType: NodeType, srcId: String) {
        _ = try? db.execute("DELETE FROM graph_edges WHERE src_type=? AND src_id=?", [srcType.rawValue, srcId])
    }
    public func edges(from type: NodeType, id: String) -> [GraphEdge] {
        ((try? db.query("SELECT * FROM graph_edges WHERE src_type=? AND src_id=?", [type.rawValue, id])) ?? []).compactMap(edge)
    }
    public func edges(to type: NodeType, id: String) -> [GraphEdge] {
        ((try? db.query("SELECT * FROM graph_edges WHERE dst_type=? AND dst_id=? COLLATE NOCASE", [type.rawValue, id])) ?? []).compactMap(edge)
    }
    public func topNodes(type: NodeType, limit: Int = 30) -> [(String, Int)] {
        ((try? db.query("SELECT dst_id, COUNT(*) c FROM graph_edges WHERE dst_type=? GROUP BY dst_id ORDER BY c DESC LIMIT \(limit)", [type.rawValue])) ?? [])
            .map { ($0.string("dst_id") ?? "", $0.int("c")) }
    }
    private func edge(_ r: SQLRow) -> GraphEdge? {
        guard let st = NodeType(rawValue: r.string("src_type") ?? ""), let dt = NodeType(rawValue: r.string("dst_type") ?? "") else { return nil }
        return GraphEdge(srcType: st, srcId: r.string("src_id") ?? "", dstType: dt, dstId: r.string("dst_id") ?? "",
                         relation: r.string("relation") ?? "", weight: r.double("weight"))
    }

    // MARK: Observed moves, snapshots, history

    public func recordObservedMove(_ m: ObservedMove) {
        _ = try? db.execute("INSERT INTO observed_moves(ts, json) VALUES(?,?)", [m.timestamp, JSON.string(m)])
    }
    public func observedMoves(since: Date) -> [ObservedMove] {
        decode((try? db.query("SELECT json FROM observed_moves WHERE ts >= ?", [since])) ?? [], ObservedMove.self)
    }
    public func saveSnapshot(folder: String, size: Int64, count: Int, date: Date = Date()) {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        _ = try? db.execute("INSERT OR REPLACE INTO folder_snapshots(folder, day, size, count) VALUES(?,?,?,?)", [folder, day, size, count])
    }
    public func snapshots(folder: String) -> [(day: String, size: Int64, count: Int)] {
        ((try? db.query("SELECT day, size, count FROM folder_snapshots WHERE folder=? ORDER BY day", [folder])) ?? [])
            .map { ($0.string("day") ?? "", Int64($0.int("size")), $0.int("count")) }
    }
    public func snapshotFolders() -> [String] {
        ((try? db.query("SELECT DISTINCT folder FROM folder_snapshots")) ?? []).compactMap { $0.string("folder") }
    }
    public func addCommandHistory(_ text: String) {
        _ = try? db.execute("DELETE FROM command_history WHERE text=?", [text])
        _ = try? db.execute("INSERT INTO command_history(text, ts) VALUES(?,?)", [text, Date()])
    }
    public func commandHistory(limit: Int = 12) -> [String] {
        ((try? db.query("SELECT text FROM command_history ORDER BY ts DESC LIMIT \(limit)")) ?? []).compactMap { $0.string("text") }
    }
}
