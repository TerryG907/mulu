import CoreGraphics
import Foundation

/// A rendered page (or part of one).
public struct RenderedPage: Sendable {
    public var image: GrayImage
    /// Pixels per PDF point.
    public var scale: Double
    /// 1-based physical page number.
    public var page: Int
}

/// Renders PDF pages to grayscale bitmaps with CoreGraphics (CGPDFDocument), honouring
/// the crop box and /Rotate. Not thread-safe; use one instance per thread.
public final class PDFRasterizer {
    public let path: String
    public let pageCount: Int
    private let document: CGPDFDocument

    public init(url: URL) throws {
        path = url.path
        guard let doc = CGPDFDocument(url as CFURL) else { throw OCRError.cannotOpen(url.path) }
        if doc.isEncrypted, !doc.isUnlocked, !doc.unlockWithPassword("") {
            throw OCRError.encrypted(url.path)
        }
        document = doc
        pageCount = doc.numberOfPages
        guard pageCount > 0 else { throw OCRError.noPages(url.path) }
    }

    private func cgPage(_ page: Int) throws -> CGPDFPage {
        guard page >= 1, page <= pageCount else { throw OCRError.pageOutOfRange(page: page, pageCount: pageCount) }
        guard let p = document.page(at: page) else { throw OCRError.renderFailed(page: page) }
        return p
    }

    private static func rotation(_ p: CGPDFPage) -> Int {
        ((Int(p.rotationAngle) % 360) + 360) % 360 / 90 * 90
    }

    /// Size in points of the page as displayed (crop box, after /Rotate).
    public func displaySize(page: Int) throws -> CGSize {
        let p = try cgPage(page)
        let crop = p.getBoxRect(.cropBox).standardized
        let r = PDFRasterizer.rotation(p)
        return (r == 90 || r == 270) ? CGSize(width: crop.height, height: crop.width) : crop.size
    }

    /// Pixels per point for rendering `page` at `dpi`, reduced so that the whole page's
    /// long edge is at most `maxLongEdge` pixels.
    public func scale(page: Int, dpi: Double, maxLongEdge: Int) throws -> Double {
        let size = try displaySize(page: page)
        let longEdge = max(size.width, size.height)
        var s = dpi / 72
        if longEdge > 0, longEdge * s > Double(maxLongEdge) { s = Double(maxLongEdge) / longEdge }
        return s
    }

    /// Renders `region` of `page` (normalized display coordinates, y DOWN: (0,0) is the
    /// top-left corner of the displayed page, (1,1) the bottom-right).
    public func render(page: Int, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                       dpi: Double = 300, maxLongEdge: Int = 4000) throws -> RenderedPage {
        let p = try cgPage(page)
        let s = try scale(page: page, dpi: dpi, maxLongEdge: maxLongEdge)
        let crop = p.getBoxRect(.cropBox).standardized
        let rot = PDFRasterizer.rotation(p)
        let disp = (rot == 90 || rot == 270) ? CGSize(width: crop.height, height: crop.width) : crop.size
        let reg = region.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !reg.isNull, reg.width > 0, reg.height > 0, disp.width > 0, disp.height > 0 else {
            throw OCRError.renderFailed(page: page)
        }
        let w = max(1, Int((reg.width * disp.width * s).rounded()))
        let h = max(1, Int((reg.height * disp.height * s).rounded()))
        guard w <= 20_000, h <= 20_000, let ctx = GrayImage.makeContext(width: w, height: h) else {
            throw OCRError.renderFailed(page: page)
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: s, y: s)
        // Region (y down) -> display points (y up): move its bottom-left corner to 0,0.
        ctx.translateBy(x: -reg.minX * disp.width, y: -(1 - reg.maxY) * disp.height)
        // Page space -> display space (crop box moved to the origin, then /Rotate, which
        // turns the page clockwise).
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
        return RenderedPage(image: GrayImage(context: ctx), scale: s, page: page)
    }
}

/// Parses a 1-based page list such as "5-7", "3,5,8-9", "12-" (to the end) or "-3".
/// Most pages `ocr-toc` / `auto` read as TOC pages in one run: a printed TOC is rarely longer,
/// and every page costs about 2.5 s of full-core OCR (a stray "--pages 9-" on a 2000-page
/// book would run for over an hour).
public let maxTOCPageCount = 40

public func parsePageList(_ spec: String, pageCount: Int) throws -> [Int] {
    var out: [Int] = []
    let parts = spec.split(separator: ",", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { throw OCRError.badPageList(spec) }
    for raw in parts {
        let part = raw.trimmingCharacters(in: .whitespaces)
        guard !part.isEmpty else { throw OCRError.badPageList(spec) }
        let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let lo: Int, hi: Int
        if bounds.count == 1 {
            guard let v = Int(bounds[0]) else { throw OCRError.badPageList(spec) }
            lo = v; hi = v
        } else {
            let a = bounds[0].isEmpty ? 1 : Int(bounds[0])
            let b = bounds[1].isEmpty ? pageCount : Int(bounds[1])
            guard let a, let b, a <= b else { throw OCRError.badPageList(spec) }
            lo = a; hi = b
        }
        guard lo >= 1 else { throw OCRError.badPageList(spec) }
        guard hi <= pageCount else { throw OCRError.pageOutOfRange(page: hi, pageCount: pageCount) }
        for pg in lo...hi where !out.contains(pg) { out.append(pg) }
    }
    return out
}
