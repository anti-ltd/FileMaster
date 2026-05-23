// swift-tools-version: 5.10
import PackageDescription
import Foundation

// Tests are kept local-only (Tests/ is gitignored), so include the test target
// only when it's actually present — a fresh clone without it still builds.
let testsPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Tests/FileDenAITests")
let hasTests = FileManager.default.fileExists(atPath: testsPath.path)

var targets: [Target] = [
        .target(
            name: "FileDenCore",
            path: "Sources/FileDenCore"
        ),
        // On-device RAG engine: extraction, chunking, embeddings, vector + lexical
        // search, retrieval, generation. Pure logic — no AppKit/SwiftUI. Apple
        // system frameworks only. FoundationModels (M2) is weak-linked here so the
        // app still launches on macOS < 26 / non-Apple-Intelligence Macs.
        .target(
            name: "FileDenAI",
            dependencies: ["FileDenCore"],
            path: "Sources/FileDenAI",
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
            name: "FileDenUI",
            dependencies: ["FileDenCore", "FileDenAI"],
            path: "Sources/FileDenUI",
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SceneKit"),
            ]
        ),
        .executableTarget(
            name: "FileDen",
            dependencies: ["FileDenCore", "FileDenAI", "FileDenUI"],
            path: "Sources/FileDen"
        ),
]

if hasTests {
    targets.append(
        .testTarget(
            name: "FileDenAITests",
            dependencies: ["FileDenAI"],
            path: "Tests/FileDenAITests"
        )
    )
}

let package = Package(
    name: "FileDen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileDenCore", targets: ["FileDenCore"]),
        .library(name: "FileDenAI", targets: ["FileDenAI"]),
        .library(name: "FileDenUI", targets: ["FileDenUI"]),
        .executable(name: "FileDen", targets: ["FileDen"]),
    ],
    targets: targets
)
