import Foundation
import AppKit
import NaturalLanguage

// MARK: - Taxonomy learner (learns the user's folder structure)

public struct FolderProfile: Codable, Hashable {
    public var path: String
    public var terms: [String: Double]
    public var extCounts: [String: Int]
    public var fileCount: Int
}

public struct DestinationSuggestion: Hashable {
    public var folder: String
    public var score: Double
    public var reason: String
}

public final class TaxonomyLearner {
    public private(set) var profiles: [FolderProfile] = []
    /// docType → destination folder → times the user confirmed it (approvals + manual moves)
    public private(set) var docTypeMemory: [String: [String: Int]] = [:]
    /// keyword → destination folder → count
    public private(set) var keywordMemory: [String: [String: Int]] = [:]
    private let lock = NSLock()
    private weak var store: NexusStore?

    struct Persisted: Codable { var profiles: [FolderProfile]; var docTypeMemory: [String: [String: Int]]; var keywordMemory: [String: [String: Int]] }

    public init(store: NexusStore) {
        self.store = store
        if let p = JSON.decode(Persisted.self, store.kv("taxonomy")) {
            profiles = p.profiles; docTypeMemory = p.docTypeMemory; keywordMemory = p.keywordMemory
        }
    }

    private func persist() {
        lock.lock(); let p = Persisted(profiles: profiles, docTypeMemory: docTypeMemory, keywordMemory: keywordMemory); lock.unlock()
        store?.setKV("taxonomy", JSON.string(p))
    }

    static let skipDirs: Set<String> = ["node_modules", ".git", "build", "DerivedData", "Pods", ".venv", "venv", "__pycache__", "target", "dist", ".build", "Library"]

    /// Walks library roots (depth ≤ 3) and builds a term profile per folder.
    public func learn(roots: [String], maxDepth: Int = 3, isCancelled: () -> Bool = { false }) {
        var newProfiles: [FolderProfile] = []
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            let rootDepth = URL(fileURLWithPath: root).pathComponents.count
            var folders: [URL] = [URL(fileURLWithPath: root)]
            for case let url as URL in en {
                if isCancelled() { return }
                let depth = url.pathComponents.count - rootDepth
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                guard vals?.isDirectory == true, vals?.isPackage != true else { continue }
                if Self.skipDirs.contains(url.lastPathComponent) || depth > maxDepth { en.skipDescendants(); continue }
                // Code repositories / app projects are never filing destinations
                if Self.isProjectRepo(url.path) { en.skipDescendants(); continue }
                folders.append(url)
                if folders.count > 2500 { break }
            }
            for folder in folders {
                var terms: [String: Double] = [:]
                let rel = folder.pathComponents.dropFirst(max(0, rootDepth - 1))
                for (i, comp) in rel.enumerated() {
                    for t in Classifier.tokens(comp) { terms[t, default: 0] += 2 + Double(i) } // deeper names are more specific
                }
                var exts: [String: Int] = [:]
                let children = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                var count = 0
                for c in children.prefix(300) where !c.hasPrefix(".") {
                    let ext = (c as NSString).pathExtension.lowercased()
                    guard !ext.isEmpty else { continue }
                    count += 1
                    exts[ext, default: 0] += 1
                    for t in Classifier.tokens((c as NSString).deletingPathExtension) { terms[t, default: 0] += 0.5 }
                }
                if let store {
                    for f in store.files(inFolder: folder.path).prefix(200) {
                        for t in f.topics { terms[t, default: 0] += 1 }
                        if let d = f.docType { for t in Classifier.tokens(d) { terms[t, default: 0] += 1 } }
                    }
                }
                guard !terms.isEmpty else { continue }
                newProfiles.append(FolderProfile(path: folder.path, terms: Self.normalize(terms), extCounts: exts, fileCount: count))
            }
        }
        lock.lock(); profiles = newProfiles; lock.unlock()
        persist()
    }

    static let repoMarkers = [".git", "Package.swift", "package.json", ".xcodeproj", "Cargo.toml", "build.gradle", "pyproject.toml"]
    static func isProjectRepo(_ path: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return items.contains { item in repoMarkers.contains { m in m.hasPrefix(".") && m.count > 4 && !m.hasPrefix(".git") ? item.hasSuffix(m) : item == m } }
    }

    /// Words that describe a kind of file, matched against folder names ("Images & Media", "CAD & Electronics").
    static func kindTerms(_ f: FileRecord) -> [String] {
        switch f.kind {
        case .image: return ["images", "image", "media", "photos", "pictures", "wallpapers", "graphics"]
        case .screenshot: return ["screenshots", "screenshot", "images", "media"]
        case .video: return ["video", "videos", "media", "movies", "clips"]
        case .audio: return ["audio", "music", "media", "recordings", "sounds"]
        case .cad: return ["cad", "electronics", "models", "printing", "pcb", "hardware"]
        case .code: return ["code", "scripts", "snippets", "software", "dev"]
        case .spreadsheet: return ["data", "sheets", "spreadsheets", "finance"]
        case .presentation: return ["presentations", "slides", "decks"]
        case .installer: return ["installers", "apps", "software"]
        case .archive: return ["archives", "zips"]
        case .pdf, .document, .text:
            var t = ["documents", "docs", "papers"]
            if let d = f.docType, ["lab report", "essay", "syllabus", "assignment"].contains(d) { t += ["school", "class", "coursework", "homework"] }
            if let d = f.docType, ["invoice", "receipt", "bank statement", "tax document"].contains(d) { t += ["finance", "bills", "money", "receipts", "invoices", "taxes"] }
            if let d = f.docType, ["contract", "resume"].contains(d) { t += ["proposals", "career", "legal"] }
            return t
        default: return []
        }
    }

    public func reinforce(folder: String, docType: String?, keywords: [String], weight: Int = 1) {
        lock.lock()
        if let d = docType { docTypeMemory[d, default: [:]][folder, default: 0] += weight }
        for k in Set(keywords).prefix(12) { keywordMemory[k, default: [:]][folder, default: 0] += weight }
        lock.unlock()
        persist()
    }

    public func penalize(folder: String, docType: String?) {
        lock.lock()
        if let d = docType, let c = docTypeMemory[d]?[folder] { docTypeMemory[d]?[folder] = max(0, c - 2) }
        lock.unlock()
        persist()
    }

    public func suggest(for file: FileRecord, keywords: [String], excluding: Set<String> = [], limit: Int = 3) -> [DestinationSuggestion] {
        lock.lock(); let profiles = self.profiles.filter { !excluding.contains($0.path) }; let dm = docTypeMemory; let km = keywordMemory; lock.unlock()
        var vec: [String: Double] = [:]
        for k in keywords { vec[k, default: 0] += 1 }
        for t in Self.kindTerms(file) { vec[t, default: 0] += 2 }
        for t in file.topics { vec[t.lowercased(), default: 0] += 3 }
        if let d = file.docType { for t in Classifier.tokens(d) { vec[t, default: 0] += 3 } }
        for e in file.entities where e.kind == .course || e.kind == .organization { for t in Classifier.tokens(e.value) { vec[t, default: 0] += 2 } }
        vec = Self.normalize(vec)

        var scores: [String: (Double, String)] = [:]
        for p in profiles where p.path != file.folder && !Paths.isInside(file.folder, p.path, recursive: false) {
            var s = 0.0
            for (t, w) in vec { s += w * (p.terms[t] ?? 0) }
            if p.fileCount > 0, let e = p.extCounts[file.ext] { s += 0.15 * Double(e) / Double(p.fileCount) }
            if s > 0.05 { scores[p.path] = (min(0.8, s * 1.8), "Similar to files in \(Paths.abbreviate(p.path))") }
        }
        // Personal memory is the strongest signal
        if let d = file.docType, let dests = dm[d] {
            let total = Double(dests.values.reduce(0, +))
            for (folder, c) in dests where c > 0 {
                let dominance = Double(c) / total
                let conf = min(0.97, 0.5 + 0.1 * Double(min(c, 4)) + 0.1 * dominance)
                if conf > (scores[folder]?.0 ?? 0) { scores[folder] = (conf, "You filed \(c) “\(d)” file\(c == 1 ? "" : "s") here before") }
            }
        }
        for k in Set(keywords).prefix(40) {
            guard let dests = km[k] else { continue }
            for (folder, c) in dests where c >= 2 {
                let conf = min(0.9, 0.45 + 0.08 * Double(c))
                if conf > (scores[folder]?.0 ?? 0) { scores[folder] = (conf, "Files mentioning “\(k)” usually go here") }
            }
        }
        return scores.filter { FileManager.default.fileExists(atPath: $0.key) }
            .map { DestinationSuggestion(folder: $0.key, score: $0.value.0, reason: $0.value.1) }
            .sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    public var knownTerms: [String] {
        lock.lock(); defer { lock.unlock() }
        return profiles.compactMap { ($0.path as NSString).lastPathComponent }.filter { $0.count > 2 }
    }

    static func normalize(_ v: [String: Double]) -> [String: Double] {
        let n = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.mapValues { $0 / n } : v
    }
}

// MARK: - Project matcher

public struct ProjectMatch {
    public var project: Project
    public var score: Double
    public var reasons: [String]
}

public final class ProjectMatcher {
    let embedder: Embedder
    public init(embedder: Embedder) { self.embedder = embedder }

    /// Noisy-OR combination of independent signals.
    public func match(file: FileRecord, text: String, projects: [Project], fileVector: [Float]?, projectVectors: [String: [Float]]) -> [ProjectMatch] {
        let hay = (file.name + " " + file.path + " " + String(text.prefix(30_000)) + " " + file.topics.joined(separator: " ") + " " + file.tags.joined(separator: " ")).lowercased()
        var out: [ProjectMatch] = []
        for p in projects where !p.archived {
            var signals: [Double] = []
            var reasons: [String] = []
            if p.folders.contains(where: { Paths.isInside(file.path, Paths.expand($0)) }) {
                signals.append(0.95); reasons.append("Inside project folder")
            }
            if hay.contains(p.name.lowercased()) { signals.append(0.7); reasons.append("Mentions “\(p.name)”") }
            let hits = p.keywords.filter { !$0.isEmpty && hay.contains($0.lowercased()) }
            if !hits.isEmpty {
                signals.append(min(0.8, 0.35 + 0.15 * Double(hits.count)))
                reasons.append("Keywords: \(hits.prefix(3).joined(separator: ", "))")
            }
            let tagHits = Set(p.tags.map { $0.lowercased() }).intersection(file.tags.map { $0.lowercased() })
            if !tagHits.isEmpty { signals.append(0.5); reasons.append("Shared tags") }
            if let fv = fileVector, let pv = projectVectors[p.id] {
                let sim = Embedder.cosine(fv, pv)
                if sim > 0.55 { signals.append(min(0.6, (sim - 0.45) * 1.5)); reasons.append("Semantically similar (\(Int(sim * 100))%)") }
            }
            if let d = p.deadline, !signals.isEmpty, d > Date(), d.timeIntervalSinceNow < 14 * 86400 {
                signals.append(0.15); reasons.append("Deadline is near")
            }
            guard !signals.isEmpty else { continue }
            let score = 1 - signals.reduce(1) { $0 * (1 - $1) }
            out.append(ProjectMatch(project: p, score: score, reasons: reasons))
        }
        return out.sorted { $0.score > $1.score }
    }
}

// MARK: - Embeddings (Apple NaturalLanguage sentence embeddings, on-device)

public final class Embedder {
    private lazy var model: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    private let lock = NSLock()
    public init() {}

    public func vector(_ text: String) -> [Float]? {
        let t = String(text.prefix(1500)).trimmed
        guard !t.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return model?.vector(for: t).map { $0.map(Float.init) }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(dot / (sqrt(na) * sqrt(nb))) : 0
    }
}

// MARK: - Extractive summarizer (fallback when no LLM is available)

public enum ExtractiveSummarizer {
    public static func summarize(_ text: String, sentences: Int = 3) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        let body = String(text.prefix(40_000))
        tokenizer.string = body
        var all: [String] = []
        tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { r, _ in
            let s = String(body[r]).trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if s.count > 30 && s.count < 400 { all.append(s) }
            return all.count < 400
        }
        guard all.count > sentences else { return all.joined(separator: " ") }
        var freq: [String: Double] = [:]
        for s in all { for t in Classifier.tokens(s) { freq[t, default: 0] += 1 } }
        let scored = all.enumerated().map { i, s -> (Int, Double) in
            let toks = Classifier.tokens(s)
            let score = toks.reduce(0) { $0 + (freq[$1] ?? 0) } / Double(max(8, toks.count)) + (i < 3 ? 0.5 : 0)
            return (i, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(sentences).sorted { $0.0 < $1.0 }.map { all[$0.0] }.joined(separator: " ")
    }
}

// MARK: - Folder discovery (find the user's real structure)

public enum FolderDiscovery {
    public struct Candidate: Hashable, Identifiable {
        public var id: String { path }
        public var path: String
        public var label: String
        public var subfolders: [String]
        public var recommended: Bool
    }

    /// Places people actually keep things: Documents, Desktop, organized Downloads subfolders, iCloud Drive, OneDrive/Dropbox/Google Drive, Pictures, Movies.
    public static func candidates() -> [Candidate] {
        let fm = FileManager.default
        let home = Paths.home
        var list: [(String, String, Bool)] = [
            (home + "/Documents", "Documents", true), (home + "/Desktop", "Desktop", true), (home + "/Downloads", "Downloads subfolders", true),
            (home + "/Library/Mobile Documents/com~apple~CloudDocs", "iCloud Drive", true),
            (home + "/Pictures", "Pictures", false), (home + "/Movies", "Movies", false), (home + "/Music", "Music", false),
        ]
        for d in (try? fm.contentsOfDirectory(atPath: home + "/Library/CloudStorage")) ?? [] {
            list.append((home + "/Library/CloudStorage/" + d, d.replacingOccurrences(of: "-", with: " "), true))
        }
        for d in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where d.hasPrefix("OneDrive") || d.hasPrefix("Dropbox") || d == "Google Drive" {
            list.append((home + "/" + d, d, true))
        }
        var seenReal = Set<String>()
        return list.compactMap { path, label, rec in
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seenReal.insert(real).inserted else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let subs = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { name in
                var d: ObjCBool = false
                let full = path + "/" + name
                return !name.hasPrefix(".") && fm.fileExists(atPath: full, isDirectory: &d) && d.boolValue && !NSWorkspace.shared.isFilePackage(atPath: full)
            }.sorted()
            // Downloads only counts if the user has organized it into subfolders
            if label == "Downloads subfolders" && subs.isEmpty { return nil }
            return Candidate(path: path, label: label, subfolders: subs, recommended: rec && !subs.isEmpty)
        }
    }

    static let synonyms: [String: [String]] = [
        "Invoices": ["invoices", "bills", "finance", "financial", "money"], "Receipts": ["receipts", "finance", "purchases"],
        "Bank statements": ["statements", "bank", "finance"], "Tax documents": ["tax", "taxes", "finance"],
        "Lab reports": ["lab", "labs", "science", "physics", "chemistry", "biology"], "Syllabi": ["syllabus", "syllabi", "school", "courses"],
        "Assignments": ["assignments", "homework", "school", "coursework"], "Essays": ["essays", "english", "writing", "school"],
        "Resumes": ["resume", "cv", "career", "proposals"], "Contracts": ["contracts", "legal", "proposals", "agreements"],
        "Research papers": ["papers", "research", "reading"], "Manuals": ["manuals", "guides", "docs"], "Tickets": ["travel", "tickets", "trips"],
        "Meeting notes": ["notes", "meetings"], "Specs": ["specs", "proposals", "documents"], "Code snippets": ["snippets", "scripts", "code"],
        "3D models": ["cad", "3d", "models", "printing", "electronics"], "Screenshots": ["screenshots", "images", "media"],
        "Installers": ["installers", "apps"],
    ]

    /// Best existing folder for a category name, or nil. Searches roots up to depth 2.
    public static func existingFolder(for category: String, roots: [String]) -> String? {
        guard let words = synonyms[category] else { return nil }
        var best: (String, Int)?
        let fm = FileManager.default
        for root in roots {
            var queue: [(String, Int)] = [(root, 0)]
            while let (dir, depth) = queue.first {
                queue.removeFirst()
                guard depth < 2 else { continue }
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                    let full = dir + "/" + name
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue, !NSWorkspace.shared.isFilePackage(atPath: full), !TaxonomyLearner.isProjectRepo(full) else { continue }
                    let tokens = Set(Classifier.tokens(name))
                    let score = words.enumerated().reduce(0) { acc, e in acc + (tokens.contains(e.element) ? (words.count - e.offset) * 2 : 0) } - depth
                    if score > 0 && score > (best?.1 ?? 0) { best = (full, score) }
                    queue.append((full, depth + 1))
                }
            }
        }
        return best?.0
    }
}
