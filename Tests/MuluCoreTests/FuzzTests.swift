import Foundation
import Testing
@testable import MuluCore

/// Deterministic mutation fuzzing: damaged inputs may be refused, but must never
/// crash, hang, or produce an output that fails the writer's own self-check (which
/// `Mulu.apply` runs before returning).
@Suite struct FuzzTests {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let seeds: [[UInt8]] = [
        Fixtures.classic(pages: 3),
        Fixtures.xrefStream(pages: 3, pngFilters: [0, 1, 2, 3, 4]),
        Fixtures.objectStreamCatalog(pages: 3),
        XRefTests.twoRevisions().bytes,
    ]

    static let interesting: [[UInt8]] = [
        "0", "9999999999", "-1", "R", "obj", "endobj", "stream", "endstream", "xref", "trailer",
        "startxref", "<<", ">>", "[", "]", "(", ")", "<", ">", "/", "%", "\r", "\n", " ",
        "/Prev 0", "/Root 1 0 R", "/XRefStm 0", "/Length 1 0 R", "/Kids [2 0 R]", "/Encrypt 1 0 R",
    ].map { Array($0.utf8) }

    @Test(arguments: 0..<4)
    func mutatedInputsNeverCrash(_ seedIndex: Int) {
        var rng = SplitMix64(state: UInt64(seedIndex + 1) * 7919)
        let seed = FuzzTests.seeds[seedIndex]
        var applied = 0
        let iterations = Int(ProcessInfo.processInfo.environment["MULU_FUZZ_ITERATIONS"] ?? "") ?? 400
        for _ in 0..<iterations {
            var b = seed
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let pos = Int.random(in: 0..<b.count, using: &rng)
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: b[pos] = UInt8.random(in: 0...255, using: &rng)
                case 1: b.removeSubrange(pos..<min(b.count, pos + Int.random(in: 1...16, using: &rng)))
                case 2: b.insert(contentsOf: FuzzTests.interesting.randomElement(using: &rng)!, at: pos)
                case 3: b = Array(b[0..<max(1, pos)])  // truncate
                default: if isASCIIDigit(b[pos]) { b[pos] = UInt8.random(in: 0x30...0x39, using: &rng) }
                }
                if b.isEmpty { b = [0x25] }
            }
            if let r = try? Mulu.apply(pdf: b, tocText: "A 1\n\tB 1", offset: 0) {
                applied += 1
                #expect(Array(r.output[0..<b.count]) == b)
            }
            _ = (try? PDFFile(bytes: b)).map { doc in (doc.info(), try? doc.readOutline()) }
        }
        #expect(applied > 0)
    }
}
