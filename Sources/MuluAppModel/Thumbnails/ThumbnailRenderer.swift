import CoreGraphics
import Foundation
import MuluOCR

/// A rendered page thumbnail. CGImage is immutable, so sharing it across actors is safe.
public struct ThumbnailImage: @unchecked Sendable {
    public let page: Int
    public let cgImage: CGImage
}

/// Renders page thumbnails with its own CGPDFDocument (never shared with the OCR or PDFKit),
/// caching the most recently used ones up to `cacheByteLimit` of pixels (GUI_SPEC §6.2, §6.10).
/// A request whose task was cancelled (the cell scrolled away) is dropped before rendering, so a
/// fast scroll does not queue hundreds of renders ahead of the pages on screen.
public actor ThumbnailRenderer {
    private let document: CGPDFDocument
    public nonisolated let pageCount: Int
    private var cache: [Key: ThumbnailImage] = [:]
    private var order: [Key] = []
    private var cachedBytes = 0
    /// About 90 A4 pages at 240 px.
    public nonisolated let cacheByteLimit: Int
    /// Pages actually rendered (cache misses); for tests.
    public private(set) var renderCount = 0

    private struct Key: Hashable {
        var page: Int
        var width: Int
    }

    public init(url: URL, cacheByteLimit: Int = 30 * 1024 * 1024) throws {
        self.cacheByteLimit = max(0, cacheByteLimit)
        guard let doc = CGPDFDocument(url as CFURL) else { throw OCRError.cannotOpen(url.path) }
        if doc.isEncrypted, !doc.isUnlocked, !doc.unlockWithPassword("") {
            throw OCRError.encrypted(url.path)
        }
        guard doc.numberOfPages > 0 else { throw OCRError.noPages(url.path) }
        document = doc
        pageCount = doc.numberOfPages
    }

    /// The page (1-based) rendered at most `maxPixelWidth` pixels wide (cached, LRU). Throws
    /// CancellationError when the calling task was cancelled before rendering started.
    public func thumbnail(page: Int, maxPixelWidth: Int) throws -> ThumbnailImage {
        guard page >= 1, page <= pageCount else { throw OCRError.pageOutOfRange(page: page, pageCount: pageCount) }
        let key = Key(page: page, width: max(1, maxPixelWidth))
        if let hit = cache[key] {
            if let i = order.firstIndex(of: key) { order.remove(at: i) }
            order.append(key)
            return hit
        }
        try Task.checkCancellation()
        let image = try render(page: page, maxPixelWidth: key.width)
        renderCount += 1
        let cost = Self.cost(image)
        guard cost <= cacheByteLimit else { return image }
        cache[key] = image
        order.append(key)
        cachedBytes += cost
        while cachedBytes > cacheByteLimit, !order.isEmpty {
            let old = order.removeFirst()
            if let evicted = cache.removeValue(forKey: old) { cachedBytes -= Self.cost(evicted) }
        }
        return image
    }

    /// Bytes held by the cache; for tests.
    public var cachedByteCount: Int { cachedBytes }

    static func cost(_ image: ThumbnailImage) -> Int {
        image.cgImage.bytesPerRow * image.cgImage.height
    }

    private func render(page: Int, maxPixelWidth: Int) throws -> ThumbnailImage {
        guard let p = document.page(at: page) else { throw OCRError.renderFailed(page: page) }
        let crop = p.getBoxRect(.cropBox).standardized
        let rot = ((Int(p.rotationAngle) % 360) + 360) % 360 / 90 * 90
        let disp = (rot == 90 || rot == 270) ? CGSize(width: crop.height, height: crop.width) : crop.size
        guard disp.width > 0, disp.height > 0 else { throw OCRError.renderFailed(page: page) }
        let s = Double(maxPixelWidth) / disp.width
        let w = max(1, min(maxPixelWidth, Int((disp.width * s).rounded(.down))))
        let h = max(1, min(8 * maxPixelWidth, Int((disp.height * s).rounded())))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw OCRError.renderFailed(page: page)
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        // Page space -> display space (crop box moved to the origin, then /Rotate, clockwise),
        // as PDFRasterizer does.
        let t: CGAffineTransform
        switch rot {
        case 90: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -crop.minY, ty: crop.maxX)
        case 180: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: crop.maxX, ty: crop.maxY)
        case 270: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: crop.maxY, ty: -crop.minX)
        default: t = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: -crop.minX, ty: -crop.minY)
        }
        ctx.concatenate(t)
        ctx.clip(to: crop)
        ctx.drawPDFPage(p)
        guard let img = ctx.makeImage() else { throw OCRError.renderFailed(page: page) }
        return ThumbnailImage(page: page, cgImage: img)
    }
}
