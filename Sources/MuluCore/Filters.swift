import Compression
import Foundation

/// Stream filters needed to read cross-reference streams and object streams.
/// Mulu never writes compressed data, so only decoding is implemented (plus a zlib
/// encoder used by the unit tests to build fixtures).
enum Filters {
    /// Guard against decompression bombs. Mulu only ever decodes cross-reference
    /// streams and object streams; real ones are a few MB at most (qpdf and Acrobat
    /// pack ~100-200 objects per object stream), so 64 MiB is generous while keeping
    /// peak memory for a hostile file around 200 MB.
    static let maxDecodedSize = 64 << 20

    static func decode(_ data: [UInt8], filter: String, parms: PDFDict?) throws -> [UInt8] {
        switch filter {
        case "FlateDecode", "Fl":
            return try applyPredictor(try flateDecode(data), parms: parms)
        case "LZWDecode", "LZW":
            let early = parms?["EarlyChange"]?.intValue ?? 1
            return try applyPredictor(try lzwDecode(data, earlyChange: early != 0), parms: parms)
        case "ASCIIHexDecode", "AHx":
            return asciiHexDecode(data)
        case "ASCII85Decode", "A85":
            return try ascii85Decode(data)
        case "RunLengthDecode", "RL":
            return try runLengthDecode(data)
        default:
            throw MuluError.unsupported("stream filter /\(filter)")
        }
    }

    static func tooLarge() -> MuluError {
        .unsupported("a cross-reference or object stream decodes to more than \(maxDecodedSize >> 20) MiB")
    }

    // MARK: Flate

    /// PDF's FlateDecode data is a zlib stream (RFC 1950): a 2-byte header, raw
    /// deflate data (RFC 1951), then an Adler-32 checksum. Apple's COMPRESSION_ZLIB
    /// is *raw* deflate, so the header must be validated and stripped first.
    static func flateDecode(_ data: [UInt8]) throws -> [UInt8] {
        var body = data[...]
        if data.count >= 2 {
            let cmf = data[0]
            let flg = data[1]
            let validHeader = (cmf & 0x0F) == 8          // CM = 8 (deflate)
                && (cmf >> 4) <= 7                          // CINFO: window <= 32K
                && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0  // FCHECK
                && (flg & 0x20) == 0                        // FDICT: preset dictionary unsupported
            if validHeader {
                body = data[2...]
            } else if (flg & 0x20) != 0 && (cmf & 0x0F) == 8 && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 {
                throw MuluError.unsupported("zlib stream with a preset dictionary")
            }
            // Otherwise: a (broken) writer emitted raw deflate with no zlib header;
            // try to inflate it as-is, like pdf.js and PDFium do.
        }
        let (out, complete) = try inflateRaw(body)
        if !complete && out.isEmpty {
            throw MuluError.malformed("corrupt Flate stream")
        }
        // A truncated stream still yields whatever was decodable; callers validate
        // the structure of what they read (xref rows, object stream offsets).
        return out
    }

    /// Raw-deflate decode using the Compression framework's streaming API. Returns the
    /// output and whether the final deflate block was reached. Trailing bytes after
    /// the final block (the Adler-32 checksum) are ignored.
    static func inflateRaw(_ input: ArraySlice<UInt8>) throws -> (data: [UInt8], complete: Bool) {
        if input.isEmpty { return ([], false) }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw MuluError.malformed("cannot initialise inflate")
        }
        defer { compression_stream_destroy(streamPtr) }

        let chunk = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        // Output is collected in chunks and joined once at the end, so the peak is about
        // twice the decoded size (a growing array would briefly hold three times it).
        var chunks: [[UInt8]] = []
        var total = 0
        var complete = false
        let finalize = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)

        try input.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = src.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunk
                let srcBefore = streamPtr.pointee.src_size
                let status = compression_stream_process(streamPtr, finalize)
                let produced = chunk - streamPtr.pointee.dst_size
                if produced > 0 {
                    chunks.append(Array(UnsafeBufferPointer(start: dst, count: produced)))
                    total += produced
                }
                if total > maxDecodedSize { throw tooLarge() }
                if status == COMPRESSION_STATUS_END {
                    complete = true
                    return
                }
                if status != COMPRESSION_STATUS_OK { return }  // corrupt data: keep partial output
                if produced == 0 && streamPtr.pointee.src_size == srcBefore { return }  // truncated: no progress
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(total)
        for c in chunks { out.append(contentsOf: c) }
        return (out, complete)
    }

    /// zlib-wrapped deflate (header 78 9C + raw deflate + Adler-32). Test helper.
    static func zlibCompress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        if data.isEmpty {
            out += [0x03, 0x00]  // a single empty final fixed-Huffman block
        } else {
            let capacity = data.count + data.count / 2 + 1024
            var dst = [UInt8](repeating: 0, count: capacity)
            let n = data.withUnsafeBufferPointer { src in
                dst.withUnsafeMutableBufferPointer { d in
                    compression_encode_buffer(d.baseAddress!, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            precondition(n > 0, "deflate failed")
            out += dst[0..<n]
        }
        let a = adler32(data)
        out += [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)]
        return out
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for x in data {
            a = (a + UInt32(x)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    // MARK: Predictors (§7.4.4.4, Table 10)

    static func applyPredictor(_ data: [UInt8], parms: PDFDict?) throws -> [UInt8] {
        guard let parms else { return data }
        let predictor = parms["Predictor"]?.intValue ?? 1
        if predictor <= 1 { return data }
        let colors = max(1, parms["Colors"]?.intValue ?? 1)
        let bpc = parms["BitsPerComponent"]?.intValue ?? 8
        let columns = max(1, parms["Columns"]?.intValue ?? 1)
        guard [1, 2, 4, 8, 16].contains(bpc), colors <= 256, columns <= 1 << 24 else {
            throw MuluError.unsupported("predictor parameters Colors=\(colors) BitsPerComponent=\(bpc) Columns=\(columns)")
        }
        let rowLength = (columns * colors * bpc + 7) / 8
        guard rowLength <= 1 << 24 else {  // hostile /Columns must not trigger a huge allocation
            throw MuluError.unsupported("predictor row of \(rowLength) bytes")
        }
        let bytesPerPixel = max(1, (colors * bpc + 7) / 8)
        if predictor == 2 {
            return try tiffPredictor(data, rowLength: rowLength, colors: colors, bpc: bpc)
        }
        if predictor >= 10 {
            return try pngPredictor(data, rowLength: rowLength, bytesPerPixel: bytesPerPixel)
        }
        throw MuluError.unsupported("predictor \(predictor)")
    }

    /// PNG predictors: every row is prefixed by a filter-type byte (0 None, 1 Sub,
    /// 2 Up, 3 Average, 4 Paeth); the /Predictor value 10...15 only says "PNG".
    static func pngPredictor(_ data: [UInt8], rowLength: Int, bytesPerPixel bpp: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var prev = [UInt8](repeating: 0, count: rowLength)
        var row = [UInt8](repeating: 0, count: rowLength)
        var i = 0
        while i < data.count {
            let filterType = data[i]
            i += 1
            let n = min(rowLength, data.count - i)  // a truncated last row is decoded as far as it goes
            for j in 0..<n { row[j] = data[i + j] }
            for j in n..<rowLength { row[j] = 0 }
            switch filterType {
            case 0:
                break
            case 1:  // Sub
                for j in stride(from: bpp, to: n, by: 1) { row[j] &+= row[j - bpp] }
            case 2:  // Up
                for j in 0..<n { row[j] &+= prev[j] }
            case 3:  // Average (computed without 8-bit overflow)
                for j in 0..<n {
                    let left = j >= bpp ? Int(row[j - bpp]) : 0
                    row[j] &+= UInt8((left + Int(prev[j])) >> 1)
                }
            case 4:  // Paeth
                for j in 0..<n {
                    let a = j >= bpp ? Int(row[j - bpp]) : 0
                    let b = Int(prev[j])
                    let c = j >= bpp ? Int(prev[j - bpp]) : 0
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                    row[j] &+= UInt8(pred)
                }
            default:
                throw MuluError.malformed("invalid PNG predictor filter type \(filterType)")
            }
            out.append(contentsOf: row[0..<n])
            swap(&prev, &row)
            i += n
        }
        return out
    }

    /// TIFF Predictor 2: horizontal differencing per colour component.
    static func tiffPredictor(_ data: [UInt8], rowLength: Int, colors: Int, bpc: Int) throws -> [UInt8] {
        var out = data
        switch bpc {
        case 8:
            for rowStart in stride(from: 0, to: out.count, by: rowLength) {
                let rowEnd = min(rowStart + rowLength, out.count)
                for j in stride(from: rowStart + colors, to: rowEnd, by: 1) { out[j] &+= out[j - colors] }
            }
        case 16:
            let step = 2 * colors
            for rowStart in stride(from: 0, to: out.count, by: rowLength) {
                let rowEnd = min(rowStart + rowLength, out.count)
                var j = rowStart + step
                while j + 1 < rowEnd {
                    let cur = UInt16(out[j]) << 8 | UInt16(out[j + 1])
                    let left = UInt16(out[j - step]) << 8 | UInt16(out[j - step + 1])
                    let v = cur &+ left
                    out[j] = UInt8(v >> 8)
                    out[j + 1] = UInt8(v & 0xFF)
                    j += 2
                }
            }
        default:
            throw MuluError.unsupported("TIFF predictor with \(bpc) bits per component")
        }
        return out
    }

    // MARK: LZW (§7.4.4) and RunLength (§7.4.5)

    /// LZW with 9- to 12-bit codes, clear-table code 256 and end-of-data code 257.
    /// With /EarlyChange 1 (the default) the code width grows one code early.
    static func lzwDecode(_ data: [UInt8], earlyChange: Bool) throws -> [UInt8] {
        var prefix = [Int](repeating: -1, count: 4096)  // table: prefix code + last byte
        var suffix = [UInt8](repeating: 0, count: 4096)
        var firstByte = [UInt8](repeating: 0, count: 4096)
        var length = [Int](repeating: 1, count: 4096)
        for i in 0..<256 {
            suffix[i] = UInt8(i)
            firstByte[i] = UInt8(i)
        }
        var next = 258
        var width = 9
        var previous = -1
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 3)
        var bitBuffer = 0, bitCount = 0
        var scratch = [UInt8](repeating: 0, count: 4096)

        func emit(_ code: Int) {
            var c = code
            let n = length[code]
            var i = n - 1
            while i >= 0 {
                scratch[i] = suffix[c]
                c = prefix[c]
                i -= 1
            }
            out.append(contentsOf: scratch[0..<n])
        }

        for byte in data {
            bitBuffer = (bitBuffer << 8) | Int(byte)
            bitCount += 8
            while bitCount >= width {
                let code = (bitBuffer >> (bitCount - width)) & ((1 << width) - 1)
                bitCount -= width
                bitBuffer &= (1 << bitCount) - 1
                if code == 256 {
                    next = 258
                    width = 9
                    previous = -1
                    continue
                }
                if code == 257 { return out }
                if previous < 0 {
                    guard code < 256 else { throw MuluError.malformed("corrupt LZW data") }
                    emit(code)
                    previous = code
                    continue
                }
                let first: UInt8
                if code < next {
                    first = firstByte[code]
                } else if code == next {
                    first = firstByte[previous]
                } else {
                    throw MuluError.malformed("corrupt LZW data")
                }
                if next < 4096 {
                    prefix[next] = previous
                    suffix[next] = first
                    firstByte[next] = firstByte[previous]
                    length[next] = length[previous] + 1
                    next += 1
                }
                emit(code)
                if out.count > maxDecodedSize { throw tooLarge() }
                previous = code
                let limit = earlyChange ? next + 1 : next
                if limit >= (1 << width), width < 12 { width += 1 }
            }
        }
        return out  // no end-of-data code: keep what was decoded
    }

    static func runLengthDecode(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let n = Int(data[i])
            i += 1
            if n == 128 { break }
            if n < 128 {
                let end = min(data.count, i + n + 1)
                out.append(contentsOf: data[i..<end])
                i = end
            } else if i < data.count {
                out.append(contentsOf: repeatElement(data[i], count: 257 - n))
                i += 1
            }
            if out.count > maxDecodedSize { throw tooLarge() }
        }
        return out
    }

    // MARK: ASCII filters

    static func asciiHexDecode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var high: UInt8? = nil
        for c in data {
            if c == 0x3E { break }
            guard let v = hexNibble(c) else { continue }
            if let h = high {
                out.append(h << 4 | v)
                high = nil
            } else {
                high = v
            }
        }
        if let h = high { out.append(h << 4) }
        return out
    }

    static func ascii85Decode(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var group: [UInt32] = []
        var i = 0
        if data.count >= 2, data[0] == 0x3C, data[1] == 0x7E { i = 2 }  // optional "<~"
        func flush(_ g: [UInt32], _ produce: Int) {
            var v: UInt32 = 0
            for k in 0..<5 { v = v &* 85 &+ (k < g.count ? g[k] : 84) }
            let bytes = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            out.append(contentsOf: bytes[0..<produce])
        }
        while i < data.count {
            let c = data[i]
            i += 1
            if c == 0x7E { break }  // "~>" end of data
            if isPDFWhitespace(c) { continue }
            if c == 0x7A && group.isEmpty {  // 'z' = four zero bytes
                out += [0, 0, 0, 0]
                continue
            }
            guard c >= 0x21 && c <= 0x75 else { throw MuluError.malformed("invalid ASCII85 character") }
            group.append(UInt32(c - 0x21))
            if group.count == 5 {
                flush(group, 4)
                group.removeAll(keepingCapacity: true)
            }
        }
        if group.count == 1 { throw MuluError.malformed("invalid ASCII85 final group") }
        if group.count > 1 { flush(group, group.count - 1) }
        return out
    }
}
