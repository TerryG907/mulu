// pdfkit_resave.swift -- open a PDF with PDFKit and write it back with PDFDocument.write(to:).
// Used only to MEASURE how much a PDFKit rewrite grows / changes a file (README comparison),
// which is exactly what mulu's incremental update avoids.
//
// usage: pdfkit_resave <in.pdf> <out.pdf>
// prints {"ok":bool,"in_size":n,"out_size":n,"growth_pct":x,"seconds":t}
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: pdfkit_resave <in.pdf> <out.pdf>\n".data(using: .utf8)!)
    exit(64)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
func size(_ u: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.intValue ?? -1
}
let t0 = Date()
guard let doc = PDFDocument(url: inURL) else {
    print("{\"ok\":false,\"error\":\"cannot open\"}")
    exit(1)
}
let ok = doc.write(to: outURL)
let dt = Date().timeIntervalSince(t0)
let a = size(inURL), b = size(outURL)
let growth = a > 0 && b >= 0 ? (Double(b) - Double(a)) / Double(a) * 100.0 : 0
let obj: [String: Any] = ["ok": ok, "in_size": a, "out_size": b, "growth_pct": growth, "seconds": dt]
let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
exit(ok ? 0 : 1)
