// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mulu",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MuluCore", targets: ["MuluCore"]),
        .executable(name: "mulu", targets: ["mulu"]),
        .executable(name: "MuluApp", targets: ["MuluApp"]),
    ],
    targets: [
        // Pure-Swift PDF reader + incremental-update writer. No dependencies beyond
        // Foundation and Apple's Compression framework (for inflate).
        .target(name: "MuluCore"),
        // Vision/CoreGraphics OCR of printed TOC pages and page-number offset detection
        // (macOS only). Linked into the CLI and the app; MuluCore stays framework-free.
        .target(name: "MuluOCR"),
        // GUI logic without views: document and outline-draft model, recognition pipeline,
        // writer glue, thumbnails, smoke runner. Unit-tested; no SwiftUI/PDFKit.
        .target(name: "MuluAppModel", dependencies: ["MuluCore", "MuluOCR"]),
        .executableTarget(name: "mulu", dependencies: ["MuluCore", "MuluOCR"]),
        // The macOS app: SwiftUI App lifecycle, views, AppKit/PDFKit bridges.
        // scripts/package_app.sh bundles the binary into dist/Mulu.app. The app icon is not a
        // SwiftPM resource: the script copies it into the app's Contents/Resources itself.
        .executableTarget(
            name: "MuluApp",
            dependencies: ["MuluAppModel", "MuluCore", "MuluOCR"],
            exclude: ["Resources/AppIcon.icns"],
            resources: [.process("Resources/Localizable.xcstrings")]),
        .testTarget(name: "MuluCoreTests", dependencies: ["MuluCore"]),
        .testTarget(name: "MuluOCRTests", dependencies: ["MuluOCR"]),
        .testTarget(name: "MuluAppModelTests", dependencies: ["MuluAppModel", "MuluCore", "MuluOCR"]),
    ]
)
