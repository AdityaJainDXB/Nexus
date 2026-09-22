using System.Text.RegularExpressions;

namespace Nexus.Core;

public class FolderProfile
{
    public string Path { get; set; } = "";
    public Dictionary<string, double> Terms { get; set; } = [];
    public Dictionary<string, int> ExtCounts { get; set; } = [];
    public int FileCount { get; set; }
}

public record DestinationSuggestion(string Folder, double Score, string Reason);

/// Learns the user's folder structure and remembers where they file things.
public class TaxonomyLearner
{
    public List<FolderProfile> Profiles { get; private set; } = [];
    public Dictionary<string, Dictionary<string, int>> DocTypeMemory { get; private set; } = [];
    public Dictionary<string, Dictionary<string, int>> KeywordMemory { get; private set; } = [];
    readonly object gate = new();
    readonly NexusStore store;

    class Persisted
    {
        public List<FolderProfile> Profiles { get; set; } = [];
        public Dictionary<string, Dictionary<string, int>> DocTypeMemory { get; set; } = [];
        public Dictionary<string, Dictionary<string, int>> KeywordMemory { get; set; } = [];
    }

    public TaxonomyLearner(NexusStore store)
    {
        this.store = store;
        if (Json.Parse<Persisted>(store.Kv("taxonomy")) is { } p) { Profiles = p.Profiles; DocTypeMemory = p.DocTypeMemory; KeywordMemory = p.KeywordMemory; }
    }

    void Persist()
    {
        Persisted p;
        lock (gate) p = new Persisted { Profiles = Profiles, DocTypeMemory = DocTypeMemory, KeywordMemory = KeywordMemory };
        store.SetKv("taxonomy", Json.Str(p));
    }

    public static readonly HashSet<string> SkipDirs = new(StringComparer.OrdinalIgnoreCase)
    { "node_modules", ".git", "build", "bin", "obj", "Pods", ".venv", "venv", "__pycache__", "target", "dist", ".build", "AppData", "$RECYCLE.BIN", ".vs", ".idea", "packages" };

    static readonly string[] RepoMarkers = [".git", "package.json", "Cargo.toml", "build.gradle", "pyproject.toml", "Package.swift"];
    public static bool IsProjectRepo(string path)
    {
        try
        {
            foreach (var item in Directory.EnumerateFileSystemEntries(path).Select(System.IO.Path.GetFileName))
                if (item != null && (RepoMarkers.Contains(item) || item.EndsWith(".sln") || item.EndsWith(".slnx") || item.EndsWith(".csproj") || item.EndsWith(".xcodeproj"))) return true;
        }
        catch { }
        return false;
    }

    /// Walks library roots (depth ≤ 3) and builds a term profile per folder.
    public void Learn(IEnumerable<string> roots, int maxDepth = 3, Func<bool>? cancelled = null)
    {
        var profiles = new List<FolderProfile>();
        foreach (var root in roots.Where(Directory.Exists))
        {
            var rootDepth = Depth(root);
            var folders = new List<string> { root };
            var stack = new Stack<string>([root]);
            while (stack.Count > 0 && folders.Count < 2500)
            {
                if (cancelled?.Invoke() == true) return;
                var dir = stack.Pop();
                IEnumerable<string> subs;
                try { subs = Directory.EnumerateDirectories(dir).ToList(); } catch { continue; }
                foreach (var s in subs)
                {
                    var name = System.IO.Path.GetFileName(s);
                    if (name.StartsWith('.') || SkipDirs.Contains(name) || IsHidden(s)) continue;
                    if (Depth(s) - rootDepth > maxDepth || IsProjectRepo(s)) continue;
                    folders.Add(s);
                    stack.Push(s);
                }
            }
            foreach (var folder in folders)
            {
                var terms = new Dictionary<string, double>();
                var rel = folder.Length > root.Length ? folder[root.Length..].Trim(Paths.Sep) : System.IO.Path.GetFileName(root);
                var comps = (System.IO.Path.GetFileName(root) + Paths.Sep + rel).Split(Paths.Sep, StringSplitOptions.RemoveEmptyEntries);
                for (var i = 0; i < comps.Length; i++)
                    foreach (var t in Classifier.Tokens(comps[i])) terms[t] = terms.GetValueOrDefault(t) + 2 + i;
                var exts = new Dictionary<string, int>();
                var count = 0;
                try
                {
                    foreach (var c in Directory.EnumerateFiles(folder).Take(300))
                    {
                        var n = System.IO.Path.GetFileName(c);
                        if (n.StartsWith('.')) continue;
                        var ext = System.IO.Path.GetExtension(n).TrimStart('.').ToLowerInvariant();
                        if (ext.Length == 0) continue;
                        count++;
                        exts[ext] = exts.GetValueOrDefault(ext) + 1;
                        foreach (var t in Classifier.Tokens(System.IO.Path.GetFileNameWithoutExtension(n))) terms[t] = terms.GetValueOrDefault(t) + 0.5;
                    }
                }
                catch { }
                foreach (var f in store.FilesInFolder(folder).Take(200))
                {
                    foreach (var t in f.Topics) terms[t] = terms.GetValueOrDefault(t) + 1;
                    if (f.DocType != null) foreach (var t in Classifier.Tokens(f.DocType)) terms[t] = terms.GetValueOrDefault(t) + 1;
                }
                if (terms.Count == 0) continue;
                profiles.Add(new FolderProfile { Path = Paths.Canonical(folder), Terms = Normalize(terms), ExtCounts = exts, FileCount = count });
            }
        }
        lock (gate) Profiles = profiles;
        Persist();
    }

    static int Depth(string p) => Paths.Canonical(p).Split(Paths.Sep, StringSplitOptions.RemoveEmptyEntries).Length;
    static bool IsHidden(string p) { try { return new DirectoryInfo(p).Attributes.HasFlag(FileAttributes.Hidden) || new DirectoryInfo(p).Attributes.HasFlag(FileAttributes.System); } catch { return false; } }

    /// Words that describe a kind of file, matched against folder names ("Images & Media", "CAD & Electronics").
    public static List<string> KindTerms(FileRecord f)
    {
        List<string> t = f.Kind switch
        {
            FileKind.image => ["images", "image", "media", "photos", "pictures", "wallpapers", "graphics"],
            FileKind.screenshot => ["screenshots", "screenshot", "images", "media"],
            FileKind.video => ["video", "videos", "media", "movies", "clips"],
            FileKind.audio => ["audio", "music", "media", "recordings", "sounds"],
            FileKind.cad => ["cad", "electronics", "models", "printing", "pcb", "hardware"],
            FileKind.code => ["code", "scripts", "snippets", "software", "dev"],
            FileKind.spreadsheet => ["data", "sheets", "spreadsheets", "finance"],
            FileKind.presentation => ["presentations", "slides", "decks"],
            FileKind.installer => ["installers", "apps", "software", "setup"],
            FileKind.archive => ["archives", "zips"],
            FileKind.pdf or FileKind.document or FileKind.text => ["documents", "docs", "papers"],
            _ => []
        };
        if (f.DocType is "lab report" or "essay" or "syllabus" or "assignment") t.AddRange(["school", "class", "coursework", "homework"]);
        if (f.DocType is "invoice" or "receipt" or "bank statement" or "tax document") t.AddRange(["finance", "bills", "money", "receipts", "invoices", "taxes"]);
        if (f.DocType is "contract" or "resume") t.AddRange(["proposals", "career", "legal"]);
        return t;
    }

    public void Reinforce(string folder, string? docType, IEnumerable<string> keywords, int weight = 1)
    {
        folder = Paths.Canonical(folder);
        lock (gate)
        {
            if (docType != null)
            {
                if (!DocTypeMemory.TryGetValue(docType, out var d)) DocTypeMemory[docType] = d = [];
                d[folder] = d.GetValueOrDefault(folder) + weight;
            }
            foreach (var k in keywords.Distinct().Take(12))
            {
                if (!KeywordMemory.TryGetValue(k, out var d)) KeywordMemory[k] = d = [];
                d[folder] = d.GetValueOrDefault(folder) + weight;
            }
        }
        Persist();
    }

    public void Penalize(string folder, string? docType)
    {
        folder = Paths.Canonical(folder);
        lock (gate)
            if (docType != null && DocTypeMemory.TryGetValue(docType, out var d) && d.TryGetValue(folder, out var c)) d[folder] = Math.Max(0, c - 2);
        Persist();
    }

    public List<DestinationSuggestion> Suggest(FileRecord file, IEnumerable<string> keywords, ISet<string>? excluding = null, int limit = 3)
    {
        List<FolderProfile> profiles; Dictionary<string, Dictionary<string, int>> dm, km;
        lock (gate)
        {
            profiles = Profiles.Where(p => excluding == null || !excluding.Contains(p.Path)).ToList();
            dm = DocTypeMemory.ToDictionary(k => k.Key, v => new Dictionary<string, int>(v.Value));
            km = KeywordMemory.ToDictionary(k => k.Key, v => new Dictionary<string, int>(v.Value));
        }
        var vec = new Dictionary<string, double>();
        var kw = keywords.ToList();
        foreach (var k in kw) vec[k] = vec.GetValueOrDefault(k) + 1;
        foreach (var t in KindTerms(file)) vec[t] = vec.GetValueOrDefault(t) + 2;
        foreach (var t in file.Topics) vec[t.ToLowerInvariant()] = vec.GetValueOrDefault(t.ToLowerInvariant()) + 3;
        if (file.DocType != null) foreach (var t in Classifier.Tokens(file.DocType)) vec[t] = vec.GetValueOrDefault(t) + 3;
        foreach (var e in file.Entities.Where(e => e.Kind is EntityKind.course or EntityKind.organization))
            foreach (var t in Classifier.Tokens(e.Value)) vec[t] = vec.GetValueOrDefault(t) + 2;
        vec = Normalize(vec);

        var scores = new Dictionary<string, (double score, string reason)>(Paths.Comparer);
        foreach (var p in profiles)
        {
            if (Paths.Same(p.Path, file.Folder) || Paths.IsInside(file.Folder, p.Path, recursive: false)) continue;
            var s = vec.Sum(kv => kv.Value * p.Terms.GetValueOrDefault(kv.Key));
            if (p.FileCount > 0 && p.ExtCounts.TryGetValue(file.Ext, out var e)) s += 0.15 * e / p.FileCount;
            if (s > 0.05) scores[p.Path] = (Math.Min(0.8, s * 1.8), $"Similar to files in {Paths.Abbreviate(p.Path)}");
        }
        if (file.DocType != null && dm.TryGetValue(file.DocType, out var dests))
        {
            double total = dests.Values.Sum();
            foreach (var (folder, c) in dests.Where(d => d.Value > 0))
            {
                var conf = Math.Min(0.97, 0.5 + 0.1 * Math.Min(c, 4) + 0.1 * (c / total));
                if (conf > (scores.TryGetValue(folder, out var x) ? x.score : 0)) scores[folder] = (conf, $"You filed {Text.Plural(c, $"“{file.DocType}” file")} here before");
            }
        }
        foreach (var k in kw.Distinct().Take(40))
        {
            if (!km.TryGetValue(k, out var d)) continue;
            foreach (var (folder, c) in d.Where(x => x.Value >= 2))
            {
                var conf = Math.Min(0.9, 0.45 + 0.08 * c);
                if (conf > (scores.TryGetValue(folder, out var x) ? x.score : 0)) scores[folder] = (conf, $"Files mentioning “{k}” usually go here");
            }
        }
        return scores.Where(s => Directory.Exists(s.Key)).Select(s => new DestinationSuggestion(s.Key, s.Value.score, s.Value.reason))
            .OrderByDescending(s => s.Score).Take(limit).ToList();
    }

    public List<string> KnownTerms { get { lock (gate) return Profiles.Select(p => System.IO.Path.GetFileName(p.Path)).Where(n => n.Length > 2).ToList(); } }

    public static Dictionary<string, double> Normalize(Dictionary<string, double> v)
    {
        var n = Math.Sqrt(v.Values.Sum(x => x * x));
        return n > 0 ? v.ToDictionary(k => k.Key, k => k.Value / n) : v;
    }
}

public record ProjectMatch(Project Project, double Score, List<string> Reasons);

public class ProjectMatcher
{
    /// Noisy-OR combination of independent signals.
    public List<ProjectMatch> Match(FileRecord file, string text, IEnumerable<Project> projects, float[]? fileVector, IReadOnlyDictionary<string, float[]> projectVectors)
    {
        var hay = (file.Name + " " + file.Path + " " + (text.Length > 30_000 ? text[..30_000] : text) + " " + string.Join(' ', file.Topics) + " " + string.Join(' ', file.Tags)).ToLowerInvariant();
        var outList = new List<ProjectMatch>();
        foreach (var p in projects.Where(p => !p.Archived))
        {
            var signals = new List<double>(); var reasons = new List<string>();
            if (p.Folders.Any(f => Paths.IsInside(file.Path, Paths.Expand(f)))) { signals.Add(0.95); reasons.Add("Inside project folder"); }
            if (hay.Contains(p.Name.ToLowerInvariant())) { signals.Add(0.7); reasons.Add($"Mentions “{p.Name}”"); }
            var hits = p.Keywords.Where(k => k.Length > 0 && hay.Contains(k.ToLowerInvariant())).ToList();
            if (hits.Count > 0) { signals.Add(Math.Min(0.8, 0.35 + 0.15 * hits.Count)); reasons.Add("Keywords: " + string.Join(", ", hits.Take(3))); }
            if (p.Tags.Select(t => t.ToLowerInvariant()).Intersect(file.Tags.Select(t => t.ToLowerInvariant())).Any()) { signals.Add(0.5); reasons.Add("Shared tags"); }
            if (fileVector != null && projectVectors.TryGetValue(p.Id, out var pv))
            {
                var sim = Embedder.Cosine(fileVector, pv);
                if (sim > 0.45) { signals.Add(Math.Min(0.6, (sim - 0.35) * 1.5)); reasons.Add($"Semantically similar ({(int)(sim * 100)}%)"); }
            }
            if (p.Deadline is { } d && signals.Count > 0 && d > DateTime.Now && (d - DateTime.Now).TotalDays < 14) { signals.Add(0.15); reasons.Add("Deadline is near"); }
            if (signals.Count == 0) continue;
            outList.Add(new ProjectMatch(p, 1 - signals.Aggregate(1.0, (acc, s) => acc * (1 - s)), reasons));
        }
        return outList.OrderByDescending(m => m.Score).ToList();
    }
}

/// On-device text vectors: hashed word unigrams + bigrams + character trigrams into 512 dims (no model needed).
public class Embedder
{
    const int Dims = 512;

    public float[]? Vector(string text)
    {
        var t = (text.Length > 1500 ? text[..1500] : text).Trim().ToLowerInvariant();
        if (t.Length == 0) return null;
        var v = new float[Dims];
        var words = Classifier.Tokens(t);
        if (words.Count == 0) return null;
        for (var i = 0; i < words.Count; i++)
        {
            Add(v, "w:" + Stem(words[i]), 1.0f);
            if (i > 0) Add(v, "b:" + Stem(words[i - 1]) + "_" + Stem(words[i]), 0.5f);
            var w = "#" + words[i] + "#";
            for (var j = 0; j + 3 <= w.Length; j++) Add(v, "c:" + w.Substring(j, 3), 0.25f);
        }
        var norm = MathF.Sqrt(v.Sum(x => x * x));
        if (norm > 0) for (var i = 0; i < Dims; i++) v[i] /= norm;
        return v;
    }

    static string Stem(string w) => w.Length > 5 && w.EndsWith('s') ? w[..^1] : w;

    static void Add(float[] v, string feature, float weight)
    {
        var h = unchecked((uint)feature.Aggregate(2166136261u, (acc, c) => (acc ^ c) * 16777619u));
        v[h % Dims] += (h & 0x80000000) != 0 ? weight : -weight;
    }

    public static double Cosine(float[] a, float[] b)
    {
        if (a.Length != b.Length || a.Length == 0) return 0;
        double dot = 0, na = 0, nb = 0;
        for (var i = 0; i < a.Length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
        return na > 0 && nb > 0 ? dot / (Math.Sqrt(na) * Math.Sqrt(nb)) : 0;
    }
}

public static class ExtractiveSummarizer
{
    public static string Summarize(string text, int sentences = 3)
    {
        var body = text.Length > 40_000 ? text[..40_000] : text;
        var all = Regex.Split(body, @"(?<=[.!?])\s+|\n{2,}").Select(s => s.Collapse()).Where(s => s.Length is > 30 and < 400).Take(400).ToList();
        if (all.Count <= sentences) return string.Join(' ', all);
        var freq = new Dictionary<string, double>();
        foreach (var s in all) foreach (var t in Classifier.Tokens(s)) freq[t] = freq.GetValueOrDefault(t) + 1;
        return string.Join(' ', all.Select((s, i) =>
        {
            var toks = Classifier.Tokens(s);
            return (i, score: toks.Sum(t => freq.GetValueOrDefault(t)) / Math.Max(8, toks.Count) + (i < 3 ? 0.5 : 0));
        }).OrderByDescending(x => x.score).Take(sentences).OrderBy(x => x.i).Select(x => all[x.i]));
    }
}

/// Finds the places this user actually keeps things.
public static class FolderDiscovery
{
    public record Candidate(string Path, string Label, List<string> Subfolders, bool Recommended);

    public static List<Candidate> Candidates()
    {
        var home = Paths.Home;
        var list = new List<(string path, string label, bool rec)>
        {
            (Paths.KnownFolder("documents"), "Documents", true), (Paths.KnownFolder("desktop"), "Desktop", true), (Paths.KnownFolder("downloads"), "Downloads subfolders", true),
            (System.IO.Path.Combine(home, "iCloudDrive"), "iCloud Drive", true),
            (Paths.KnownFolder("pictures"), "Pictures", false), (Paths.KnownFolder("videos"), "Videos", false), (Paths.KnownFolder("music"), "Music", false),
        };
        foreach (var env in new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" })
            if (Environment.GetEnvironmentVariable(env) is { Length: > 0 } od && Environment.GetEnvironmentVariable("NEXUS_HOME_ROOT") == null) list.Add((od, "OneDrive", true));
        try
        {
            foreach (var d in Directory.EnumerateDirectories(home))
            {
                var n = System.IO.Path.GetFileName(d);
                if (n.StartsWith("OneDrive") || n.StartsWith("Dropbox") || n is "Google Drive" or "My Drive" or "Box") list.Add((d, n, true));
            }
        }
        catch { }
        var seen = new HashSet<string>(Paths.Comparer);
        var result = new List<Candidate>();
        foreach (var (path, label, rec) in list)
        {
            var p = Paths.Canonical(path);
            if (!Directory.Exists(p) || !seen.Add(p)) continue;
            List<string> subs;
            try
            {
                subs = Directory.EnumerateDirectories(p).Select(System.IO.Path.GetFileName).Where(n => n != null && !n.StartsWith('.') && !TaxonomyLearner.SkipDirs.Contains(n) && n != "desktop.ini")
                    .Select(n => n!).OrderBy(n => n).ToList();
            }
            catch { continue; }
            if (label == "Downloads subfolders" && subs.Count == 0) continue;
            // Documents/Desktop inside OneDrive are already listed via the known folders
            result.Add(new Candidate(p, label, subs, rec && subs.Count > 0));
        }
        return result;
    }

    static readonly Dictionary<string, string[]> Synonyms = new()
    {
        ["Invoices"] = ["invoices", "bills", "finance", "financial", "money"], ["Receipts"] = ["receipts", "finance", "purchases"],
        ["Bank statements"] = ["statements", "bank", "finance"], ["Tax documents"] = ["tax", "taxes", "finance"],
        ["Lab reports"] = ["lab", "labs", "science", "physics", "chemistry", "biology"], ["Syllabi"] = ["syllabus", "syllabi", "school", "courses"],
        ["Assignments"] = ["assignments", "homework", "school", "coursework"], ["Essays"] = ["essays", "english", "writing", "school"],
        ["Resumes"] = ["resume", "career", "proposals"], ["Contracts"] = ["contracts", "legal", "proposals", "agreements"],
        ["Research papers"] = ["papers", "research", "reading"], ["Manuals"] = ["manuals", "guides", "docs"], ["Tickets"] = ["travel", "tickets", "trips"],
        ["Meeting notes"] = ["notes", "meetings"], ["Specs"] = ["specs", "proposals", "documents"], ["Code snippets"] = ["snippets", "scripts", "code"],
        ["3D models"] = ["cad", "models", "printing", "electronics"], ["Screenshots"] = ["screenshots", "images", "media"], ["Installers"] = ["installers", "apps", "setup"],
    };

    /// Best existing folder for a category name, or null. Searches roots up to depth 2.
    public static string? ExistingFolder(string category, IEnumerable<string> roots)
    {
        if (!Synonyms.TryGetValue(category, out var words)) return null;
        (string path, int score)? best = null;
        foreach (var root in roots.Where(Directory.Exists))
        {
            var queue = new Queue<(string, int)>([(root, 0)]);
            while (queue.Count > 0)
            {
                var (dir, depth) = queue.Dequeue();
                if (depth >= 2) continue;
                IEnumerable<string> subs;
                try { subs = Directory.EnumerateDirectories(dir).ToList(); } catch { continue; }
                foreach (var full in subs)
                {
                    var name = System.IO.Path.GetFileName(full);
                    if (name.StartsWith('.') || TaxonomyLearner.SkipDirs.Contains(name) || TaxonomyLearner.IsProjectRepo(full)) continue;
                    var tokens = Classifier.Tokens(name).ToHashSet();
                    var score = words.Select((w, i) => tokens.Contains(w) ? (words.Length - i) * 2 : 0).Sum() - depth;
                    if (score > 0 && score > (best?.score ?? 0)) best = (full, score);
                    queue.Enqueue((full, depth + 1));
                }
            }
        }
        return best?.path;
    }
}
