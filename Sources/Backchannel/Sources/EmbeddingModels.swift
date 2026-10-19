import Foundation
import Observation

/// An EmbeddingGemma model the user can pick in onboarding. Add a catalog entry when a newer version
/// ships; the picker, downloader and `Embedders.make` work from this description.
struct EmbeddingModel: Identifiable, Hashable, Sendable {
    struct RemoteFile: Hashable, Sendable {
        /// Path relative to `directory`, e.g. "text-q8/model.safetensors".
        let name: String
        let url: URL
        let bytes: Int64
    }

    let id: String
    let name: String
    let summary: String
    let dimension: Int
    /// Folder under Application Support/Backchannel/models shared by variants of one model version.
    let folder: String
    let files: [RemoteFile]
    /// Subfolder holding the text encoder weights.
    let textSubfolder: String
    /// Subfolder holding the vision encoder weights; nil for text-only variants.
    let visionSubfolder: String?
    /// False when this build cannot run the model (MLX not compiled in).
    let isSupported: Bool

    var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var directory: URL { Store.appSupport.appendingPathComponent("models/\(folder)", isDirectory: true) }
    var textDirectory: URL { directory.appendingPathComponent(textSubfolder, isDirectory: true) }
    var visionDirectory: URL? { visionSubfolder.map { directory.appendingPathComponent($0, isDirectory: true) } }
    var hasVision: Bool { visionSubfolder != nil }

    var isInstalled: Bool {
        let fm = FileManager.default
        return files.allSatisfy { f in
            (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(f.name).path)[.size] as? Int64) == f.bytes
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
    private static var mlxSupported: Bool {
        #if canImport(EmbeddingGemma2)
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
        dimension: 768, folder: "embeddinggemma-2", files: remote(gemma2TextFiles),
        textSubfolder: "text-q8", visionSubfolder: nil, isSupported: mlxSupported)

    static let gemma2MultimodalQ8 = EmbeddingModel(
        id: "embeddinggemma-2-text-vision-q8", name: "EmbeddingGemma 2 · text + vision",
        summary: "Same text model plus the vision encoder, so images and PDF scans are embedded by what they show, not only their text. 514 MB download (shares the text weights).",
        dimension: 768, folder: "embeddinggemma-2", files: remote(gemma2TextFiles + gemma2VisionFiles),
        textSubfolder: "text-q8", visionSubfolder: "vision-q8", isSupported: mlxSupported)

    static let catalog: [EmbeddingModel] = [gemma2MultimodalQ8, gemma2TextQ8]
}

/// The user's model choice and downloads. The choice persists in UserDefaults; weights live on disk.
@MainActor
@Observable
final class ModelManager {
    private static let key = "embeddingModelID"

    private(set) var selected: EmbeddingModel
    /// True until a chosen model is installed, so the picker opens on launch.
    let needsOnboarding: Bool
    private(set) var downloading: EmbeddingModel.ID?
    private(set) var progress: Double = 0
    var error: String?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        let chosen = EmbeddingModel.catalog.first { $0.id == saved } ?? EmbeddingModel.catalog[0]
        selected = chosen
        needsOnboarding = !(chosen.isSupported && chosen.isInstalled)
    }

    func select(_ model: EmbeddingModel) {
        guard model.isSupported, model.isInstalled else { return }
        selected = model
        UserDefaults.standard.set(model.id, forKey: Self.key)
    }

    func download(_ model: EmbeddingModel) {
        guard downloading == nil, !model.isInstalled else { return }
        downloading = model.id; progress = 0; error = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Self.fetch(model) { p in Task { @MainActor in self?.progress = p } }
            } catch {
                await MainActor.run { self?.error = "\(model.name): \(error.localizedDescription)" }
            }
            await MainActor.run { self?.downloading = nil }
        }
    }

    private nonisolated static func fetch(_ model: EmbeddingModel, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        let total = Double(model.downloadBytes)
        var done: Int64 = 0
        for file in model.files {
            let dest = model.directory.appendingPathComponent(file.name)
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
