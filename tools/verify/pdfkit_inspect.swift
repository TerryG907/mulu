// pdfkit_inspect.swift -- Apple PDFKit reader for the mulu verification harness.
//
// usage: pdfkit_inspect <file.pdf>
// prints one JSON object:
//   {"ok":true,"pages":n,"locked":false,"encrypted":false,
//    "outline":[{"title":..,"level":0,"page_index":0},...],   // level/page_index 0-based, -1 = unresolved dest
//    "first_text":"..","last_text":"..",                       // PDFPage.string of first/last page
//    "first_render":"sha256","last_render":"sha256"}           // hash of a fixed-size RGBA rendering
// exit 0 even when the document cannot be opened ({"ok":false,"error":..}); exit 64 on bad usage.
//
// Build once:  swiftc -O -swift-version 5 pdfkit_inspect.swift -o .bin/pdfkit_inspect
import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

func emit(_ obj: [String: Any]) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(0)
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: pdfkit_inspect <file.pdf>\n".data(using: .utf8)!)
    exit(64)
}
let url = URL(fileURLWithPath: args[1])
guard let doc = PDFDocument(url: url) else {
    emit(["ok": false, "error": "PDFDocument(url:) returned nil"])
}
if doc.isLocked {
    emit(["ok": false, "error": "document is locked", "locked": true, "encrypted": doc.isEncrypted])
}

var items: [[String: Any]] = []
func walk(_ node: PDFOutline, level: Int, depth: Int) {
    if depth > 64 { return }
    for i in 0..<node.numberOfChildren {
        guard let child = node.child(at: i) else { continue }
        var dest = child.destination
        if dest == nil, let goTo = child.action as? PDFActionGoTo { dest = goTo.destination }
        var pageIndex = -1
        if let d = dest, let page = d.page {
            let idx = doc.index(for: page)
            if idx != NSNotFound { pageIndex = idx }
        }
        items.append(["title": child.label ?? "", "level": level, "page_index": pageIndex])
        walk(child, level: level + 1, depth: depth + 1)
    }
}
if let root = doc.outlineRoot { walk(root, level: 0, depth: 0) }

func renderHash(_ page: PDFPage) -> String {
    let box = page.bounds(for: .mediaBox)
    let width = 240
    let scale = CGFloat(width) / max(box.width, 1)
    let height = max(1, Int((box.height * scale).rounded()))
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
    let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return true
    }
    if !ok { return "render-failed" }
    return SHA256.hash(data: Data(buffer)).map { String(format: "%02x", $0) }.joined()
}

var result: [String: Any] = [
    "ok": true,
    "pages": doc.pageCount,
    "locked": doc.isLocked,
    "encrypted": doc.isEncrypted,
    "outline": items,
]
if doc.pageCount > 0, let first = doc.page(at: 0), let last = doc.page(at: doc.pageCount - 1) {
    result["first_text"] = first.string ?? ""
    result["last_text"] = last.string ?? ""
    result["first_render"] = renderHash(first)
    result["last_render"] = renderHash(last)
}
emit(result)
