import CoreGraphics
import Foundation

/// Printed page numbers found on one sampled body page.
public struct OffsetSample: Sendable {
    /// 1-based physical page.
    public var page: Int
    /// Arabic numbers that could be the page's folio (standalone ones first).
    public var printed: [Int]
    /// The subset of `printed` that stood alone in the header/footer ("12", "- 12 -").
    public var standalone: [Int]
    /// Recognized header/footer text (for --verbose / debugging).
    public var texts: [String]
    public var seconds: Double

    public init(page: Int, printed: [Int], standalone: [Int] = [], texts: [String] = [], seconds: Double = 0) {
        self.page = page
        self.printed = printed
        self.standalone = standalone
        self.texts = texts
        self.seconds = seconds
    }
}

public struct OffsetReport: Sendable {
    public enum Status: String, Sendable {
        case ok
        case lowConfidence = "low-confidence"
        case notFound = "not-found"
    }

    /// physical = printed + offset. Set only when `status == .ok`.
    public var offset: Int?
    /// The winning offset even when it is not trusted.
    public var bestGuess: Int?
    /// Winning votes / sampled pages.
    public var confidence: Double
    public var samples: Int
    /// Sampled pages that agree with the winner.
    public var agreeing: Int
    /// Sampled pages on which at least one candidate number was read.
    public var readable: Int
    /// (offset, pages) sorted by votes, most first.
    public var votes: [(offset: Int, count: Int)]
    public var status: Status
    public var reason: String
    public var details: [OffsetSample]
    public var seconds: Double
    /// A competing offset the samples also support (a runner-up with more than a third of
    /// the winner's votes, or a run of the last / first sampled pages that agree on another
    /// offset): the offset probably changes inside the book. Set whatever the status.
    public var conflict: (offset: Int, count: Int)? = nil
    /// Sampled pages that could not be rendered (skipped: they count as unreadable).
    public var unrenderable: [Int] = []
    /// The first 2+ readable sampled pages agree on another offset (not a refusal by itself:
    /// usually front matter numbered on its own; `mulu auto` refuses when the run reaches
    /// the first chapter).
    public var leadingRun: (offset: Int, pages: [Int])? = nil

    public var json: String {
        func q(_ s: String) -> String { OCRJSON.quote(s) }
        let v = votes.prefix(10).map { "\(q(String($0.offset))):\($0.count)" }.joined(separator: ",")
        let d = details.map { s -> String in
            let off = s.printed.map { String(s.page - $0) }.joined(separator: ",")
            return "{\"page\":\(s.page),\"printed\":[\(s.printed.map(String.init).joined(separator: ","))],\"offsets\":[\(off)]}"
        }.joined(separator: ",")
        return "{\"offset\":\(offset.map(String.init) ?? "null"),\"confidence\":\(String(format: "%.3f", confidence)),"
            + "\"samples\":\(samples),\"agreeing\":\(agreeing),\"readable\":\(readable),\"votes\":{\(v)},"
            + "\"status\":\(q(status.rawValue)),\"best_guess\":\(bestGuess.map(String.init) ?? "null"),"
            + "\"reason\":\(q(reason)),\"conflict\":\(conflict.map { "{\"offset\":\($0.offset),\"pages\":\($0.count)}" } ?? "null"),"
            + "\"unrenderable\":[\(unrenderable.map(String.init).joined(separator: ","))],"
            + "\"seconds\":\(String(format: "%.2f", seconds)),\"details\":[\(d)]}"
    }
}

enum OCRJSON {
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

/// The voting rule (pure). Each sampled page votes once for every distinct
/// physical-minus-printed value among its candidates. The winner needs
///   - at least `minAgreeing` agreeing pages (default 6),
///   - confidence = agreeing / samples >= `minConfidence` (default 0.4), and
///   - at least 3x the votes of the runner-up (otherwise the offset probably changes inside
///     the book, e.g. unnumbered plates, and one number would be wrong for part of it).
///     Runner-up votes that are digit slips of the winner's folio ("7" or "17" for 37) on a
///     page between two agreeing pages are not counted: the offset holds on both sides.
///   - no run of 2 or more of the LAST readable sampled pages that all agree on one other
///     offset and not on the winner's (plates or a restart near the end of the book: a
///     minority of votes, but every entry after the change would be wrong). Such a run at
///     the START is only reported (`leadingRun`): it is usually front matter with its own
///     arabic numbering.
/// Ties are broken by the number of standalone folios, then by the smaller |offset|.
public enum OffsetVoter {
    public static func vote(_ samples: [OffsetSample], minAgreeing: Int = 6, minConfidence: Double = 0.4) -> OffsetReport {
        var votes: [Int: Int] = [:]
        var standaloneVotes: [Int: Int] = [:]
        var readable = 0
        for s in samples {
            let offs = Set(s.printed.map { s.page - $0 })
            if !offs.isEmpty { readable += 1 }
            for o in offs { votes[o, default: 0] += 1 }
            for o in Set(s.standalone.map { s.page - $0 }) { standaloneVotes[o, default: 0] += 1 }
        }
        let ranked = votes.map { (offset: $0.key, count: $0.value) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            let a = standaloneVotes[$0.offset] ?? 0, b = standaloneVotes[$1.offset] ?? 0
            if a != b { return a > b }
            if abs($0.offset) != abs($1.offset) { return abs($0.offset) < abs($1.offset) }
            return $0.offset > $1.offset
        }
        var r = OffsetReport(offset: nil, bestGuess: ranked.first?.offset, confidence: 0, samples: samples.count,
                             agreeing: ranked.first?.count ?? 0, readable: readable, votes: ranked, status: .notFound,
                             reason: "", details: samples, seconds: samples.map(\.seconds).reduce(0, +))
        guard let win = ranked.first, !samples.isEmpty else {
            r.reason = "no printed page numbers found in the headers/footers of \(samples.count) sampled pages"
            return r
        }
        r.confidence = Double(win.count) / Double(samples.count)
        // For the runner-up rule, a vote that is a misread of the winner's folio does not count:
        // the reading is the expected folio with a digit lost ("7" for 37) or a leading digit
        // changed ("16" for 46), and pages on both sides agree with the winner, so the offset
        // did not change there (an offset change holds from some page on).
        let agreePages = samples.filter { s in s.printed.contains { s.page - $0 == win.offset } }.map(\.page)
        var unexplained: [Int: Int] = [:]
        for s in samples {
            let expected = s.page - win.offset
            let inside = agreePages.contains { $0 < s.page } && agreePages.contains { $0 > s.page }
            for o in Set(s.printed.map { s.page - $0 }) where o != win.offset {
                if inside && isDigitSlip(read: s.page - o, expected: expected) { continue }
                unexplained[o, default: 0] += 1
            }
        }
        let runnerUp = ranked.dropFirst().map { (offset: $0.offset, count: unexplained[$0.offset] ?? 0) }
            .max { $0.count != $1.count ? $0.count < $1.count : $0.offset > $1.offset }
        if let ru = runnerUp, ru.count > 0, ru.count * 3 > win.count { r.conflict = (ru.offset, ru.count) }
        let edge = edgeRun(samples, winner: win.offset, last: true)
        if r.conflict == nil, let e = edge { r.conflict = (e.offset, e.pages.count) }
        if let l = edgeRun(samples, winner: win.offset, last: false) { r.leadingRun = (l.offset, l.pages) }
        if win.count < minAgreeing {
            r.status = .lowConfidence
            r.reason = "only \(win.count) of \(samples.count) sampled pages agree on offset \(win.offset) (need \(minAgreeing))"
        } else if r.confidence < minConfidence {
            r.status = .lowConfidence
            r.reason = String(format: "only %d of %d sampled pages (%.0f%%) agree on offset %d (need %.0f%%)",
                              win.count, samples.count, r.confidence * 100, win.offset, minConfidence * 100)
        } else if let ru = runnerUp, ru.count > 0, ru.count * 3 > win.count {
            r.status = .lowConfidence
            r.reason = "sampled pages disagree: offset \(win.offset) on \(win.count) pages, \(ru.offset) on \(ru.count); the offset may change inside the book"
        } else if let e = edge {
            r.status = .lowConfidence
            r.reason = "the last \(e.pages.count) sampled pages (\(e.pages.map(String.init).joined(separator: ", ")))"
                + " agree on offset \(e.offset), not \(win.offset); the offset changes near the end of the book"
        } else {
            r.status = .ok
            r.offset = win.offset
            r.reason = "\(win.count) of \(samples.count) sampled pages agree"
        }
        return r
    }

    /// The longest run of readable samples at the end (`last`) or the start of the book that
    /// all share one offset other than `winner` and none of which supports `winner`; nil when
    /// shorter than 2.
    static func edgeRun(_ samples: [OffsetSample], winner: Int, last: Bool) -> (offset: Int, pages: [Int], last: Bool)? {
        let readable = samples.filter { !$0.printed.isEmpty }.sorted { $0.page < $1.page }
        do {
            var common: Set<Int>? = nil
            var pages: [Int] = []
            for s in (last ? Array(readable.reversed()) : readable) {
                let offs = Set(s.printed.map { s.page - $0 })
                guard !offs.contains(winner) else { break }
                let next = common.map { $0.intersection(offs) } ?? offs
                guard !next.isEmpty else { break }
                common = next
                pages.append(s.page)
            }
            if pages.count >= 2, let c = common, let o = c.min(by: { abs($0 - winner) < abs($1 - winner) }) {
                return (o, pages.sorted(), last)
            }
        }
        return nil
    }

    /// `read` is `expected` with one digit lost, or with the same length and last digit but a
    /// different leading part: the misreads a broken folio produces.
    static func isDigitSlip(read: Int, expected: Int) -> Bool {
        guard read >= 0, expected >= 1, read != expected else { return false }
        let r = Array(String(read)), e = Array(String(expected))
        if r.count == e.count - 1 {
            return e.indices.contains { i in Array(e[..<i] + e[(i + 1)...]) == r }
        }
        return r.count == e.count && r.count >= 2 && r.last == e.last
    }
}

/// Finds physical - printed by reading page numbers in the header and footer bands of body
/// pages spread through the book.
public final class OffsetDetector {
    public let rasterizer: PDFRasterizer

    public init(url: URL) throws {
        rasterizer = try PDFRasterizer(url: url)
    }

    /// `count` pages spread evenly through the book, skipping the first and last 5%.
    public static func samplePages(pageCount n: Int, count: Int) -> [Int] {
        guard n > 0, count > 0 else { return [] }
        let skip = n / 20
        let lo = 1 + skip, hi = max(lo, n - skip)
        let span = hi - lo + 1
        if span <= count { return Array(lo...hi) }
        var out: [Int] = []
        for k in 0..<count {
            let p = lo + Int((Double(k) * Double(span - 1) / Double(count - 1)).rounded())
            if out.last != p { out.append(p) }
        }
        return out
    }

    public struct Options: Sendable {
        public var samples = 24
        /// Height of the top and bottom bands, as a fraction of the page height.
        public var band = 0.12
        public var minAgreeing = 6
        public var minConfidence = 0.4
        public var dpi = 300.0
        public var maxLongEdge = 4000
        public init() {}
    }

    /// Reads the header/footer page numbers of one page.
    public func sample(page p: Int, options: Options = Options()) throws -> OffsetSample {
        let clock = ContinuousClock()
        let t0 = clock.now
        let top = try rasterizer.render(page: p, region: CGRect(x: 0, y: 0, width: 1, height: options.band),
                                        dpi: options.dpi, maxLongEdge: options.maxLongEdge)
        let bottom = try rasterizer.render(page: p, region: CGRect(x: 0, y: 1 - options.band, width: 1, height: options.band),
                                           dpi: options.dpi, maxLongEdge: options.maxLongEdge)
        let gap = 40
        let (stack, _) = GrayImage.stacked([top.image, bottom.image], gap: gap)
        let (rawObs, _) = try TextRecognizer.recognizeUpright(stack, options: RecognitionOptions(
            languageCorrection: true, minimumTextHeightPixels: max(8, 4 * top.scale)))
        let obs = TextRecognizer.upright(rawObs)
        var printed: [Int] = []
        var standalone: [Int] = []
        let maxPrinted = max(2 * rasterizer.pageCount, rasterizer.pageCount + 100)
        for o in obs.sorted(by: { $0.rect.minY < $1.rect.minY || ($0.rect.minY == $1.rect.minY && $0.rect.minX < $1.rect.minX) }) {
            for (v, alone) in PageToken.folioCandidates(o.text) where v <= maxPrinted {
                if alone {
                    if !standalone.contains(v) { standalone.append(v) }
                    printed.removeAll { $0 == v }
                    printed.insert(v, at: standalone.count - 1)
                } else if !printed.contains(v) {
                    printed.append(v)
                }
            }
        }
        // No folio standing alone: read the bands again in English without language
        // correction (better on bare digits in noisy scans); only standalone numbers count.
        var texts = obs.map(\.text)
        if standalone.isEmpty {
            var o2 = RecognitionOptions(languageCorrection: false, minimumTextHeightPixels: max(8, 4 * top.scale))
            o2.languages = ["en-US"]
            let again = TextRecognizer.upright(try TextRecognizer.recognize(stack.normalized(), options: o2))
            for o in again {
                guard let n = PageToken.parseStandalone(o.text, allowRoman: false), n.value <= maxPrinted,
                      !n.text.contains("-") else { continue }
                if !standalone.contains(n.value) { standalone.append(n.value) }
                printed.removeAll { $0 == n.value }
                printed.insert(n.value, at: standalone.count - 1)
                texts.append("[en] " + o.text)
            }
        }
        let d = clock.now - t0
        return OffsetSample(page: p, printed: printed, standalone: standalone, texts: texts,
                            seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    public func detect(options: Options = Options(), progress: ((OffsetSample) -> Void)? = nil) throws -> OffsetReport {
        let clock = ContinuousClock()
        let t0 = clock.now
        var samples: [OffsetSample] = []
        var unrenderable: [Int] = []
        var firstError: Error? = nil
        for p in OffsetDetector.samplePages(pageCount: rasterizer.pageCount, count: options.samples) {
            // A page that cannot be rendered (broken page box, bad content) is an unreadable
            // sample, not the end of the detection.
            let s: OffsetSample
            do { s = try sample(page: p, options: options) } catch {
                unrenderable.append(p)
                firstError = firstError ?? error
                s = OffsetSample(page: p, printed: [], texts: ["(could not render: \(error))"])
            }
            progress?(s)
            samples.append(s)
        }
        if !samples.isEmpty && unrenderable.count == samples.count, let firstError { throw firstError }
        var r = OffsetVoter.vote(samples, minAgreeing: options.minAgreeing, minConfidence: options.minConfidence)
        // Not conclusive: read the pages that showed no standalone folio again with thickened
        // ink (broken strokes of a noisy scan), then vote again.
        if r.status != .ok {
            var changed = false
            for k in samples.indices where samples[k].standalone.isEmpty && !unrenderable.contains(samples[k].page) {
                let before = samples[k].standalone
                guard let thick = try? thickenedSample(samples[k], options: options) else { continue }
                samples[k] = thick
                if samples[k].standalone != before {
                    changed = true
                    progress?(samples[k])
                }
            }
            if changed { r = OffsetVoter.vote(samples, minAgreeing: options.minAgreeing, minConfidence: options.minConfidence) }
        }
        let d = clock.now - t0
        r.seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        r.unrenderable = unrenderable
        return r
    }

    /// Second reading of a page whose header/footer showed no standalone folio: the folio's
    /// thin strokes may be broken (a hard-thresholded, noisy scan). The ink is thickened and
    /// the image halved, which joins the pieces and shrinks the speckle: both bands together,
    /// then each band on its own (a lone folio in a wide, speckled band is easily missed),
    /// then with more thickening. Only standalone numbers count; the first layout that yields
    /// one ends the search.
    public func thickenedSample(_ s: OffsetSample, options: Options = Options()) throws -> OffsetSample {
        let clock = ContinuousClock()
        let t0 = clock.now
        let top = try rasterizer.render(page: s.page, region: CGRect(x: 0, y: 0, width: 1, height: options.band),
                                        dpi: options.dpi, maxLongEdge: options.maxLongEdge)
        let bottom = try rasterizer.render(page: s.page, region: CGRect(x: 0, y: 1 - options.band, width: 1, height: options.band),
                                           dpi: options.dpi, maxLongEdge: options.maxLongEdge)
        let (stack, _) = GrayImage.stacked([top.image, bottom.image], gap: 40)
        let maxPrinted = max(2 * rasterizer.pageCount, rasterizer.pageCount + 100)
        var out = s
        var o3 = RecognitionOptions(languageCorrection: false, minimumTextHeightPixels: max(6, 2 * top.scale))
        o3.languages = ["en-US"]
        let layouts: [(name: String, image: GrayImage, radius: Int)] = [
            ("both", stack, 1), ("bottom", bottom.image, 1), ("top", top.image, 1), ("bottom", bottom.image, 2), ("top", top.image, 2),
        ]
        // A blank band (no page number printed there) has nothing to thicken.
        func inked(_ g: GrayImage) -> Bool { g.pixels.lazy.filter { $0 < 128 }.count >= 20 }
        let hasInk = ["both": inked(stack), "bottom": inked(bottom.image), "top": inked(top.image)]
        for l in layouts where out.standalone.isEmpty && hasInk[l.name] == true {
            let img = l.image.thickened(radius: l.radius).boxDownscaled(by: 2)
            for o in TextRecognizer.upright(try TextRecognizer.recognize(img, options: o3)) {
                guard let n = PageToken.parseStandalone(o.text, allowRoman: false), n.value <= maxPrinted,
                      !n.text.contains("-") else { continue }
                if !out.standalone.contains(n.value) { out.standalone.append(n.value) }
                out.printed.removeAll { $0 == n.value }
                out.printed.insert(n.value, at: out.standalone.count - 1)
                out.texts.append("[thick\(l.radius) \(l.name)] " + o.text)
            }
        }
        let d = clock.now - t0
        out.seconds += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return out
    }
}

// MARK: - front matter (roman page numbers)

/// Where the front matter's roman page numbers sit: physical = roman value + offset.
public struct RomanOffsetReport: Sendable {
    /// Set only when the evidence agrees (see `RomanOffsetVoter`).
    public var offset: Int?
    /// (offset, pages) sorted by votes, most first.
    public var votes: [(offset: Int, count: Int)]
    /// Pages whose header/footer was read (not counting folios passed in as `known`).
    public var sampled: [Int]
    /// (physical page, roman value) pairs the vote used.
    public var evidence: [(page: Int, value: Int)]
    public var reason: String
}

/// The voting rule for roman folios (pure): the winner needs at least 2 agreeing pages
/// and at least twice the votes of the runner-up. Front matter is short, so one stray
/// "i" (often a misread "1" or "l") must not decide it alone.
public enum RomanOffsetVoter {
    public static func vote(_ evidence: [(page: Int, value: Int)], sampled: [Int] = []) -> RomanOffsetReport {
        var byPage: [Int: Set<Int>] = [:]
        for e in evidence { byPage[e.page, default: []].insert(e.page - e.value) }
        var votes: [Int: Int] = [:]
        for (_, offs) in byPage { for o in offs { votes[o, default: 0] += 1 } }
        let ranked = votes.map { (offset: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.offset < $1.offset
        }
        var r = RomanOffsetReport(offset: nil, votes: ranked, sampled: sampled, evidence: evidence, reason: "")
        guard let win = ranked.first else {
            r.reason = "no roman page numbers found in the front matter"
            return r
        }
        let runnerUp = ranked.dropFirst().first?.count ?? 0
        if win.count < 2 {
            r.reason = "only \(win.count) front-matter page shows a roman page number (need 2)"
        } else if runnerUp * 2 > win.count {
            r.reason = "front-matter page numbers disagree (\(ranked.prefix(3).map { "\($0.offset): \($0.count)" }.joined(separator: ", ")))"
        } else if win.offset < 0 {
            r.reason = "roman page numbers would start before the first page"
        } else {
            r.offset = win.offset
            r.reason = "\(win.count) front-matter page\(win.count == 1 ? "" : "s") agree"
        }
        return r
    }
}

extension OffsetDetector {
    /// Roman numerals standing alone in the header/footer bands of one page.
    public func romanFolios(page p: Int, options: Options = Options()) throws -> [Int] {
        let top = try rasterizer.render(page: p, region: CGRect(x: 0, y: 0, width: 1, height: options.band),
                                        dpi: options.dpi, maxLongEdge: options.maxLongEdge)
        let bottom = try rasterizer.render(page: p, region: CGRect(x: 0, y: 1 - options.band, width: 1, height: options.band),
                                           dpi: options.dpi, maxLongEdge: options.maxLongEdge)
        let (stack, _) = GrayImage.stacked([top.image, bottom.image], gap: 40)
        let (rawObs, _) = try TextRecognizer.recognizeUpright(stack, options: RecognitionOptions(
            languageCorrection: false, minimumTextHeightPixels: max(8, 4 * top.scale)))
        var out: [Int] = []
        for o in TextRecognizer.upright(rawObs) {
            guard let n = PageToken.parseStandalone(o.text, allowRoman: true), n.kind == .roman, n.value <= 60 else { continue }
            if !out.contains(n.value) { out.append(n.value) }
        }
        return out
    }

    /// Finds the front matter's roman offset from the folios already known (e.g. those of
    /// the TOC pages) plus the header/footer bands of `pages` (at most `limit` of them,
    /// nearest to the body first).
    public func detectRoman(pages: [Int], known: [(page: Int, value: Int)] = [], limit: Int = 12,
                            options: Options = Options()) throws -> RomanOffsetReport {
        let knownPages = Set(known.map(\.page))
        let todo = Array(pages.filter { $0 >= 1 && $0 <= rasterizer.pageCount && !knownPages.contains($0) }
            .sorted(by: >).prefix(limit)).sorted()
        var evidence = known
        for p in todo {
            for v in try romanFolios(page: p, options: options) { evidence.append((page: p, value: v)) }
        }
        return RomanOffsetVoter.vote(evidence, sampled: todo)
    }
}
