// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Tests are kept local-only (Tests/ is gitignored), so include each test
// target only when it's actually present — a fresh clone without them still
// builds.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasAITests   = FileManager.default.fileExists(
    atPath: repoRoot.appendingPathComponent("Tests/FileMasterAITests").path)
let hasCoreTests = FileManager.default.fileExists(
    atPath: repoRoot.appendingPathComponent("Tests/FileMasterCoreTests").path)

var targets: [Target] = [
        .target(
            name: "FileMasterCore",
            path: "Sources/FileMasterCore"
        ),
        // On-device RAG engine: extraction, chunking, embeddings, vector + lexical
        // search, retrieval, generation. Pure logic — no AppKit/SwiftUI. Apple
        // system frameworks only. FoundationModels (M2) is weak-linked here so the
        // app still launches on macOS < 26 / non-Apple-Intelligence Macs.
        .target(
            name: "FileMasterAI",
            dependencies: ["FileMasterCore"],
            path: "Sources/FileMasterAI",
            swiftSettings: [
                // Opt into the current CBLAS headers so Accelerate calls aren't
                // flagged deprecated. We use the 32-bit (LP64) interface.
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"]),
            ],
            linkerSettings: [
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Accelerate"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedLibrary("sqlite3"),
                // FoundationModels (the on-device LLM) is macOS 26+ only. Weak-link
                // it so the binary still loads on macOS 14–25 / non-Apple-Intelligence
                // Macs; all uses are guarded by `if #available(macOS 26, *)`.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .target(
            name: "FileMasterUI",
            dependencies: [
                "FileMasterCore",
                "FileMasterAI",
                // Shared UX layer — settings popover shell and menu-bar host live
                // here so every app we ship matches pixel-for-pixel.
                .product(name: "iUX-MacOS", package: "iUX-MacOS"),
            ],
            path: "Sources/FileMasterUI",
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SceneKit"),
            ]
        ),
        .executableTarget(
            name: "FileMaster",
            dependencies: ["FileMasterCore", "FileMasterAI", "FileMasterUI"],
            path: "Sources/FileMaster"
        ),
]

if hasAITests {
    targets.append(
        .testTarget(
            name: "FileMasterAITests",
            dependencies: ["FileMasterAI"],
            path: "Tests/FileMasterAITests"
        )
    )
}

if hasCoreTests {
    targets.append(
        .testTarget(
            name: "FileMasterCoreTests",
            dependencies: ["FileMasterCore"],
            path: "Tests/FileMasterCoreTests"
        )
    )
}

let package = Package(
    name: "FileMaster",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileMasterCore", targets: ["FileMasterCore"]),
        .library(name: "FileMasterAI", targets: ["FileMasterAI"]),
        .library(name: "FileMasterUI", targets: ["FileMasterUI"]),
        .executable(name: "FileMaster", targets: ["FileMaster"]),
    ],
    dependencies: [
        // Shared UX layer — settings popover, menu-bar host, overlay windows.
        // Local path so the two packages can iterate in lock-step.
        .package(path: "../iUX-MacOS"),
    ],
    targets: targets
)
