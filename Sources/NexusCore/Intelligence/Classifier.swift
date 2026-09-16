import Foundation
import NaturalLanguage

public struct Classification {
    public var docType: String?
    public var docTypeConfidence: Double
    public var topics: [String]
    public var entities: [Entity]
    public var language: String?
    public var keywords: [String]      // normalized tokens used for similarity
}

/// Fast heuristic + Apple NaturalLanguage classifier. No network, no model download.
public final class Classifier {
    public init() {}

    struct DocTypeSignature {
        let name: String
        let terms: [String: Double]
        let namePatterns: [String]
        let kinds: Set<FileKind>
    }

    static let signatures: [DocTypeSignature] = [
        .init(name: "invoice", terms: ["invoice": 3, "invoice number": 3, "amount due": 3, "bill to": 2, "due date": 1.5, "subtotal": 1.5, "tax": 0.5, "total": 0.5, "payment terms": 2, "vat": 1], namePatterns: ["invoice", "inv-", "inv_"], kinds: [.pdf, .document, .image, .screenshot]),
        .init(name: "receipt", terms: ["receipt": 3, "order number": 1.5, "paid": 1, "thank you for your purchase": 2.5, "card ending": 2, "order total": 2], namePatterns: ["receipt", "order"], kinds: [.pdf, .image, .screenshot, .document]),
        .init(name: "bank statement", terms: ["statement period": 3, "opening balance": 3, "closing balance": 3, "account number": 1.5, "transactions": 1], namePatterns: ["statement"], kinds: [.pdf]),
        .init(name: "tax document", terms: ["form 1099": 4, "w-2": 3, "irs": 2, "tax year": 2.5, "taxable": 1.5, "form 1040": 4], namePatterns: ["1099", "w2", "1040", "tax"], kinds: [.pdf, .document]),
        .init(name: "lab report", terms: ["lab report": 4, "hypothesis": 2, "procedure": 1.5, "materials": 1, "independent variable": 3, "dependent variable": 3, "controlled variable": 2.5, "conclusion": 1, "data analysis": 1.5, "experiment": 1.5, "results": 0.5], namePatterns: ["lab", "experiment"], kinds: [.pdf, .document, .text]),
        .init(name: "essay", terms: ["introduction": 1, "in conclusion": 2, "thesis": 2, "works cited": 3, "bibliography": 2.5, "references": 1], namePatterns: ["essay"], kinds: [.pdf, .document, .text]),
        .init(name: "syllabus", terms: ["syllabus": 4, "course description": 3, "grading": 2, "office hours": 2.5, "learning outcomes": 2, "assessment criteria": 2], namePatterns: ["syllabus", "course outline"], kinds: [.pdf, .document]),
        .init(name: "assignment", terms: ["assignment": 2.5, "due": 1, "submit": 1.5, "rubric": 2.5, "criterion": 1.5, "task": 0.5, "worksheet": 2.5], namePatterns: ["assignment", "homework", "hw", "worksheet"], kinds: [.pdf, .document]),
        .init(name: "resume", terms: ["experience": 1, "education": 1, "skills": 1, "resume": 3, "curriculum vitae": 3, "references available": 2], namePatterns: ["resume", "cv"], kinds: [.pdf, .document]),
        .init(name: "contract", terms: ["agreement": 2, "hereinafter": 3, "party": 1, "terms and conditions": 2, "signature": 1, "governing law": 3, "indemnif": 3], namePatterns: ["contract", "agreement", "nda"], kinds: [.pdf, .document]),
        .init(name: "spec", terms: ["requirements": 2, "specification": 3, "acceptance criteria": 3, "user story": 2.5, "scope": 1, "architecture": 1.5, "api": 1, "non-goals": 2.5], namePatterns: ["spec", "prd", "rfc", "design doc"], kinds: [.pdf, .document, .text]),
        .init(name: "meeting notes", terms: ["agenda": 2, "attendees": 3, "action items": 3, "minutes": 1.5, "next steps": 1.5], namePatterns: ["notes", "minutes", "meeting"], kinds: [.document, .text, .pdf]),
        .init(name: "research paper", terms: ["abstract": 2.5, "doi": 2.5, "et al": 2, "arxiv": 3, "methodology": 1.5, "literature review": 2], namePatterns: ["paper", "arxiv"], kinds: [.pdf]),
        .init(name: "manual", terms: ["user manual": 4, "installation": 1.5, "troubleshooting": 2.5, "warranty": 2, "safety instructions": 2.5], namePatterns: ["manual", "guide"], kinds: [.pdf]),
        .init(name: "ticket", terms: ["boarding pass": 4, "gate": 1, "seat": 1, "flight": 2, "e-ticket": 3, "admit one": 3, "booking reference": 3], namePatterns: ["ticket", "boarding"], kinds: [.pdf, .image, .screenshot]),
        .init(name: "presentation", terms: [:], namePatterns: ["slides", "deck", "presentation"], kinds: [.presentation]),
        .init(name: "dataset", terms: [:], namePatterns: ["data", "dataset", "export"], kinds: [.spreadsheet]),
        .init(name: "3d model", terms: [:], namePatterns: [], kinds: []),
    ]

    static let stopwords: Set<String> = Set("""
    a an the and or but if then else of to in on at by for with about against between into through during before after above below from up down out off over under again further once here there when where why how all any both each few more most other some such no nor not only own same so than too very can will just don should now is are was were be been being have has had having do does did doing i me my we our you your he him his she her it its they them their what which who whom this that these those am would could page file pdf document image screenshot copy new final untitled version
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    static let pcbExtensions: Set<String> = ["kicad_pcb", "kicad_sch", "kicad_pro", "kicad_mod", "kicad_sym", "brd", "sch", "gbr", "gbl", "gtl", "gbo", "gto", "gts", "gbs", "drl", "lbr"]

    /// Subject lexicon → topic. Lets "velocity, acceleration, Newton…" route to a folder called Physics.
    static let subjects: [(String, [String])] = [
        ("physics", ["velocity", "acceleration", "momentum", "newton", "kinematics", "force", "friction", "joule", "electric field", "circuit", "wavelength", "frequency", "projectile", "gravitational", "thermodynamics", "quantum", "photon", "magnetic"]),
        ("mathematics", ["equation", "integral", "derivative", "theorem", "algebra", "calculus", "matrix", "polynomial", "trigonometry", "probability", "quadratic", "logarithm", "geometry", "vector", "proof", "sin(", "cos("]),
        ("chemistry", ["molecule", "reaction", "compound", "stoichiometry", "mole", "periodic table", "covalent", "ionic", "acid", "titration", "electron configuration", "catalyst", "oxidation"]),
        ("biology", ["cell", "photosynthesis", "enzyme", "organism", "dna", "mitosis", "ecosystem", "protein", "evolution", "respiration", "genetics"]),
        ("english", ["essay", "poem", "novel", "literary", "thesis statement", "protagonist", "metaphor", "stanza", "narrative", "shakespeare", "rhetorical", "paragraph"]),
        ("history", ["empire", "revolution", "war", "treaty", "dynasty", "colonial", "century", "civilization", "historian"]),
        ("economics", ["demand", "supply", "inflation", "gdp", "market", "elasticity", "fiscal", "monetary"]),
        ("computer science", ["algorithm", "complexity", "data structure", "recursion", "binary", "pseudocode", "compiler"]),
        ("electronics", ["pcb", "schematic", "resistor", "capacitor", "microcontroller", "gerber", "footprint", "esp32", "arduino", "voltage regulator", "soldering", "kicad"]),
        ("design", ["figma", "wireframe", "mockup", "typography", "brand guidelines", "logo"]),
    ]

    static func subjectTopics(_ lower: String) -> [String] {
        subjects.compactMap { name, words in
            let hits = words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            return hits >= 3 ? name : nil
        }
    }

    static let modelExtensions: Set<String> = ["stl", "obj", "3mf", "step", "stp", "iges", "igs", "f3d", "f3z", "fcstd", "blend", "gcode", "bgcode", "scad", "dwg", "dxf", "skp", "sldprt", "sldasm"]

    public func classify(path: String, content: ExtractedContent, taxonomyTerms: [String] = []) -> Classification {
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        let text = content.text
        let lower = (name + "\n" + String(text.prefix(60_000))).lowercased()

        // Document type
        var best: (String, Double)?
        for sig in Self.signatures where sig.kinds.isEmpty || sig.kinds.contains(content.kind) || sig.kinds.contains(.document) && content.kind == .text {
            var score = 0.0
            for (term, w) in sig.terms where lower.contains(term) { score += w }
            let lname = name.lowercased()
            if sig.namePatterns.contains(where: { lname.contains($0) }) { score += 2.5 }
            if !sig.kinds.isEmpty && sig.terms.isEmpty && sig.kinds.contains(content.kind) { score += 3 }
            if score > (best?.1 ?? 0) { best = (sig.name, score) }
        }
        var docType = best.map(\.0)
        var docConf = min(1, (best?.1 ?? 0) / 7.5)
        if docConf < 0.3 { docType = nil }
        switch content.kind {
        case .screenshot: docType = "screenshot"; docConf = 0.95
        case .code: docType = "code"; docConf = 0.95
        case .installer: docType = "installer"; docConf = 0.95
        case .image where name.lowercased().contains("logo") || name.lowercased().contains("icon"): docType = "logo"; docConf = 0.8
        case .image: if docType == nil { docType = "photo"; docConf = 0.5 }
        case .archive: if docType == nil { docType = "archive"; docConf = 0.7 }
        case .audio: docType = docType ?? "audio"
        case .video: docType = docType ?? (name.hasPrefix("Screen Recording") ? "screen recording" : "video")
        default: break
        }
        if Self.modelExtensions.contains(ext) { docType = "3d model"; docConf = 0.95 }
        if Self.pcbExtensions.contains(ext) { docType = "pcb design"; docConf = 0.95 }

        // Language
        var language: String? = content.codeLanguage
        if language == nil, text.count > 40 {
            let rec = NLLanguageRecognizer()
            rec.processString(String(text.prefix(2000)))
            language = rec.dominantLanguage.map { Locale.current.localizedString(forLanguageCode: $0.rawValue) ?? $0.rawValue }
        }

        let sample = String(text.prefix(20_000))
        let entities = extractEntities(sample, fileName: name)
        var topics = content.kind == .code ? codeTopics(sample, name: name) : extractTopics(sample, fileName: name, extra: taxonomyTerms)
        let subjects = Self.subjectTopics(lower)
        if content.kind == .cad { topics.insert(contentsOf: ["cad", "electronics"].filter { t in Self.pcbExtensions.contains(ext) || t == "cad" }, at: 0) }
        topics = Array(NSOrderedSet(array: subjects + topics).array as? [String] ?? topics).prefix(8).map { $0 }
        return Classification(docType: docType, docTypeConfidence: docConf, topics: topics, entities: entities,
                              language: language, keywords: Self.tokens(name + " " + String(text.prefix(8000))))
    }

    // MARK: Entities

    public func extractEntities(_ text: String, fileName: String) -> [Entity] {
        var out = Set<Entity>()
        if !text.isEmpty {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
                let value = String(text[range]).trimmed
                guard value.count > 2, value.count < 60 else { return true }
                switch tag {
                case .personalName?: out.insert(Entity(kind: .person, value: value))
                case .organizationName?: out.insert(Entity(kind: .organization, value: value))
                case .placeName?: out.insert(Entity(kind: .place, value: value))
                default: break
                }
                return out.count < 60
            }
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue | NSTextCheckingResult.CheckingType.link.rawValue) {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                var dates = 0, links = 0
                detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, stop in
                    guard let m else { return }
                    if let d = m.date, dates < 8 { out.insert(Entity(kind: .date, value: f.string(from: d))); dates += 1 }
                    if let u = m.url {
                        if u.scheme == "mailto" { out.insert(Entity(kind: .email, value: u.absoluteString.replacingOccurrences(of: "mailto:", with: ""))) }
                        else if links < 8 { out.insert(Entity(kind: .url, value: u.host ?? u.absoluteString)); links += 1 }
                    }
                    if dates >= 8 && links >= 8 { stop.pointee = true }
                }
            }
        }
        let combined = fileName + " " + String(text.prefix(20_000))
        // Course / class codes: MYP3, CS101, MATH 201, IB DP
        if let re = try? NSRegularExpression(pattern: #"\b(MYP\s?\d|DP\s?\d|[A-Z]{2,4}\s?\d{3}[A-Z]?|Grade\s\d{1,2})\b"#) {
            for m in re.matches(in: combined, range: NSRange(combined.startIndex..., in: combined)).prefix(10) {
                if let r = Range(m.range, in: combined) { out.insert(Entity(kind: .course, value: String(combined[r]).replacingOccurrences(of: " ", with: ""))) }
            }
        }
        if let re = try? NSRegularExpression(pattern: #"[$€£₹]\s?\d{1,3}(?:[,\d{3}]*)(?:\.\d{2})?"#) {
            for m in re.matches(in: combined, range: NSRange(combined.startIndex..., in: combined)).prefix(5) {
                if let r = Range(m.range, in: combined) { out.insert(Entity(kind: .money, value: String(combined[r]))) }
            }
        }
        return Array(out).sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.value < $1.value : $0.kind.rawValue < $1.kind.rawValue }
    }

    // MARK: Topics

    public func extractTopics(_ text: String, fileName: String, extra: [String] = [], limit: Int = 6) -> [String] {
        var counts: [String: Double] = [:]
        let nameTokens = Self.tokens((fileName as NSString).deletingPathExtension)
        for t in nameTokens { counts[t, default: 0] += 2 }
        if !text.isEmpty {
            let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
            tagger.string = text
            let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther]
            var n = 0
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: opts) { tag, range in
                n += 1
                guard tag == .noun else { return n < 12_000 }
                let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? String(text[range])
                let w = lemma.lowercased()
                if w.count > 3, !Self.stopwords.contains(w), w.rangeOfCharacter(from: .decimalDigits) == nil { counts[w, default: 0] += 1 }
                return n < 12_000
            }
        }
        // Boost user's known taxonomy terms (project keywords, folder names) when present
        let lower = text.lowercased() + " " + fileName.lowercased()
        for term in extra where term.count > 2 && lower.contains(term.lowercased()) { counts[term.lowercased(), default: 0] += 4 }
        return counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    func codeTopics(_ text: String, name: String) -> [String] {
        var topics: [String] = []
        let lower = text.lowercased()
        let libs: [(String, String)] = [("import pandas", "pandas"), ("import numpy", "numpy"), ("fastf1", "F1 data"), ("import torch", "pytorch"),
                                        ("tensorflow", "tensorflow"), ("import swiftui", "SwiftUI"), ("from flask", "flask"), ("django", "django"),
                                        ("react", "react"), ("matplotlib", "plotting"), ("requests", "http"), ("sqlite", "database"),
                                        ("arduino", "arduino"), ("gpio", "electronics"), ("selenium", "scraping"), ("beautifulsoup", "scraping")]
        for (needle, topic) in libs where lower.contains(needle) { topics.append(topic) }
        topics.append(contentsOf: Self.tokens((name as NSString).deletingPathExtension).prefix(3))
        return Array(NSOrderedSet(array: topics).array as! [String]).prefix(6).map { $0 }
    }

    /// Lowercased word tokens without stopwords (splits camelCase, snake_case, kebab-case).
    public static func tokens(_ s: String) -> [String] {
        let spaced = s.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) && Int($0) == nil }
    }
}
