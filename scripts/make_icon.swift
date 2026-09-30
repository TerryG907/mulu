#!/usr/bin/env swift
// Draws the Mulu app icon with CoreGraphics and writes
//
//   Sources/MuluApp/Resources/AppIcon.icns   16–512 pt, @1x and @2x (ten PNGs, packed by iconutil)
//   docs/images/icon-256.png                 256 × 256 px, for the docs
//
// Usage: swift scripts/make_icon.swift [--preview DIR]
//   --preview DIR   only write the ten iconset PNGs to DIR; nothing in the repository changes
//
// The picture: a page carrying a two-level outline (indented title bars, page-number dots on the
// right) and a bookmark ribbon, on the macOS icon grid: 1024 canvas, 824 rounded square centred
// in it, corner radius 185.4, drop shadow inside the 100 px margin. The 32 px and 16 px
// renditions use simpler drawings (three square bars, no page numbers) laid out on the pixel
// grid of their size, so the bars stay sharp.
//
// scripts/package_app.sh copies the .icns into Mulu.app; run this script again only when the
// drawing changes, and commit both outputs.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Rounded rectangle with continuous-curvature corners (the shape of macOS app icons).
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    let a = 1.528665 * radius
    let b = 1.088493 * radius
    let c = 0.868407 * radius
    let d = 0.631494 * radius
    let e = 0.074911 * radius
    let f = 0.372824 * radius
    let g = 0.169060 * radius
    let path = CGMutablePath()
    path.move(to: point(x0 + a, y0))
    path.addLine(to: point(x1 - a, y0))
    path.addCurve(to: point(x1 - d, y0 + e), control1: point(x1 - b, y0), control2: point(x1 - c, y0))
    path.addCurve(to: point(x1 - e, y0 + d), control1: point(x1 - f, y0 + g), control2: point(x1 - g, y0 + f))
    path.addCurve(to: point(x1, y0 + a), control1: point(x1, y0 + c), control2: point(x1, y0 + b))
    path.addLine(to: point(x1, y1 - a))
    path.addCurve(to: point(x1 - e, y1 - d), control1: point(x1, y1 - b), control2: point(x1, y1 - c))
    path.addCurve(to: point(x1 - d, y1 - e), control1: point(x1 - g, y1 - f), control2: point(x1 - f, y1 - g))
    path.addCurve(to: point(x1 - a, y1), control1: point(x1 - c, y1), control2: point(x1 - b, y1))
    path.addLine(to: point(x0 + a, y1))
    path.addCurve(to: point(x0 + d, y1 - e), control1: point(x0 + b, y1), control2: point(x0 + c, y1))
    path.addCurve(to: point(x0 + e, y1 - d), control1: point(x0 + f, y1 - g), control2: point(x0 + g, y1 - f))
    path.addCurve(to: point(x0, y1 - a), control1: point(x0, y1 - c), control2: point(x0, y1 - b))
    path.addLine(to: point(x0, y0 + a))
    path.addCurve(to: point(x0 + e, y0 + d), control1: point(x0, y0 + b), control2: point(x0, y0 + c))
    path.addCurve(to: point(x0 + d, y0 + e), control1: point(x0 + g, y0 + f), control2: point(x0 + f, y0 + g))
    path.addCurve(to: point(x0 + a, y0), control1: point(x0 + c, y0), control2: point(x0 + b, y0))
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// One outline row: a title bar and, when `number` is set, a page-number dot on the right.
struct Row {
    var y: CGFloat          // top edge
    var x0: CGFloat         // title bar left edge (the indent shows the level)
    var x1: CGFloat         // title bar right edge
    var topLevel: Bool
    var number: ClosedRange<CGFloat>?
}

/// Everything that differs between the full drawing and the small ones. Units: 1024 canvas, y down.
struct Layout {
    var body: CGRect        // the rounded square
    var bodyRadius: CGFloat
    var page: CGRect
    var pageRadius: CGFloat
    var barHeight: CGFloat
    var roundBars: Bool
    var rows: [Row]
    var ribbon: CGRect
    var ribbonNotch: CGFloat

    /// 64 px and larger. Page, bars and ribbon sit on a 16-unit grid, so at 64 px every edge is a pixel edge.
    static let full = Layout(
        body: CGRect(x: 100, y: 100, width: 824, height: 824),
        bodyRadius: 185.4,
        page: CGRect(x: 288, y: 208, width: 448, height: 608),
        pageRadius: 34,
        barHeight: 48,
        roundBars: true,
        rows: [
            Row(y: 304, x0: 352, x1: 544, topLevel: true, number: nil),
            Row(y: 400, x0: 416, x1: 544, topLevel: false, number: nil),
            Row(y: 496, x0: 416, x1: 592, topLevel: false, number: 624...672),
            Row(y: 592, x0: 352, x1: 560, topLevel: true, number: 624...672),
            Row(y: 688, x0: 416, x1: 576, topLevel: false, number: 624...672),
        ],
        ribbon: CGRect(x: 592, y: 176, width: 80, height: 288),
        ribbonNotch: 40)

    /// 32 px: three square bars on a 32-unit grid (one unit = one pixel).
    static let small = Layout(
        body: CGRect(x: 96, y: 96, width: 832, height: 832),
        bodyRadius: 190,
        page: CGRect(x: 288, y: 192, width: 448, height: 640),
        pageRadius: 40,
        barHeight: 64,
        roundBars: false,
        rows: [
            Row(y: 320, x0: 352, x1: 512, topLevel: true, number: nil),
            Row(y: 480, x0: 416, x1: 672, topLevel: false, number: nil),
            Row(y: 640, x0: 416, x1: 672, topLevel: false, number: nil),
        ],
        ribbon: CGRect(x: 576, y: 160, width: 96, height: 256),
        ribbonNotch: 48)

    /// 16 px: the same three bars on a 64-unit grid, one pixel high each; the ribbon keeps a flat end.
    static let tiny = Layout(
        body: CGRect(x: 64, y: 64, width: 896, height: 896),
        bodyRadius: 205,
        page: CGRect(x: 256, y: 192, width: 512, height: 640),
        pageRadius: 48,
        barHeight: 64,
        roundBars: false,
        rows: [
            Row(y: 384, x0: 320, x1: 512, topLevel: true, number: nil),
            Row(y: 512, x0: 384, x1: 704, topLevel: false, number: nil),
            Row(y: 640, x0: 384, x1: 704, topLevel: false, number: nil),
        ],
        ribbon: CGRect(x: 576, y: 128, width: 128, height: 320),
        ribbonNotch: 0)

    static func forPixels(_ pixels: Int) -> Layout {
        pixels <= 16 ? tiny : pixels <= 32 ? small : full
    }
}

enum Palette {
    static let backgroundTop = rgb(0x4B88DA)
    static let backgroundBottom = rgb(0x22489A)
    static let pageTop = rgb(0xFFFFFF)
    static let pageBottom = rgb(0xEDF1F7)
    static let inkTopLevel = rgb(0x27457F)
    static let inkSubLevel = rgb(0x9CB1D6)
    static let inkSubLevelSmall = rgb(0x7E97C8)   // stronger, for 32 px and smaller
    static let inkNumber = rgb(0xC6D2E8)
    static let ribbonTop = rgb(0xFF6B4E)
    static let ribbonBottom = rgb(0xE03B2C)
}

func fillVertical(_ ctx: CGContext, _ path: CGPath, from top: CGColor, to bottom: CGColor, y0: CGFloat, y1: CGFloat) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: point(0, y0), end: point(0, y1),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Fills `path` with a drop shadow. Shadow offset and blur are in device pixels, so they are scaled here.
func fillWithShadow(_ ctx: CGContext, _ path: CGPath, fill: CGColor, scale: CGFloat,
                    drop: CGFloat, blur: CGFloat, opacity: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -drop * scale), blur: blur * scale, color: rgb(0x000000, opacity))
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)   // 1024 canvas, origin top left, y down

    let small = pixels <= 32
    let layout = Layout.forPixels(pixels)

    // Background: the icon shape, its shadow, a vertical gradient and a thin light rim along the top.
    let body = continuousRoundedRect(layout.body, radius: layout.bodyRadius)
    fillWithShadow(ctx, body, fill: Palette.backgroundBottom, scale: scale, drop: 12, blur: 24, opacity: 0.30)
    fillVertical(ctx, body, from: Palette.backgroundTop, to: Palette.backgroundBottom,
                 y0: layout.body.minY, y1: layout.body.maxY)
    if !small {
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.addPath(body)
        ctx.setLineWidth(10)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = CGGradient(colorsSpace: sRGB, colors: [rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(rim, start: point(0, 100), end: point(0, 420), options: [])
        ctx.restoreGState()
    }

    // Page.
    let page = roundedRect(layout.page, radius: layout.pageRadius)
    fillWithShadow(ctx, page, fill: Palette.pageBottom, scale: scale, drop: 14, blur: 36, opacity: small ? 0.22 : 0.30)
    fillVertical(ctx, page, from: Palette.pageTop, to: Palette.pageBottom, y0: layout.page.minY, y1: layout.page.maxY)

    // Outline rows.
    for row in layout.rows {
        let bar = CGRect(x: row.x0, y: row.y, width: row.x1 - row.x0, height: layout.barHeight)
        ctx.addPath(roundedRect(bar, radius: layout.roundBars ? layout.barHeight / 2 : 0))
        ctx.setFillColor(row.topLevel ? Palette.inkTopLevel : small ? Palette.inkSubLevelSmall : Palette.inkSubLevel)
        ctx.fillPath()
        if let number = row.number {
            let dot = CGRect(x: number.lowerBound, y: row.y, width: number.upperBound - number.lowerBound,
                             height: layout.barHeight)
            ctx.addPath(roundedRect(dot, radius: layout.barHeight / 2))
            ctx.setFillColor(Palette.inkNumber)
            ctx.fillPath()
        }
    }

    // Bookmark ribbon: hangs over the top edge of the page, swallow-tail at the bottom.
    let r = layout.ribbon
    let ribbon = CGMutablePath()
    let cap: CGFloat = small ? 0 : 10
    ribbon.move(to: point(r.minX, r.minY + cap))
    ribbon.addQuadCurve(to: point(r.minX + cap, r.minY), control: point(r.minX, r.minY))
    ribbon.addLine(to: point(r.maxX - cap, r.minY))
    ribbon.addQuadCurve(to: point(r.maxX, r.minY + cap), control: point(r.maxX, r.minY))
    ribbon.addLine(to: point(r.maxX, r.maxY))
    ribbon.addLine(to: point(r.midX, r.maxY - layout.ribbonNotch))
    ribbon.addLine(to: point(r.minX, r.maxY))
    ribbon.closeSubpath()
    fillWithShadow(ctx, ribbon, fill: Palette.ribbonBottom, scale: scale, drop: 6, blur: 14, opacity: small ? 0.15 : 0.26)
    fillVertical(ctx, ribbon, from: Palette.ribbonTop, to: Palette.ribbonBottom, y0: r.minY, y1: r.maxY)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// The ten files `iconutil` expects in an .iconset directory.
let iconsetFiles: [(name: String, pixels: Int)] = [16, 32, 128, 256, 512].flatMap { points in
    [("icon_\(points)x\(points).png", points), ("icon_\(points)x\(points)@2x.png", points * 2)]
}

func writeIconset(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var cache: [Int: CGImage] = [:]
    for file in iconsetFiles {
        let image = cache[file.pixels] ?? render(pixels: file.pixels)
        cache[file.pixels] = image
        try writePNG(image, to: directory.appendingPathComponent(file.name))
    }
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--preview", arguments.count == 2 {
        let directory = URL(fileURLWithPath: arguments[1])
        try writeIconset(to: directory)
        print("make_icon: wrote \(iconsetFiles.count) PNGs to \(directory.path)")
        return
    }
    guard arguments.isEmpty else {
        FileHandle.standardError.write(Data("usage: swift scripts/make_icon.swift [--preview DIR]\n".utf8))
        exit(2)
    }

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let icns = root.appendingPathComponent("Sources/MuluApp/Resources/AppIcon.icns")
    let docsImage = root.appendingPathComponent("docs/images/icon-256.png")

    let work = FileManager.default.temporaryDirectory.appendingPathComponent("mulu-icon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    let iconset = work.appendingPathComponent("AppIcon.iconset")
    try writeIconset(to: iconset)

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", icns.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("make_icon: iconutil failed (\(iconutil.terminationStatus))\n".utf8))
        exit(1)
    }

    try FileManager.default.createDirectory(at: docsImage.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePNG(render(pixels: 256), to: docsImage)
    print("make_icon: wrote Sources/MuluApp/Resources/AppIcon.icns and docs/images/icon-256.png")
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("make_icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
