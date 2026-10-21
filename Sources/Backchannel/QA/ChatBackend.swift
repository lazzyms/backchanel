import Foundation
import FoundationModels
import Observation
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

/// Where chat answers and meeting summaries come from. Retrieval is the same for all three.
enum ChatBackendKind: String, CaseIterable, Identifiable, Sendable {
    case apple, mlx, endpoint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .mlx: "Hugging Face model (on device)"
        case .endpoint: "Your own model (API)"
        }
    }

    /// Builds before the Hub search stored the on-device choice as "gemma".
    init(saved: String?) {
        self = saved == "gemma" ? .mlx : ChatBackendKind(rawValue: saved ?? "") ?? .apple
    }
}

/// A multi-turn conversation with one backend. The system instructions are fixed at creation.
protocol ChatConversation: AnyObject, Sendable {
    func send(_ prompt: String) async throws -> String
}

enum ChatBackendError: Error, LocalizedError {
    case unavailable(String), http(Int, String), badReply, notBuilt
    var errorDescription: String? {
        switch self {
        case .unavailable(let why): why
        case .http(let code, let body): "The endpoint answered HTTP \(code): \(body.prefix(300))"
        case .badReply: "The endpoint's reply was not an OpenAI-style chat completion."
        case .notBuilt: "This build was made without MLX, so on-device models cannot run. Pick another chat model."
        }
    }
}

// MARK: Apple Intelligence

actor AppleConversation: ChatConversation {
    private let instructions: String
    private var session: LanguageModelSession?

    init(instructions: String) { self.instructions = instructions }

    /// Keeps the multi-turn session; starts a fresh one when the context window fills up.
    func send(_ prompt: String) async throws -> String {
        if session == nil { session = LanguageModelSession(instructions: instructions) }
        do {
            return try await session!.respond(to: prompt).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            session = LanguageModelSession(instructions: instructions)
            return try await session!.respond(to: prompt).content
        }
    }
}

// MARK: OpenAI-compatible endpoint (Ollama, LM Studio, llama.cpp, OpenAI, OpenRouter…)

struct EndpointConfig: Sendable, Equatable {
    var baseURL: String
    var model: String
    /// Nil for local servers that need no key.
    var apiKey: String?

    var chatURL: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/chat/completions")
    }
}

actor EndpointConversation: ChatConversation {
    private let config: EndpointConfig
    private var messages: [[String: String]]

    init(config: EndpointConfig, instructions: String) {
        self.config = config
        messages = [["role": "system", "content": instructions]]
    }

    func send(_ prompt: String) async throws -> String {
        messages.append(["role": "user", "content": prompt])
        let reply = try await Self.complete(config: config, messages: messages)
        messages.append(["role": "assistant", "content": reply])
        // Keep the request bounded: the system prompt plus the last few exchanges.
        if messages.count > 13 { messages.removeSubrange(1..<(messages.count - 12)) }
        return reply
    }

    static func complete(config: EndpointConfig, messages: [[String: String]]) async throws -> String {
        guard let url = config.chatURL else { throw ChatBackendError.unavailable("The endpoint URL is not valid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.model, "messages": messages, "stream": false])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatBackendError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else { throw ChatBackendError.badReply }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Hub models on MLX

#if canImport(MLXLLM)
/// The one loaded on-device chat model, shared by every conversation. Weights come from the Hugging
/// Face Hub into the shared Hub cache and stay there. Switching repos drops the previous weights.
actor MLXChatModel {
    static let shared = MLXChatModel()

    private var loaded: (id: String, container: ModelContainer)?

    func load(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ModelContainer {
        if let loaded, loaded.id == id { return loaded.container }
        loaded = nil
        let hub = HubClient(cache: HubCache(cacheDirectory: HubCacheFolder.directory))
        // Registered ids keep their extra EOS tokens (Gemma 4's "<turn|>"); any other repo gets a plain configuration.
        let container = try await loadModelContainer(
            from: #hubDownloader(hub), using: #huggingFaceTokenizerLoader(),
            configuration: LLMModelFactory.shared.configuration(id: id)) { p in progress(p.fractionCompleted) }
        loaded = (id, container)
        return container
    }
}

actor MLXConversation: ChatConversation {
    /// MLX's session is not Sendable; this actor is its only user, one request at a time.
    private final class Box: @unchecked Sendable { let session: MLXLMCommon.ChatSession; init(_ s: MLXLMCommon.ChatSession) { session = s } }
    private let modelID: String
    private let instructions: String
    private var box: Box?

    init(modelID: String, instructions: String) { self.modelID = modelID; self.instructions = instructions }

    func send(_ prompt: String) async throws -> String {
        if box == nil {
            let model = try await MLXChatModel.shared.load(modelID) { _ in }
            box = Box(MLXLMCommon.ChatSession(model, instructions: instructions,
                                              generateParameters: GenerateParameters(maxTokens: 1200, temperature: 0.3)))
        }
        let reply = try await box!.session.respond(to: prompt)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

// MARK: Choice and settings

/// The user's chat-model choice, the on-device repos they added from the Hub, and endpoint settings.
/// All of it persists in UserDefaults except the API key, which only ever lives in the Keychain.
@MainActor
@Observable
final class ChatModelManager {
    private static let kindKey = "chatBackend", mlxKey = "mlxModelID", urlKey = "endpointURL", modelKey = "endpointModel", keyAccount = "endpoint-api-key"

    var kind: ChatBackendKind { didSet { UserDefaults.standard.set(kind.rawValue, forKey: Self.kindKey) } }
    /// Repo id of the on-device model; always one of `mlxModels`.
    var mlxModelID: String { didSet { UserDefaults.standard.set(mlxModelID, forKey: Self.mlxKey) } }
    /// Gemma 4 plus whatever the user added from the Hub search.
    private(set) var mlxModels: [HubModel] { didSet { HubCacheFolder.save(mlxModels, for: .chat) } }
    var endpointURL: String { didSet { UserDefaults.standard.set(endpointURL, forKey: Self.urlKey) } }
    var endpointModel: String { didSet { UserDefaults.standard.set(endpointModel, forKey: Self.modelKey) } }
    /// Mirrors the Keychain item; never written anywhere else.
    var apiKey: String { didSet { Keychain.write(apiKey, account: Self.keyAccount) } }

    /// Repo ids whose weights are in the Hub cache.
    private(set) var installed: Set<String>
    private(set) var downloading: String?
    private(set) var progress: Double = 0
    var error: String?

    static var mlxSupported: Bool {
        #if canImport(MLXLLM)
        true
        #else
        false
        #endif
    }

    init() {
        let d = UserDefaults.standard
        kind = ChatBackendKind(saved: d.string(forKey: Self.kindKey))
        let saved = HubCacheFolder.savedModels(for: .chat)
        let models = saved.contains { $0.id == HubModel.gemma4.id } ? saved : [HubModel.gemma4] + saved
        mlxModels = models
        mlxModelID = d.string(forKey: Self.mlxKey) ?? HubModel.gemma4.id
        endpointURL = d.string(forKey: Self.urlKey) ?? "http://localhost:11434/v1"
        endpointModel = d.string(forKey: Self.modelKey) ?? ""
        apiKey = Keychain.read(Self.keyAccount) ?? ""
        installed = Set(models.map(\.id).filter(HubCacheFolder.isInstalled))
    }

    var mlxModel: HubModel? { mlxModels.first { $0.id == mlxModelID } }
    var mlxInstalled: Bool { installed.contains(mlxModelID) }

    func addMLXModel(_ model: HubModel) {
        guard !mlxModels.contains(where: { $0.id == model.id }) else { return }
        mlxModels.append(model)
        if HubCacheFolder.isInstalled(model.id) { installed.insert(model.id) }
    }

    /// The weights stay in the Hub cache; only the row goes. Gemma 4 stays and takes over when the removed model was in use.
    func removeMLXModel(_ model: HubModel) {
        guard model.id != HubModel.gemma4.id else { return }
        mlxModels.removeAll { $0.id == model.id }
        if mlxModelID == model.id { mlxModelID = HubModel.gemma4.id }
    }

    var endpoint: EndpointConfig { EndpointConfig(baseURL: endpointURL, model: endpointModel, apiKey: apiKey.isEmpty ? nil : apiKey) }

    /// Why the chosen backend cannot answer right now, or nil when it can.
    var availability: String? {
        switch kind {
        case .apple: return OnDeviceLM.availability
        case .mlx:
            if !Self.mlxSupported { return ChatBackendError.notBuilt.localizedDescription }
            guard let mlxModel else { return "Pick an on-device model under Settings › Chat." }
            if !mlxModel.isSupported(for: .chat) { return "\(mlxModel.name) is a \(mlxModel.modelType ?? "unknown") model, which this app cannot run. Pick another under Settings › Chat." }
            return mlxInstalled ? nil : "\(mlxModel.name) is not downloaded yet. Download it under Settings › Chat."
        case .endpoint:
            if endpoint.chatURL == nil { return "Enter the endpoint URL under Settings › Chat." }
            if endpointModel.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the model name under Settings › Chat." }
            return nil
        }
    }
    var isAvailable: Bool { availability == nil }

    /// Short label for the UI, e.g. "gemma-4-e2b-it-4bit" or "llama3.2 via localhost".
    var displayName: String {
        switch kind {
        case .apple: "Apple Intelligence"
        case .mlx: mlxModel?.name ?? "an on-device model"
        case .endpoint: endpointModel.isEmpty ? "your endpoint" : "\(endpointModel) via \(URL(string: endpointURL)?.host() ?? "endpoint")"
        }
    }

    func makeConversation(instructions: String) throws -> any ChatConversation {
        if let availability { throw ChatBackendError.unavailable(availability) }
        switch kind {
        case .apple: return AppleConversation(instructions: instructions)
        case .endpoint: return EndpointConversation(config: endpoint, instructions: instructions)
        case .mlx:
            #if canImport(MLXLLM)
            return MLXConversation(modelID: mlxModelID, instructions: instructions)
            #else
            throw ChatBackendError.notBuilt
            #endif
        }
    }

    /// One prompt, one answer, no history.
    func respond(instructions: String, prompt: String) async throws -> String {
        try await makeConversation(instructions: instructions).send(prompt)
    }

    /// Downloads and loads the repo once; loading is the proof that this build can run it.
    func download(_ model: HubModel) {
        #if canImport(MLXLLM)
        guard downloading == nil else { return }
        downloading = model.id; progress = 0; error = nil
        Task {
            do {
                _ = try await MLXChatModel.shared.load(model.id) { p in Task { @MainActor in self.progress = p } }
                installed.insert(model.id)
            } catch {
                self.error = "\(model.name): \(error.localizedDescription)"
            }
            downloading = nil
        }
        #endif
    }

    /// Sends a one-word prompt to the endpoint and reports what came back.
    func testEndpoint() async -> String {
        do {
            let reply = try await EndpointConversation.complete(config: endpoint, messages: [["role": "user", "content": "Reply with the single word OK."]])
            return "Reply: " + reply.prefix(80)
        } catch let error as ChatBackendError {
            return error.localizedDescription
        } catch {
            let where_ = endpoint.chatURL?.absoluteString ?? endpoint.baseURL
            return "\(error.localizedDescription) Tried \(where_). Check that the server is running and the base URL ends at the API root (for Ollama, http://localhost:11434/v1)."
        }
    }
}
