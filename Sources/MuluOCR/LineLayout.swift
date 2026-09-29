import Foundation

/// Observations that sit on one visual line, left to right.
public struct TextLine: Sendable {
    public var members: [OCRObservation]
    public var rect: PixelRect

    public init(members: [OCRObservation]) {
        self.members = members.sorted { $0.rect.minX < $1.rect.minX }
        rect = members.dropFirst().reduce(members[0].rect) { $0.union($1.rect) }
    }

    public var text: String { members.map(\.text).joined(separator: " ") }
    public var confidence: Double { members.map(\.confidence).min() ?? 0 }
    /// Where the line's text starts: the first letter or digit of its first observation.
    public var textMinX: Double { members.first?.textStart?.x ?? rect.minX }
}

/// Geometry rules that turn Vision observations into reading-order lines (pure; tested with
/// synthetic boxes).
public enum LineLayout {
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Scan skew in radians: the median baseline angle of long observations (at least 3 of
    /// them, each at least 4x wider than tall). 0 when unknown or implausible (> 5 degrees).
    public static func estimateSkew(_ obs: [OCRObservation]) -> Double {
        let angles = obs.filter { $0.rect.width >= 4 * max(1, $0.rect.height) }.map(\.baselineAngle)
        guard angles.count >= 3, let m = median(angles), abs(m) <= 5 * .pi / 180 else { return 0 }
        return m
    }

    /// Groups observations into lines: an observation joins the line it overlaps most
    /// vertically (at least half of the smaller height) and does not overlap horizontally.
    /// Lines come back top to bottom.
    public static func groupLines(_ obs: [OCRObservation]) -> [TextLine] {
        var groups: [[OCRObservation]] = []
        for o in obs.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            var best: (Int, Double)? = nil
            for (i, g) in groups.enumerated() {
                var overlap = 0.0
                var collides = false
                for m in g {
                    overlap = max(overlap, m.rect.verticalOverlapRatio(o.rect))
                    let hx = min(m.rect.maxX, o.rect.maxX) - max(m.rect.minX, o.rect.minX)
                    if hx > 0.3 * min(m.rect.width, o.rect.width) { collides = true }
                }
                if overlap >= 0.5, !collides, overlap > (best?.1 ?? 0) { best = (i, overlap) }
            }
            if let (i, _) = best { groups[i].append(o) } else { groups.append([o]) }
        }
        return groups.map(TextLine.init).sorted { $0.rect.midY < $1.rect.midY }
    }

    /// Letters (CJK or Latin) in a string, ignoring digits, leaders and punctuation.
    static func letterCount(_ s: String) -> Int { s.filter { $0.isLetter }.count }

    /// Splits a page into two text columns when there is a vertical gutter between 30% and
    /// 70% of the width that (almost) nothing crosses and both sides carry real titles (at
    /// least 3 observations with 2+ letters each; a column of bare page numbers is not a
    /// text column). Observations wider than 60% of the page (a centred heading) go to the
    /// left column. Returns one or two groups, left first, and the gutter's x if split.
    public static func splitColumns(_ obs: [OCRObservation], pageWidth W: Double) -> (groups: [[OCRObservation]], gutter: Double?) {
        guard W > 0, obs.count >= 8 else { return ([obs], nil) }
        let bins = 200
        var cover = [Int](repeating: 0, count: bins)
        let narrow = obs.filter { $0.rect.width < 0.6 * W }
        for o in narrow {
            let a = max(0, Int(o.rect.minX / W * Double(bins)))
            let b = min(bins - 1, Int(o.rect.maxX / W * Double(bins)))
            if a <= b { for i in a...b { cover[i] += 1 } }
        }
        let allowed = max(1, narrow.count / 25)
        var runs: [(Int, Int)] = []
        var i = Int(0.3 * Double(bins))
        let hi = Int(0.7 * Double(bins))
        while i <= hi {
            if cover[i] <= allowed {
                var j = i
                while j + 1 <= hi, cover[j + 1] <= allowed { j += 1 }
                if j - i + 1 >= 3 { runs.append((i, j)) }
                i = j + 1
            } else {
                i += 1
            }
        }
        func titled(_ g: [OCRObservation]) -> Int { g.filter { letterCount($0.text) >= 2 }.count }
        // Among the candidate gaps, prefer the one whose right side starts with titles (the
        // gap between a column's numbers and the next column's titles), then the widest.
        var best: (score: Double, width: Int, split: ([OCRObservation], [OCRObservation]), gutter: Double)? = nil
        for (a, b) in runs {
            let gutter = (Double(a) + Double(b + 1)) / 2 / Double(bins) * W
            let gapEnd = Double(b + 1) / Double(bins) * W
            var left: [OCRObservation] = [], right: [OCRObservation] = []
            for o in obs {
                if o.rect.width >= 0.6 * W || o.rect.midX < gutter { left.append(o) } else { right.append(o) }
            }
            guard titled(left) >= 3, titled(right) >= 3 else { continue }
            let starters = right.filter { $0.rect.minX < gapEnd + 0.1 * W }
            let score = starters.isEmpty ? 0 : Double(titled(starters)) / Double(starters.count)
            if best == nil || score > best!.score + 1e-9 || (abs(score - best!.score) < 1e-9 && b - a > best!.width) {
                best = (score, b - a, (left, right), gutter)
            }
        }
        guard let best, best.score >= 0.5 else { return ([obs], nil) }
        return ([best.split.0, best.split.1], best.gutter)
    }

    /// Scan skew in radians from a right-aligned column of page numbers: the Theil-Sen slope
    /// of their right edges against y (a vertical column tilts by -tan(skew)). Uses the
    /// rightmost numbers (within 5% of the page width of the rightmost one); needs at least 4
    /// spanning a quarter of the page height whose residuals stay within `tolerance`.
    public static func skewFromNumberColumn(_ points: [PixelPoint], pageWidth W: Double, pageHeight H: Double,
                                            tolerance: Double) -> Double? {
        guard let right = points.map(\.x).max() else { return nil }
        let pts = points.filter { $0.x >= right - 0.05 * W }
        guard pts.count >= 4, let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max(), y1 - y0 >= 0.25 * H else { return nil }
        var slopes: [Double] = []
        for i in pts.indices {
            for j in pts.indices where j > i && abs(pts[j].y - pts[i].y) >= 0.1 * H {
                slopes.append((pts[j].x - pts[i].x) / (pts[j].y - pts[i].y))
            }
        }
        guard let slope = median(slopes) else { return nil }
        guard let icpt = median(pts.map { $0.x - slope * $0.y }) else { return nil }
        let good = pts.filter { abs($0.x - (icpt + slope * $0.y)) <= tolerance }.count
        guard good * 4 >= pts.count * 3 else { return nil }
        let a = -atan(slope)
        return abs(a) <= 5 * .pi / 180 ? a : nil
    }

    /// The x-range of the page-number column: the largest set of token boxes whose right
    /// edges (right-aligned numbers) or left edges agree within about one character height.
    /// Needs at least `minCount` tokens and at least half of all tokens.
    public static func numberColumn(tokenRects: [PixelRect], charHeight: Double, minCount: Int = 3) -> (minX: Double, maxX: Double)? {
        guard tokenRects.count >= minCount else { return nil }
        let tol = max(1.2 * charHeight, 4)
        func cluster(_ key: (PixelRect) -> Double) -> [PixelRect] {
            let s = tokenRects.sorted { key($0) < key($1) }
            var best: ArraySlice<PixelRect> = []
            var lo = 0
            for hi in s.indices {
                while key(s[hi]) - key(s[lo]) > tol { lo += 1 }
                if hi - lo + 1 > best.count { best = s[lo...hi] }
            }
            return Array(best)
        }
        let right = cluster { $0.maxX }
        let left = cluster { $0.minX }
        let best = right.count >= left.count ? right : left
        guard best.count >= minCount, best.count * 2 >= tokenRects.count else { return nil }
        return (best.map(\.minX).min()!, best.map(\.maxX).max()!)
    }

    /// Indentation levels: left edges clustered (a new level wherever consecutive distinct
    /// edges differ by more than `tolerance`), counted from the leftmost edge.
    public static func indentLevels(_ lefts: [Double], tolerance: Double) -> [Int] {
        let sorted = Array(Set(lefts)).sorted()
        guard !sorted.isEmpty else { return [] }
        var levelOf: [Double: Int] = [:]
        var level = 0
        var prev = sorted[0]
        for x in sorted {
            if x - prev > tolerance { level += 1 }
            levelOf[x] = level
            prev = x
        }
        return lefts.map { levelOf[$0] ?? 0 }
    }
}
