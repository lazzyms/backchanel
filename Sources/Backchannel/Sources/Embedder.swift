import Foundation
#if canImport(EmbeddingGemma2)
import EmbeddingGemma2
#endif

enum EmbeddingTaskKind { case document, query }

protocol Embedder: Sendable {
    var name: String { get }
    /// True when `embedImage` can produce a vector from pixels.
    var supportsImages: Bool { get }
    func embed(_ texts: [String], task: EmbeddingTaskKind) async throws -> [[Float]]
    /// An image embedding in the same space as text. Nil when this embedder has no vision encoder.
    func embedImage(at url: URL) async throws -> [Float]?
}

#if canImport(EmbeddingGemma2)
/// EmbeddingGemma 2 (8-bit MLX weights) running on the GPU via MLX Swift. 768-dim normalized vectors.
actor GemmaEmbedder: Embedder {
    nonisolated let name: String
    nonisolated let supportsImages: Bool
    private let textDirectory: URL
    private let visionDirectory: URL?
    private var encoder: TextEncoder?

    init(model: EmbeddingModel) {
        name = model.name
        textDirectory = model.textDirectory
        visionDirectory = model.visionDirectory
        supportsImages = model.hasVision
    }

    private func loaded() async throws -> TextEncoder {
        if let encoder { return encoder }
        let e = try await TextEncoder(directory: textDirectory)
        if let visionDirectory { try await e.enableVision(directory: visionDirectory) }
        encoder = e
        return e
    }

    func embed(_ texts: [String], task: EmbeddingTaskKind) async throws -> [[Float]] {
        let e = try await loaded()
        return try await e.encode(texts, task: task == .query ? .search : .document)
    }

    func embedImage(at url: URL) async throws -> [Float]? {
        guard supportsImages else { return nil }
        return try await loaded().encodeImage(url: url)
    }
}
#endif

enum EmbedderError: Error, LocalizedError {
    case notInstalled
    var errorDescription: String? { "No embedding model is installed. Choose one under Models…" }
}

enum Embedders {
    /// Nil when the chosen model is not installed or this build cannot run it.
    static func make(for model: EmbeddingModel) -> (any Embedder)? {
        #if canImport(EmbeddingGemma2)
        if model.isSupported, model.isInstalled { return GemmaEmbedder(model: model) }
        #endif
        return nil
    }
}
