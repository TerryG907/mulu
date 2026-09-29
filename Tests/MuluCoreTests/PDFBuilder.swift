import Foundation
@testable import MuluCore

/// Builds small PDFs in memory, byte by byte, recording exact object offsets so the
/// tests control every detail of the cross-reference data.
struct PDFBuilder {
    var bytes: [UInt8]
    var offsets: [Int: (offset: Int, gen: Int)] = [:]

    init(version: String = "1.7") {
        bytes = Array("%PDF-\(version)\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
    }

    mutating func add(_ s: String) { bytes += Array(s.utf8) }
    mutating func add(_ b: [UInt8]) { bytes += b }

    mutating func obj(_ num: Int, _ body: String, gen: Int = 0) {
        offsets[num] = (bytes.count, gen)
        add("\(num) \(gen) obj\n\(body)\nendobj\n")
    }

    mutating func stream(_ num: Int, dict: String, data: [UInt8], gen: Int = 0) {
        offsets[num] = (bytes.count, gen)
        add("\(num) \(gen) obj\n<< \(dict) /Length \(data.count) >>\nstream\n")
        add(data)
        add("\nendstream\nendobj\n")
    }

    /// Appends a classic xref section for `nums` (using recorded offsets) plus the
    /// given free entries, then the trailer, startxref and %%EOF. Returns its offset.
    @discardableResult
    mutating func classicXRef(nums: [Int], free: [Int] = [], includeZero: Bool = true, trailer: String) -> Int {
        var rows: [Int: String] = [:]
        if includeZero { rows[0] = "0000000000 65535 f\r\n" }
        for n in free { rows[n] = "0000000000 00001 f\r\n" }
        for n in nums {
            let (o, g) = offsets[n]!
            rows[n] = pad(o, 10) + " " + pad(g, 5) + " n\r\n"
        }
        let start = bytes.count
        add("xref\n")
        for run in IncrementalWriter.runs(rows.keys.sorted()) {
            add("\(run.start) \(run.count)\n")
            for k in run.start..<(run.start + run.count) { add(rows[k]!) }
        }
        add("trailer\n\(trailer)\nstartxref\n\(start)\n%%EOF\n")
        return start
    }

    /// Appends an xref stream object `num` whose rows are `rows` (num -> (type, f2, f3))
    /// plus its own entry. Optionally PNG-predicted (with the given per-row filter
    /// types, cycled) and Flate-compressed. Returns its offset.
    @discardableResult
    mutating func xrefStream(
        num: Int, rows: [Int: (Int, Int, Int)], trailerKeys: String, size: Int? = nil,
        pngFilters: [UInt8]? = [2], compress: Bool = true, w: (Int, Int, Int) = (1, 4, 2),
        writeStartxref: Bool = true, lengthObject: Int? = nil
    ) -> Int {
        var all = rows
        if let lo = lengthObject {
            // Indirect /Length (uncompressed, unpredicted data only: its size is known up front).
            precondition(!compress && pngFilters == nil)
            offsets[lo] = (bytes.count, 0)
            all[lo] = (1, bytes.count, 0)
            add("\(lo) 0 obj\n\((all.count + 1) * (w.0 + w.1 + w.2))\nendobj\n")
        }
        let start = bytes.count
        offsets[num] = (start, 0)
        all[num] = (1, start, 0)
        let nums = all.keys.sorted()
        let columns = w.0 + w.1 + w.2
        let raw: [[UInt8]] = nums.map { n in
            let (t, f2, f3) = all[n]!
            return be(t, w.0) + be(f2, w.1) + be(f3, w.2)
        }
        var data: [UInt8]
        var parms = ""
        if let filters = pngFilters {
            data = PDFBuilder.pngEncode(raw, filterTypes: filters)
            parms = "/DecodeParms << /Predictor 12 /Columns \(columns) >>"
        } else {
            data = raw.flatMap { $0 }
        }
        var filter = ""
        if compress {
            data = Filters.zlibCompress(data)
            filter = "/Filter /FlateDecode"
        }
        let index = IncrementalWriter.runs(nums).map { "\($0.start) \($0.count)" }.joined(separator: " ")
        let sz = size ?? (nums.max()! + 1)
        add("\(num) 0 obj\n<< /Type /XRef /Size \(sz) /W [\(w.0) \(w.1) \(w.2)] /Index [\(index)] \(filter) \(parms) \(trailerKeys) /Length \(lengthObject.map { "\($0) 0 R" } ?? String(data.count)) >>\nstream\r\n")
        add(data)
        add("\nendstream\nendobj\n")
        if writeStartxref { add("startxref\n\(start)\n%%EOF\n") }
        return start
    }

    static func pngEncode(_ rows: [[UInt8]], filterTypes: [UInt8], bpp: Int = 1) -> [UInt8] {
        var out: [UInt8] = []
        var prev = [UInt8](repeating: 0, count: rows.first?.count ?? 0)
        for (r, row) in rows.enumerated() {
            let ft = filterTypes[r % filterTypes.count]
            out.append(ft)
            for j in 0..<row.count {
                let a = j >= bpp ? Int(row[j - bpp]) : 0
                let b = Int(prev[j])
                let c = j >= bpp ? Int(prev[j - bpp]) : 0
                let pred: Int
                switch ft {
                case 0: pred = 0
                case 1: pred = a
                case 2: pred = b
                case 3: pred = (a + b) / 2
                default:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                }
                out.append(row[j] &- UInt8(pred))
            }
            prev = row
        }
        return out
    }
}

func pad(_ v: Int, _ w: Int) -> String {
    let s = String(v)
    return String(repeating: "0", count: max(0, w - s.count)) + s
}

func be(_ v: Int, _ width: Int) -> [UInt8] {
    (0..<width).map { k in UInt8((v >> (8 * (width - 1 - k))) & 0xFF) }
}

enum Fixtures {
    /// Objects: 1 catalog, 2 page tree root, 3... pages, (n+3) Info.
    static func pageObjects(_ b: inout PDFBuilder, pages n: Int, catalogExtra: String = "") {
        b.obj(1, "<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>")
        let kids = (0..<n).map { "\($0 + 3) 0 R" }.joined(separator: " ")
        b.obj(2, "<< /Type /Pages /Kids [\(kids)] /Count \(n) >>")
        for i in 0..<n {
            b.obj(i + 3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Rotate 0 >>")
        }
        b.obj(n + 3, "<< /Title (Test \\(fixture\\)) /Producer (MuluCoreTests) >>")
    }

    static func classic(pages n: Int, catalogExtra: String = "") -> [UInt8] {
        var b = PDFBuilder(version: "1.4")
        pageObjects(&b, pages: n, catalogExtra: catalogExtra)
        b.classicXRef(nums: Array(1...(n + 3)),
                      trailer: "<< /Size \(n + 4) /Root 1 0 R /Info \(n + 3) 0 R /ID [<0123456789ABCDEF0123456789ABCDEF> <0123456789ABCDEF0123456789ABCDEF>] >>")
        return b.bytes
    }

    static func xrefStream(pages n: Int, pngFilters: [UInt8] = [2]) -> [UInt8] {
        var b = PDFBuilder(version: "1.5")
        pageObjects(&b, pages: n)
        var rows: [Int: (Int, Int, Int)] = [0: (0, 0, 65535)]
        for k in 1...(n + 3) { rows[k] = (1, b.offsets[k]!.offset, 0) }
        b.xrefStream(num: n + 4, rows: rows, trailerKeys: "/Root 1 0 R /Info \(n + 3) 0 R", pngFilters: pngFilters)
        return b.bytes
    }

    /// Catalog (1) and page tree root (2) live in object stream 100; pages are plain.
    static func objectStreamCatalog(pages n: Int) -> [UInt8] {
        var b = PDFBuilder(version: "1.5")
        let kids = (0..<n).map { "\($0 + 3) 0 R" }.joined(separator: " ")
        let o1 = "<< /Type /Catalog /Pages 2 0 R /Lang (en-US) /ViewerPreferences << /DisplayDocTitle true >> >>"
        let o2 = "<< /Type /Pages /Kids [\(kids)] /Count \(n) >>"
        let header = "1 0 2 \(o1.utf8.count + 1) "
        let body = Array((header + o1 + " " + o2).utf8)
        for i in 0..<n {
            b.obj(i + 3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] >>")
        }
        b.stream(100, dict: "/Type /ObjStm /N 2 /First \(header.utf8.count) /Filter /FlateDecode", data: Filters.zlibCompress(body))
        var rows: [Int: (Int, Int, Int)] = [0: (0, 0, 65535), 1: (2, 100, 0), 2: (2, 100, 1), 100: (1, b.offsets[100]!.offset, 0)]
        for i in 0..<n { rows[i + 3] = (1, b.offsets[i + 3]!.offset, 0) }
        b.xrefStream(num: 101, rows: rows, trailerKeys: "/Root 1 0 R", pngFilters: [2])
        return b.bytes
    }
}

/// Rewrites the value of the last `startxref` (byte-level, so offsets stay exact).
func withStartxref(_ bytes: [UInt8], _ transform: (Int) -> Int) -> [UInt8] {
    let i = bytes.lastIndex(of: Array("startxref".utf8))!
    var lx = Lexer(bytes, at: i + 9)
    guard case .integer(let v) = lx.next() else { fatalError("no startxref value") }
    return Array(bytes[..<i]) + Array("startxref\n\(transform(v))\n%%EOF\n".utf8)
}
