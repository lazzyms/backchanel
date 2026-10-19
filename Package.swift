// swift-tools-version: 6.3
import PackageDescription
import Foundation

// EmbeddingGemma 2 and Gemma 4 run on MLX, whose Metal shaders need Xcode's Metal Toolchain
// (`xcodebuild -downloadComponent MetalToolchain`). Set BACKCHANNEL_NO_MLX=1 to build without it;
// the app then cannot embed sources or run Gemma chat (the pickers show those as "Not in this build").
let withMLX = ProcessInfo.processInfo.environment["BACKCHANNEL_NO_MLX"] == nil

var dependencies: [Package.Dependency] = [
    // Speaker diarization (Core ML). No traits: skips the NeMo text-normalisation binary we never use.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
]
var products: [Target.Dependency] = [
    .product(name: "FluidAudio", package: "FluidAudio"),
]

if withMLX {
    dependencies += [
        .package(url: "https://github.com/Obscyra-app/EmbeddingGemma2Swift.git", from: "0.1.0"),
        // Gemma 4 chat on the GPU; pinned to the release that shares mlx-swift 0.32.3 with EmbeddingGemma2Swift.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        // Already pulled in by the two above; listed so the app can import the Hub downloader and tokenizer.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.13.0"),
    ]
    products += [
        .product(name: "EmbeddingGemma2", package: "EmbeddingGemma2Swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
    ]
}

let package = Package(
    name: "Backchannel",
    platforms: [.macOS("27.0")],
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "Backchannel",
            dependencies: products,
            path: "Sources/Backchannel",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
