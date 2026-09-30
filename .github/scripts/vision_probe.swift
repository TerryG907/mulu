// vision_probe.swift -- does Vision text recognition work on this machine?
//
// Some virtual Macs cannot run VNRecognizeTextRequest at all (every request throws), and some
// stop working after the first request of a process. The OCR tests would then fail for a reason
// that has nothing to do with Mulu. This probe uses none of Mulu's code: it draws three lines of
// text, reads each one back with the same kind of request Mulu makes (.accurate, zh-Hans +
// en-US), several requests in one process, and reports the result.
//
//   swiftc -O .github/scripts/vision_probe.swift -o vision_probe && ./vision_probe
//
// Exit status: 0 = every line was read back; 1 = Vision threw or read something else;
// 3 = no answer within 90 seconds.
import CoreGraphics
import CoreText
import Dispatch
import Foundation
import Vision

// The three lines, and what must come back (spaces are ignored).
let samples: [(text: String, font: String, want: String)] = [
    ("MULU 2468", "Helvetica", "MULU2468"),
    ("Chapter 7 .......... 135", "Times-Roman", "135"),
    ("第三章 目录 97", "STHeitiSC-Medium", "97"),
]

func render(_ text: String, font name: String) -> CGImage? {
    let width = 1600, height = 240
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(gray: 0, alpha: 1)
    let font = CTFontCreateWithName(name as CFString, 96, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]))
    ctx.textPosition = CGPoint(x: 60, y: 80)
    CTLineDraw(line, ctx)
    return ctx.makeImage()
}

func recognize(_ image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

// A request that never returns must not hang the caller.
DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
    print("vision_probe: no answer within 90 seconds")
    exit(3)
}

var failures = 0
for (index, sample) in samples.enumerated() {
    guard let image = render(sample.text, font: sample.font) else {
        print("vision_probe: line \(index + 1): could not draw the test image")
        failures += 1
        continue
    }
    do {
        let got = try recognize(image)
        let ok = got.filter { !$0.isWhitespace }.contains(sample.want)
        print("vision_probe: line \(index + 1): drew \"\(sample.text)\", read \"\(got)\" -> \(ok ? "ok" : "MISMATCH")")
        if !ok { failures += 1 }
    } catch {
        print("vision_probe: line \(index + 1): the request failed: \(error)")
        failures += 1
    }
}
print(failures == 0 ? "vision_probe: Vision text recognition works" : "vision_probe: Vision text recognition does NOT work here")
exit(failures == 0 ? 0 : 1)
