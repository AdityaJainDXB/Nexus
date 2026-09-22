using System.Globalization;
using System.Text.RegularExpressions;

namespace Nexus.Core;

public class Classification
{
    public string? DocType { get; set; }
    public double DocTypeConfidence { get; set; }
    public List<string> Topics { get; set; } = [];
    public List<Entity> Entities { get; set; } = [];
    public string? Language { get; set; }
    public List<string> Keywords { get; set; } = [];
}

/// Fast heuristic classifier — no network, no model download. Mirrors the macOS signatures.
public class Classifier
{
    record Signature(string Name, Dictionary<string, double> Terms, string[] NamePatterns, FileKind[] Kinds);

    static readonly Signature[] Signatures =
    [
        new("invoice", new() { ["invoice"] = 3, ["invoice number"] = 3, ["amount due"] = 3, ["bill to"] = 2, ["due date"] = 1.5, ["subtotal"] = 1.5, ["tax"] = 0.5, ["total"] = 0.5, ["payment terms"] = 2, ["vat"] = 1, ["gst"] = 1 }, ["invoice", "inv-", "inv_"], [FileKind.pdf, FileKind.document, FileKind.image, FileKind.screenshot]),
        new("receipt", new() { ["receipt"] = 3, ["order number"] = 1.5, ["paid"] = 1, ["thank you for your purchase"] = 2.5, ["card ending"] = 2, ["order total"] = 2 }, ["receipt", "order"], [FileKind.pdf, FileKind.image, FileKind.screenshot, FileKind.document]),
        new("bank statement", new() { ["statement period"] = 3, ["opening balance"] = 3, ["closing balance"] = 3, ["account number"] = 1.5, ["transactions"] = 1 }, ["statement"], [FileKind.pdf]),
        new("tax document", new() { ["form 1099"] = 4, ["w-2"] = 3, ["irs"] = 2, ["tax year"] = 2.5, ["taxable"] = 1.5, ["form 1040"] = 4 }, ["1099", "w2", "1040", "tax"], [FileKind.pdf, FileKind.document]),
        new("lab report", new() { ["lab report"] = 4, ["hypothesis"] = 2, ["procedure"] = 1.5, ["materials"] = 1, ["independent variable"] = 3, ["dependent variable"] = 3, ["controlled variable"] = 2.5, ["conclusion"] = 1, ["data analysis"] = 1.5, ["experiment"] = 1.5, ["results"] = 0.5 }, ["lab", "experiment"], [FileKind.pdf, FileKind.document, FileKind.text]),
        new("essay", new() { ["introduction"] = 1, ["in conclusion"] = 2, ["thesis"] = 2, ["works cited"] = 3, ["bibliography"] = 2.5, ["references"] = 1 }, ["essay"], [FileKind.pdf, FileKind.document, FileKind.text]),
        new("syllabus", new() { ["syllabus"] = 4, ["course description"] = 3, ["grading"] = 2, ["office hours"] = 2.5, ["learning outcomes"] = 2, ["assessment criteria"] = 2 }, ["syllabus", "course outline"], [FileKind.pdf, FileKind.document]),
        new("assignment", new() { ["assignment"] = 2.5, ["due"] = 1, ["submit"] = 1.5, ["rubric"] = 2.5, ["criterion"] = 1.5, ["task"] = 0.5, ["worksheet"] = 2.5 }, ["assignment", "homework", "hw", "worksheet"], [FileKind.pdf, FileKind.document]),
        new("resume", new() { ["experience"] = 1, ["education"] = 1, ["skills"] = 1, ["resume"] = 3, ["curriculum vitae"] = 3, ["references available"] = 2 }, ["resume", "cv"], [FileKind.pdf, FileKind.document]),
        new("contract", new() { ["agreement"] = 2, ["hereinafter"] = 3, ["party"] = 1, ["terms and conditions"] = 2, ["signature"] = 1, ["governing law"] = 3, ["indemnif"] = 3 }, ["contract", "agreement", "nda"], [FileKind.pdf, FileKind.document]),
        new("spec", new() { ["requirements"] = 2, ["specification"] = 3, ["acceptance criteria"] = 3, ["user story"] = 2.5, ["scope"] = 1, ["architecture"] = 1.5, ["api"] = 1, ["non-goals"] = 2.5 }, ["spec", "prd", "rfc", "design doc"], [FileKind.pdf, FileKind.document, FileKind.text]),
        new("meeting notes", new() { ["agenda"] = 2, ["attendees"] = 3, ["action items"] = 3, ["minutes"] = 1.5, ["next steps"] = 1.5 }, ["notes", "minutes", "meeting"], [FileKind.document, FileKind.text, FileKind.pdf]),
        new("research paper", new() { ["abstract"] = 2.5, ["doi"] = 2.5, ["et al"] = 2, ["arxiv"] = 3, ["methodology"] = 1.5, ["literature review"] = 2 }, ["paper", "arxiv"], [FileKind.pdf]),
        new("manual", new() { ["user manual"] = 4, ["installation"] = 1.5, ["troubleshooting"] = 2.5, ["warranty"] = 2, ["safety instructions"] = 2.5 }, ["manual", "guide"], [FileKind.pdf]),
        new("ticket", new() { ["boarding pass"] = 4, ["gate"] = 1, ["seat"] = 1, ["flight"] = 2, ["e-ticket"] = 3, ["admit one"] = 3, ["booking reference"] = 3 }, ["ticket", "boarding"], [FileKind.pdf, FileKind.image, FileKind.screenshot]),
        new("presentation", [], ["slides", "deck", "presentation"], [FileKind.presentation]),
        new("dataset", [], ["data", "dataset", "export"], [FileKind.spreadsheet]),
    ];

    public static readonly HashSet<string> Stopwords = new(("a an the and or but if then else of to in on at by for with about against between into through during before after above below from up down out off over under again " +
        "further once here there when where why how all any both each few more most other some such no nor not only own same so than too very can will just don should now is are was were be been being " +
        "have has had having do does did doing i me my we our you your he him his she her it its they them their what which who whom this that these those am would could page file pdf document image " +
        "screenshot copy new final untitled version also may must shall use used using one two three first second get got make made like well much many way per via within without upon").Split(' '));

    static readonly HashSet<string> WeakWords = new("been being make made take taken give given show shown found find need needs want wants include includes including based following provide provides please thanks thank regards dear".Split(' '));

    public static readonly HashSet<string> PcbExtensions = new(StringComparer.OrdinalIgnoreCase) { "kicad_pcb", "kicad_sch", "kicad_pro", "kicad_mod", "kicad_sym", "brd", "sch", "gbr", "gbl", "gtl", "gbo", "gto", "gts", "gbs", "drl", "lbr" };
    public static readonly HashSet<string> ModelExtensions = new(StringComparer.OrdinalIgnoreCase) { "stl", "obj", "3mf", "step", "stp", "iges", "igs", "f3d", "f3z", "fcstd", "blend", "gcode", "bgcode", "scad", "dwg", "dxf", "skp", "sldprt", "sldasm", "ipt", "iam" };

    static readonly (string name, string[] words)[] Subjects =
    [
        ("physics", ["velocity", "acceleration", "momentum", "newton", "kinematics", "force", "friction", "joule", "electric field", "circuit", "wavelength", "frequency", "projectile", "gravitational", "thermodynamics", "quantum", "photon", "magnetic"]),
        ("mathematics", ["equation", "integral", "derivative", "theorem", "algebra", "calculus", "matrix", "polynomial", "trigonometry", "probability", "quadratic", "logarithm", "geometry", "vector", "proof", "sin(", "cos(", "surds", "set notation"]),
        ("chemistry", ["molecule", "reaction", "compound", "stoichiometry", "mole", "periodic table", "covalent", "ionic", "acid", "titration", "electron configuration", "catalyst", "oxidation"]),
        ("biology", ["cell", "photosynthesis", "enzyme", "organism", "dna", "mitosis", "ecosystem", "protein", "evolution", "respiration", "genetics", "chlorophyll"]),
        ("english", ["essay", "poem", "novel", "literary", "thesis statement", "protagonist", "metaphor", "stanza", "narrative", "shakespeare", "rhetorical", "paragraph", "macbeth", "tragedy"]),
        ("history", ["empire", "revolution", "war", "treaty", "dynasty", "colonial", "century", "civilization", "historian"]),
        ("economics", ["demand", "supply", "inflation", "gdp", "market", "elasticity", "fiscal", "monetary"]),
        ("computer science", ["algorithm", "complexity", "data structure", "recursion", "binary", "pseudocode", "compiler"]),
        ("electronics", ["pcb", "schematic", "resistor", "capacitor", "microcontroller", "gerber", "footprint", "esp32", "arduino", "voltage regulator", "soldering", "kicad"]),
        ("design", ["figma", "wireframe", "mockup", "typography", "brand guidelines", "logo"]),
    ];

    public static List<string> SubjectTopics(string lower) =>
        Subjects.Where(s => s.words.Count(w => lower.Contains(w)) >= 3).Select(s => s.name).ToList();

    public Classification Classify(string path, ExtractedContent content, IEnumerable<string>? taxonomyTerms = null)
    {
        var name = Path.GetFileName(path);
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        var text = content.Text;
        var lower = (name + "\n" + (text.Length > 60_000 ? text[..60_000] : text)).ToLowerInvariant();
        var lname = name.ToLowerInvariant();

        (string name, double score)? best = null;
        foreach (var sig in Signatures)
        {
            if (sig.Kinds.Length > 0 && !sig.Kinds.Contains(content.Kind) && !(sig.Kinds.Contains(FileKind.document) && content.Kind == FileKind.text)) continue;
            var score = sig.Terms.Where(t => lower.Contains(t.Key)).Sum(t => t.Value);
            if (sig.NamePatterns.Any(p => lname.Contains(p))) score += 2.5;
            if (sig.Terms.Count == 0 && sig.Kinds.Contains(content.Kind)) score += 3;
            if (score > (best?.score ?? 0)) best = (sig.Name, score);
        }
        var docType = best?.name;
        var conf = Math.Min(1, (best?.score ?? 0) / 7.5);
        if (conf < 0.3) docType = null;
        switch (content.Kind)
        {
            case FileKind.screenshot: docType = "screenshot"; conf = 0.95; break;
            case FileKind.code: docType = "code"; conf = 0.95; break;
            case FileKind.installer: docType = "installer"; conf = 0.95; break;
            case FileKind.image when lname.Contains("logo") || lname.Contains("icon"): docType = "logo"; conf = 0.8; break;
            case FileKind.image: if (docType == null) { docType = "photo"; conf = 0.5; } break;
            case FileKind.archive: if (docType == null) { docType = "archive"; conf = 0.7; } break;
            case FileKind.audio: docType ??= "audio"; break;
            case FileKind.video: docType ??= name.StartsWith("Screen Recording") ? "screen recording" : "video"; break;
        }
        if (ModelExtensions.Contains(ext)) { docType = "3d model"; conf = 0.95; }
        if (PcbExtensions.Contains(ext)) { docType = "pcb design"; conf = 0.95; }

        var sample = text.Length > 20_000 ? text[..20_000] : text;
        var language = content.CodeLanguage ?? (text.Length > 40 && LooksEnglish(sample) ? "English" : null);
        var entities = ExtractEntities(sample, name);
        var topics = content.Kind == FileKind.code ? CodeTopics(sample, name) : ExtractTopics(sample, name, taxonomyTerms ?? []);
        var subjects = SubjectTopics(lower);
        if (content.Kind == FileKind.cad) topics.InsertRange(0, PcbExtensions.Contains(ext) ? ["cad", "electronics"] : ["cad"]);
        topics = subjects.Concat(topics).Distinct(StringComparer.OrdinalIgnoreCase).Take(8).ToList();
        return new Classification
        {
            DocType = docType, DocTypeConfidence = conf, Topics = topics, Entities = entities, Language = language,
            Keywords = Tokens(name + " " + (text.Length > 8000 ? text[..8000] : text)),
        };
    }

    static bool LooksEnglish(string s)
    {
        var words = Regex.Matches(s.ToLowerInvariant(), "[a-z']+").Take(400).Select(m => m.Value).ToList();
        return words.Count > 8 && words.Count(w => w is "the" or "and" or "of" or "to" or "is" or "in" or "for" or "with") * 12 > words.Count;
    }

    // MARK: Entities

    static readonly string[] OrgSuffixes = ["inc", "llc", "ltd", "corp", "corporation", "company", "co", "gmbh", "university", "school", "college", "academy", "electronics", "supplies", "bank", "labs", "studio", "group", "institute"];
    static readonly string[] DateFormats = ["MMM d yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy", "d MMMM yyyy", "yyyy-MM-dd", "M/d/yyyy", "d/M/yyyy", "dd.MM.yyyy"];

    public List<Entity> ExtractEntities(string text, string fileName)
    {
        var set = new HashSet<Entity>();
        if (!string.IsNullOrEmpty(text))
        {
            foreach (Match m in Regex.Matches(text, @"\b([A-Z][a-zA-Z&'.-]+(?:[ \t]+[A-Z][a-zA-Z&'.-]+){1,3})\b").Take(200))
            {
                var v = m.Groups[1].Value.Trim().TrimEnd('.');
                if (v.Length < 4 || v.Length > 60) continue;
                var words = v.Split(' ');
                if (words.Any(w => Stopwords.Contains(w.ToLowerInvariant()))) continue;
                var last = words[^1].ToLowerInvariant().TrimEnd('.');
                if (OrgSuffixes.Contains(last)) set.Add(new Entity(EntityKind.organization, v));
                else if (words.Length is 2 or 3 && words.All(w => w.Length > 1 && char.IsLower(w[1]))) set.Add(new Entity(EntityKind.person, v));
                if (set.Count > 40) break;
            }
            var dates = 0;
            foreach (Match m in Regex.Matches(text, @"\b(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}|\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{4}|\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})\b", RegexOptions.IgnoreCase))
            {
                var raw = Regex.Replace(m.Value.Replace("Sept", "Sep"), @"(\d)(st|nd|rd|th)", "$1").Replace(".", "");
                if (DateTime.TryParseExact(raw, DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var d)
                    || DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out d))
                { set.Add(new Entity(EntityKind.date, d.ToString("yyyy-MM-dd"))); if (++dates >= 8) break; }
            }
            foreach (Match m in Regex.Matches(text, @"[\w.+-]+@[\w-]+\.[\w.]+").Take(8)) set.Add(new Entity(EntityKind.email, m.Value));
            foreach (Match m in Regex.Matches(text, @"https?://([\w.-]+)").Take(8)) set.Add(new Entity(EntityKind.url, m.Groups[1].Value));
        }
        var combined = fileName + " " + (text.Length > 20_000 ? text[..20_000] : text);
        foreach (Match m in Regex.Matches(combined, @"\b(MYP\s?\d|DP\s?\d|[A-Z]{2,4}\s?\d{3}[A-Z]?|Grade\s\d{1,2}|G\d{1,2})\b").Take(10))
            if (!Regex.IsMatch(m.Value, @"^(PDF|JPG|PNG|MP\d|USB|HDMI|ISO)")) set.Add(new Entity(EntityKind.course, m.Value.Replace(" ", "")));
        foreach (Match m in Regex.Matches(combined, @"[$€£₹]\s?\d{1,3}(?:[,\d{3}]*)(?:\.\d{2})?").Take(5)) set.Add(new Entity(EntityKind.money, m.Value));
        return set.OrderBy(e => e.Kind.ToString()).ThenBy(e => e.Value).ToList();
    }

    // MARK: Topics

    public List<string> ExtractTopics(string text, string fileName, IEnumerable<string> extra, int limit = 6)
    {
        var counts = new Dictionary<string, double>();
        foreach (var t in Tokens(Path.GetFileNameWithoutExtension(fileName))) counts[t] = counts.GetValueOrDefault(t) + 2;
        var n = 0;
        foreach (Match m in Regex.Matches(text, @"[A-Za-z][A-Za-z\-]{3,}"))
        {
            if (++n > 12_000) break;
            var w = Stem(m.Value.ToLowerInvariant());
            if (w.Length > 3 && !Stopwords.Contains(w) && !WeakWords.Contains(w) && !w.EndsWith("ly") && !w.EndsWith("ing")) counts[w] = counts.GetValueOrDefault(w) + 1;
        }
        var lower = text.ToLowerInvariant() + " " + fileName.ToLowerInvariant();
        foreach (var term in extra) if (term.Length > 2 && lower.Contains(term.ToLowerInvariant())) counts[term.ToLowerInvariant()] = counts.GetValueOrDefault(term.ToLowerInvariant()) + 4;
        return counts.Where(kv => kv.Value >= 2).OrderByDescending(kv => kv.Value).Take(limit).Select(kv => kv.Key).ToList();
    }

    static string Stem(string w) =>
        w.EndsWith("ies") && w.Length > 5 ? w[..^3] + "y" : w.EndsWith("sses") ? w[..^2] : w.EndsWith('s') && !w.EndsWith("ss") && !w.EndsWith("us") && !w.EndsWith("is") && w.Length > 4 ? w[..^1] : w;

    static List<string> CodeTopics(string text, string name)
    {
        var lower = text.ToLowerInvariant();
        (string needle, string topic)[] libs = [("import pandas", "pandas"), ("import numpy", "numpy"), ("fastf1", "F1 data"), ("import torch", "pytorch"), ("tensorflow", "tensorflow"),
            ("from flask", "flask"), ("django", "django"), ("react", "react"), ("matplotlib", "plotting"), ("requests", "http"), ("sqlite", "database"), ("arduino", "arduino"),
            ("gpio", "electronics"), ("selenium", "scraping"), ("beautifulsoup", "scraping"), ("using system", ".net"), ("winforms", "windows")];
        var topics = libs.Where(l => lower.Contains(l.needle)).Select(l => l.topic).ToList();
        topics.AddRange(Tokens(Path.GetFileNameWithoutExtension(name)).Take(3));
        return topics.Distinct().Take(6).ToList();
    }

    /// Lowercased word tokens without stopwords (splits camelCase, snake_case, kebab-case).
    public static List<string> Tokens(string s)
    {
        var spaced = Regex.Replace(s, "([a-z])([A-Z])", "$1 $2");
        return Regex.Split(spaced.ToLowerInvariant(), @"[^\p{L}\p{N}]+")
            .Where(t => t.Length > 2 && !Stopwords.Contains(t) && !int.TryParse(t, out _)).ToList();
    }
}
