import Foundation
import Observation

/// An embedding model the user can pick: one of the two EmbeddingGemma 2 variants the app ships
/// with, or any repo added from the Hugging Face search. The picker, downloader and
/// `Embedders.make` work from this description.
struct EmbeddingModel: Identifiable, Hashable, Sendable {
    struct RemoteFile: Hashable, Sendable {
        /// Path relative to the model folder, e.g. "text-q8/model.safetensors".
        let name: String
        let url: URL
        let bytes: Int64
    }

    /// Where the weights come from and how they sit on disk.
    enum Weights: Hashable, Sendable {
        /// A fixed file list fetched into models/<folder>, in the flat layout EmbeddingGemma2Swift reads.
        case bundled(folder: String, files: [RemoteFile], textSubfolder: String, visionSubfolder: String?)
        /// A repo in the shared Hub cache, loaded by MLXEmbedders.
        case hub(HubModel)
    }

    let id: String
    let name: String
    let summary: String
    let weights: Weights
    /// False when this build cannot run the model (MLX not compiled in, or an architecture MLXEmbedders lacks).
    let isSupported: Bool

    var hub: HubModel? { if case .hub(let m) = weights { m } else { nil } }

    /// Known up front for bundled files only; the Hub reports sizes per file while downloading.
    var downloadBytes: Int64? {
        if case .bundled(_, let files, _, _) = weights { files.reduce(0) { $0 + $1.bytes } } else { nil }
    }

    /// Text encoder folder and, when the variant has one, the vision encoder folder. Nil for Hub repos.
    var bundledDirectories: (text: URL, vision: URL?)? {
        guard case .bundled(let folder, _, let text, let vision) = weights else { return nil }
        let directory = Store.appSupport.appendingPathComponent("models/\(folder)", isDirectory: true)
        return (directory.appendingPathComponent(text, isDirectory: true), vision.map { directory.appendingPathComponent($0, isDirectory: true) })
    }

    var hasVision: Bool { bundledDirectories?.vision != nil }

    var isInstalled: Bool {
        switch weights {
        case .bundled(let folder, let files, _, _):
            let directory = Store.appSupport.appendingPathComponent("models/\(folder)", isDirectory: true)
            return files.allSatisfy { f in
                (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f.name).path)[.size] as? Int64) == f.bytes
            }
        case .hub(let model):
            return HubCacheFolder.isInstalled(model.id)
        }
    }

    // MARK: EmbeddingGemma 2 (8-bit MLX weights from Nurymanau/EmbeddingGemma-2-MLX-Swift)

    private static let gemma2Base = "https://huggingface.co/Nurymanau/EmbeddingGemma-2-MLX-Swift/resolve/main/"
    private static let gemma2TextFiles: [(String, Int64)] = [
        ("text-q8/config.json", 2359), ("text-q8/config_sentence_transformers.json", 1565), ("text-q8/manifest.json", 379),
        ("text-q8/model.safetensors", 288_118_885), ("text-q8/quantization.json", 16288),
        ("text-q8/tokenizer.json", 32_170_510), ("text-q8/tokenizer_config.json", 1599),
    ]
    private static let gemma2VisionFiles: [(String, Int64)] = [
        ("vision-q8/config.json", 3453), ("vision-q8/manifest.json", 380),
        ("vision-q8/quantization.json", 11258), ("vision-q8/vision.safetensors", 193_095_171),
    ]
    private static var gemma2Supported: Bool {
        #if canImport(EmbeddingGemma2)
        true
        #else
        false
        #endif
    }
    private static var hubSupported: Bool {
        #if canImport(MLXEmbedders)
        true
        #else
        false
        #endif
    }
    private static func remote(_ files: [(String, Int64)]) -> [RemoteFile] {
        files.map { .init(name: $0.0, url: URL(string: gemma2Base + $0.0)!, bytes: $0.1) }
    }

    static let gemma2TextQ8 = EmbeddingModel(
        id: "embeddinggemma-2-text-q8", name: "EmbeddingGemma 2 · text",
        summary: "Google's multilingual embedding model on the GPU via MLX. 768 dimensions. Images are embedded from their OCR text. 320 MB download.",
        weights: .bundled(folder: "embeddinggemma-2", files: remote(gemma2TextFiles), textSubfolder: "text-q8", visionSubfolder: nil),
        isSupported: gemma2Supported)

    static let gemma2MultimodalQ8 = EmbeddingModel(
        id: "embeddinggemma-2-text-vision-q8", name: "EmbeddingGemma 2 · text + vision",
        summary: "Same text model plus the vision encoder, so images and PDF scans are embedded by what they show, not only their text. 514 MB download (shares the text weights).",
        weights: .bundled(folder: "embeddinggemma-2", files: remote(gemma2TextFiles + gemma2VisionFiles), textSubfolder: "text-q8", visionSubfolder: "vision-q8"),
        isSupported: gemma2Supported)

    static let catalog: [EmbeddingModel] = [gemma2MultimodalQ8, gemma2TextQ8]

    /// A repo from the Hub search. Text only: images are embedded from their OCR text.
    static func hub(_ model: HubModel) -> EmbeddingModel {
        EmbeddingModel(id: "hub:" + model.id, name: model.name, summary: model.detail + ". Text only; images are embedded from their OCR text.",
                       weights: .hub(model), isSupported: hubSupported && model.isSupported(for: .embedding))
    }
}

/// The user's model choice, the repos they added from the Hub, and downloads. Choice and list
/// persist in UserDefaults; weights live on disk.
@MainActor
@Observable
final class ModelManager {
    private static let key = "embeddingModelID"

    private(set) var selected: EmbeddingModel
    private(set) var hubModels: [HubModel] { didSet { HubCacheFolder.save(hubModels, for: .embedding) } }
    /// True until a chosen model is installed, so the picker opens on launch.
    let needsOnboarding: Bool
    private(set) var downloading: EmbeddingModel.ID?
    private(set) var progress: Double = 0
    var error: String?

    init() {
        let hub = HubCacheFolder.savedModels(for: .embedding)
        hubModels = hub
        let saved = UserDefaults.standard.string(forKey: Self.key)
        let chosen = (EmbeddingModel.catalog + hub.map(EmbeddingModel.hub)).first { $0.id == saved } ?? EmbeddingModel.catalog[0]
        selected = chosen
        needsOnboarding = !(chosen.isSupported && chosen.isInstalled)
    }

    /// The built-in catalog followed by the user's Hub repos.
    var all: [EmbeddingModel] { EmbeddingModel.catalog + hubModels.map(EmbeddingModel.hub) }

    func select(_ model: EmbeddingModel) {
        guard model.isSupported, model.isInstalled else { return }
        selected = model
        UserDefaults.standard.set(model.id, forKey: Self.key)
    }

    func add(hub model: HubModel) {
        guard !hubModels.contains(where: { $0.id == model.id }) else { return }
        hubModels.append(model)
    }

    /// The weights stay in the Hub cache; only the row goes. The model in use cannot be removed.
    func remove(_ model: EmbeddingModel) {
        guard let hub = model.hub, model.id != selected.id else { return }
        hubModels.removeAll { $0.id == hub.id }
    }

    func download(_ model: EmbeddingModel) {
        guard downloading == nil, !model.isInstalled else { return }
        downloading = model.id; progress = 0; error = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let onProgress: @Sendable (Double) -> Void = { p in Task { @MainActor in self?.progress = p } }
                switch model.weights {
                case .bundled: try await Self.fetch(model, onProgress: onProgress)
                case .hub(let hub): try await Embedders.fetch(hub, onProgress: onProgress)
                }
            } catch {
                await MainActor.run { self?.error = "\(model.name): \(error.localizedDescription)" }
            }
            await MainActor.run { self?.downloading = nil }
        }
    }

    private nonisolated static func fetch(_ model: EmbeddingModel, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        guard case .bundled(let folder, let files, _, _) = model.weights else { return }
        let fm = FileManager.default
        let directory = Store.appSupport.appendingPathComponent("models/\(folder)", isDirectory: true)
        let total = Double(model.downloadBytes ?? 1)
        var done: Int64 = 0
        for file in files {
            let dest = directory.appendingPathComponent(file.name)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) == file.bytes {
                done += file.bytes; onProgress(Double(done) / total); continue
            }
            let (bytes, response) = try await URLSession.shared.bytes(from: file.url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ModelError.http(http.statusCode, file.name)
            }
            let part = dest.appendingPathExtension("part")
            fm.createFile(atPath: part.path, contents: nil)
            let handle = try FileHandle(forWritingTo: part)
            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer); done += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true); onProgress(Double(done) / total)
                }
            }
            try handle.write(contentsOf: buffer); done += Int64(buffer.count)
            try handle.close()
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
            onProgress(Double(done) / total)
        }
    }
}

enum ModelError: Error, LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self { case .http(let code, let file): "Download of \(file) failed (HTTP \(code))." }
    }
}
