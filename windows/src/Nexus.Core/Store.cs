using Microsoft.Data.Sqlite;

namespace Nexus.Core;

public enum NodeType { file, topic, person, organization, place, date, tag, project }
public record GraphEdge(NodeType SrcType, string SrcId, NodeType DstType, string DstId, string Relation);

/// SQLite repository: JSON documents with indexed columns, FTS5 search, embeddings, knowledge-graph edges.
/// One connection guarded by a lock (Microsoft.Data.Sqlite connections are not thread-safe).
public sealed class NexusStore : IDisposable
{
    readonly SqliteConnection db;
    readonly object gate = new();
    public Action<string>? OnChange;
    public string DatabasePath { get; }

    public NexusStore(string? path = null)
    {
        DatabasePath = path ?? Path.Combine(Paths.AppSupport, "nexus.sqlite");
        Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);
        db = new SqliteConnection($"Data Source={DatabasePath};Cache=Private;Pooling=False");
        db.Open();
        Exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF; PRAGMA busy_timeout=5000;");
        Migrate();
    }

    public void Dispose() { lock (gate) db.Dispose(); }

    void Migrate()
    {
        Exec("""
        CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY, path TEXT UNIQUE COLLATE NOCASE, folder TEXT COLLATE NOCASE, kind TEXT, hash TEXT, phash INTEGER,
            status TEXT, modified REAL, indexed REAL, created REAL, size INTEGER, project_id TEXT, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS files_folder ON files(folder);
        CREATE INDEX IF NOT EXISTS files_hash ON files(hash);
        CREATE INDEX IF NOT EXISTS files_project ON files(project_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(id UNINDEXED, name, body, meta, tokenize='porter unicode61');
        CREATE TABLE IF NOT EXISTS file_content(id TEXT PRIMARY KEY, content TEXT);
        CREATE TABLE IF NOT EXISTS embeddings(file_id TEXT PRIMARY KEY, vec BLOB);
        CREATE TABLE IF NOT EXISTS rules(id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS categories(id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, status TEXT, priority INTEGER, scheduled_for REAL, created REAL, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status, priority, scheduled_for);
        CREATE TABLE IF NOT EXISTS schedules(id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, ts REAL, kind TEXT, batch TEXT, undoable INTEGER, undone INTEGER, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE INDEX IF NOT EXISTS events_batch ON events(batch);
        CREATE TABLE IF NOT EXISTS insights(key TEXT PRIMARY KEY, id TEXT, created REAL, dismissed INTEGER, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS review_items(id TEXT PRIMARY KEY, file_id TEXT, status TEXT, created REAL, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS graph_edges(src_type TEXT, src_id TEXT, dst_type TEXT, dst_id TEXT, relation TEXT);
        CREATE INDEX IF NOT EXISTS edges_src ON graph_edges(src_type, src_id);
        CREATE INDEX IF NOT EXISTS edges_dst ON graph_edges(dst_type, dst_id);
        CREATE TABLE IF NOT EXISTS observed_moves(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_snapshots(folder TEXT, ts REAL, size INTEGER, count INTEGER);
        CREATE TABLE IF NOT EXISTS command_history(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, text TEXT);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
        """);
    }

    // MARK: plumbing

    void Exec(string sql, params object?[] args)
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = sql;
            Bind(cmd, args);
            cmd.ExecuteNonQuery();
        }
    }

    List<object?[]> Query(string sql, params object?[] args)
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = sql;
            Bind(cmd, args);
            using var r = cmd.ExecuteReader();
            var rows = new List<object?[]>();
            while (r.Read())
            {
                var row = new object?[r.FieldCount];
                for (var i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
                rows.Add(row);
            }
            return rows;
        }
    }

    static void Bind(SqliteCommand cmd, object?[] args)
    {
        for (var i = 0; i < args.Length; i++)
        {
            var v = args[i] switch { null => DBNull.Value, bool b => b ? 1 : 0, DateTime d => Time.Epoch(d), ulong u => unchecked((long)u), var x => x };
            cmd.Parameters.AddWithValue("$" + (i + 1), v);
        }
        var n = 0;
        cmd.CommandText = System.Text.RegularExpressions.Regex.Replace(cmd.CommandText, @"\?", _ => "$" + (++n));
    }

    List<T> Docs<T>(string sql, params object?[] args) =>
        Query(sql, args).Select(r => Json.Parse<T>(r[0] as string)).Where(x => x != null).Select(x => x!).ToList();

    void Changed(string entity) => OnChange?.Invoke(entity);

    // MARK: kv

    public string? Kv(string key) => Query("SELECT value FROM kv WHERE key=?", key).FirstOrDefault()?[0] as string;
    public void SetKv(string key, string? value)
    {
        if (value == null) Exec("DELETE FROM kv WHERE key=?", key);
        else Exec("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value);
    }

    public NexusSettings LoadSettings() => Json.Parse<NexusSettings>(Kv("settings")) ?? new NexusSettings();
    public void SaveSettings(NexusSettings s) { SetKv("settings", Json.Str(s)); Changed("settings"); }

    // MARK: files

    public void UpsertFile(FileRecord f, string? content = null)
    {
        f.Path = Paths.Canonical(f.Path);
        lock (gate)
        {
            // A different record may already own this path (e.g. file replaced) — keep the newest
            Exec("DELETE FROM files WHERE path=? AND id<>?", f.Path, f.Id);
            Exec("""
                INSERT INTO files(id,path,folder,kind,hash,phash,status,modified,indexed,created,size,project_id,json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET path=excluded.path, folder=excluded.folder, kind=excluded.kind, hash=excluded.hash, phash=excluded.phash,
                status=excluded.status, modified=excluded.modified, indexed=excluded.indexed, created=excluded.created, size=excluded.size, project_id=excluded.project_id, json=excluded.json
                """, f.Id, f.Path, f.Folder, f.Kind.ToString(), f.ContentHash, f.PerceptualHash, f.Status.ToString(), f.ModifiedAt, f.IndexedAt, f.CreatedAt, f.Size, f.ProjectId, Json.Str(f));
            var body = content;
            if (body == null) body = FileContent(f.Id) ?? f.Snippet;
            else Exec("INSERT INTO file_content(id,content) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET content=excluded.content", f.Id, content);
            Exec("DELETE FROM files_fts WHERE id=?", f.Id);
            var meta = string.Join(' ', f.Topics.Concat(f.Tags).Concat(f.Entities.Select(e => e.Value)).Append(f.DocType ?? ""));
            Exec("INSERT INTO files_fts(id,name,body,meta) VALUES(?,?,?,?)", f.Id, System.IO.Path.GetFileNameWithoutExtension(f.Name).Replace('_', ' ').Replace('-', ' '), body.Length > 200_000 ? body[..200_000] : body, meta);
        }
        Changed("files");
    }

    public FileRecord? File(string id) => Docs<FileRecord>("SELECT json FROM files WHERE id=?", id).FirstOrDefault();
    public FileRecord? FileByPath(string path) => Docs<FileRecord>("SELECT json FROM files WHERE path=?", Paths.Canonical(path)).FirstOrDefault();
    public string? FileContent(string id) => Query("SELECT content FROM file_content WHERE id=?", id).FirstOrDefault()?[0] as string;
    public int FileCount() => Convert.ToInt32(Query("SELECT COUNT(*) FROM files WHERE status<>'missing'")[0][0]);

    public List<FileRecord> Files(int limit = 500, string? projectId = null, string orderBy = "modified DESC") =>
        projectId == null
            ? Docs<FileRecord>($"SELECT json FROM files WHERE status<>'missing' ORDER BY {orderBy} LIMIT ?", limit)
            : Docs<FileRecord>($"SELECT json FROM files WHERE status<>'missing' AND project_id=? ORDER BY {orderBy} LIMIT ?", projectId, limit);

    public List<FileRecord> FilesInFolder(string folder) => Docs<FileRecord>("SELECT json FROM files WHERE folder=? AND status<>'missing'", Paths.Canonical(folder));
    public List<FileRecord> FilesWithHash(string hash) => Docs<FileRecord>("SELECT json FROM files WHERE hash=? AND status<>'missing'", hash);

    public List<string> DuplicateHashes(long minSize = 1) =>
        Query("SELECT hash FROM files WHERE hash IS NOT NULL AND status<>'missing' AND size>=? GROUP BY hash HAVING COUNT(*)>1", minSize).Select(r => (string)r[0]!).ToList();

    public void MarkMissing(string path)
    {
        if (FileByPath(path) is { } f) { f.Status = FileStatus.missing; UpsertFile(f); }
    }

    public (int count, long size) ProjectStats(string projectId)
    {
        var r = Query("SELECT COUNT(*), COALESCE(SUM(size),0) FROM files WHERE project_id=? AND status<>'missing'", projectId)[0];
        return (Convert.ToInt32(r[0]), Convert.ToInt64(r[1]));
    }

    public List<FileRecord> SearchFiles(string text, int limit = 100)
    {
        var terms = Classifier.Tokens(text).Concat(text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length > 1 && w.All(char.IsLetterOrDigit)).Select(w => w.ToLowerInvariant()))
            .Distinct().Take(8).ToList();
        if (terms.Count == 0) return [];
        var match = string.Join(" OR ", terms.Select(t => "\"" + t.Replace("\"", "") + "\"*"));
        try
        {
            return Docs<FileRecord>("SELECT f.json FROM files_fts s JOIN files f ON f.id=s.id WHERE files_fts MATCH ? AND f.status<>'missing' ORDER BY bm25(files_fts, 0, 4.0, 1.0, 2.0) LIMIT ?", match, limit);
        }
        catch (SqliteException) { return []; }
    }

    // MARK: embeddings

    public void SaveEmbedding(string fileId, float[] v)
    {
        var bytes = new byte[v.Length * 4];
        Buffer.BlockCopy(v, 0, bytes, 0, bytes.Length);
        Exec("INSERT INTO embeddings(file_id,vec) VALUES(?,?) ON CONFLICT(file_id) DO UPDATE SET vec=excluded.vec", fileId, bytes);
    }

    public List<(string id, float[] vec)> AllEmbeddings() =>
        Query("SELECT e.file_id, e.vec FROM embeddings e JOIN files f ON f.id=e.file_id WHERE f.status<>'missing'").Select(r =>
        {
            var b = (byte[])r[1]!; var v = new float[b.Length / 4]; Buffer.BlockCopy(b, 0, v, 0, b.Length); return ((string)r[0]!, v);
        }).ToList();

    // MARK: graph

    public void RemoveEdges(NodeType srcType, string srcId) => Exec("DELETE FROM graph_edges WHERE src_type=? AND src_id=?", srcType.ToString(), srcId);
    public void AddEdges(IEnumerable<GraphEdge> edges)
    {
        foreach (var e in edges) Exec("INSERT INTO graph_edges VALUES(?,?,?,?,?)", e.SrcType.ToString(), e.SrcId, e.DstType.ToString(), e.DstId, e.Relation);
    }
    public List<GraphEdge> EdgesFrom(NodeType t, string id) => Query("SELECT * FROM graph_edges WHERE src_type=? AND src_id=?", t.ToString(), id).Select(ToEdge).ToList();
    public List<GraphEdge> EdgesTo(NodeType t, string id) => Query("SELECT * FROM graph_edges WHERE dst_type=? AND dst_id=? LIMIT 500", t.ToString(), id).Select(ToEdge).ToList();
    static GraphEdge ToEdge(object?[] r) => new(Enum.Parse<NodeType>((string)r[0]!), (string)r[1]!, Enum.Parse<NodeType>((string)r[2]!), (string)r[3]!, (string)r[4]!);

    // MARK: rules, projects, categories

    public List<Rule> Rules() => Docs<Rule>("SELECT json FROM rules").OrderByDescending(r => r.Priority).ThenBy(r => r.CreatedAt).ToList();
    public Rule? Rule(string id) => Docs<Rule>("SELECT json FROM rules WHERE id=?", id).FirstOrDefault();
    public void SaveRule(Rule r) { Exec("INSERT INTO rules(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", r.Id, Json.Str(r)); Changed("rules"); }
    public void DeleteRule(string id) { Exec("DELETE FROM rules WHERE id=?", id); Changed("rules"); }
    public void RecordRuleHit(string id)
    {
        if (Rule(id) is not { } r) return;
        r.HitCount++; r.LastTriggeredAt = DateTime.Now; SaveRule(r);
    }

    public List<Project> Projects(bool includeArchived = true) => Docs<Project>("SELECT json FROM projects").Where(p => includeArchived || !p.Archived).OrderBy(p => p.Name).ToList();
    public Project? Project(string id) => Docs<Project>("SELECT json FROM projects WHERE id=?", id).FirstOrDefault();
    public Project? ProjectNamed(string name)
    {
        var all = Projects();
        return all.FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
            ?? all.FirstOrDefault(p => p.Name.Contains(name, StringComparison.OrdinalIgnoreCase) || name.Contains(p.Name, StringComparison.OrdinalIgnoreCase));
    }
    public void SaveProject(Project p) { Exec("INSERT INTO projects(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", p.Id, Json.Str(p)); Changed("projects"); }
    public void DeleteProject(string id) { Exec("DELETE FROM projects WHERE id=?", id); Changed("projects"); }

    public List<Category> Categories() => Docs<Category>("SELECT json FROM categories");
    public void SaveCategory(Category c) => Exec("INSERT INTO categories(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", c.Id, Json.Str(c));

    // MARK: jobs & schedules

    public void SaveJob(Job j)
    {
        Exec("INSERT INTO jobs(id,status,priority,scheduled_for,created,json) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status, priority=excluded.priority, scheduled_for=excluded.scheduled_for, json=excluded.json",
            j.Id, j.Status.ToString(), (int)j.Priority, j.ScheduledFor, j.CreatedAt, Json.Str(j));
        Changed("jobs");
    }
    public Job? Job(string id) => Docs<Job>("SELECT json FROM jobs WHERE id=?", id).FirstOrDefault();
    public List<Job> Jobs(int limit = 100) => Docs<Job>("SELECT json FROM jobs ORDER BY created DESC LIMIT ?", limit);
    public List<Job> JobsWithStatus(IEnumerable<JobStatus> statuses, int limit = 200)
    {
        var list = string.Join(",", statuses.Select(s => $"'{s}'"));
        return Docs<Job>($"SELECT json FROM jobs WHERE status IN ({list}) ORDER BY priority DESC, scheduled_for LIMIT ?", limit);
    }
    public List<Job> DueJobs(int limit) =>
        Docs<Job>("SELECT json FROM jobs WHERE status IN ('queued','scheduled') AND scheduled_for<=? ORDER BY priority DESC, scheduled_for LIMIT ?", DateTime.Now, limit);
    public void PruneJobs() => Exec("DELETE FROM jobs WHERE status IN ('completed','cancelled') AND created<?", DateTime.Now.AddDays(-14));

    public List<Schedule> Schedules() => Docs<Schedule>("SELECT json FROM schedules");
    public void SaveSchedule(Schedule s) { Exec("INSERT INTO schedules(id,json) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", s.Id, Json.Str(s)); Changed("schedules"); }
    public void DeleteSchedule(string id) { Exec("DELETE FROM schedules WHERE id=?", id); Changed("schedules"); }

    // MARK: events & undo

    public void Log(ActivityEvent e)
    {
        Exec("INSERT INTO events(id,ts,kind,batch,undoable,undone,json) VALUES(?,?,?,?,?,?,?)", e.Id, e.Timestamp, e.Kind.ToString(), e.BatchId, e.Undo != null, e.Undone, Json.Str(e));
        Changed("events");
    }
    public List<ActivityEvent> Events(int limit = 200) => Docs<ActivityEvent>("SELECT json FROM events ORDER BY ts DESC LIMIT ?", limit);
    public int EventCount(EventKind kind, DateTime since) => Convert.ToInt32(Query("SELECT COUNT(*) FROM events WHERE kind=? AND ts>=?", kind.ToString(), since)[0][0]);
    public string? LastUndoableBatch() => Query("SELECT batch FROM events WHERE undoable=1 AND undone=0 AND batch IS NOT NULL ORDER BY ts DESC LIMIT 1").FirstOrDefault()?[0] as string;
    public List<ActivityEvent> BatchEvents(string batch) => Docs<ActivityEvent>("SELECT json FROM events WHERE batch=? AND undoable=1 AND undone=0 ORDER BY ts DESC", batch);
    public void MarkUndone(ActivityEvent e)
    {
        e.Undone = true;
        Exec("UPDATE events SET undone=1, json=? WHERE id=?", Json.Str(e), e.Id);
        Changed("events");
    }

    public void AddCommandHistory(string text) => Exec("INSERT INTO command_history(ts,text) VALUES(?,?)", DateTime.Now, text);
    public List<string> CommandHistory(int limit = 20) => Query("SELECT text FROM command_history ORDER BY id DESC LIMIT ?", limit).Select(r => (string)r[0]!).Distinct().ToList();

    // MARK: insights & review

    public List<Insight> Insights() => Docs<Insight>("SELECT json FROM insights WHERE dismissed=0 ORDER BY created DESC")
        .OrderByDescending(i => (int)i.Severity).ToList();
    public void UpsertInsight(Insight i)
    {
        var existing = Query("SELECT id, dismissed FROM insights WHERE key=?", i.Key).FirstOrDefault();
        if (existing != null) { i.Id = (string)existing[0]!; i.Dismissed = Convert.ToInt32(existing[1]) == 1 && i.Dismissed; }
        Exec("INSERT INTO insights(key,id,created,dismissed,json) VALUES(?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET json=excluded.json, created=excluded.created, dismissed=excluded.dismissed",
            i.Key, i.Id, i.CreatedAt, i.Dismissed, Json.Str(i));
        Changed("insights");
    }
    public void RemoveInsight(string key) { Exec("DELETE FROM insights WHERE key=?", key); Changed("insights"); }
    public void RemoveInsightsWithPrefix(string prefix) { Exec("DELETE FROM insights WHERE key LIKE ?", prefix + "%"); Changed("insights"); }
    public void DismissInsight(string id) { Exec("UPDATE insights SET dismissed=1 WHERE id=?", id); Changed("insights"); }

    public List<ReviewItem> ReviewItems() => Docs<ReviewItem>("SELECT json FROM review_items WHERE status='pending' ORDER BY created DESC");
    public int ReviewCount() => Convert.ToInt32(Query("SELECT COUNT(*) FROM review_items WHERE status='pending'")[0][0]);
    public ReviewItem? PendingReview(string fileId) => Docs<ReviewItem>("SELECT json FROM review_items WHERE file_id=? AND status='pending'", fileId).FirstOrDefault();
    public void SaveReview(ReviewItem r)
    {
        Exec("INSERT INTO review_items(id,file_id,status,created,json) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status, json=excluded.json",
            r.Id, r.FileId, r.Status.ToString(), r.CreatedAt, Json.Str(r));
        Changed("review");
    }

    // MARK: learning data

    public void RecordObservedMove(ObservedMove m) => Exec("INSERT INTO observed_moves(ts,json) VALUES(?,?)", m.At, Json.Str(m));
    public List<ObservedMove> ObservedMoves(int days = 60) => Docs<ObservedMove>("SELECT json FROM observed_moves WHERE ts>=?", DateTime.Now.AddDays(-days));

    public void SaveSnapshot(string folder, long size, int count) => Exec("INSERT INTO folder_snapshots VALUES(?,?,?,?)", folder, DateTime.Now, size, count);
    public List<(DateTime at, long size, int count)> Snapshots(string folder) =>
        Query("SELECT ts,size,count FROM folder_snapshots WHERE folder=? ORDER BY ts", folder).Select(r => (Time.FromEpoch(Convert.ToDouble(r[0])), Convert.ToInt64(r[1]), Convert.ToInt32(r[2]))).ToList();
}
