import Foundation

/// A last resort for the one page number Vision will not read at all: a lone "1" (or a
/// roman "i") standing by itself in the page-number column. Vision returns no observation
/// for such a crop in any layout, so the crop's ink is inspected directly.
enum GlyphShape {
    struct Component: Equatable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var area: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// 8-connected components of pixels darker than `threshold`.
    static func components(_ img: GrayImage, threshold: UInt8 = 128) -> [Component] {
        let w = img.width, h = img.height
        var seen = [Bool](repeating: false, count: w * h)
        var out: [Component] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where !seen[start] && img.pixels[start] < threshold {
            var c = Component(minX: start % w, minY: start / w, maxX: start % w, maxY: start / w, area: 0)
            seen[start] = true
            stack.append(start)
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                c.area += 1
                c.minX = min(c.minX, x); c.maxX = max(c.maxX, x)
                c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let q = ny * w + nx
                        if !seen[q] && img.pixels[q] < threshold {
                            seen[q] = true
                            stack.append(q)
                        }
                    }
                }
            }
            out.append(c)
        }
        return out
    }

    /// "1" when the right two thirds of a page-number crop hold exactly one tall, thin stroke
    /// (0.45-1.2 of the text height, at most 0.6 as wide as tall) and otherwise only specks
    /// and leader dots; "i" when a dot sits right above a shorter stroke. Nil otherwise.
    static func loneStroke(_ crop: GrayImage, textHeight: Double) -> PageNumber? {
        let comps = components(crop).filter { $0.area >= 3 }
        let xMin = Int(Double(crop.width) * 0.3)
        let strokes = comps.filter { c in
            Double(c.height) >= 0.3 * textHeight && Double(c.height) <= 1.2 * textHeight
                && Double(c.width) <= 0.6 * Double(c.height) && c.minX >= xMin
        }
        guard strokes.count == 1, let s = strokes.first else { return nil }
        var dot = false
        for c in comps where c != s {
            let small = Double(max(c.width, c.height)) <= 0.3 * Double(s.height)
            let above = c.maxY < s.minY && s.minY - c.maxY <= s.height / 2 && c.maxX >= s.minX - 2 && c.minX <= s.maxX + 2
            if small && above && Double(max(c.width, c.height)) >= 0.12 * Double(s.height) {
                dot = true
            } else if !small {
                return nil  // other ink that is not a speck: not a lone stroke
            }
        }
        if dot {
            return Double(s.height) <= 0.8 * textHeight ? PageNumber(value: 1, kind: .roman, text: "i", noisy: true) : nil
        }
        guard Double(s.height) >= 0.45 * textHeight else { return nil }
        return PageNumber(value: 1, kind: .arabic, text: "1", noisy: true)
    }
}
