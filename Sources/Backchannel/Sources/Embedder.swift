import Foundation
#if canImport(EmbeddingGemma2)
import EmbeddingGemma2
#endif
#if canImport(MLXEmbedders)
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
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

    init(name: String, textDirectory: URL, visionDirectory: URL?) {
        self.name = name
        self.textDirectory = textDirectory
        self.visionDirectory = visionDirectory
        supportsImages = visionDirectory != nil
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

#if canImport(MLXEmbedders)
/// Any embedding repo from the Hub whose architecture MLXEmbedders knows, running on the GPU.
/// Pooling comes from the repo's `1_Pooling/config.json`; vectors are normalized. Text only.
actor HubEmbedder: Embedder {
    nonisolated let name: String
    nonisolated let supportsImages = false
    private let model: HubModel
    private var container: EmbedderModelContainer?

    init(model: HubModel) {
        self.model = model
        name = model.name
    }

    static func load(_ model: HubModel, progress: @escaping @Sendable (Double) -> Void) async throws -> EmbedderModelContainer {
        let hub = HubClient(cache: HubCache(cacheDirectory: HubCacheFolder.directory))
        return try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(hub), using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: model.id)) { p in progress(p.fractionCompleted) }
    }

    /// Prompt prefixes these families were trained with, matched on the repo name. Other repos get none.
    private static let prefixes: [(family: String, query: String, document: String)] = [
        ("nomic", "search_query: ", "search_document: "),
        ("embeddinggemma", "task: search result | query: ", "title: none | text: "),
        ("qwen3-embedding", "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: ", ""),
        ("e5", "query: ", "passage: "),
    ]

    func embed(_ texts: [String], task: EmbeddingTaskKind) async throws -> [[Float]] {
        if container == nil { container = try await Self.load(model) { _ in } }
        let family = Self.prefixes.first { model.name.lowercased().contains($0.family) }
        let prefix = (task == .query ? family?.query : family?.document) ?? ""
        let prefixed = texts.map { prefix + $0 }
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: prefixed.count, by: 8) {
            let batch = Array(prefixed[start..<min(start + 8, prefixed.count)])
            vectors += await container!.perform { context in Self.encode(batch, in: context) }
        }
        return vectors
    }

    func embedImage(at url: URL) async throws -> [Float]? { nil }

    /// Pads to the longest text and masks the padding, so the pad id never reaches the pooled vector.
    private static func encode(_ texts: [String], in context: EmbedderModelContext) -> [[Float]] {
        let limit = min(context.model.maxPositionEmbeddings ?? 2048, 2048)
        let tokens = texts.map { Array(context.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(limit)) }
        let length = max(tokens.map(\.count).max() ?? 1, 1)
        let pad = Int32(context.tokenizer.eosTokenId ?? 0)
        var ids: [Int32] = [], keep: [Int32] = []
        for t in tokens {
            ids += t.map(Int32.init) + Array(repeating: pad, count: length - t.count)
            keep += Array(repeating: 1, count: t.count) + Array(repeating: 0, count: length - t.count)
        }
        let shape = [texts.count, length]
        let input = MLXArray(ids, shape)
        let mask = MLXArray(keep, shape) .!= 0
        let output = context.model(input, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: input), attentionMask: mask)
        let result = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: true)
        result.eval()
        return result.map { $0.asArray(Float.self) }
    }
}
#endif

enum EmbedderError: Error, LocalizedError {
    case notInstalled
    var errorDescription: String? { "No embedding model is installed. Choose one under Settings › Embedding." }
}

enum Embedders {
    /// Nil when the chosen model is not installed or this build cannot run it.
    static func make(for model: EmbeddingModel) -> (any Embedder)? {
        guard model.isSupported, model.isInstalled else { return nil }
        switch model.weights {
        case .bundled:
            #if canImport(EmbeddingGemma2)
            if let dirs = model.bundledDirectories { return GemmaEmbedder(name: model.name, textDirectory: dirs.text, visionDirectory: dirs.vision) }
            #endif
        case .hub(let hub):
            #if canImport(MLXEmbedders)
            return HubEmbedder(model: hub)
            #else
            _ = hub
            #endif
        }
        return nil
    }

    /// Downloads a Hub repo and loads it once; loading is the proof that this build can run it.
    static func fetch(_ model: HubModel, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        #if canImport(MLXEmbedders)
        _ = try await HubEmbedder.load(model, progress: onProgress)
        #else
        throw EmbedderError.notInstalled
        #endif
    }
}
