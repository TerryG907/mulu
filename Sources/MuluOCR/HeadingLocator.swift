import CoreGraphics
import Foundation

/// Finds where TOC entries start by reading the headings at the top of body or front-matter
/// pages. Used by `mulu auto` to anchor roman front-matter entries ("前言 …… i") to a
/// physical page, and to check a page offset against the chapter headings.
public final class HeadingLocator {
    public let rasterizer: PDFRasterizer
    /// Fraction of the page height read from the top.
    public var band = 0.45
    private var cache: [Int: [String]] = [:]

    public init(url: URL) throws {
        rasterizer = try PDFRasterizer(url: url)
    }

    public init(rasterizer: PDFRasterizer) {
        self.rasterizer = rasterizer
    }

    /// Normalized text lines in the top band of a page (cached).
    public func topLines(page p: Int) throws -> [String] {
        if let c = cache[p] { return c }
        let r = try rasterizer.render(page: p, region: CGRect(x: 0, y: 0, width: 1, height: band), dpi: 200, maxLongEdge: 3000)
        let (raw, _) = try TextRecognizer.recognizeUpright(r.image, options: RecognitionOptions(
            languageCorrection: true, minimumTextHeightPixels: max(8, 6 * r.scale)))
        let obs = TextRecognizer.upright(raw).filter { $0.text.contains { $0.isLetter || $0.isNumber } }
        let lines = LineLayout.groupLines(obs).map { HeadingLocator.normalize($0.text) }.filter { !$0.isEmpty }
        cache[p] = lines
        return lines
    }

    /// NFKC, lower case, letters and digits only ("第 一 章　绪论" → "第一章绪论").
    public static func normalize(_ s: String) -> String {
        String(s.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Levenshtein distance over characters.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Whether a heading line (or two consecutive lines, for "第一章" over "绪论") reads as
    /// `title`. Short titles must match exactly; longer ones may differ by up to 20% of
    /// their characters (OCR slips on either side).
    public static func matches(lines: [String], title: String) -> Bool {
        let t = Array(normalize(title))
        guard !t.isEmpty else { return false }
        var candidates = lines
        if lines.count >= 2 { for k in 0..<(lines.count - 1) { candidates.append(lines[k] + lines[k + 1]) } }
        let allowed = t.count <= 3 ? 0 : Int((0.2 * Double(t.count)).rounded(.down))
        for c in candidates {
            let a = Array(c)
            guard abs(a.count - t.count) <= allowed else { continue }
            if distance(a, t) <= allowed { return true }
        }
        return false
    }

    /// The pages among `pages` whose top band shows `title` as a heading.
    public func pages(showing title: String, among pages: [Int]) throws -> [Int] {
        var out: [Int] = []
        for p in pages where p >= 1 && p <= rasterizer.pageCount {
            if HeadingLocator.matches(lines: try topLines(page: p), title: title) { out.append(p) }
        }
        return out
    }
}
