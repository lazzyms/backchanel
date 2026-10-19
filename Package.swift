// swift-tools-version: 6.3
import PackageDescription
import Foundation

// EmbeddingGemma 2 runs on MLX, whose Metal shaders need Xcode's Metal Toolchain
// (`xcodebuild -downloadComponent MetalToolchain`). Set FORESIGHT_NO_MLX=1 to build without it;
// the app then cannot embed sources (the picker shows the models as "Not in this build").
let withMLX = ProcessInfo.processInfo.environment["FORESIGHT_NO_MLX"] == nil

let package = Package(
    name: "Foresight",
    platforms: [.macOS("27.0")],
    dependencies: withMLX ? [
        .package(url: "https://github.com/Obscyra-app/EmbeddingGemma2Swift.git", from: "0.1.0"),
    ] : [],
    targets: [
        .executableTarget(
            name: "Foresight",
            dependencies: withMLX ? [
                .product(name: "EmbeddingGemma2", package: "EmbeddingGemma2Swift"),
            ] : [],
            path: "Sources/Foresight",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
            ]
        ),
    ]
)
