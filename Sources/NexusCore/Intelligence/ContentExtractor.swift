import Foundation
import PDFKit
import Vision
import CryptoKit
import CoreServices
import ImageIO
import Speech

public struct ExtractedContent {
    public var kind: FileKind
    public var text: String
    public var size: Int64
    public var createdAt: Date
    public var modifiedAt: Date
    public var contentHash: String?
    public var perceptualHash: UInt64?
    public var sourceURL: String?
    public var isScreenCapture: Bool
    public var codeLanguage: String?
    public var pageCount: Int?
}

/// Turns any file into text + metadata. Everything runs on-device.
public final class ContentExtractor {
    public var enableOCR = true
    public var enableSpeech = false
    public var maxChars = 512_000

    public init() {}

    static let kindByExt: [String: FileKind] = {
        var m: [String: FileKind] = ["pdf": .pdf]
        for e in ["doc", "docx", "rtf", "rtfd", "odt", "pages", "md", "markdown", "tex", "epub", "html", "htm", "webarchive"] { m[e] = .document }
        for e in ["xls", "xlsx", "csv", "tsv", "numbers", "ods"] { m[e] = .spreadsheet }
        for e in ["ppt", "pptx", "key", "odp"] { m[e] = .presentation }
        for e in ["txt", "log", "text", "rst", "org"] { m[e] = .text }
        for e in codeLanguages.keys { m[e] = .code }
        for e in ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "svg", "raw", "cr2", "nef", "dng", "psd", "ai", "sketch", "fig"] { m[e] = .image }
        for e in ["mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "aac", "opus"] { m[e] = .audio }
        for e in ["mp4", "mov", "m4v", "mkv", "avi", "webm"] { m[e] = .video }
        for e in ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"] { m[e] = .archive }
        for e in cadExtensions { m[e] = .cad }
        m["obj"] = .cad
        for e in ["dmg", "pkg", "mpkg", "app", "iso"] { m[e] = .installer }
        return m
    }()

    /// 3D / CAD / PCB design files.
    public static let cadExtensions: Set<String> = ["stl", "3mf", "step", "stp", "iges", "igs", "f3d", "f3z", "fcstd", "scad", "blend", "dwg", "dxf", "skp", "sldprt", "sldasm",
                                                    "gcode", "bgcode", "kicad_pcb", "kicad_sch", "kicad_pro", "kicad_mod", "kicad_sym", "brd", "sch", "gbr", "gbl", "gtl", "gbo", "gto", "gts", "gbs", "drl", "lbr"]

    public static let codeLanguages: [String: String] = [
        "swift": "Swift", "py": "Python", "ipynb": "Python", "js": "JavaScript", "mjs": "JavaScript", "jsx": "JavaScript",
        "ts": "TypeScript", "tsx": "TypeScript", "rs": "Rust", "go": "Go", "java": "Java", "kt": "Kotlin", "c": "C", "h": "C",
        "cpp": "C++", "cc": "C++", "hpp": "C++", "m": "Objective-C", "mm": "Objective-C++", "rb": "Ruby", "php": "PHP",
        "cs": "C#", "sh": "Shell", "zsh": "Shell", "bash": "Shell", "fish": "Shell", "ps1": "PowerShell", "sql": "SQL",
        "r": "R", "jl": "Julia", "lua": "Lua", "dart": "Dart", "scala": "Scala", "hs": "Haskell", "ex": "Elixir", "exs": "Elixir",
        "json": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML", "css": "CSS", "scss": "SCSS",
        "vue": "Vue", "svelte": "Svelte", "gradle": "Gradle", "cmake": "CMake", "ino": "Arduino",
    ]

    public static func kind(for path: String) -> FileKind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
           !["app", "rtfd", "pages", "key", "numbers"].contains((path as NSString).pathExtension.lowercased()) { return .folder }
        return kindByExt[(path as NSString).pathExtension.lowercased()] ?? .other
    }

    public func extract(path: String) -> ExtractedContent? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent
        var kind = Self.kind(for: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let meta = spotlightMeta(path)
        let screenshotName = name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") || name.hasPrefix("CleanShot") || name.hasPrefix("Screen Recording")
        if kind == .image && (meta.isScreenCapture || screenshotName) { kind = .screenshot }

        var text = ""
        var pages: Int?
        var phash: UInt64?
        switch kind {
        case .pdf:
            if let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
                pages = doc.pageCount
                var buf = ""
                for i in 0..<min(doc.pageCount, 40) {
                    buf += (doc.page(at: i)?.string ?? "") + "\n"
                    if buf.count > maxChars { break }
                }
                text = buf
                // Scanned PDF with no text layer → OCR the first pages
                if text.trimmed.count < 20 && enableOCR {
                    for i in 0..<min(doc.pageCount, 3) {
                        if let page = doc.page(at: i), let cg = render(page) { text += ocr(cg) + "\n" }
                    }
                }
            }
        case .text, .code:
            text = readText(path)
        case .cad:
            if ["scad", "gcode", "kicad_pcb", "kicad_sch", "kicad_pro", "kicad_mod", "kicad_sym", "dxf", "step", "stp"].contains(ext) { text = String(readText(path).prefix(20_000)) }
        case .document:
            if ["md", "markdown", "tex"].contains(ext) { text = readText(path) }
            else if ["html", "htm"].contains(ext) { text = stripTags(readText(path)) }
            else if ext == "pages" { text = run("/usr/bin/unzip", ["-p", path, "index.xml"]).map(stripTags) ?? "" }
            else { text = run("/usr/bin/textutil", ["-convert", "txt", "-stdout", path]) ?? "" }
        case .presentation:
            if ext == "pptx" { text = stripTags(run("/usr/bin/unzip", ["-p", path, "ppt/slides/*.xml"]) ?? "") }
        case .spreadsheet:
            if ["csv", "tsv"].contains(ext) { text = readText(path) }
            else if ext == "xlsx" { text = stripTags(run("/usr/bin/unzip", ["-p", path, "xl/sharedStrings.xml"]) ?? "") }
        case .image, .screenshot:
            if let cg = cgImage(path) {
                phash = Self.dHash(cg)
                if enableOCR { text = ocr(cg) }
            }
        case .audio:
            if enableSpeech { text = transcribe(path) ?? "" }
        case .archive:
            if ext == "zip" { text = run("/usr/bin/unzip", ["-Z1", path]).map { String($0.prefix(4000)) } ?? "" }
        default: break
        }
        if text.count > maxChars { text = String(text.prefix(maxChars)) }

        var codeLang: String?
        if kind == .code { codeLang = Self.codeLanguages[ext] }
        else if kind == .text || kind == .other, let first = text.split(separator: "\n").first, first.hasPrefix("#!") {
            kind = .code
            codeLang = first.contains("python") ? "Python" : first.contains("node") ? "JavaScript" : "Shell"
        }

        return ExtractedContent(kind: kind, text: text, size: size,
                                createdAt: (attrs[.creationDate] as? Date) ?? Date(),
                                modifiedAt: (attrs[.modificationDate] as? Date) ?? Date(),
                                contentHash: kind == .folder ? nil : hash(path, size: size),
                                perceptualHash: phash, sourceURL: meta.whereFrom, isScreenCapture: kind == .screenshot,
                                codeLanguage: codeLang, pageCount: pages)
    }

    // MARK: - Pieces

    func readText(_ path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let data = h.readData(ofLength: maxChars)
        if data.prefix(8000).contains(0) { return "" } // binary
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
    }

    func run(_ exe: String, _ args: [String], timeout: TimeInterval = 20) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "nexus.extract.read")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        return String(data: data.prefix(maxChars), encoding: .utf8)
    }

    func spotlightMeta(_ path: String) -> (isScreenCapture: Bool, whereFrom: String?) {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return (false, nil) }
        let screen = (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue ?? false
        let froms = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String]
        return (screen, froms?.first)
    }

    func hash(_ path: String, size: Int64) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        hasher.update(data: withUnsafeBytes(of: size) { Data($0) })
        if size > 256 * 1024 * 1024 {
            // Large files: sample head, middle and tail (fast, still collision-resistant in practice)
            for offset in [0, size / 2, max(0, size - 4_194_304)] {
                try? h.seek(toOffset: UInt64(offset))
                hasher.update(data: h.readData(ofLength: 4_194_304))
            }
        } else {
            while true {
                let chunk = h.readData(ofLength: 1_048_576)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func cgImage(_ path: String, maxPixel: Int = 2400) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    public func ocr(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch { return "" }
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 64-bit difference hash. Hamming distance ≤ 6 ≈ visually near-identical.
    public static func dHash(_ image: CGImage) -> UInt64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    func transcribe(_ path: String) -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let rec = SFSpeechRecognizer(), rec.isAvailable, rec.supportsOnDeviceRecognition else { return nil }
        let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        let task = rec.recognitionTask(with: req) { result, error in
            if let result, result.isFinal { out = result.bestTranscription.formattedString; sem.signal() }
            else if error != nil { sem.signal() }
        }
        if sem.wait(timeout: .now() + 120) == .timedOut { task.cancel() }
        return out
    }
}
