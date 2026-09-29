import CoreGraphics
import CoreText
import Foundation
@testable import MuluOCR

/// Builds small "scanned" test PDFs: pages are drawn with CoreGraphics/CoreText as vector
/// text, rasterized with PDFRasterizer, thresholded to black and white (optionally skewed)
/// and stored as image-only pages. Nothing is read from outside the test.
enum SyntheticPDF {
    static let pageSize = CGSize(width: 432, height: 648)  // 6 x 9 in
    typealias Painter = (CGContext) -> Void

    /// A file directly in the temp directory (no per-run folder left behind); every test removes
    /// its files in a `defer`, and the pid keeps concurrent runs apart.
    static func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mulu-ocr-tests-\(getpid())-\(name)")
    }

    static func font(_ name: String, _ size: Double) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
    static let song = "STSongti-SC-Regular"
    static let hei = "STHeitiSC-Medium"
    static let times = "Times-Roman"

    static func line(_ s: String, _ f: CTFont) -> CTLine {
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        return CTLineCreateWithAttributedString(attr)
    }

    static func width(_ s: String, _ f: CTFont) -> Double {
        Double(CTLineGetTypographicBounds(line(s, f), nil, nil, nil))
    }

    /// Draws `s` with its baseline at `y` (PDF coordinates, y up).
    static func draw(_ s: String, _ f: CTFont, x: Double, y: Double, in ctx: CGContext) {
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line(s, f), ctx)
    }

    static func drawRight(_ s: String, _ f: CTFont, right: Double, y: Double, in ctx: CGContext) {
        draw(s, f, x: right - width(s, f), y: y, in: ctx)
    }

    static func drawCentered(_ s: String, _ f: CTFont, center: Double, y: Double, in ctx: CGContext) {
        draw(s, f, x: center - width(s, f) / 2, y: y, in: ctx)
    }

    /// Writes a vector PDF with one page per painter.
    static func vectorPDF(_ pages: [Painter], to url: URL) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OCRError.cannotWrite(url.path) }
        for paint in pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(gray: 0, alpha: 1)
            paint(ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Rasterizes every page of `vector` at `dpi`, thresholds it to pure black/white,
    /// rotates page `i` by `skew(i)` degrees, and writes an image-only PDF.
    static func scanned(_ vector: URL, to url: URL, dpi: Double = 300, skew: (Int) -> Double = { _ in 0 }) throws {
        let r = try PDFRasterizer(url: vector)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let out = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OCRError.cannotWrite(url.path) }
        for p in 1...r.pageCount {
            var img = try r.render(page: p, dpi: dpi, maxLongEdge: 6000).image
            let deg = skew(p)
            if deg != 0 { img = rotated(img, degrees: deg) }
            for i in img.pixels.indices { img.pixels[i] = img.pixels[i] < 150 ? 0 : 255 }
            out.beginPDFPage(nil)
            out.interpolationQuality = .none
            out.draw(img.cgImage()!, in: box)
            out.endPDFPage()
        }
        out.closePDF()
    }

    static func rotated(_ img: GrayImage, degrees: Double) -> GrayImage {
        guard let src = img.cgImage(), let ctx = GrayImage.makeContext(width: img.width, height: img.height) else { return img }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.interpolationQuality = .high
        ctx.translateBy(x: Double(img.width) / 2, y: Double(img.height) / 2)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -Double(img.width) / 2, y: -Double(img.height) / 2)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return GrayImage(context: ctx)
    }

    // MARK: printed TOC pages

    struct Entry {
        var level: Int
        var title: String
        var page: String
        var leaders = true
    }

    /// Paints TOC entries into the column [left, right] from baseline `top` downwards.
    static func paintTOC(_ entries: [Entry], left: Double, right: Double, top: Double, step: Double = 21,
                         size: Double = 10.5, in ctx: CGContext) {
        let f = font(song, size)
        let bold = font(hei, size + 0.5)
        let num = font(times, size)
        var y = top
        for e in entries {
            let tf = e.level == 0 ? bold : f
            let x = left + Double(e.level) * size * 1.5
            draw(e.title, tf, x: x, y: y, in: ctx)
            let nw = width(e.page, num)
            drawRight(e.page, num, right: right, y: y, in: ctx)
            if e.leaders {
                var dx = x + width(e.title, tf) + 6
                let dot = CGFloat(0.9)
                while dx < right - nw - 6 {
                    ctx.fillEllipse(in: CGRect(x: dx, y: y + 1, width: dot, height: dot))
                    dx += 3.5
                }
            }
            y -= step
        }
    }

    static let tocEntries: [Entry] = [
        Entry(level: 0, title: "前言", page: "iii"),
        Entry(level: 0, title: "第一章 绪论", page: "1", leaders: false),
        Entry(level: 1, title: "第一节 研究背景", page: "2"),
        Entry(level: 2, title: "一、问题的提出", page: "3"),
        Entry(level: 2, title: "二、研究意义", page: "5"),
        Entry(level: 1, title: "第二节 文献综述", page: "8"),
        Entry(level: 0, title: "第二章 理论基础", page: "１５"),
        Entry(level: 1, title: "2.1 基本概念", page: "16"),
        Entry(level: 1, title: "2.2 分析框架", page: "30-35"),
        Entry(level: 0, title: "Chapter 3 Memory Models", page: "41"),
        Entry(level: 1, title: "3.1 Cache Coherence", page: "42"),
        Entry(level: 1, title: "3.2 Ordering", page: "57"),
        Entry(level: 0, title: "附录A 数据来源", page: "101"),
        Entry(level: 0, title: "参考文献", page: "120"),
        Entry(level: 0, title: "索引", page: "131"),
    ]

    static func tocPage(_ entries: [Entry]) -> Painter {
        { ctx in
            drawCentered("目　录", font(hei, 16), center: pageSize.width / 2, y: pageSize.height - 70, in: ctx)
            paintTOC(entries, left: 54, right: pageSize.width - 54, top: pageSize.height - 115, in: ctx)
            drawCentered("v", font(times, 9), center: pageSize.width / 2, y: 30, in: ctx)
        }
    }

    static func twoColumnTOCPage(_ left: [Entry], _ right: [Entry]) -> Painter {
        { ctx in
            drawCentered("目　录", font(hei, 16), center: pageSize.width / 2, y: pageSize.height - 70, in: ctx)
            let mid = pageSize.width / 2
            paintTOC(left, left: 36, right: mid - 14, top: pageSize.height - 115, size: 9.5, in: ctx)
            paintTOC(right, left: mid + 14, right: pageSize.width - 36, top: pageSize.height - 115, size: 9.5, in: ctx)
        }
    }

    // MARK: a small book for detect-offset

    static let bodyText = [
        "市场经济的运行依赖于价格机制对资源的配置作用，",
        "消费者和生产者根据价格信号调整各自的行为选择。",
        "在1990年代以后，这一领域的研究取得了显著进展，",
        "学者们从不同角度讨论了均衡的存在性与稳定性问题。",
        "本节首先回顾相关文献，然后给出基本的分析框架。",
        "如图3所示，需求曲线向右下方倾斜，供给曲线相反。",
        "两条曲线的交点决定了均衡价格与均衡数量的大小。",
        "当外部条件发生变化时，均衡点也会随之发生移动。",
    ]

    /// `front` unnumbered/roman front-matter pages, then body pages printed 1, 2, ... with the
    /// folio in the footer's outer corner (alternating left/right), a running head carrying
    /// the chapter number, and a chapter opener (no running head, centred folio) every 8 pages.
    static func book(front: Int, body: Int, folios: Bool = true) -> [Painter] {
        var pages: [Painter] = []
        let w = pageSize.width
        for i in 1...front {
            pages.append { ctx in
                if i == 1 {
                    drawCentered("微观经济学原理", font(hei, 24), center: w / 2, y: 420, in: ctx)
                } else {
                    for (k, t) in bodyText.prefix(5).enumerated() {
                        draw(t, font(song, 10.5), x: 54, y: 560 - Double(k) * 20, in: ctx)
                    }
                    if folios {
                        let roman = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii"][max(0, i - 2) % 8]
                        drawCentered(roman, font(times, 9), center: w / 2, y: 36, in: ctx)
                    }
                }
            }
        }
        for printed in 1...body {
            let chapter = (printed - 1) / 8 + 1
            let opener = (printed - 1) % 8 == 0
            pages.append { ctx in
                let f = font(song, 10.5)
                var y = 580.0
                if opener {
                    drawCentered("第\(chapter)章 需求与供给", font(hei, 18), center: w / 2, y: 540, in: ctx)
                    y = 480
                } else {
                    drawCentered("第\(chapter)章 需求与供给", font(song, 9), center: w / 2, y: 612, in: ctx)
                    ctx.fill(CGRect(x: 54, y: 606, width: w - 108, height: 0.6))
                }
                var k = printed
                while y > 80 {
                    draw(bodyText[k % bodyText.count], f, x: 54, y: y, in: ctx)
                    y -= 20
                    k += 1
                }
                guard folios else { return }
                let n = String(printed)
                if opener {
                    drawCentered(n, font(times, 9.5), center: w / 2, y: 40, in: ctx)
                } else if printed % 2 == 1 {
                    drawRight(n, font(times, 9.5), right: w - 54, y: 40, in: ctx)
                } else {
                    draw(n, font(times, 9.5), x: 54, y: 40, in: ctx)
                }
            }
        }
        return pages
    }
}
