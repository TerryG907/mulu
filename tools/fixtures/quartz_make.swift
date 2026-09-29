// quartz_make.swift -- writes a multi-page text PDF with Apple Quartz (CGPDFContext + CoreText).
// Used by make_fixtures.py to produce the `quartz_made` fixture.
//
// usage: quartz_make <out.pdf> <pages> <titles.txt>
//   titles.txt: one "<printed page>\t<heading>" per line; headings are drawn on those pages.
import CoreGraphics
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pageCount = Int(args[2]), pageCount > 0 else {
    FileHandle.standardError.write("usage: quartz_make <out.pdf> <pages> [headings.tsv]\n".data(using: .utf8)!)
    exit(64)
}
let outURL = URL(fileURLWithPath: args[1])

var headings: [Int: [String]] = [:]
if args.count >= 4, let text = try? String(contentsOfFile: args[3], encoding: .utf8) {
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        if parts.count == 2, let p = Int(parts[0]) { headings[p, default: []].append(parts[1]) }
    }
}

var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)  // A4 portrait
let info: [CFString: Any] = [
    kCGPDFContextTitle: "Quartz 生成的测试文档 (mulu fixture)",
    kCGPDFContextAuthor: "mulu fixtures",
    kCGPDFContextCreator: "quartz_make.swift",
    kCGPDFContextSubject: "CGPDFContext + CoreText, CJK text",
]
guard let ctx = CGContext(outURL as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
    FileHandle.standardError.write("cannot create PDF context\n".data(using: .utf8)!)
    exit(1)
}

func font(_ size: CGFloat) -> CTFont {
    for name in ["PingFang SC", "Songti SC", "STHeiti", "Heiti SC", "Helvetica"] {
        let f = CTFontCreateWithName(name as CFString, size, nil)
        if (CTFontCopyFamilyName(f) as String).isEmpty == false { return f }
    }
    return CTFontCreateWithName("Helvetica" as CFString, size, nil)
}
let bodyFont = font(11)
let headFont = font(18)

func draw(_ s: String, _ f: CTFont, x: CGFloat, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

let filler = [
    "本页由 Apple Quartz (CGPDFContext) 生成，用于测试增量更新写入器。",
    "The quick brown fox jumps over the lazy dog. 0123456789",
    "目录书签应当指向正确的页面，原始字节不得改变。",
    "Incremental updates append bytes after %%EOF; nothing is rewritten.",
]

for p in 1...pageCount {
    ctx.beginPDFPage(nil)
    var y: CGFloat = 790
    for h in headings[p] ?? [] {
        draw(h, headFont, x: 60, y: y)
        y -= 30
    }
    for i in 0..<28 {
        draw(filler[(i + p) % filler.count] + "  [p\(p) l\(i + 1)]", bodyFont, x: 60, y: y)
        y -= 22
        if y < 70 { break }
    }
    draw("— \(p) —", bodyFont, x: 280, y: 36)
    ctx.endPDFPage()
}
ctx.closePDF()
