import CoreGraphics
import Foundation
import Vision

/// A point in image pixels, y growing DOWN.
public struct PixelPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One piece of recognized text (a Vision observation), in image pixels (y down).
public struct OCRObservation: Sendable {
    public var text: String
    /// Axis-aligned bounding box.
    public var rect: PixelRect
    /// The text quadrilateral: top-left, top-right, bottom-right, bottom-left.
    public var corners: [PixelPoint]
    public var confidence: Double
    /// Box of the trailing page-number token (see `PageToken.splitTrailing`), when the
    /// text ends in one.
    public var trailingRect: PixelRect?
    /// Left end (x) and vertical middle of the first letter or digit, which is where the
    /// line visually starts (specks read as "•" before it do not count).
    public var textStart: PixelPoint?

    public init(text: String, rect: PixelRect, corners: [PixelPoint]? = nil, confidence: Double = 1,
                trailingRect: PixelRect? = nil) {
        self.text = text
        self.rect = rect
        self.corners = corners ?? [
            PixelPoint(x: rect.minX, y: rect.minY), PixelPoint(x: rect.maxX, y: rect.minY),
            PixelPoint(x: rect.maxX, y: rect.maxY), PixelPoint(x: rect.minX, y: rect.maxY),
        ]
        self.confidence = confidence
        self.trailingRect = trailingRect
        self.textStart = nil
    }

    /// Baseline angle in radians (positive = the text descends to the right, y down).
    public var baselineAngle: Double {
        let bl = corners[3], br = corners[2]
        return atan2(br.y - bl.y, br.x - bl.x)
    }

    /// The observation rotated by `-angle` about `center` (undoes a scan skew of `angle`).
    public func deskewed(angle: Double, center: PixelPoint) -> OCRObservation {
        guard angle != 0 else { return self }
        let c = cos(-angle), s = sin(-angle)
        func rot(_ p: PixelPoint) -> PixelPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            return PixelPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
        }
        func box(_ pts: [PixelPoint]) -> PixelRect {
            PixelRect(minX: pts.map(\.x).min()!, minY: pts.map(\.y).min()!, maxX: pts.map(\.x).max()!, maxY: pts.map(\.y).max()!)
        }
        var o = self
        o.corners = corners.map(rot)
        o.rect = box(o.corners)
        if let s = textStart { o.textStart = rot(s) }
        if let t = trailingRect {
            o.trailingRect = box([PixelPoint(x: t.minX, y: t.minY), PixelPoint(x: t.maxX, y: t.minY),
                                  PixelPoint(x: t.maxX, y: t.maxY), PixelPoint(x: t.minX, y: t.maxY)].map(rot))
        }
        return o
    }
}

/// Settings for one Vision text-recognition pass.
public struct RecognitionOptions: Sendable {
    public var languages: [String] = ["zh-Hans", "en-US"]
    public var languageCorrection = true
    /// Smallest text height to look for, in pixels (converted to Vision's relative value).
    public var minimumTextHeightPixels = 12.0
    /// VNRecognizeTextRequest revision; nil = the newest.
    public var revision: Int? = nil

    public init(languageCorrection: Bool = true, minimumTextHeightPixels: Double = 12) {
        self.languageCorrection = languageCorrection
        self.minimumTextHeightPixels = minimumTextHeightPixels
    }
}

/// Runs VNRecognizeTextRequest (.accurate) on a grayscale image.
public enum TextRecognizer {
    public static func recognize(_ image: GrayImage, options: RecognitionOptions = RecognitionOptions()) throws -> [OCRObservation] {
        guard let cg = image.cgImage() else { throw OCRError.visionFailed("empty image") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = options.languages
        request.usesLanguageCorrection = options.languageCorrection
        if let r = options.revision { request.revision = r }
        request.minimumTextHeight = Float(min(0.03, max(0.001, options.minimumTextHeightPixels / Double(image.height))))
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.visionFailed(error.localizedDescription)
        }
        let W = Double(image.width), H = Double(image.height)
        func px(_ p: CGPoint) -> PixelPoint { PixelPoint(x: p.x * W, y: (1 - p.y) * H) }
        func px(_ r: CGRect) -> PixelRect {
            PixelRect(minX: r.minX * W, minY: (1 - r.maxY) * H, maxX: r.maxX * W, maxY: (1 - r.minY) * H)
        }
        var out: [OCRObservation] = []
        for obs in request.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            let text = top.string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var trailing: PixelRect? = nil
            if let split = PageToken.splitTrailing(text), let box = try? top.boundingBox(for: split.tokenRange) {
                trailing = px(box.boundingBox)
            }
            var o = OCRObservation(
                text: text, rect: px(obs.boundingBox),
                corners: [px(obs.topLeft), px(obs.topRight), px(obs.bottomRight), px(obs.bottomLeft)],
                confidence: Double(top.confidence), trailingRect: trailing)
            if let i = text.firstIndex(where: { $0.isLetter || $0.isNumber }),
               let box = try? top.boundingBox(for: i..<text.index(after: i)) {
                let r = px(box.boundingBox)
                o.textStart = PixelPoint(x: r.minX, y: r.midY)
            }
            out.append(o)
        }
        return dedupe(out)
    }
}

extension TextRecognizer {
    /// Share of the recognized text (by width) whose baseline runs right-to-left or
    /// vertically: Vision's newest revision sometimes decides a whole upright page is upside
    /// down (dense dot leaders provoke it) and returns garbage.
    static func misorientedShare(_ obs: [OCRObservation]) -> Double {
        let total = obs.map(\.rect.width).reduce(0, +)
        guard total > 0 else { return 0 }
        return obs.filter { abs($0.baselineAngle) > .pi / 4 }.map(\.rect.width).reduce(0, +) / total
    }

    /// `recognize`, retried when the result is mostly misoriented: first with the previous
    /// recognizer revision, then at 70% scale (coordinates are mapped back). Returns the
    /// attempt with the least misoriented text and a note describing the retry, if any.
    public static func recognizeUpright(_ image: GrayImage, options: RecognitionOptions) throws -> ([OCRObservation], String?) {
        var best = try recognize(image, options: options)
        var bestShare = misorientedShare(best)
        guard bestShare > 0.3 else { return (best, nil) }
        var note = String(format: "Vision read %.0f%% of the text as rotated; ", bestShare * 100)
        var o2 = options
        o2.revision = 2
        let r2 = try recognize(image, options: o2)
        let s2 = misorientedShare(r2)
        if s2 < bestShare { best = r2; bestShare = s2; note += "re-read with recognizer revision 2" }
        if bestShare > 0.3 {
            let f = 0.7
            var o3 = options
            o3.minimumTextHeightPixels = options.minimumTextHeightPixels * f
            let r3 = try recognize(image.scaled(by: f), options: o3).map { o -> OCRObservation in
                var m = o
                m.rect = o.rect.scaled(by: 1 / f)
                m.corners = o.corners.map { PixelPoint(x: $0.x / f, y: $0.y / f) }
                m.trailingRect = o.trailingRect?.scaled(by: 1 / f)
                m.textStart = o.textStart.map { PixelPoint(x: $0.x / f, y: $0.y / f) }
                return m
            }
            let s3 = misorientedShare(r3)
            if s3 < bestShare { best = r3; bestShare = s3; note += "re-read at 70% scale" }
        }
        return (best, note)
    }
}

extension TextRecognizer {
    /// Vision sometimes returns a piece of a line twice: "...6" and, inside its box, "6".
    /// An observation lying mostly (70%+) inside a longer one whose text contains its text
    /// is dropped.
    static func dedupe(_ obs: [OCRObservation]) -> [OCRObservation] {
        func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        return obs.enumerated().filter { (i, b) in
            let area = max(1e-9, b.rect.width * b.rect.height)
            return !obs.enumerated().contains { (j, a) in
                guard j != i else { return false }
                let ta = squash(a.text), tb = squash(b.text)
                guard ta.count > tb.count || (ta == tb && j < i), ta.contains(tb) else { return false }
                let ix = min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX)
                let iy = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
                return ix > 0 && iy > 0 && ix * iy >= 0.7 * area
            }
        }.map(\.1)
    }
}

extension TextRecognizer {
    /// Drops observations Vision read upside down or sideways (baseline more than 60 degrees
    /// off): in a small crop it may turn the image over and read a 6 as 9.
    public static func upright(_ obs: [OCRObservation]) -> [OCRObservation] {
        obs.filter { abs($0.baselineAngle) <= .pi / 3 }
    }
}
