// producers.swift -- Apple-framework PDF producers for the mulu producer-matrix adversarial run.
//
// Build:  swiftc -O -swift-version 5 producers.swift -o ../.bin/producers
//
// usage:
//   producers quartz          <out.pdf> <pages> [--dests] [--links] [--outline] [--pdfa-ish]
//   producers pdfkit-resave   <in.pdf> <out.pdf>                 PDFDocument.write (plain re-serialization)
//   producers pdfkit-outline  <in.pdf> <out.pdf>                 add a PDFKit outline, then write
//   producers pdfkit-annots   <in.pdf> <out.pdf>                 add highlight/note/link annotations, then write
//   producers pdfkit-merge    <out.pdf> <in1.pdf> <in2.pdf>...   concatenate pages from several documents
//   producers pdfkit-encrypt  <in.pdf> <out.pdf> <user> <owner>  write with CG passwords (refusal fixture)
//   producers webkit-createpdf <in.html> <out.pdf>               WKWebView.createPDF (one tall page)
//   producers webkit-print    <in.html> <out.pdf>                WKWebView.printOperation -> PDF (paginated)
//   producers textview-print  <in.rtf|html|txt> <out.pdf>        NSTextView + NSPrintOperation -> PDF
// Nothing is shown on screen: the app runs as an accessory (no Dock icon), windows are never ordered front.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import WebKit

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { die("usage: producers <cmd> ...", 64) }

// ---------------------------------------------------------------- Quartz
func ctFont(_ size: CGFloat) -> CTFont {
    for name in ["PingFang SC", "Songti SC", "STHeiti", "Heiti SC", "Helvetica"] {
        let f = CTFontCreateWithName(name as CFString, size, nil)
        if !(CTFontCopyFamilyName(f) as String).isEmpty { return f }
    }
    return CTFontCreateWithName("Helvetica" as CFString, size, nil)
}

func drawText(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat) {
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): ctFont(size),
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func quartz(_ a: [String]) {
    guard a.count >= 2, let n = Int(a[1]), n > 0 else { die("quartz <out> <pages> [flags]", 64) }
    let flags = Set(a.dropFirst(2))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [
        kCGPDFContextTitle: "Quartz 矩阵测试 producer matrix",
        kCGPDFContextAuthor: "mulu adversarial",
        kCGPDFContextCreator: "producers.swift quartz",
        kCGPDFContextKeywords: ["目录", "outline", "Quartz"] as CFArray,
    ]
    if flags.contains("--linearized") { info[kCGPDFContextCreateLinearizedPDF] = kCFBooleanTrue }
    if flags.contains("--pdfa") { info[kCGPDFContextCreatePDFA] = kCFBooleanTrue }
    if flags.contains("--owner-pw") { info[kCGPDFContextOwnerPassword] = "owner-pw"; info[kCGPDFContextUserPassword] = "" }
    if flags.contains("--user-pw") { info[kCGPDFContextUserPassword] = "user" ; info[kCGPDFContextOwnerPassword] = "owner" }
    let tagged = flags.contains("--tagged")
    guard let ctx = CGContext(URL(fileURLWithPath: a[0]) as CFURL, mediaBox: &box, info as CFDictionary) else {
        die("cannot create CGPDFContext")
    }
    for p in 1...n {
        ctx.beginPDFPage(nil)
        if tagged { CGPDFContextBeginTag(ctx, .header1, [CGPDFTagProperty.titleText.rawValue: "第 \(p) 页"] as CFDictionary) }
        drawText(ctx, "第 \(p) 页 · Page \(p) of \(n)", x: 72, y: 720, size: 22)
        if tagged { CGPDFContextEndTag(ctx); CGPDFContextBeginTag(ctx, .paragraph, [:] as CFDictionary) }
        drawText(ctx, "Quartz CGPDFContext + CoreText：中文与 English 混排。", x: 72, y: 690, size: 12)
        for k in 0..<18 {
            drawText(ctx, "\(p).\(k + 1)  增量更新不改原始字节 — incremental update keeps the original bytes.",
                     x: 72, y: CGFloat(650 - k * 28), size: 10)
        }
        if tagged { CGPDFContextEndTag(ctx) }
        // a vector shape so rendering hashes are meaningful
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.4))
        ctx.fill(CGRect(x: 400, y: 60, width: 140, height: 60 + CGFloat(p % 7) * 10))
        if flags.contains("--dests") {
            // named destinations -> the catalog gets a /Dests or /Names tree
            ctx.addDestination("sec-\(p)" as CFString, at: CGPoint(x: 72, y: 740))
        }
        if flags.contains("--links") {
            if p < n {
                ctx.setDestination("sec-\(p + 1)" as CFString, for: CGRect(x: 72, y: 40, width: 200, height: 20))
            }
            ctx.setURL(URL(string: "https://example.com/mulu/\(p)")! as CFURL,
                       for: CGRect(x: 300, y: 40, width: 200, height: 20))
            drawText(ctx, "→ next section / 下一节", x: 72, y: 45, size: 10)
        }
        ctx.endPDFPage()
    }
    if flags.contains("--outline") {
        // Quartz writes its own /Outlines tree; mulu must REPLACE it.
        func item(_ t: String, _ page: Int, _ kids: [[String: Any]] = []) -> [String: Any] {
            var d: [String: Any] = [kCGPDFOutlineTitle as String: t,
                                    kCGPDFOutlineDestination as String: page]
            if !kids.isEmpty { d[kCGPDFOutlineChildren as String] = kids }
            return d
        }
        let root: [String: Any] = [kCGPDFOutlineChildren as String: [
            item("旧书签 Old Bookmark A", 1, [item("旧 A.1", 1)]),
            item("旧书签 Old Bookmark B", min(2, n)),
        ]]
        CGPDFContextSetOutline(ctx, root as CFDictionary)
    }
    ctx.closePDF()
}

// ---------------------------------------------------------------- PDFKit
func openDoc(_ path: String) -> PDFDocument {
    guard let d = PDFDocument(url: URL(fileURLWithPath: path)) else { die("PDFDocument(url:) nil for \(path)") }
    return d
}

func write(_ doc: PDFDocument, _ out: String, _ opts: [PDFDocumentWriteOption: Any] = [:]) {
    if !doc.write(to: URL(fileURLWithPath: out), withOptions: opts) { die("PDFDocument.write failed") }
}

func pdfkitOutline(_ a: [String]) {
    let doc = openDoc(a[0])
    let root = PDFOutline()
    let n = doc.pageCount
    for i in 0..<min(3, n) {
        let o = PDFOutline()
        o.label = "PDFKit 旧目录 \(i + 1) / old entry"
        if let pg = doc.page(at: i) { o.destination = PDFDestination(page: pg, at: CGPoint(x: 0, y: 792)) }
        let kid = PDFOutline()
        kid.label = "子项 child \(i + 1).1"
        if let pg = doc.page(at: min(n - 1, i + 1)) { kid.destination = PDFDestination(page: pg, at: .zero) }
        o.insertChild(kid, at: 0)
        root.insertChild(o, at: i)
    }
    doc.outlineRoot = root
    write(doc, a[1])
}

func pdfkitAnnots(_ a: [String]) {
    let doc = openDoc(a[0])
    for i in 0..<doc.pageCount {
        guard let pg = doc.page(at: i) else { continue }
        let b = pg.bounds(for: .mediaBox)
        let hl = PDFAnnotation(bounds: CGRect(x: 60, y: b.height - 120, width: 300, height: 20),
                               forType: .highlight, withProperties: nil)
        hl.color = .yellow
        hl.contents = "高亮 highlight \(i + 1)"
        pg.addAnnotation(hl)
        let note = PDFAnnotation(bounds: CGRect(x: b.width - 80, y: b.height - 80, width: 24, height: 24),
                                 forType: .text, withProperties: nil)
        note.contents = "批注 note on page \(i + 1)"
        pg.addAnnotation(note)
        if i + 1 < doc.pageCount, let next = doc.page(at: i + 1) {
            let link = PDFAnnotation(bounds: CGRect(x: 60, y: 30, width: 200, height: 20),
                                     forType: .link, withProperties: nil)
            link.action = PDFActionGoTo(destination: PDFDestination(page: next, at: CGPoint(x: 0, y: 792)))
            pg.addAnnotation(link)
        }
        let ft = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 320, height: 40),
                               forType: .freeText, withProperties: nil)
        ft.contents = "FreeText 自由文本 \(i + 1)"
        ft.font = NSFont(name: "PingFang SC", size: 12) ?? NSFont.systemFont(ofSize: 12)
        pg.addAnnotation(ft)
    }
    write(doc, a[1])
}

func pdfkitMerge(_ a: [String]) {
    let out = PDFDocument()
    var k = 0
    for path in a.dropFirst() {
        let d = openDoc(path)
        for i in 0..<d.pageCount {
            if let pg = d.page(at: i)?.copy() as? PDFPage { out.insert(pg, at: k); k += 1 }
        }
    }
    write(out, a[0])
}

func pdfkitEncrypt(_ a: [String]) {
    let doc = openDoc(a[0])
    var o: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: a[3]]
    if !a[2].isEmpty { o[.userPasswordOption] = a[2] }
    write(doc, a[1], o)
}

// ---------------------------------------------------------------- WebKit / AppKit (headless)
final class Loader: NSObject, WKNavigationDelegate {
    var done: ((WKWebView) -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // give layout/fonts a beat
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.done?(webView) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        die("webkit load failed: \(error)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        die("webkit provisional load failed: \(error)")
    }
}

func printInfo(_ out: String) -> NSPrintInfo {
    let pi = NSPrintInfo()
    pi.paperSize = NSSize(width: 595, height: 842)
    pi.topMargin = 36; pi.bottomMargin = 36; pi.leftMargin = 36; pi.rightMargin = 36
    pi.jobDisposition = .save
    pi.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: out)
    pi.horizontalPagination = .fit
    pi.verticalPagination = .automatic
    return pi
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var keep: [AnyObject] = []

func webkit(_ a: [String], paginated: Bool) {
    guard let html = try? String(contentsOfFile: a[0], encoding: .utf8) else { die("cannot read \(a[0])") }
    let out = a[1]
    let cfg = WKWebViewConfiguration()
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: cfg)
    let win = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 1000),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = wv
    let loader = Loader()
    keep += [wv, win, loader]
    loader.done = { w in
        if !paginated {
            w.createPDF(configuration: WKPDFConfiguration()) { r in
                switch r {
                case .success(let data):
                    do { try data.write(to: URL(fileURLWithPath: out)); exit(0) } catch { die("\(error)") }
                case .failure(let e): die("createPDF failed: \(e)")
                }
            }
        } else {
            let op = w.printOperation(with: printInfo(out))
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.view?.frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
            op.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
            // runModal(for:) is async; poll for the file
            var tries = 0
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
                tries += 1
                if let attrs = try? FileManager.default.attributesOfItem(atPath: out),
                   let sz = attrs[.size] as? Int, sz > 0, tries > 4 {
                    t.invalidate(); exit(0)
                }
                if tries > 120 { die("webkit print timed out") }
            }
        }
    }
    wv.navigationDelegate = loader
    wv.loadHTMLString(html, baseURL: URL(fileURLWithPath: a[0]).deletingLastPathComponent())
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { die("webkit timed out") }
    app.run()
}

func textviewPrint(_ a: [String]) {
    let url = URL(fileURLWithPath: a[0])
    var docAttrs: NSDictionary? = nil
    guard let s = try? NSAttributedString(url: url, options: [:], documentAttributes: &docAttrs) else {
        die("cannot load \(a[0]) as attributed string")
    }
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 523, height: 770))
    tv.textStorage?.setAttributedString(s)
    tv.isVerticallyResizable = true
    tv.sizeToFit()
    let op = NSPrintOperation(view: tv, printInfo: printInfo(a[1]))
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    if !op.run() { die("NSPrintOperation.run failed") }
}

switch cmd {
case "quartz": quartz(Array(args.dropFirst()))
case "pdfkit-resave": let d = openDoc(args[1]); write(d, args[2])
case "pdfkit-outline": pdfkitOutline(Array(args.dropFirst()))
case "pdfkit-annots": pdfkitAnnots(Array(args.dropFirst()))
case "pdfkit-merge": pdfkitMerge(Array(args.dropFirst()))
case "pdfkit-encrypt": pdfkitEncrypt(Array(args.dropFirst()))
case "webkit-createpdf": webkit(Array(args.dropFirst()), paginated: false)
case "webkit-print": webkit(Array(args.dropFirst()), paginated: true)
case "textview-print": textviewPrint(Array(args.dropFirst()))
default: die("unknown command \(cmd)", 64)
}
exit(0)
