// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileDen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileDenCore", targets: ["FileDenCore"]),
        .library(name: "FileDenUI", targets: ["FileDenUI"]),
        .executable(name: "FileDen", targets: ["FileDen"]),
    ],
    targets: [
        .target(
            name: "FileDenCore",
            path: "Sources/FileDenCore"
        ),
        .target(
            name: "FileDenUI",
            dependencies: ["FileDenCore"],
            path: "Sources/FileDenUI",
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "FileDen",
            dependencies: ["FileDenCore", "FileDenUI"],
            path: "Sources/FileDen"
        ),
    ]
)
