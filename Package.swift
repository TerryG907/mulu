// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mulu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MuluCore", targets: ["MuluCore"]),
        .executable(name: "mulu", targets: ["mulu"]),
    ],
    targets: [
        // Pure-Swift PDF reader + incremental-update writer. No dependencies beyond
        // Foundation and Apple's Compression framework (for inflate).
        .target(name: "MuluCore"),
        // Vision/CoreGraphics OCR of printed TOC pages and page-number offset detection
        // (macOS only). Linked into the CLI; MuluCore stays framework-free.
        .target(name: "MuluOCR"),
        .executableTarget(name: "mulu", dependencies: ["MuluCore", "MuluOCR"]),
        .testTarget(name: "MuluCoreTests", dependencies: ["MuluCore"]),
        .testTarget(name: "MuluOCRTests", dependencies: ["MuluOCR"]),
    ]
)
