import CoreGraphics
import CoreText
import Foundation
@testable import MuluOCR

/// Test PDFs generated in the test (nothing is read from outside it). The drawing helpers are
/// copied from Tests/MuluOCRTests/SyntheticPDF.swift: pages are drawn as vector text, and a
/// "scan" rasterizes them, thresholds to black and white and stores image-only pages.
enum SyntheticBook {
    static let pageSize = CGSize(width: 432, height: 648)  // 6 x 9 in
    typealias Painter = (CGContext) -> Void

    /// A file directly in the temp directory; tests remove their files in a `defer`, and the pid
    /// keeps concurrent runs apart.
    static func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mulu-app-tests-\(getpid())-\(name)")
    }

    static func remove(_ urls: URL...) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    static func font(_ name: String, _ size: Double) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
    static let song = "STSongti-SC-Regular"
    static let hei = "STHeitiSC-Medium"
    static let times = "Times-Roman"
    static let helvetica = "Helvetica"

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

    /// Rasterizes every page of `vector` at `dpi`, thresholds it to pure black/white and
    /// writes an image-only PDF.
    static func scanned(_ vector: URL, to url: URL, dpi: Double = 200) throws {
        let r = try PDFRasterizer(url: vector)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let out = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OCRError.cannotWrite(url.path) }
        for p in 1...r.pageCount {
            var img = try r.render(page: p, dpi: dpi, maxLongEdge: 6000).image
            for i in img.pixels.indices { img.pixels[i] = img.pixels[i] < 150 ? 0 : 255 }
            out.beginPDFPage(nil)
            out.interpolationQuality = .none
            out.draw(img.cgImage()!, in: box)
            out.endPDFPage()
        }
        out.closePDF()
    }

    // MARK: plain vector PDF (write round trips; milliseconds)

    /// N pages, each with one large line "Page N".
    static func plainPDF(pages: Int, name: String = "plain-\(UUID().uuidString).pdf") throws -> URL {
        let url = tempURL(name)
        try vectorPDF((1...pages).map { n in { ctx in
            draw("Page \(n)", font(helvetica, 36), x: 72, y: 480, in: ctx)
        } }, to: url)
        return url
    }

    // MARK: a small scanned book with a printed TOC

    struct Entry {
        var title: String
        var printed: Int
        var level: Int
    }

    static let entries: [Entry] = [
        Entry(title: "第一章 市场与价格", printed: 1, level: 0),
        Entry(title: "第一节 需求", printed: 3, level: 1),
        Entry(title: "第二章 消费者行为", printed: 9, level: 0),
        Entry(title: "第二节 效用", printed: 12, level: 1),
        Entry(title: "第三章 生产与成本", printed: 17, level: 0),
        Entry(title: "第四章 市场结构", printed: 25, level: 0),
    ]

    static let bodyText = [
        "市场经济的运行依赖于价格机制对资源的配置作用，",
        "消费者和生产者根据价格信号调整各自的行为选择。",
        "学者们从不同角度讨论了均衡的存在性与稳定性问题。",
        "本节首先回顾相关文献，然后给出基本的分析框架。",
        "需求曲线向右下方倾斜，供给曲线的方向正好相反。",
        "两条曲线的交点决定了均衡价格与均衡数量的大小。",
        "当外部条件发生变化时，均衡点也会随之发生移动。",
    ]

    /// The TOC page: heading, entries with dot leaders and right-aligned page numbers.
    static func tocPage() -> Painter {
        { ctx in
            drawCentered("目　录", font(hei, 16), center: pageSize.width / 2, y: pageSize.height - 70, in: ctx)
            let left = 54.0, right = pageSize.width - 54
            var y = pageSize.height - 120
            for e in entries {
                let size = 10.5
                let tf = e.level == 0 ? font(hei, size + 0.5) : font(song, size)
                let x = left + Double(e.level) * size * 1.5
                draw(e.title, tf, x: x, y: y, in: ctx)
                let n = String(e.printed)
                let num = font(times, size)
                let nw = width(n, num)
                drawRight(n, num, right: right, y: y, in: ctx)
                var dx = x + width(e.title, tf) + 6
                while dx < right - nw - 6 {
                    ctx.fillEllipse(in: CGRect(x: dx, y: y + 1, width: 0.9, height: 0.9))
                    dx += 3.5
                }
                y -= 24
            }
        }
    }

    /// Page 1 title; pages 2…(1+tocCopies) the TOC (repeated); one blank page; then 32 body
    /// pages printed 1–32: every chapter opens with its title in large type at the top, other
    /// pages carry a running head, and (with `folios`) the page number sits in the footer's
    /// outer corner (centred on chapter openers). The offset is 2 + tocCopies (+3 for one
    /// TOC page, 35 pages in all). Without `runningHeads` the header and footer bands of body
    /// pages are empty (with no folios either, offset detection then has nothing to re-read).
    static func scannedBook(tocCopies: Int = 1, folios: Bool = true, runningHeads: Bool = true, name: String = "book-\(UUID().uuidString)")
        throws -> (url: URL, tocPages: [Int], offset: Int, entries: [(title: String, printed: Int, level: Int)]) {
        let w = pageSize.width
        var pages: [Painter] = []
        pages.append { ctx in drawCentered("微观经济学原理", font(hei, 24), center: w / 2, y: 420, in: ctx) }
        for _ in 0..<tocCopies { pages.append(tocPage()) }
        pages.append { _ in }
        let chapters = entries.filter { $0.level == 0 }
        for printed in 1...32 {
            let chapter = chapters.last { $0.printed <= printed }!
            let opener = chapter.printed == printed
            pages.append { ctx in
                var y = 520.0
                if opener {
                    drawCentered(chapter.title, font(hei, 18), center: w / 2, y: 560, in: ctx)
                    y = 480
                } else if runningHeads {
                    drawCentered(chapter.title, font(song, 9), center: w / 2, y: 612, in: ctx)
                    ctx.fill(CGRect(x: 54, y: 606, width: w - 108, height: 0.6))
                }
                var k = printed
                while y > 110 {
                    draw(bodyText[k % bodyText.count], font(song, 10.5), x: 54, y: y, in: ctx)
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
        let vector = tempURL("\(name)-vector.pdf")
        let url = tempURL("\(name).pdf")
        defer { remove(vector) }
        try vectorPDF(pages, to: vector)
        try scanned(vector, to: url, dpi: 200)
        return (url, Array(2..<(2 + tocCopies)), 2 + tocCopies, entries.map { ($0.title, $0.printed, $0.level) })
    }
}

/// Character similarity 1 − edit distance / longer length (as OCRIntegrationTests.similarity).
func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(a), y = Array(b)
    guard !x.isEmpty || !y.isEmpty else { return 1 }
    var d = Array(0...y.count)
    for i in 1...max(1, x.count) where !x.isEmpty {
        var prev = d[0]
        d[0] = i
        for j in stride(from: 1, through: y.count, by: 1) {
            let t = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
            prev = t
        }
    }
    return 1 - Double(d[y.count]) / Double(max(x.count, y.count))
}
