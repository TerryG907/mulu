import Foundation

/// Where a line's page number came from.
public enum PageSource: String, Sendable {
    /// The same OCR observation (or line) as the title.
    case inline
    /// A second, 2x-upscaled OCR pass over the page-number column next to the line.
    case columnReOCR = "column-reocr"
    /// A number that OCR returned as a separate line, attached to the line above it.
    case attached
}

/// One printed-TOC line as read from a page image.
public struct TOCLine: Sendable {
    /// 1-based physical page the line was read from.
    public var sourcePage: Int
    /// 0 = left (or only) column, 1 = right column.
    public var column: Int
    /// Indentation cluster within the column (0 = leftmost).
    public var indentLevel: Int
    /// Box in the rendered page, as fractions of its width/height (after deskewing).
    public var x: Double, y: Double, width: Double, height: Double
    /// Title text with dot leaders removed.
    public var title: String
    public var page: PageNumber?
    public var pageSource: PageSource?
    /// 0...1: Vision's confidence, lowered for repaired or doubtful page numbers.
    public var confidence: Double
    public var notes: [String]

    /// The line as ocr-toc prints it: two spaces per indentation level, the title, and
    /// when a page number was found, a TAB and the number.
    public var text: String {
        String(repeating: "  ", count: indentLevel) + title + (page.map { "\t" + $0.text } ?? "")
    }
}

public struct TOCPageStats: Sendable {
    public var page: Int
    public var renderSeconds: Double
    public var ocrSeconds: Double
    public var reocrSeconds: Double
    public var observations: Int
    public var lines: Int
    public var columns: Int
    public var skewDegrees: Double
    public var pixelSize: (width: Int, height: Int)
}

public struct TOCReadResult: Sendable {
    public var lines: [TOCLine]
    public var pages: [TOCPageStats]
    public var warnings: [String]
    /// The TOC pages' own printed page numbers (folios) found in the top/bottom margin and
    /// dropped from `lines`: (physical page, folio). Used to map roman front-matter pages.
    public var folios: [(page: Int, number: PageNumber)] = []
}

public struct TOCReadOptions: Sendable {
    public var dpi = 300.0
    public var maxLongEdge = 4000
    /// Lines below this confidence produce a warning.
    public var warnBelow = 0.5
    /// Write page images and raw observations here (debugging).
    public var debugDirectory: URL? = nil
    /// Read each page again at 200 and 400 dpi and vote on the titles (see `voteTitle`).
    public var titleVote = true
    public init() {}
}

/// Reads printed table-of-contents pages: renders each page, runs Vision, rebuilds lines,
/// finds the page-number column and re-reads it where a line lacks a number.
public final class TOCPageReader {
    public let rasterizer: PDFRasterizer

    public init(url: URL) throws {
        rasterizer = try PDFRasterizer(url: url)
    }

    /// `progress`, when given, is called before page k (0-based) is read with (k, pages.count),
    /// and once more with (pages.count, pages.count) after the last page, before the cross-page
    /// "1"/"i" resolution. An error it throws (e.g. CancellationError) ends the read and is
    /// rethrown unchanged. Without it (or when it never throws) the result is the same.
    public func read(pages: [Int], options: TOCReadOptions = TOCReadOptions(),
                     progress: ((_ done: Int, _ total: Int) throws -> Void)? = nil) throws -> TOCReadResult {
        var result = TOCReadResult(lines: [], pages: [], warnings: [])
        for (k, p) in pages.enumerated() {
            try progress?(k, pages.count)
            try readPage(p, options: options, into: &result)
        }
        try progress?(pages.count, pages.count)
        TOCPageReader.resolveOneOrI(&result.lines)
        return result
    }

    static let headingWords: Set<String> = ["目录", "目錄", "目次", "contents", "tableofcontents", "content"]

    static func isHeading(_ title: String) -> Bool {
        headingWords.contains(title.filter { $0.isLetter }.lowercased())
    }

    private struct Work {
        var line: TextLine
        var title: String
        var number: PageNumber?
        var tokenRect: PixelRect?
        var source: PageSource?
        var confidence: Double
        var notes: [String] = []
        var drop = false
        /// Where the title starts when it came from another reading (the line had none).
        var titleMinX: Double? = nil
    }

    /// The page-number column from the ink alone: the rightmost dark pixels of each line's
    /// row (right of its title, left of `rightLimit`). Right-aligned numbers end at the same
    /// x on most lines; nil when fewer than 60% of the lines (at least 4) agree within 0.8
    /// character heights.
    static func inkNumberColumn(lines: [PixelRect], rightLimit: Double, charH: Double, image: GrayImage,
                                toImage: (PixelRect) -> PixelRect) -> (minX: Double, maxX: Double)? {
        var rights: [Double] = []
        let titleRight = lines.map(\.maxX).max() ?? 0
        for l in lines {
            let h = l.maxY - l.minY
            let region = PixelRect(minX: l.maxX + 0.5 * charH, minY: l.minY + 0.2 * h, maxX: rightLimit, maxY: l.maxY - 0.2 * h)
            guard region.maxX - region.minX > 2 * charH else { continue }
            let r = toImage(region)
            let crop = image.cropped(r)
            var x = crop.width - 1
            var found: Int? = nil
            while x >= 0 {
                var dark = 0
                for y in 0..<crop.height where crop.pixels[y * crop.width + x] < 128 { dark += 1 }
                if dark >= 2 { found = x; break }
                x -= 1
            }
            if let f = found { rights.append(max(0, r.minX.rounded(.down)) + Double(f) + 1) }
        }
        guard rights.count >= 4, let med = LineLayout.median(rights) else { return nil }
        let aligned = rights.filter { abs($0 - med) <= 0.8 * charH }
        guard aligned.count >= 4, Double(aligned.count) >= 0.6 * Double(lines.count), med > titleRight + 1.5 * charH else { return nil }
        let maxX = aligned.max()!
        return (minX: maxX - 1.6 * charH, maxX: maxX)
    }

    private func readPage(_ p: Int, options: TOCReadOptions, into result: inout TOCReadResult) throws {
        let clock = ContinuousClock()
        var t = clock.now
        func lap() -> Double {
            let n = clock.now
            let d = n - t
            t = n
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let rendered = try rasterizer.render(page: p, dpi: options.dpi, maxLongEdge: options.maxLongEdge)
        let img = rendered.image
        let renderSeconds = lap()
        // Smallest TOC text worth reading: about 5 pt.
        let (raw, retryNote) = try TextRecognizer.recognizeUpright(img, options: RecognitionOptions(
            languageCorrection: true, minimumTextHeightPixels: max(8, 5 * rendered.scale)))
        if let retryNote { result.warnings.append("page \(p): \(retryNote)") }
        let ocrSeconds = lap()

        let W = Double(img.width), H = Double(img.height)
        // Observations without a letter or digit are leader fragments or specks.
        let textObs = TextRecognizer.upright(raw).filter { $0.text.contains { $0.isLetter || $0.isNumber } }
        let charH0 = LineLayout.median(textObs.map(\.rect.height)) ?? 40
        // Skew: from the right edges of the page-number column when there is one (Vision's
        // text quadrilaterals are mostly axis-aligned), else from Vision's baselines.
        let numberPoints = textObs.compactMap { o -> PixelPoint? in
            if let n = PageToken.parseStandalone(o.text), n.kind == .arabic { return PixelPoint(x: o.rect.maxX, y: o.rect.midY) }
            if let r = o.trailingRect, let s = PageToken.splitTrailing(o.text), s.number.kind == .arabic {
                return PixelPoint(x: r.maxX, y: r.midY)
            }
            return nil
        }
        let skew = LineLayout.skewFromNumberColumn(numberPoints, pageWidth: W, pageHeight: H, tolerance: 0.6 * charH0)
            ?? LineLayout.estimateSkew(textObs)
        let center = PixelPoint(x: W / 2, y: H / 2)
        var obs = textObs.map { $0.deskewed(angle: skew, center: center) }
        // The page heading ("目 录", "Contents"), possibly read as separate characters, is
        // removed before the column split so a centred heading cannot straddle the gutter.
        var headingBottom = 0.0
        for line in LineLayout.groupLines(obs) where line.rect.midY < 0.3 * H && TOCPageReader.isHeading(line.text) {
            headingBottom = max(headingBottom, line.rect.maxY)
            obs.removeAll { o in line.members.contains { $0.rect == o.rect && $0.text == o.text } }
        }
        var (groups, gutter) = LineLayout.splitColumns(obs, pageWidth: W)
        if let g = gutter {
            result.warnings.append(String(format: "page %d: two-column layout (gutter at %.0f%% of the width); reading the left column first", p, g / W * 100))
        }
        let charH = LineLayout.median(LineLayout.groupLines(obs).map(\.rect.height)) ?? charH0

        if let dir = options.debugDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? img.writePNG(to: dir.appendingPathComponent("page-\(p).png"))
            let dump = raw.map { String(format: "%@ conf=%.2f angle=%.2f  %@", $0.rect.description, $0.confidence, $0.baselineAngle * 180 / .pi, $0.text) }
                .joined(separator: "\n")
            try? Data((dump + "\n").utf8).write(to: dir.appendingPathComponent("page-\(p).observations.txt"))
        }

        let cosA = cos(skew), sinA = sin(skew)
        func toImage(_ r: PixelRect) -> PixelRect {
            // deskewed -> original image coordinates (rotate by +skew about the centre)
            let pts = [(r.minX, r.minY), (r.maxX, r.minY), (r.maxX, r.maxY), (r.minX, r.maxY)].map { (x, y) -> (Double, Double) in
                let dx = x - center.x, dy = y - center.y
                return (center.x + dx * cosA - dy * sinA, center.y + dx * sinA + dy * cosA)
            }
            return PixelRect(minX: pts.map(\.0).min()!, minY: pts.map(\.1).min()!, maxX: pts.map(\.0).max()!, maxY: pts.map(\.1).max()!)
        }

        // Lines Vision skipped entirely (a one-character title with leaders, "序 …… i", is
        // sometimes not returned at all): unusually tall gaps between the lines of a column,
        // and above its first / below its last line, are read again as one stacked image.
        var gapCrops: [(g: Int, origin: (x: Double, y: Double), crop: GrayImage)] = []
        for (gi, g) in groups.enumerated() {
            let lines = LineLayout.groupLines(g)
            guard lines.count >= 3 else { continue }
            let mids = lines.map(\.rect.midY)
            let steps = zip(mids.dropFirst(), mids).map { $0 - $1 }.filter { $0 < 3 * charH }
            guard let pitch = LineLayout.median(steps) else { continue }
            let left = lines.map(\.rect.minX).min()! - charH, right = lines.map(\.rect.maxX).max()! + charH
            var bands: [(Double, Double)] = []
            let top = max(0.08 * H, headingBottom + 0.3 * charH)
            if lines[0].rect.minY - top > 1.2 * pitch { bands.append((top, lines[0].rect.minY)) }
            for (a, b) in zip(lines, lines.dropFirst()) where b.rect.minY - a.rect.maxY > 1.2 * pitch {
                bands.append((a.rect.maxY, b.rect.minY))
            }
            if 0.92 * H - lines[lines.count - 1].rect.maxY > 1.2 * pitch { bands.append((lines[lines.count - 1].rect.maxY, 0.92 * H)) }
            for (y0, y1) in bands {
                // Shrunk by the skew's vertical run so the rotated band cannot reach into the
                // neighbouring lines at its ends.
                let m = abs(sin(skew)) * (right - left) / 2 + 3
                guard y1 - y0 - 2 * m > 0.5 * charH else { continue }
                let r = toImage(PixelRect(minX: max(0, left), minY: y0 + m, maxX: min(W, right), maxY: y1 - m))
                guard r.width > 4, r.height > 4 else { continue }
                let ox = max(0, min(W - 1, r.minX.rounded(.down))), oy = max(0, min(H - 1, r.minY.rounded(.down)))
                gapCrops.append((gi, (ox, oy), img.cropped(r)))
            }
        }
        var recovered = 0
        if !gapCrops.isEmpty {
            let gap = max(20, Int(2 * charH))
            let (stack, offsets) = GrayImage.stacked(gapCrops.map(\.crop), gap: gap)
            let found = TextRecognizer.upright(try TextRecognizer.recognize(stack, options: RecognitionOptions(
                languageCorrection: true, minimumTextHeightPixels: max(8, 5 * rendered.scale))))
            for o in found where o.text.contains(where: { $0.isLetter || $0.isNumber }) {
                guard let k = offsets.lastIndex(where: { Double($0) <= o.rect.midY }),
                      o.rect.midY < Double(offsets[k] + gapCrops[k].crop.height) else { continue }
                // Glyphs cut by the band edge are not whole lines.
                guard o.rect.minY > Double(offsets[k]) + 2, o.rect.maxY < Double(offsets[k] + gapCrops[k].crop.height) - 2 else { continue }
                let dx = gapCrops[k].origin.x, dy = gapCrops[k].origin.y - Double(offsets[k])
                var m = o
                m.rect = o.rect.offsetBy(dx: dx, dy: dy)
                m.corners = o.corners.map { PixelPoint(x: $0.x + dx, y: $0.y + dy) }
                m.trailingRect = o.trailingRect?.offsetBy(dx: dx, dy: dy)
                m.textStart = o.textStart.map { PixelPoint(x: $0.x + dx, y: $0.y + dy) }
                m = m.deskewed(angle: skew, center: center)
                // Not a second copy of something already read.
                let dup = groups[gapCrops[k].g].contains { e in
                    let ix = min(e.rect.maxX, m.rect.maxX) - max(e.rect.minX, m.rect.minX)
                    let iy = min(e.rect.maxY, m.rect.maxY) - max(e.rect.minY, m.rect.minY)
                    return ix > 0 && iy > 0 && ix * iy > 0.3 * m.rect.width * m.rect.height
                }
                if !dup {
                    groups[gapCrops[k].g].append(m)
                    recovered += 1
                }
            }
            if recovered > 0 {
                result.warnings.append("page \(p): \(recovered) piece\(recovered == 1 ? "" : "s") of text found in a second pass over gaps between lines")
            }
        }

        var columns: [[Work]] = []
        var numberColumns: [(minX: Double, maxX: Double)?] = []
        for (gi, g) in groups.enumerated() {
            var works = LineLayout.groupLines(g).map { line -> Work in
                let joined = line.text
                var w = Work(line: line, title: PageToken.stripTrailingLeaders(joined), confidence: line.confidence)
                if line.members.count >= 2, let last = line.members.last, var n = PageToken.parseStandalone(last.text),
                   n.kind == .arabic || !n.upperRoman {
                    // The last observation is only a number ("1 5" for a spaced full-width 15,
                    // "•.....57" for leaders read with it). Digit groups OCR returned as
                    // separate observations just before it ("1", "5") are part of it.
                    var first = line.members.count - 1
                    var rect = last.rect
                    var acc = last.text
                    while first >= 2, n.kind == .arabic {
                        let prev = line.members[first - 1]
                        guard prev.text.count <= 3, prev.text.allSatisfy({ $0.isNumber }),
                              line.members[first].rect.minX - prev.rect.maxX < 0.8 * max(prev.rect.height, 1),
                              let m = PageToken.parseStandalone(prev.text + acc), m.kind == .arabic else { break }
                        n = m
                        acc = prev.text + acc
                        first -= 1
                        rect = rect.union(prev.rect)
                    }
                    w.title = PageToken.stripTrailingLeaders(line.members[..<first].map(\.text).joined(separator: " "))
                    w.number = n
                    w.source = .inline
                    w.tokenRect = rect
                } else if let last = line.members.last, let s = PageToken.splitTrailing(last.text) {
                    let head = line.members.dropLast().map(\.text) + (s.title.isEmpty ? [] : [s.title])
                    w.title = PageToken.stripTrailingLeaders(head.joined(separator: " "))
                    w.number = s.number
                    w.source = .inline
                    w.tokenRect = last.trailingRect ?? (s.title.isEmpty ? last.rect : nil)
                    if w.tokenRect == nil {
                        // Proportional estimate from the character position.
                        let n = Double(last.text.count)
                        let k = Double(last.text.distance(from: last.text.startIndex, to: s.tokenRange.lowerBound))
                        var r = last.rect
                        r.minX = last.rect.minX + last.rect.width * (n > 0 ? k / n : 0)
                        w.tokenRect = r
                    }
                    if s.abutting { w.notes.append("page number touches the title") }
                }
                return w
            }
            // Page-number column from clearly separated arabic numbers.
            let candidates = works.compactMap { w -> PixelRect? in
                guard let n = w.number, n.kind == .arabic, let r = w.tokenRect, !w.title.isEmpty else { return nil }
                return r
            }
            var col = LineLayout.numberColumn(tokenRects: candidates, charHeight: charH)
            if col == nil {
                // Vision returned the titles but not the page numbers (dense 8 pt lines with
                // leaders run into one another): locate the right-aligned number column from
                // the ink at the right end of each line, so the column re-read below reads them.
                let titled = works.filter { !$0.title.isEmpty }
                if titled.count >= 4, titled.filter({ $0.number == nil }).count * 2 >= titled.count {
                    let rightLimit = (gutter != nil && gi == 0 && groups.count > 1) ? gutter! : 0.97 * W
                    col = TOCPageReader.inkNumberColumn(lines: titled.map(\.line.rect), rightLimit: rightLimit, charH: charH,
                                                        image: img, toImage: toImage)
                    if col != nil {
                        result.warnings.append("page \(p): page numbers not recognized with the titles; reading the page-number column found from the ink")
                    }
                }
            }
            numberColumns.append(col)
            if let col {
                for i in works.indices {
                    guard works[i].number != nil, let r = works[i].tokenRect else { continue }
                    if r.maxX < col.minX - 0.5 * charH {
                        // Not in the page-number column: a number inside the title.
                        works[i].number = nil
                        works[i].source = nil
                        works[i].tokenRect = nil
                        works[i].title = PageToken.stripTrailingLeaders(works[i].line.text)
                        works[i].notes = []
                    }
                }
            } else {
                // No column: only trust abutting digits when leaders are also present.
                for i in works.indices where works[i].notes.contains("page number touches the title") {
                    if let last = works[i].line.members.last, let s = PageToken.splitTrailing(last.text), !s.leader {
                        works[i].number = nil
                        works[i].source = nil
                        works[i].tokenRect = nil
                        works[i].title = PageToken.stripTrailingLeaders(works[i].line.text)
                        works[i].notes = []
                    }
                }
            }
            // Headings, folios and bare numbers.
            for i in works.indices {
                let w = works[i]
                let inMargin = w.line.rect.midY < 0.08 * H || w.line.rect.midY > 0.92 * H
                if w.number == nil, TOCPageReader.isHeading(w.title) {
                    works[i].drop = true
                } else if w.number != nil, TOCPageReader.isHeading(w.title), inMargin {
                    works[i].drop = true  // running head "目录 iii"
                } else if w.title.isEmpty, let n = w.number {
                    let inColumn = col.map { (w.tokenRect?.maxX ?? 0) >= $0.minX - 0.5 * charH } ?? false
                    if inMargin && !inColumn {
                        works[i].drop = true  // folio of the TOC page itself
                        result.folios.append((page: p, number: n))
                    } else if let j = [i - 1, i + 1].filter({ j in
                        j >= 0 && j < works.count && works[j].number == nil && !works[j].drop && !works[j].title.isEmpty
                            && max(w.line.rect.minY - works[j].line.rect.maxY, works[j].line.rect.minY - w.line.rect.maxY) < 0.8 * charH
                    }).min(by: { abs(works[$0].line.rect.midY - w.line.rect.midY) < abs(works[$1].line.rect.midY - w.line.rect.midY) }) {
                        // A number OCR returned on its own, next to a title without one.
                        works[j].number = n
                        works[j].source = .attached
                        works[j].tokenRect = w.tokenRect
                        works[j].confidence = min(works[j].confidence, w.confidence) * 0.9
                        works[i].drop = true
                    } else if inMargin {
                        works[i].drop = true  // an unattached number in the margin: the page's folio
                        result.folios.append((page: p, number: n))
                    }
                } else if w.number == nil, w.title.isEmpty {
                    works[i].drop = true  // leaders or punctuation only
                } else if w.number == nil, inMargin, w.title.count <= 5,
                          PageToken.parseStandalone(w.title) != nil || w.title.allSatisfy({ "0123456789ivxlIVXL|".contains($0) }) {
                    // a folio OCR could not parse ("1X" for ix)
                    works[i].drop = true
                }
            }
            columns.append(works)
        }

        // Second pass over the page-number column: lines without a number (or with a
        // repaired one) whose right end stops short of the column.
        var targets: [(c: Int, i: Int, crop: GrayImage, columnMinX: Double?)] = []
        // Arabic page numbers in reading order; a number smaller than the one before it
        // breaks the printed order, so both get a second reading.
        var sequence: [(c: Int, i: Int, value: Int)] = []
        for (c, works) in columns.enumerated() {
            for (i, w) in works.enumerated() where !w.drop {
                if let n = w.number, n.kind == .arabic { sequence.append((c, i, n.value)) }
            }
        }
        var outOfOrder = Set<[Int]>()
        for m in sequence.indices.dropFirst() where sequence[m].value < sequence[m - 1].value {
            outOfOrder.insert([sequence[m].c, sequence[m].i])
            outOfOrder.insert([sequence[m - 1].c, sequence[m - 1].i])
        }
        func neighbours(_ c: Int, _ i: Int) -> (prev: Int?, next: Int?) {
            guard let m = sequence.firstIndex(where: { $0.c == c && $0.i == i }) else {
                let before = sequence.last { $0.c < c || ($0.c == c && $0.i < i) }
                let after = sequence.first { $0.c > c || ($0.c == c && $0.i > i) }
                return (before?.value, after?.value)
            }
            return (m > 0 ? sequence[m - 1].value : nil, m + 1 < sequence.count ? sequence[m + 1].value : nil)
        }
        for (c, works) in columns.enumerated() {
            guard let col = numberColumns[c] else { continue }
            let right = LineLayout.median(works.compactMap { w -> Double? in
                guard w.number?.kind == .arabic, let r = w.tokenRect, r.maxX >= col.minX - 0.5 * charH else { return nil }
                return r.maxX
            }) ?? col.maxX
            for (i, w) in works.enumerated() where !w.drop && !w.title.isEmpty {
                // Lines without a number, repaired numbers, roman numerals (short; Vision drops
                // strokes: "iii" -> "ii"), a digit left in the title ("理论基础 1 | 8"), a
                // number that stops short of the right-aligned column edge (a digit lost on
                // the right), and numbers out of printed order.
                let short = w.number?.kind == .arabic && (w.tokenRect.map { $0.maxX < right - 0.6 * charH } ?? false)
                let needs = w.number == nil || (w.number?.noisy ?? false) || w.number?.kind == .roman
                    || (w.number?.kind == .arabic && TOCPageReader.trailingDigits(w.title) != nil)
                    || short || outOfOrder.contains([c, i])
                guard needs else { continue }
                let pad = 0.8 * charH
                let region = PixelRect(minX: col.minX - pad, minY: w.line.rect.minY - 0.2 * w.line.rect.height,
                                       maxX: col.maxX + pad, maxY: w.line.rect.maxY + 0.2 * w.line.rect.height)
                let r = toImage(region)
                guard r.maxX > 0, r.minX < W, r.maxY > 0, r.minY < H else { continue }
                // No number parsed although the text may run into the number column: its last
                // words can be a misread page number ("Acknowledgments ×11", "量效关系 1 0").
                targets.append((c, i, img.cropped(r).normalized(), w.number == nil ? col.minX : nil))
            }
        }
        var reocrSeconds = 0.0
        if !targets.isEmpty {
            // Vision is unreliable on a lone short number ("1", "8", "i") in a small crop, and
            // how it fails depends on what else is in the image. The crops are read in several
            // layouts: side by side in one row (a "line" of numbers; 2x, the upscaled pass,
            // then 1x) and stacked (1x, 2x), in English, then Chinese+English. A crop is
            // settled by two agreeing readings; a single reading is accepted after all passes
            // with a lower confidence; disagreeing readings keep the most frequent and are
            // flagged.
            var readings = [[(number: PageNumber, confidence: Double)]](repeating: [], count: targets.count)
            func settled(_ r: [(number: PageNumber, confidence: Double)]) -> Bool {
                Dictionary(grouping: r, by: { $0.number.text }).values.contains { $0.count >= 2 }
            }
            let passes: [(row: Bool, scale: Double, languages: [String])] = [
                (true, 2, ["en-US"]), (false, 1, ["en-US"]), (true, 1, ["en-US"]), (false, 2, ["en-US"]),
                (false, 2, ["zh-Hans", "en-US"]),
            ]
            for (pi, pass) in passes.enumerated() {
                let ks = targets.indices.filter { !settled(readings[$0]) }
                if ks.isEmpty { break }
                let crops = ks.map { pass.scale == 1 ? targets[$0].crop : targets[$0].crop.scaled(by: pass.scale) }
                var ro = RecognitionOptions(languageCorrection: false, minimumTextHeightPixels: max(8, 0.4 * charH * pass.scale))
                ro.languages = pass.languages
                let perCrop = try TOCPageReader.readCrops(crops, row: pass.row, gap: max(20, Int(charH * pass.scale)), options: ro,
                                                          debug: options.debugDirectory.map { ($0, "page-\(p).reocr\(pi + 1)") })
                for (j, k) in ks.enumerated() {
                    // The longest run of rightmost observations that reads as one page number
                    // ("1 5" split in two, specks and leader fragments to the left ignored).
                    let row = perCrop[j].sorted { $0.rect.minX < $1.rect.minX }
                    for start in row.indices {
                        let part = row[start...]
                        let text = part.map(\.text).joined(separator: " ")
                        var n = PageToken.parseStandalone(text)
                        if columns[targets[k].c][targets[k].i].number?.kind == .roman, let r = PageToken.romanLookalike(text) { n = r }
                        if n == nil, let s = PageToken.splitTrailing(text),
                           s.title.allSatisfy({ !$0.isLetter && !$0.isNumber }) { n = s.number }
                        if let n {
                            readings[k].append((n, part.map(\.confidence).min() ?? 0))
                            break
                        }
                    }
                }
            }
            for (k, tg) in targets.enumerated() where !readings[k].isEmpty {
                let groups = Dictionary(grouping: readings[k], by: { $0.number.text })
                let firstIndex = { (t: String) in readings[k].firstIndex { $0.number.text == t } ?? 0 }
                let bestText = groups.keys.max { a, b in
                    groups[a]!.count != groups[b]!.count ? groups[a]!.count < groups[b]!.count : firstIndex(a) > firstIndex(b)
                }!
                let n = groups[bestText]![0].number
                var oc = groups[bestText]!.map(\.confidence).max() ?? 0
                oc *= groups[bestText]!.count >= 2 ? 0.95 : 0.85
                if groups.count > 1 {
                    oc *= 0.6
                    columns[tg.c][tg.i].notes.append("column re-reads disagree: " + groups.keys.sorted().joined(separator: " / "))
                }
                let old = columns[tg.c][tg.i].number
                if let old {
                    // A second reading of a number the line already had.
                    // "理论基础 1 | 8": the title kept the first digit of a wide page number.
                    if old.kind == .arabic, n.kind == .arabic, let d = TOCPageReader.trailingDigits(columns[tg.c][tg.i].title),
                       n.text == d.digits + old.text {
                        columns[tg.c][tg.i].title = d.rest
                        columns[tg.c][tg.i].number = n
                        columns[tg.c][tg.i].notes.append("page number \(n.text) was split by OCR")
                        continue
                    }
                    if (n.noisy && old.kind != .roman) || n.text == old.text { continue }
                    if old.kind == .roman {
                        guard n.kind == .roman, n.text != old.text else { continue }
                        // Strokes get lost more often than invented: keep the longer one.
                        let keep = n.text.count > old.text.count ? n : old
                        columns[tg.c][tg.i].notes.append("roman page number read as \(old.text) and \(n.text); kept \(keep.text)")
                        columns[tg.c][tg.i].confidence *= 0.7
                        columns[tg.c][tg.i].number = keep
                        continue
                    }
                    if old.value != n.value {
                        // Replace the first reading only when the re-read fits the printed order
                        // better, or when two re-reads agree and it fits at least as well.
                        let (prev, next) = neighbours(tg.c, tg.i)
                        func fits(_ v: Int) -> Bool { (prev.map { v >= $0 } ?? true) && (next.map { v <= $0 } ?? true) }
                        let agreed = groups[bestText]!.count >= 2
                        guard (fits(n.value) && !fits(old.value)) || (agreed && (fits(n.value) || !fits(old.value))) else {
                            columns[tg.c][tg.i].notes.append("column re-read gave \(n.text); kept \(old.text)")
                            columns[tg.c][tg.i].confidence *= 0.8
                            continue
                        }
                        columns[tg.c][tg.i].notes.append("column re-read \(n.text) instead of \(old.text)")
                    }
                }
                if n.kind == .roman && n.text.count == 1 {
                    columns[tg.c][tg.i].notes.append("single-letter roman page number")
                }
                if old == nil, let colX = tg.columnMinX,
                   let cut = TOCPageReader.dropMisreadTail(columns[tg.c][tg.i].title, line: columns[tg.c][tg.i].line, columnMinX: colX - charH) {
                    columns[tg.c][tg.i].notes.append("dropped '\(cut.tail)' (the page number misread) from the title")
                    columns[tg.c][tg.i].title = cut.rest
                }
                columns[tg.c][tg.i].number = n
                columns[tg.c][tg.i].source = .columnReOCR
                columns[tg.c][tg.i].confidence = min(columns[tg.c][tg.i].confidence, oc)
            }
            // Nothing read at all and no number yet: a lone "1" / "i" by its shape, only where
            // it fits the printed order (a 1 after no larger number; an i before any arabic).
            for (k, tg) in targets.enumerated() where readings[k].isEmpty && columns[tg.c][tg.i].number == nil {
                guard let n = GlyphShape.loneStroke(tg.crop, textHeight: charH) else { continue }
                let (prev, _) = neighbours(tg.c, tg.i)
                if n.kind == .arabic, let prev, prev > 1 { continue }
                if n.kind == .roman, prev != nil { continue }
                columns[tg.c][tg.i].number = n
                columns[tg.c][tg.i].source = .columnReOCR
                columns[tg.c][tg.i].confidence = 0.4
                columns[tg.c][tg.i].notes.append("page number \(n.text) read from the glyph shape (OCR found no text)")
            }
            // Still nothing: each column's whole page-number strip as one image. A lone digit
            // between its neighbours ("5 / 6 / 9") is read upright there, where a crop of it
            // alone is often not read at all or read upside down (6 as 9, discarded). Used
            // only as this last resort, because the strip reads other numbers worse (it drops
            // digits of full-width numbers): one number on the line's row, not a lone 1 (it
            // could be an i), and in printed order.
            let open = targets.indices.filter { readings[$0].isEmpty && columns[targets[$0].c][targets[$0].i].number == nil }
            for c in Set(open.map { targets[$0].c }).sorted() {
                guard let col = numberColumns[c] else { continue }
                let kept = columns[c].filter { !$0.drop }
                guard let y0 = kept.map(\.line.rect.minY).min(), let y1 = kept.map(\.line.rect.maxY).max() else { continue }
                let pad = 0.8 * charH
                let r = toImage(PixelRect(minX: col.minX - pad, minY: y0 - 0.5 * charH, maxX: col.maxX + pad, maxY: y1 + 0.5 * charH))
                guard r.width > 4, r.height > 4, r.maxX > 0, r.minX < W, r.maxY > 0, r.minY < H else { continue }
                let ox = max(0, min(W - 1, r.minX.rounded(.down))), oy = max(0, min(H - 1, r.minY.rounded(.down)))
                var ro = RecognitionOptions(languageCorrection: false, minimumTextHeightPixels: max(8, 0.4 * charH))
                ro.languages = ["en-US"]
                let found = TextRecognizer.upright(try TextRecognizer.recognize(img.cropped(r).normalized(), options: ro))
                if let dir = options.debugDirectory {
                    let dump = found.map { String(format: "%@ conf=%.2f  %@", $0.rect.description, $0.confidence, $0.text) }.joined(separator: "\n")
                    try? Data((dump + "\n").utf8).write(to: dir.appendingPathComponent("page-\(p).strip\(c).txt"))
                }
                let placed = found.map { o -> OCRObservation in
                    var m = o
                    m.rect = o.rect.offsetBy(dx: ox, dy: oy)
                    m.corners = o.corners.map { PixelPoint(x: $0.x + ox, y: $0.y + oy) }
                    m.trailingRect = o.trailingRect?.offsetBy(dx: ox, dy: oy)
                    m.textStart = o.textStart.map { PixelPoint(x: $0.x + ox, y: $0.y + oy) }
                    return m.deskewed(angle: skew, center: center)
                }
                for k in open where targets[k].c == c {
                    let line = columns[c][targets[k].i].line.rect
                    let mine = placed.filter { $0.rect.verticalOverlapRatio(line) >= 0.5 }
                    guard mine.count == 1, let n = PageToken.parseStandalone(mine[0].text), n.kind == .arabic, n.value >= 2,
                          !n.noisy else { continue }
                    let (prev, next) = neighbours(c, targets[k].i)
                    guard prev.map({ n.value >= $0 }) ?? true, next.map({ n.value <= $0 }) ?? true else { continue }
                    columns[c][targets[k].i].number = n
                    columns[c][targets[k].i].source = .columnReOCR
                    columns[c][targets[k].i].confidence = min(columns[c][targets[k].i].confidence, 0.6)
                    columns[c][targets[k].i].notes.append("page number \(n.text) read from the whole page-number column (not read on its own)")
                }
            }
            reocrSeconds = lap()
        }
        // Titles read again at two other resolutions: Vision drops a thin character (一 二 为)
        // or reads a leader dot into a title at one scale and not at another.
        if options.titleVote {
            let alts = try alternateReadings(page: p, primaryScale: rendered.scale, skew: skew, center: center)
            for c in columns.indices {
                let colMinX = numberColumns[c]?.minX
                let blockLeft = columns[c].filter { !$0.drop }.map(\.line.rect.minX).min() ?? 0
                for i in columns[c].indices where !columns[c][i].drop {
                    let w = columns[c][i]
                    let limit = min(colMinX ?? .infinity, w.tokenRect?.minX ?? .infinity) - 0.3 * charH
                    let cands = alts.map { TOCPageReader.titleFrom($0, line: w.line.rect, leftLimit: blockLeft - charH,
                                                                   rightLimit: limit, charH: charH) }
                    if let (t, why) = TOCPageReader.voteTitle(primary: w.title, alternates: cands.map { $0?.title }) {
                        columns[c][i].notes.append("title \(why): '\(w.title)' → '\(t)'")
                        if w.title.isEmpty { columns[c][i].titleMinX = cands.compactMap { $0 }.first { $0.title == t }?.minX }
                        columns[c][i].title = t
                    }
                    if TOCPageReader.titleUnstable(columns[c][i].title, alternates: cands.map { $0?.title }) {
                        columns[c][i].notes.append(TOCPageReader.unstableNote)
                    }
                }
            }
        }

        // A page number with no title: Vision sometimes returns only the number of a line with
        // a short title ("之一 …… 50"), at every resolution. The title region alone (left of
        // the page-number column, leaders included) is read again, all such lines stacked in
        // one image.
        // Also a one-character title (another resolution may have kept only "献" of 参考文献);
        // the region starts at the page margin (or the gutter), since the lines of this page
        // that were read may all be indented deeper than the unread one.
        var titleTargets: [(c: Int, i: Int, origin: (x: Double, y: Double), crop: GrayImage)] = []
        for c in columns.indices {
            let seenLeft = columns[c].filter { !$0.drop && !$0.title.isEmpty }.map(\.line.rect.minX).min() ?? 0
            let marginLeft = (gutter != nil && c == 1) ? gutter! + charH : 0.03 * W
            let blockLeft = min(seenLeft, marginLeft + charH)
            for i in columns[c].indices where !columns[c][i].drop && columns[c][i].title.count <= 1 && columns[c][i].number != nil {
                let w = columns[c][i]
                let limit = min(numberColumns[c]?.minX ?? .infinity, w.tokenRect?.minX ?? .infinity) - 0.3 * charH
                guard limit.isFinite, limit - (blockLeft - charH) > 2 * charH else { continue }
                let pad = 0.25 * max(w.line.rect.height, charH)
                let r = toImage(PixelRect(minX: max(0, blockLeft - charH), minY: w.line.rect.minY - pad,
                                          maxX: limit, maxY: w.line.rect.maxY + pad))
                guard r.width > 4, r.height > 4, r.maxX > 0, r.minX < W, r.maxY > 0, r.minY < H else { continue }
                let ox = max(0, min(W - 1, r.minX.rounded(.down))), oy = max(0, min(H - 1, r.minY.rounded(.down)))
                titleTargets.append((c, i, (ox, oy), img.cropped(r)))
            }
        }
        // Reads the stacked title regions; returns the targets whose title was filled.
        func readTitles(_ targets: [(c: Int, i: Int, origin: (x: Double, y: Double), crop: GrayImage)]) throws -> Set<Int> {
            guard !targets.isEmpty else { return [] }
            let gap = max(20, Int(2 * charH))
            let (stack, offsets) = GrayImage.stacked(targets.map(\.crop), gap: gap)
            let found = TextRecognizer.upright(try TextRecognizer.recognize(stack, options: RecognitionOptions(
                languageCorrection: true, minimumTextHeightPixels: max(8, 5 * rendered.scale))))
            if let dir = options.debugDirectory {
                try? stack.writePNG(to: dir.appendingPathComponent("page-\(p).titles.png"))
                let dump = found.map { String(format: "%@ conf=%.2f  %@", $0.rect.description, $0.confidence, $0.text) }.joined(separator: "\n")
                try? Data((dump + "\n").utf8).write(to: dir.appendingPathComponent("page-\(p).titles.txt"))
            }
            var parts = [[OCRObservation]](repeating: [], count: targets.count)
            for o in found where o.text.contains(where: { $0.isLetter || $0.isNumber }) {
                guard let k = offsets.lastIndex(where: { Double($0) <= o.rect.midY }),
                      o.rect.midY < Double(offsets[k] + targets[k].crop.height) else { continue }
                let dx = targets[k].origin.x, dy = targets[k].origin.y - Double(offsets[k])
                var m = o
                m.rect = o.rect.offsetBy(dx: dx, dy: dy)
                m.corners = o.corners.map { PixelPoint(x: $0.x + dx, y: $0.y + dy) }
                m.trailingRect = o.trailingRect?.offsetBy(dx: dx, dy: dy)
                m.textStart = o.textStart.map { PixelPoint(x: $0.x + dx, y: $0.y + dy) }
                parts[k].append(m.deskewed(angle: skew, center: center))
            }
            var filled: Set<Int> = []
            for (k, tg) in targets.enumerated() where !parts[k].isEmpty {
                let ps = parts[k].sorted { $0.rect.minX < $1.rect.minX }
                var text = ps.map(\.text).joined(separator: " ")
                if let s = PageToken.splitTrailing(text) { text = s.title }
                let t = TOCPageReader.cleanTitle(PageToken.stripTrailingLeaders(text))
                // Only a title: not another number, not a stray mark.
                guard t.contains(where: { $0.isLetter }), PageToken.parseStandalone(t) == nil else { continue }
                let old = columns[tg.c][tg.i].title
                // A one-character title is replaced only by a longer reading that contains it.
                if !old.isEmpty { guard t.count > old.count, t.contains(old) else { continue } }
                columns[tg.c][tg.i].title = t
                columns[tg.c][tg.i].titleMinX = ps[0].textStart?.x ?? ps[0].rect.minX
                columns[tg.c][tg.i].notes.append("title read from the title region alone (the line was read without it)")
                filled.insert(k)
            }
            return filled
        }
        let filledFirst = try readTitles(titleTargets)
        // Still no title: a short title followed by a long run of leader dots (and a speck in
        // the margin) is sometimes read as a number ("之一 ……" as "17") or not at all. The text
        // before the leaders alone, found from the ink (glyph-sized blobs up to the first run
        // of dots), is read again, enlarged 2x and 3x (at 1x Vision reads that 之一 as "2一");
        // the title is taken only when both readings agree, and it is marked uncertain.
        var tight: [(c: Int, i: Int, textX: Double, textY: (Double, Double), crop: GrayImage)] = []
        for (k, tg) in titleTargets.enumerated() where !filledFirst.contains(k) && columns[tg.c][tg.i].title.isEmpty {
            guard let span = tg.crop.leadingTextSpan(charH: charH) else { continue }
            let x0 = max(0, Double(span.start) - 0.5 * charH), x1 = min(Double(tg.crop.width), Double(span.end) + 0.5 * charH)
            guard x1 - x0 > charH, x1 < Double(tg.crop.width) - charH else { continue }
            let piece = tg.crop.cropped(PixelRect(minX: x0, minY: 0, maxX: x1, maxY: Double(tg.crop.height))).padded(by: Int(charH.rounded()))
            tight.append((tg.c, tg.i, tg.origin.x + Double(span.start), (tg.origin.y, tg.origin.y + Double(tg.crop.height)), piece))
        }
        if !tight.isEmpty {
            func readTight(_ f: Double) throws -> [Int: String] {
                let pieces = tight.map { $0.crop.scaled(by: f) }
                let (stack, offsets) = GrayImage.stacked(pieces, gap: max(20, Int(2 * charH * f)))
                let found = TextRecognizer.upright(try TextRecognizer.recognize(stack, options: RecognitionOptions(
                    languageCorrection: true, minimumTextHeightPixels: max(8, 5 * rendered.scale * f))))
                if let dir = options.debugDirectory {
                    try? stack.writePNG(to: dir.appendingPathComponent("page-\(p).titles-x\(Int(f)).png"))
                    let dump = found.map { String(format: "%@ conf=%.2f  %@", $0.rect.description, $0.confidence, $0.text) }.joined(separator: "\n")
                    try? Data((dump + "\n").utf8).write(to: dir.appendingPathComponent("page-\(p).titles-x\(Int(f)).txt"))
                }
                var words: [Int: [(x: Double, text: String)]] = [:]
                for o in found where o.text.contains(where: { $0.isLetter || $0.isNumber }) {
                    guard let k = offsets.lastIndex(where: { Double($0) <= o.rect.midY }),
                          o.rect.midY < Double(offsets[k] + pieces[k].height) else { continue }
                    words[k, default: []].append((o.rect.minX, o.text))
                }
                return words.mapValues { ws in
                    var text = ws.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
                    if let s = PageToken.splitTrailing(text) { text = s.title }
                    return TOCPageReader.cleanTitle(PageToken.stripTrailingLeaders(text))
                }
            }
            let a = try readTight(2), b = try readTight(3)
            func letters(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber }) }
            for k in tight.indices {
                guard let t = a[k], let u = b[k], letters(t) == letters(u), t.contains(where: { $0.isLetter }),
                      PageToken.parseStandalone(t) == nil else { continue }
                let tg = tight[k]
                columns[tg.c][tg.i].title = t
                columns[tg.c][tg.i].titleMinX = OCRObservation(text: t, rect: PixelRect(minX: tg.textX, minY: tg.textY.0, maxX: tg.textX + charH,
                                                                                        maxY: tg.textY.1)).deskewed(angle: skew, center: center).rect.minX
                columns[tg.c][tg.i].confidence = min(columns[tg.c][tg.i].confidence, 0.3)
                columns[tg.c][tg.i].notes.append(TOCPageReader.enlargedTitleNote)
            }
        }

        // Emit.
        var emitted = 0
        for (c, works) in columns.enumerated() {
            let kept = works.filter { !$0.drop }
            let withNumbers = kept.filter { $0.number != nil }
            let margin = (withNumbers.isEmpty ? kept : withNumbers).map { $0.titleMinX ?? $0.line.textMinX }.min() ?? 0
            let lefts = kept.map { max(margin, $0.titleMinX ?? $0.line.textMinX) }
            let levels = LineLayout.indentLevels(lefts, tolerance: 0.6 * charH)
            for (k, w) in kept.enumerated() {
                // Vision reports 0.3 / 0.5 / 1.0 for most CJK lines, including correct ones; map
                // it to 0.65...1 and let the structural doubts below pull it down.
                var conf = 0.5 + 0.5 * w.confidence
                var notes = w.notes
                if let n = w.number {
                    if n.noisy { conf *= 0.7; notes.append("page number repaired from OCR look-alikes (O/l/I)") }
                    if n.upperRoman { conf *= 0.8 }
                    if w.notes.contains("page number touches the title") { conf *= 0.8 }
                }
                if w.title.isEmpty { conf *= 0.5; notes.append("no title text") }
                if w.notes.contains(TOCPageReader.unstableNote) { conf *= 0.85 }
                var title = w.title
                if let n = w.number, n.kind == .arabic, let d = TOCPageReader.trailingDigits(title), d.digits == n.text {
                    title = d.rest  // "量效关系 1 0" + page 10: the page number was read twice
                }
                let r = w.line.rect
                let line = TOCLine(sourcePage: p, column: c, indentLevel: min(levels[k], 8),
                                   x: r.minX / W, y: r.minY / H, width: r.width / W, height: r.height / H,
                                   title: TOCPageReader.cleanTitle(title), page: w.number, pageSource: w.source,
                                   confidence: max(0, min(1, conf)), notes: notes)
                if line.confidence < options.warnBelow {
                    result.warnings.append(String(format: "page %d line %d: low confidence %.2f: %@", p, emitted + 1,
                                                  line.confidence, line.text.replacingOccurrences(of: "\t", with: " → ")))
                }
                result.lines.append(line)
                emitted += 1
            }
        }
        if raw.isEmpty { result.warnings.append("page \(p): no text recognized") }
        result.pages.append(TOCPageStats(page: p, renderSeconds: renderSeconds, ocrSeconds: ocrSeconds, reocrSeconds: reocrSeconds,
                                         observations: raw.count, lines: emitted, columns: groups.count,
                                         skewDegrees: skew * 180 / .pi, pixelSize: (img.width, img.height)))
    }
}

extension TOCPageReader {
    /// Observations of the page read at 200 and 400 dpi, mapped into the primary reading's
    /// deskewed pixel coordinates.
    func alternateReadings(page p: Int, primaryScale: Double, skew: Double, center: PixelPoint) throws -> [[OCRObservation]] {
        var out: [[OCRObservation]] = []
        for dpi in [200.0, 400.0] {
            let r = try rasterizer.render(page: p, dpi: dpi, maxLongEdge: 5400)
            let (raw, _) = try TextRecognizer.recognizeUpright(r.image, options: RecognitionOptions(
                languageCorrection: true, minimumTextHeightPixels: max(8, 5 * r.scale)))
            let f = primaryScale / r.scale
            out.append(TextRecognizer.upright(raw).filter { $0.text.contains { $0.isLetter || $0.isNumber } }.map { o in
                var m = o
                m.rect = o.rect.scaled(by: f)
                m.corners = o.corners.map { PixelPoint(x: $0.x * f, y: $0.y * f) }
                m.trailingRect = o.trailingRect?.scaled(by: f)
                m.textStart = o.textStart.map { PixelPoint(x: $0.x * f, y: $0.y * f) }
                return m.deskewed(angle: skew, center: center)
            })
        }
        return out
    }

    /// The title an alternate reading gives for a line: its observations that overlap the
    /// line vertically (at least half) and start between `leftLimit` (the column's text
    /// block) and `rightLimit` (the page-number column), left to right, without a trailing
    /// page number or leaders. nil when none.
    static func titleFrom(_ obs: [OCRObservation], line: PixelRect, leftLimit: Double, rightLimit: Double,
                          charH: Double) -> (title: String, minX: Double)? {
        let parts = obs.filter { o in
            o.rect.verticalOverlapRatio(line) >= 0.5 && o.rect.minX >= leftLimit
                && o.rect.minX < min(rightLimit, line.maxX + charH) && o.rect.maxY - o.rect.minY < 2.5 * max(line.height, charH)
        }.sorted { $0.rect.minX < $1.rect.minX }
        guard !parts.isEmpty else { return nil }
        var text = parts.map(\.text).joined(separator: " ")
        if let s = PageToken.splitTrailing(text) { text = s.title }
        let t = cleanTitle(PageToken.stripTrailingLeaders(text))
        return t.isEmpty ? nil : (t, parts[0].textStart?.x ?? parts[0].rect.minX)
    }

    static func isIdeograph(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    static func isSubsequence(_ a: [Character], of b: [Character]) -> Bool {
        var j = 0
        for c in b where j < a.count && c == a[j] { j += 1 }
        return j == a.count
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// The title after a vote between the primary (300 dpi) reading and the alternates, with
    /// the reason; nil keeps the primary. Letters and digits are compared (marks and white
    /// space ignored), and characters are only ever added, never substituted:
    ///   - lost characters: the primary is a subsequence of an alternate that adds 1-3 CJK
    ///     ideographs ("消费者行理论" → "消费者行为理论", "第章" → "第一章"). Vision often
    ///     drops a character at one resolution; it rarely invents one. The other alternate
    ///     must not contradict it (be longer than the primary without being part of it).
    ///   - stray marks: both alternates read the same letters as the primary, agree with each
    ///     other, and have only a subset of its marks ("第二节•赋役制度" → "第二节 赋役制度").
    ///   - no title: an alternate's title, when the alternates that read one agree.
    static func voteTitle(primary: String, alternates: [String?]) -> (String, String)? {
        func key(_ s: String) -> [Character] { Array(s.filter { !$0.isWhitespace }) }
        func letters(_ s: String) -> [Character] { Array(s.filter { $0.isLetter || $0.isNumber }) }
        let p = letters(primary)
        let alts = alternates.compactMap { $0 }.filter { !letters($0).isEmpty }
        guard !alts.isEmpty else { return nil }
        if p.isEmpty {
            return Set(alts.map { String(letters($0)) }).count == 1 ? (alts[0], "read only at another resolution") : nil
        }
        let supers = alts.filter { a in
            let k = letters(a)
            guard k.count > p.count, k.count - p.count <= 3, isSubsequence(p, of: k) else { return false }
            var j = 0
            let extra = k.filter { c in
                if j < p.count && c == p[j] { j += 1; return false }
                return true
            }
            guard extra.allSatisfy(isIdeograph) else { return false }
            // The added characters must not be a word of their own at either end ("状态转换
            // 學": a misread leader or page number), only part of the title's words.
            let words = a.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.count >= 2 {
                if isSubsequence(p, of: letters(words.dropLast().joined())) { return false }
                if isSubsequence(p, of: letters(words.dropFirst().joined())) { return false }
            }
            return true
        }
        if let best = supers.max(by: { letters($0).count < letters($1).count }) {
            let contradicted = alts.contains { o in
                letters(o) != letters(best) && letters(o).count > p.count && !isSubsequence(letters(o), of: letters(best))
            }
            if !contradicted { return (best, "had characters OCR lost at 300 dpi") }
        }
        if alts.count == 2, key(alts[0]) == key(alts[1]), letters(alts[0]) == p, key(alts[0]) != key(primary),
           isSubsequence(key(alts[0]), of: key(primary)) {
            return (alts[0], "had a stray mark removed")
        }
        return nil
    }

    public static let unstableNote = "title read differently at 200, 300 and 400 dpi"
    /// The title was read only from the enlarged text before the leaders (see `read`): not
    /// read on the line itself, so it counts as doubtful.
    public static let enlargedTitleNote = "title read only from the enlarged text before the leaders (the line was read without it)"

    /// No other resolution reads the title's letters the same way (and at least one read
    /// the line): the scan is too poor for the title to be trusted.
    static func titleUnstable(_ title: String, alternates: [String?]) -> Bool {
        func letters(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber }) }
        let t = letters(title)
        let alts = alternates.compactMap { $0 }.map(letters).filter { !$0.isEmpty }
        guard !t.isEmpty, !alts.isEmpty, !alts.contains(t) else { return false }
        // The readings differ only by a whole trailing number that one of them took into the
        // title and the other left out as a page ("3.2 回顾20" / "3.2 回顾", the first line of
        // a wrapped title): the title's letters agree, the parser decides what the number is.
        func dropTrailingDigits(_ s: String) -> String { String(s.reversed().drop(while: \.isNumber).reversed()) }
        return !alts.contains { a in
            (a != dropTrailingDigits(a) && dropTrailingDigits(a) == t) || (t != dropTrailingDigits(t) && dropTrailingDigits(t) == a)
        }
    }

    static let leadingNoise: Set<Character> = [".", "．", "·", "•", "・", "。", ",", "，", "'", "`", "‘", "’", "_", ":", ";", "|", "¦"]

    /// Removes scan specks that OCR reads as bullets or dots: U+2022 bullets anywhere,
    /// punctuation before the first word, runs of spaces.
    static let numberingSeparator = try! NSRegularExpression(
        pattern: "^(第[一二三四五六七八九十百千零〇两0-9０-９]+(?:章|节|節|篇|部分|部|讲|講|课|課|编|編|卷|回))[\\s.,，．、:：]*")

    /// Trailing words of a title that are a misread page number: each at most 5 characters,
    /// no CJK, made of digits, roman letters and OCR look-alikes (× | ! l I O), not all plain
    /// letters ("×11", "1 0" for a split "１０"), and positioned (proportionally within the
    /// line's last observation) at or right of `columnMinX`. nil when there is none, so
    /// "Windows 10 ……" or "Part II" keep their last word.
    static func dropMisreadTail(_ title: String, line: TextLine, columnMinX: Double) -> (rest: String, tail: String)? {
        let allowed = Set("0123456789ivxlIVXL×|!Oo")
        // Every word of the line with the x of its start (proportional within its observation).
        var words: [(text: String, x: Double)] = []
        for m in line.members {
            let n = Double(max(1, m.text.count))
            var k = 0
            for w in m.text.split(separator: " ", omittingEmptySubsequences: false) {
                if !w.isEmpty { words.append((String(w), m.rect.minX + m.rect.width * Double(k) / n)) }
                k += w.count + 1
            }
        }
        var rest = title.trimmingCharacters(in: .whitespaces)
        var dropped: [String] = []
        while let sp = rest.lastIndex(of: " "), dropped.joined().count < 6 {
            let tail = String(rest[rest.index(after: sp)...])
            guard tail.count <= 5, tail.allSatisfy({ allowed.contains($0) }), tail.contains(where: { !$0.isLetter }),
                  let w = words.lastIndex(where: { $0.text == tail }), words[w].x >= columnMinX else { break }
            words.removeSubrange(w...)
            dropped.insert(tail, at: 0)
            rest = String(rest[..<sp]).trimmingCharacters(in: .whitespaces)
        }
        rest = PageToken.stripTrailingLeaders(rest)
        guard !dropped.isEmpty, !rest.isEmpty else { return nil }
        return (rest, dropped.joined(separator: " "))
    }

    public static func cleanTitle(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "•", with: " ")
        // "-、" / "—、": a faint 一 read as a dash.
        if let f = t.first, ["-", "—", "–", "_", "‐", "―"].contains(f), t.dropFirst().first == "、" { t = "一" + t.dropFirst() }
        while let f = t.first, f.isWhitespace || leadingNoise.contains(f) { t.removeFirst() }
        // "第一节，工资" / "第一节.古诺模型" / "第三节厂商": one space after a 第X章-style number.
        let ns = t as NSString
        if let m = numberingSeparator.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
            let head = ns.substring(with: m.range(at: 1))
            let rest = ns.substring(from: m.range.location + m.range.length)
            if !rest.isEmpty { t = head + " " + rest }
        }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return PageToken.stripTrailingLeaders(t)
    }
}

extension TOCPageReader {
    /// A title that ends in a separate 1-3 digit group ("理论基础 1", "量效关系 1 0"), not a
    /// section number ("2.3") or part of a word: the digits and the title without them.
    static func trailingDigits(_ title: String) -> (digits: String, rest: String)? {
        var chars = Array(title)
        var digits: [Character] = []
        while let c = chars.last, c == " " || c.isASCII && c.isNumber {
            if c != " " { digits.insert(c, at: 0) }
            chars.removeLast()
            if digits.count > 3 { return nil }
        }
        guard !digits.isEmpty, chars.count < title.count, title.count - chars.count > digits.count,
              let before = chars.last, !before.isNumber, before != ".", !(before.isASCII && before.isLetter) else { return nil }
        return (String(digits), String(chars).trimmingCharacters(in: .whitespaces))
    }
}

extension TOCPageReader {
    /// Recognizes crops laid out side by side (`row`, at most 10 per image) or stacked, and
    /// returns each crop's observations (coordinates of the composite image). An observation
    /// that spills into a neighbouring crop is dropped.
    static func readCrops(_ crops: [GrayImage], row: Bool, gap: Int, options: RecognitionOptions,
                          debug: (URL, String)?) throws -> [[OCRObservation]] {
        var per = [[OCRObservation]](repeating: [], count: crops.count)
        let chunk = row ? 10 : max(1, crops.count)
        var start = 0
        var part = 0
        while start < crops.count {
            let pieces = Array(crops[start..<min(crops.count, start + chunk)])
            let (img, offsets) = row ? GrayImage.row(pieces, gap: gap) : GrayImage.stacked(pieces, gap: gap)
            let found = TextRecognizer.upright(try TextRecognizer.recognize(img, options: options))
            if let (dir, name) = debug {
                try? img.writePNG(to: dir.appendingPathComponent("\(name)-\(part).png"))
                let dump = found.map { String(format: "%@ conf=%.2f  %@", $0.rect.description, $0.confidence, $0.text) }.joined(separator: "\n")
                try? Data((dump + "\n").utf8).write(to: dir.appendingPathComponent("\(name)-\(part).txt"))
            }
            for o in found {
                let lo = row ? o.rect.minX : o.rect.minY, hi = row ? o.rect.maxX : o.rect.maxY
                let mid = (lo + hi) / 2
                guard let j = offsets.lastIndex(where: { Double($0) <= mid }) else { continue }
                let begin = Double(offsets[j]), end = begin + Double(row ? pieces[j].width : pieces[j].height)
                guard mid < end, lo >= begin - Double(gap) / 2, hi <= end + Double(gap) / 2 else { continue }
                per[start + j].append(o)
            }
            start += chunk
            part += 1
        }
        return per
    }
}

extension TOCPageReader {
    /// A single "1" and a roman "i" look alike in many serif faces. The printed order decides
    /// where it can: roman front matter comes before arabic page 1, so
    ///   - an "i" after a roman entry and before arabic page 2 or 3 is the arabic 1, and
    ///   - a "1" followed by a roman entry is the roman i.
    static func resolveOneOrI(_ lines: inout [TOCLine]) {
        let numbered = lines.indices.filter { lines[$0].page != nil }
        for (m, idx) in numbered.enumerated() {
            guard let n = lines[idx].page, n.value == 1 else { continue }
            let prev = m > 0 ? lines[numbered[m - 1]].page : nil
            let next = m + 1 < numbered.count ? lines[numbered[m + 1]].page : nil
            if n.kind == .roman, prev?.kind == .roman, let nx = next, nx.kind == .arabic, nx.value <= 3 {
                lines[idx].page = PageNumber(value: 1, kind: .arabic, text: "1", noisy: true)
                lines[idx].notes.append("read as i; the printed order says arabic 1")
                lines[idx].confidence *= 0.8
            } else if n.kind == .arabic, n.text == "1", let nx = next, nx.kind == .roman {
                lines[idx].page = PageNumber(value: 1, kind: .roman, text: "i", noisy: true)
                lines[idx].notes.append("read as 1; the printed order says roman i")
                lines[idx].confidence *= 0.8
            }
        }
    }
}
