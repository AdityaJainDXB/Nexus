using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

namespace Nexus.Core;

public class ExtractedContent
{
    public FileKind Kind { get; set; }
    public string Text { get; set; } = "";
    public long Size { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime ModifiedAt { get; set; }
    public string? ContentHash { get; set; }
    public ulong? PerceptualHash { get; set; }
    public string? SourceUrl { get; set; }
    public string? CodeLanguage { get; set; }
    public int? Pages { get; set; }
}

/// Reads what's inside a file: text, PDFs (PdfPig), Office/OpenDocument (zip XML), RTF/HTML, notebooks, OCR for images.
public class ContentExtractor
{
    public bool EnableOcr { get; set; } = true;
    public int MaxChars { get; set; } = 512 * 1024;

    public static readonly Dictionary<string, string> CodeLanguages = new(StringComparer.OrdinalIgnoreCase)
    {
        ["swift"] = "Swift", ["py"] = "Python", ["ipynb"] = "Python", ["js"] = "JavaScript", ["mjs"] = "JavaScript", ["jsx"] = "JavaScript",
        ["ts"] = "TypeScript", ["tsx"] = "TypeScript", ["rs"] = "Rust", ["go"] = "Go", ["java"] = "Java", ["kt"] = "Kotlin", ["c"] = "C", ["h"] = "C",
        ["cpp"] = "C++", ["cc"] = "C++", ["hpp"] = "C++", ["rb"] = "Ruby", ["php"] = "PHP", ["cs"] = "C#", ["sh"] = "Shell", ["bash"] = "Shell",
        ["ps1"] = "PowerShell", ["bat"] = "Batch", ["cmd"] = "Batch", ["sql"] = "SQL", ["r"] = "R", ["lua"] = "Lua", ["dart"] = "Dart", ["scala"] = "Scala",
        ["ino"] = "Arduino", ["vue"] = "Vue", ["svelte"] = "Svelte", ["css"] = "CSS", ["scss"] = "CSS", ["json"] = "JSON", ["yaml"] = "YAML", ["yml"] = "YAML",
        ["toml"] = "TOML", ["xml"] = "XML", ["gradle"] = "Gradle", ["m"] = "MATLAB", ["jl"] = "Julia", ["vb"] = "Visual Basic", ["fs"] = "F#",
    };

    public static readonly HashSet<string> CadExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "stl", "3mf", "step", "stp", "iges", "igs", "f3d", "f3z", "fcstd", "scad", "blend", "dwg", "dxf", "skp", "sldprt", "sldasm", "ipt", "iam",
        "gcode", "bgcode", "kicad_pcb", "kicad_sch", "kicad_pro", "kicad_mod", "kicad_sym", "brd", "sch", "gbr", "gbl", "gtl", "gbo", "gto", "gts", "gbs", "drl", "lbr", "obj"
    };

    public static readonly Dictionary<string, FileKind> KindByExt = BuildKinds();

    static Dictionary<string, FileKind> BuildKinds()
    {
        var m = new Dictionary<string, FileKind>(StringComparer.OrdinalIgnoreCase) { ["pdf"] = FileKind.pdf };
        foreach (var e in new[] { "doc", "docx", "rtf", "odt", "md", "markdown", "tex", "epub", "html", "htm", "mht", "pages", "xps", "oxps" }) m[e] = FileKind.document;
        foreach (var e in new[] { "xls", "xlsx", "xlsm", "csv", "tsv", "ods", "numbers" }) m[e] = FileKind.spreadsheet;
        foreach (var e in new[] { "ppt", "pptx", "odp", "key" }) m[e] = FileKind.presentation;
        foreach (var e in new[] { "txt", "log", "text", "rst", "org", "ini", "cfg" }) m[e] = FileKind.text;
        foreach (var e in CodeLanguages.Keys) m[e] = FileKind.code;
        foreach (var e in new[] { "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "svg", "raw", "cr2", "nef", "dng", "psd", "ai", "ico", "jfif", "avif" }) m[e] = FileKind.image;
        foreach (var e in new[] { "mp3", "m4a", "wav", "aiff", "flac", "ogg", "aac", "opus", "wma" }) m[e] = FileKind.audio;
        foreach (var e in new[] { "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv" }) m[e] = FileKind.video;
        foreach (var e in new[] { "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "cab" }) m[e] = FileKind.archive;
        foreach (var e in CadExtensions) m[e] = FileKind.cad;
        foreach (var e in new[] { "exe", "msi", "msix", "msixbundle", "appx", "appinstaller", "iso", "dmg", "pkg" }) m[e] = FileKind.installer;
        return m;
    }

    public static FileKind KindFor(string path) =>
        KindByExt.TryGetValue(Path.GetExtension(path).TrimStart('.'), out var k) ? k : FileKind.other;

    public static bool LooksLikeScreenshot(string path)
    {
        var name = Path.GetFileName(path);
        if (name.StartsWith("Screenshot", StringComparison.OrdinalIgnoreCase) || name.StartsWith("Screen Shot", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("Screen Recording", StringComparison.OrdinalIgnoreCase) || name.StartsWith("Capture", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("Snip", StringComparison.OrdinalIgnoreCase) || name.StartsWith("CleanShot", StringComparison.OrdinalIgnoreCase)) return true;
        var folder = Path.GetFileName(Path.GetDirectoryName(path) ?? "");
        return folder.Equals("Screenshots", StringComparison.OrdinalIgnoreCase);
    }

    public ExtractedContent? Extract(string path)
    {
        FileInfo info;
        try { info = new FileInfo(path); if (!info.Exists) return Directory.Exists(path) ? new ExtractedContent { Kind = FileKind.folder } : null; }
        catch { return null; }
        var ext = info.Extension.TrimStart('.').ToLowerInvariant();
        var kind = KindFor(path);
        if (kind == FileKind.image && LooksLikeScreenshot(path)) kind = FileKind.screenshot;
        var x = new ExtractedContent
        {
            Kind = kind, Size = info.Length, CreatedAt = info.CreationTime, ModifiedAt = info.LastWriteTime,
            SourceUrl = ReadZoneIdentifier(path), CodeLanguage = kind == FileKind.code ? CodeLanguages.GetValueOrDefault(ext) : null,
        };
        try { if (info.Length < 2L * 1024 * 1024 * 1024) x.ContentHash = Text.Sha256File(path); } catch { }
        try
        {
            x.Text = kind switch
            {
                FileKind.pdf => ReadPdf(path, x),
                FileKind.text or FileKind.code when ext == "ipynb" => ReadNotebook(path),
                FileKind.text or FileKind.code => ReadText(path),
                FileKind.document when ext is "docx" => ReadOpenXml(path, "word/document.xml", "w:t"),
                FileKind.document when ext is "odt" => ReadOpenXml(path, "content.xml", "text:p"),
                FileKind.document when ext is "rtf" => StripRtf(ReadText(path)),
                FileKind.document when ext is "html" or "htm" or "mht" => StripHtml(ReadText(path)),
                FileKind.document when ext is "md" or "markdown" or "tex" => ReadText(path),
                FileKind.spreadsheet when ext is "xlsx" or "xlsm" => ReadXlsx(path),
                FileKind.spreadsheet when ext is "csv" or "tsv" => ReadText(path),
                FileKind.presentation when ext is "pptx" => ReadPptx(path),
                FileKind.presentation when ext is "odp" => ReadOpenXml(path, "content.xml", "text:p"),
                FileKind.image or FileKind.screenshot => EnableOcr && info.Length < 40_000_000 ? Platform.Current.Ocr(path) ?? "" : "",
                FileKind.cad when ext.StartsWith("kicad") || ext is "gcode" or "scad" => ReadText(path),
                _ => ""
            };
        }
        catch { x.Text = ""; }
        if (kind is FileKind.image or FileKind.screenshot) { try { x.PerceptualHash = Platform.Current.ImageHash(path); } catch { } }
        if (x.Text.Length > MaxChars) x.Text = x.Text[..MaxChars];
        return x;
    }

    string ReadText(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var buf = new byte[Math.Min(fs.Length, MaxChars * 2L)];
        var n = fs.Read(buf, 0, buf.Length);
        if (buf.Take(Math.Min(n, 8000)).Count(b => b == 0) > 4) return ""; // binary
        return Encoding.UTF8.GetString(buf, 0, n);
    }

    static string ReadPdf(string path, ExtractedContent x)
    {
        using var doc = UglyToad.PdfPig.PdfDocument.Open(path, new UglyToad.PdfPig.ParsingOptions { UseLenientParsing = true });
        x.Pages = doc.NumberOfPages;
        var sb = new StringBuilder();
        foreach (var page in doc.GetPages())
        {
            string pageText;
            try { pageText = UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor.GetText(page); }
            catch { pageText = page.Text; }
            sb.AppendLine(pageText);
            if (sb.Length > 600_000 || page.Number > 150) break;
        }
        var text = sb.ToString();
        // Scanned PDFs have no text layer; OCR happens only for images (fast path)
        return text;
    }

    static string ReadOpenXml(string path, string entry, string element)
    {
        using var zip = ZipFile.OpenRead(path);
        var e = zip.GetEntry(entry);
        return e == null ? "" : XmlText(e.Open(), element);
    }

    static string ReadPptx(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        var sb = new StringBuilder();
        foreach (var e in zip.Entries.Where(e => e.FullName.StartsWith("ppt/slides/slide") && e.FullName.EndsWith(".xml"))
                     .OrderBy(e => int.TryParse(Regex.Match(e.FullName, @"\d+").Value, out var n) ? n : 0))
            sb.AppendLine(XmlText(e.Open(), "a:t"));
        return sb.ToString();
    }

    static string ReadXlsx(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        var e = zip.GetEntry("xl/sharedStrings.xml");
        return e == null ? "" : XmlText(e.Open(), "t");
    }

    static string XmlText(Stream s, string element)
    {
        using (s)
        {
            var sb = new StringBuilder();
            using var r = XmlReader.Create(s, new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null });
            var local = element.Contains(':') ? element.Split(':')[1] : element;
            while (r.Read())
            {
                if (r.NodeType == XmlNodeType.Element && r.LocalName == local && !r.IsEmptyElement)
                {
                    var t = r.ReadInnerXml();
                    sb.Append(Regex.Replace(t, "<[^>]+>", " ")).Append(local == "p" ? "\n" : " ");
                }
                else if (r.NodeType == XmlNodeType.Element && r.LocalName is "p" or "br" && local == "t") sb.Append('\n');
                if (sb.Length > 600_000) break;
            }
            return System.Net.WebUtility.HtmlDecode(sb.ToString());
        }
    }

    string ReadNotebook(string path)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(ReadText(path));
            var sb = new StringBuilder();
            foreach (var cell in doc.RootElement.GetProperty("cells").EnumerateArray())
                if (cell.TryGetProperty("source", out var src))
                    foreach (var line in src.ValueKind == System.Text.Json.JsonValueKind.Array ? src.EnumerateArray().Select(l => l.GetString()) : [src.GetString()])
                        sb.Append(line);
            return sb.ToString();
        }
        catch { return ""; }
    }

    static string StripRtf(string rtf) =>
        Regex.Replace(Regex.Replace(rtf, @"\\[a-z]+-?\d* ?|\{\\\*[^}]*\}|[{}]", " "), @"\s+", " ");

    static string StripHtml(string html) =>
        System.Net.WebUtility.HtmlDecode(Regex.Replace(Regex.Replace(html, @"<(script|style)[\s\S]*?</\1>", " ", RegexOptions.IgnoreCase), "<[^>]+>", " "));

    /// Windows records where a download came from in the NTFS Zone.Identifier stream (like macOS "Where from").
    static string? ReadZoneIdentifier(string path)
    {
        if (!Paths.IsWindows) return null;
        try
        {
            var text = File.ReadAllText(path + ":Zone.Identifier");
            var m = Regex.Match(text, @"^(?:HostUrl|ReferrerUrl)=(.+)$", RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value.Trim() : null;
        }
        catch { return null; }
    }
}
