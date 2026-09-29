import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Axis-aligned rectangle in image pixels, y growing DOWN (row 0 is the top of the page).
public struct PixelRect: Sendable, Equatable, CustomStringConvertible {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }

    public func union(_ o: PixelRect) -> PixelRect {
        PixelRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    /// Vertical overlap divided by the smaller of the two heights (0...1).
    public func verticalOverlapRatio(_ o: PixelRect) -> Double {
        let overlap = min(maxY, o.maxY) - max(minY, o.minY)
        let base = min(height, o.height)
        guard overlap > 0, base > 0 else { return 0 }
        return overlap / base
    }

    public func offsetBy(dx: Double, dy: Double) -> PixelRect {
        PixelRect(minX: minX + dx, minY: minY + dy, maxX: maxX + dx, maxY: maxY + dy)
    }

    public func scaled(by f: Double) -> PixelRect {
        PixelRect(minX: minX * f, minY: minY * f, maxX: maxX * f, maxY: maxY * f)
    }

    public var description: String {
        String(format: "[%.0f,%.0f – %.0f,%.0f]", minX, minY, maxX, maxY)
    }
}

/// 8-bit grayscale raster, row 0 at the top, 0 = black ink, 255 = white paper.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    /// Copies a CGImage into 8-bit gray (drawn onto white, so alpha becomes paper).
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0, let ctx = GrayImage.makeContext(width: w, height: h) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.init(context: ctx)
    }

    /// Reads the pixels of an 8-bit DeviceGray bitmap context (its first row is the top).
    init(context ctx: CGContext) {
        let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
        var out = [UInt8](repeating: 255, count: w * h)
        if let data = ctx.data {
            let src = data.bindMemory(to: UInt8.self, capacity: stride * h)
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    (dst.baseAddress! + y * w).update(from: src + y * stride, count: w)
                }
            }
        }
        self.init(width: w, height: h, pixels: out)
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    public func cgImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The part of the image inside `rect` (clamped to the image; at least 1x1).
    public func cropped(_ rect: PixelRect) -> GrayImage {
        let x0 = max(0, min(width - 1, Int(rect.minX.rounded(.down))))
        let y0 = max(0, min(height - 1, Int(rect.minY.rounded(.down))))
        let x1 = max(x0 + 1, min(width, Int(rect.maxX.rounded(.up))))
        let y1 = max(y0 + 1, min(height, Int(rect.maxY.rounded(.up))))
        let w = x1 - x0, h = y1 - y0
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let s = (y0 + y) * width + x0
            out.replaceSubrange((y * w)..<((y + 1) * w), with: pixels[s..<(s + w)])
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// The image with `m` white pixels added on every side.
    public func padded(by m: Int) -> GrayImage {
        guard m > 0 else { return self }
        var out = GrayImage(width: width + 2 * m, height: height + 2 * m)
        for y in 0..<height {
            let d = (y + m) * out.width + m
            out.pixels.replaceSubrange(d..<(d + width), with: pixels[(y * width)..<((y + 1) * width)])
        }
        return out
    }

    /// Column span (first, last pixel column) of the text at the start of a one-line crop,
    /// before a run of leader dots. The ink is split into blobs at blank columns; a blob
    /// narrower and lower than 0.45 `charH` is a dot (a leader, a speck), anything else part of
    /// a glyph. The span runs from the first glyph blob to the last one before three
    /// consecutive dots. nil when there is no glyph blob.
    public func leadingTextSpan(charH: Double, darkBelow: UInt8 = 140) -> (start: Int, end: Int)? {
        guard width > 0, height > 0, charH > 0 else { return nil }
        var blobs: [(x0: Int, x1: Int, y0: Int, y1: Int)] = []
        var cur: (x0: Int, x1: Int, y0: Int, y1: Int)? = nil
        var blank = 0
        let gapLimit = max(1, Int(0.08 * charH))
        for x in 0..<width {
            var top = -1, bottom = -1
            for y in 0..<height where pixels[y * width + x] < darkBelow {
                if top < 0 { top = y }
                bottom = y
            }
            if top >= 0 {
                if var c = cur {
                    c.x1 = x; c.y0 = min(c.y0, top); c.y1 = max(c.y1, bottom)
                    cur = c
                } else {
                    cur = (x, x, top, bottom)
                }
                blank = 0
            } else if let c = cur {
                blank += 1
                if blank > gapLimit { blobs.append(c); cur = nil }
            }
        }
        if let c = cur { blobs.append(c) }
        func isDot(_ b: (x0: Int, x1: Int, y0: Int, y1: Int)) -> Bool {
            Double(b.x1 - b.x0 + 1) < 0.45 * charH && Double(b.y1 - b.y0 + 1) < 0.45 * charH
        }
        guard let first = blobs.firstIndex(where: { !isDot($0) }) else { return nil }
        var last = first, dots = 0
        for k in (first + 1)..<max(first + 1, blobs.count) {
            if isDot(blobs[k]) {
                dots += 1
                if dots >= 3 { break }
            } else {
                dots = 0
                last = k
            }
        }
        return (blobs[first].x0, blobs[last].x1)
    }

    /// Resampled by `factor` with high-quality interpolation.
    public func scaled(by factor: Double) -> GrayImage {
        let w = max(1, Int((Double(width) * factor).rounded()))
        let h = max(1, Int((Double(height) * factor).rounded()))
        guard let src = cgImage(), let ctx = GrayImage.makeContext(width: w, height: h) else { return self }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return GrayImage(context: ctx)
    }

    /// Ink thickened by `radius` pixels (a (2r+1)x(2r+1) minimum filter: dark strokes grow).
    /// Reconnects the broken thin strokes of a hard-thresholded scan.
    public func thickened(radius r: Int) -> GrayImage {
        guard r > 0, width > 0, height > 0 else { return self }
        let w = width, h = height
        var tmp = [UInt8](repeating: 255, count: w * h)
        var out = [UInt8](repeating: 255, count: w * h)
        pixels.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        var m: UInt8 = 255
                        var xx = max(0, x - r)
                        let x1 = min(w - 1, x + r)
                        while xx <= x1 { m = min(m, src[row + xx]); xx += 1 }
                        t[row + x] = m
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let y0 = max(0, y - r), y1 = min(h - 1, y + r)
                    for x in 0..<w {
                        var m: UInt8 = 255
                        var yy = y0
                        while yy <= y1 { m = min(m, t[yy * w + x]); yy += 1 }
                        o[y * w + x] = m
                    }
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Downscaled by an integer factor, each output pixel the mean of an f x f block.
    public func boxDownscaled(by f: Int) -> GrayImage {
        guard f > 1 else { return self }
        let w = max(1, width / f), h = max(1, height / f)
        var out = [UInt8](repeating: 255, count: w * h)
        let W = width, H = height
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    for x in 0..<w {
                        var sum = 0
                        for yy in (y * f)..<min(H, y * f + f) {
                            let row = yy * W
                            for xx in (x * f)..<min(W, x * f + f) { sum += Int(src[row + xx]) }
                        }
                        o[y * w + x] = UInt8(sum / (f * f))
                    }
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Stacks images vertically (left-aligned) with `gap` white rows between them.
    /// Returns the combined image and the y offset of each part.
    public static func stacked(_ parts: [GrayImage], gap: Int) -> (GrayImage, [Int]) {
        let w = parts.map(\.width).max() ?? 0
        let h = parts.map(\.height).reduce(0, +) + gap * max(0, parts.count - 1)
        var out = GrayImage(width: w, height: h)
        var offsets: [Int] = []
        var y = 0
        for p in parts {
            offsets.append(y)
            for row in 0..<p.height {
                let d = (y + row) * w
                out.pixels.replaceSubrange(d..<(d + p.width), with: p.pixels[(row * p.width)..<((row + 1) * p.width)])
            }
            y += p.height + gap
        }
        return (out, offsets)
    }

    /// Contrast stretched so the darkest ink (2nd percentile) is black and the paper (the
    /// median, for a mostly-blank crop) is white. Grey JPEG scans read better this way.
    public func normalized() -> GrayImage {
        guard !pixels.isEmpty else { return self }
        var hist = [Int](repeating: 0, count: 256)
        for v in pixels { hist[Int(v)] += 1 }
        func percentile(_ q: Double) -> Int {
            let target = Int(Double(pixels.count) * q)
            var acc = 0
            for (v, n) in hist.enumerated() {
                acc += n
                if acc > target { return v }
            }
            return 255
        }
        let lo = percentile(0.02), hi = percentile(0.5)
        guard hi - lo >= 24 else { return self }
        var out = self
        let scale = 255.0 / Double(hi - lo)
        for i in out.pixels.indices {
            out.pixels[i] = UInt8(max(0, min(255, (Double(Int(pixels[i]) - lo) * scale).rounded())))
        }
        return out
    }

    /// Places images side by side, vertically centred, with `gap` white columns between
    /// them and a `gap` margin all round. Returns the combined image and the x offset of
    /// each part.
    public static func row(_ parts: [GrayImage], gap: Int) -> (GrayImage, [Int]) {
        let h = (parts.map(\.height).max() ?? 0) + 2 * gap
        let w = parts.map(\.width).reduce(0, +) + gap * (parts.count + 1)
        var out = GrayImage(width: w, height: h)
        var offsets: [Int] = []
        var x = gap
        for p in parts {
            offsets.append(x)
            let y0 = (h - p.height) / 2
            for row in 0..<p.height {
                let d = (y0 + row) * w + x
                out.pixels.replaceSubrange(d..<(d + p.width), with: p.pixels[(row * p.width)..<((row + 1) * p.width)])
            }
            x += p.width + gap
        }
        return (out, offsets)
    }

    /// Writes a PNG (debugging aid for --debug-dir).
    public func writePNG(to url: URL) throws {
        guard let img = cgImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw OCRError.cannotWrite(url.path) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw OCRError.cannotWrite(url.path) }
    }
}

public enum OCRError: Error, CustomStringConvertible, Equatable {
    case cannotOpen(String)
    case encrypted(String)
    case noPages(String)
    case pageOutOfRange(page: Int, pageCount: Int)
    case badPageList(String)
    case renderFailed(page: Int)
    case visionFailed(String)
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .cannotOpen(let p): return "\(p): not a PDF CoreGraphics can open"
        case .encrypted(let p): return "\(p): the PDF is encrypted and needs a password"
        case .noPages(let p): return "\(p): the PDF has no pages"
        case .pageOutOfRange(let page, let n): return "page \(page) is out of range (the PDF has \(n) page\(n == 1 ? "" : "s"))"
        case .badPageList(let s): return "bad page list '\(s)'; use e.g. 5-7 or 3,5,8-9 (1-based physical pages)"
        case .renderFailed(let page): return "could not render page \(page)"
        case .visionFailed(let m): return "text recognition failed: \(m)"
        case .cannotWrite(let p): return "cannot write \(p)"
        }
    }
}
