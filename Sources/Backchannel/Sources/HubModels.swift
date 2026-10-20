import Foundation

/// One repository on the Hugging Face Hub that ships MLX weights, as the Hub's search reports it.
/// The same shape serves both roles; whether a repo can fill a role is decided by its `model_type`
/// against the architectures the linked loader knows.
struct HubModel: Identifiable, Hashable, Sendable, Codable {
    enum Role: String, Sendable {
        case embedding, chat

        /// Hub pipeline tags that hold models for this role. Two tags cannot share one request.
        var pipelineTags: [String] {
            switch self {
            case .embedding: ["feature-extraction", "sentence-similarity"]
            case .chat: ["text-generation"]
            }
        }
    }

    /// Repo id, e.g. "mlx-community/gemma-4-e2b-it-4bit".
    let id: String
    /// `config.model_type` on the Hub; nil when the repo has no config.
    let modelType: String?
    /// Parameter count from the safetensors index; nil when the Hub has not computed it.
    let parameters: Int64?
    let downloads: Int

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    var owner: String { id.split(separator: "/").dropLast().joined(separator: "/") }

    func isSupported(for role: Role) -> Bool {
        guard let modelType else { return false }
        return Self.supportedTypes[role]?.contains(modelType) ?? false
    }

    /// Architectures each loader can build, from mlx-swift-lm 3.32.3: `EmbedderTypeRegistry` and `LLMTypeRegistry`.
    static let supportedTypes: [Role: Set<String>] = [
        .embedding: ["bert", "roberta", "xlm-roberta", "distilbert", "nomic_bert", "qwen3", "lfm2", "gemma3", "gemma3_text", "gemma3n"],
        .chat: ["mistral", "mixtral", "llama", "phi", "phi3", "phimoe", "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
                "gemma4", "gemma4_unified", "gemma4_text", "qwen2", "qwen3", "qwen3_moe", "qwen3_next", "qwen3_5", "qwen3_5_moe",
                "qwen3_5_text", "nanbeige", "minicpm", "starcoder2", "cohere", "openelm", "internlm2", "deepseek_v2", "deepseek_v3",
                "granite", "helium", "granitemoehybrid", "mimo", "mimo_v2_flash", "minimax", "glm4", "glm4_moe", "glm4_moe_lite",
                "acereason", "falcon_h1", "bitnet", "smollm3", "ernie4_5", "lfm2", "baichuan_m1", "exaone4", "gpt_oss", "olmoe",
                "olmo2", "olmo3", "bailing_moe", "lfm2_moe", "nanochat", "nemotron_h", "afmoe", "jamba", "mamba2", "mistral3",
                "apertus", "hunyuan_v1_dense", "nemotron_labs_diffusion"],
    ]

    /// "0.6B" or "300M"; nil when unknown.
    var parametersText: String? {
        guard let parameters else { return nil }
        if parameters >= 1_000_000_000 { return String(format: "%.1fB", Double(parameters) / 1e9).replacingOccurrences(of: ".0B", with: "B") }
        return "\(parameters / 1_000_000)M"
    }

    /// One line for a row: "mlx-community · gemma3_text · 300M · 12K downloads".
    var detail: String {
        var parts = [owner]
        if let modelType { parts.append(modelType) }
        if let parametersText { parts.append(parametersText) }
        parts.append("\(downloads.formatted(.number.notation(.compactName))) downloads")
        return parts.joined(separator: " · ")
    }

    /// The chat model the app ships with as its default on-device choice.
    static let gemma4 = HubModel(id: "mlx-community/gemma-4-e2b-it-4bit", modelType: "gemma4", parameters: 5_100_000_000, downloads: 0)
}

/// Search of the Hub's model list, limited to repos tagged `mlx`, most downloaded first.
enum HubSearch {
    static func search(_ query: String, role: HubModel.Role) async throws -> [HubModel] {
        var found: [String: HubModel] = [:]
        for tag in role.pipelineTags {
            for model in try await request(query: query, pipelineTag: tag) where found[model.id] == nil {
                found[model.id] = model
            }
        }
        return found.values.sorted { ($0.downloads, $0.id) > ($1.downloads, $1.id) }
    }

    private struct Entry: Decodable {
        struct Config: Decodable { let model_type: String? }
        struct Safetensors: Decodable { let total: Int64? }
        let id: String
        let config: Config?
        let safetensors: Safetensors?
        let downloads: Int?
    }

    private static func request(query: String, pipelineTag: String) async throws -> [HubModel] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            .init(name: "search", value: query), .init(name: "filter", value: "mlx"),
            .init(name: "pipeline_tag", value: pipelineTag), .init(name: "sort", value: "downloads"),
            .init(name: "limit", value: "25"),
            .init(name: "expand[]", value: "config"), .init(name: "expand[]", value: "safetensors"), .init(name: "expand[]", value: "downloads"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelError.http(http.statusCode, "Hub search")
        }
        return try JSONDecoder().decode([Entry].self, from: data).map {
            HubModel(id: $0.id, modelType: $0.config?.model_type, parameters: $0.safetensors?.total, downloads: $0.downloads ?? 0)
        }
    }
}

/// The Hub cache both roles download into: one `models--owner--name/snapshots/<revision>` folder per repo.
enum HubCacheFolder {
    static let directory = Store.appSupport.appendingPathComponent("models/hub", isDirectory: true)

    /// True once a snapshot holds weights. Shards are `model-0000N-of-0000M.safetensors`, single files `model.safetensors`.
    static func isInstalled(_ id: String) -> Bool {
        let snapshots = directory.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--") + "/snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return false }
        return revisions.contains { revision in
            ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.appendingPathComponent(revision).path)) ?? [])
                .contains { $0.hasSuffix(".safetensors") }
        }
    }

    /// Persisted lists of user-added repos, one UserDefaults key per role.
    static func savedModels(for role: HubModel.Role) -> [HubModel] {
        guard let data = UserDefaults.standard.data(forKey: key(role)) else { return [] }
        return (try? JSONDecoder().decode([HubModel].self, from: data)) ?? []
    }

    static func save(_ models: [HubModel], for role: HubModel.Role) {
        UserDefaults.standard.set(try? JSONEncoder().encode(models), forKey: key(role))
    }

    private static func key(_ role: HubModel.Role) -> String { "hub\(role == .chat ? "Chat" : "Embedding")Models" }
}
