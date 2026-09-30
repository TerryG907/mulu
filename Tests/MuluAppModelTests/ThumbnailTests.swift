import CoreGraphics
import Foundation
import MuluOCR
import Testing
@testable import MuluAppModel

@Suite struct ThumbnailTests {
    @Test func rendersAndCaches() async throws {
        let pdf = try SyntheticBook.plainPDF(pages: 3)
        defer { SyntheticBook.remove(pdf) }
        let r = try ThumbnailRenderer(url: pdf)
        #expect(r.pageCount == 3)
        let a = try await r.thumbnail(page: 1, maxPixelWidth: 240)
        #expect(a.page == 1)
        #expect(a.cgImage.width <= 240 && a.cgImage.width >= 200)
        // 6 x 9 in page: the height follows the aspect ratio
        #expect(abs(Double(a.cgImage.height) / Double(a.cgImage.width) - 1.5) < 0.02)
        // some ink was drawn ("Page 1"), on a white page
        #expect(Self.darkPixels(a.cgImage) > 50)
        let b = try await r.thumbnail(page: 1, maxPixelWidth: 240)
        #expect(a.cgImage === b.cgImage)
        #expect(await r.renderCount == 1)
        _ = try await r.thumbnail(page: 2, maxPixelWidth: 240)
        _ = try await r.thumbnail(page: 1, maxPixelWidth: 120)
        #expect(await r.renderCount == 3)
        await #expect(throws: OCRError.pageOutOfRange(page: 4, pageCount: 3)) { try await r.thumbnail(page: 4, maxPixelWidth: 240) }
        await #expect(throws: OCRError.self) { try await r.thumbnail(page: 0, maxPixelWidth: 240) }
    }

    @Test func refusesWhatIsNotAPDF() throws {
        let bogus = SyntheticBook.tempURL("thumb-bogus-\(UUID().uuidString).pdf")
        defer { SyntheticBook.remove(bogus) }
        try Data("nope".utf8).write(to: bogus)
        #expect(throws: OCRError.self) { try ThumbnailRenderer(url: bogus) }
    }

    static func darkPixels(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf.lazy.filter { $0 < 128 }.count
    }
}
