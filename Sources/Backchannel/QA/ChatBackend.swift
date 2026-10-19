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
    case apple, gemma, endpoint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .gemma: "Gemma 4 E2B (on device)"
        case .endpoint: "Your own model (API)"
        }
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
        case .notBuilt: "This build was made without MLX, so Gemma cannot run. Pick another chat model."
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

// MARK: Gemma 4 on MLX

#if canImport(MLXLLM)
/// One loaded Gemma 4 E2B (4-bit) shared by every conversation. Weights come from the Hugging Face
/// Hub into Application Support/Backchannel/models/hub and stay there.
actor GemmaModel {
    static let shared = GemmaModel()
    static let configuration = LLMRegistry.gemma4_e2b_it_4bit
    static let hubDirectory = Store.appSupport.appendingPathComponent("models/hub", isDirectory: true)

    private var container: ModelContainer?

    /// True once the weights are on disk (the Hub cache keeps one snapshot folder per revision).
    nonisolated static var isInstalled: Bool {
        let repo = hubDirectory.appendingPathComponent("models--" + Self.configuration.name.replacingOccurrences(of: "/", with: "--") + "/snapshots")
        guard let snapshots = try? FileManager.default.contentsOfDirectory(atPath: repo.path) else { return false }
        return snapshots.contains { FileManager.default.fileExists(atPath: repo.appendingPathComponent("\($0)/model.safetensors").path) }
    }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws -> ModelContainer {
        if let container { return container }
        let hub = HubClient(cache: HubCache(cacheDirectory: Self.hubDirectory))
        let loaded = try await loadModelContainer(
            from: #hubDownloader(hub), using: #huggingFaceTokenizerLoader(),
            configuration: Self.configuration) { p in progress(p.fractionCompleted) }
        container = loaded
        return loaded
    }
}

actor GemmaConversation: ChatConversation {
    /// MLX's session is not Sendable; this actor is its only user, one request at a time.
    private final class Box: @unchecked Sendable { let session: MLXLMCommon.ChatSession; init(_ s: MLXLMCommon.ChatSession) { session = s } }
    private let instructions: String
    private var box: Box?

    init(instructions: String) { self.instructions = instructions }

    func send(_ prompt: String) async throws -> String {
        if box == nil {
            let model = try await GemmaModel.shared.load { _ in }
            box = Box(MLXLMCommon.ChatSession(model, instructions: instructions,
                                              generateParameters: GenerateParameters(maxTokens: 1200, temperature: 0.3)))
        }
        let reply = try await box!.session.respond(to: prompt)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

// MARK: Choice and settings

/// The user's chat-model choice and endpoint settings. Backend and endpoint fields persist in
/// UserDefaults; the API key only ever lives in the Keychain.
@MainActor
@Observable
final class ChatModelManager {
    private static let kindKey = "chatBackend", urlKey = "endpointURL", modelKey = "endpointModel", keyAccount = "endpoint-api-key"

    var kind: ChatBackendKind { didSet { UserDefaults.standard.set(kind.rawValue, forKey: Self.kindKey) } }
    var endpointURL: String { didSet { UserDefaults.standard.set(endpointURL, forKey: Self.urlKey) } }
    var endpointModel: String { didSet { UserDefaults.standard.set(endpointModel, forKey: Self.modelKey) } }
    /// Mirrors the Keychain item; never written anywhere else.
    var apiKey: String { didSet { Keychain.write(apiKey, account: Self.keyAccount) } }

    private(set) var gemmaInstalled: Bool
    private(set) var downloadingGemma = false
    private(set) var gemmaProgress: Double = 0
    var error: String?

    static var gemmaSupported: Bool {
        #if canImport(MLXLLM)
        true
        #else
        false
        #endif
    }

    init() {
        let d = UserDefaults.standard
        kind = ChatBackendKind(rawValue: d.string(forKey: Self.kindKey) ?? "") ?? .apple
        endpointURL = d.string(forKey: Self.urlKey) ?? "http://localhost:11434/v1"
        endpointModel = d.string(forKey: Self.modelKey) ?? ""
        apiKey = Keychain.read(Self.keyAccount) ?? ""
        #if canImport(MLXLLM)
        gemmaInstalled = GemmaModel.isInstalled
        #else
        gemmaInstalled = false
        #endif
    }

    var endpoint: EndpointConfig { EndpointConfig(baseURL: endpointURL, model: endpointModel, apiKey: apiKey.isEmpty ? nil : apiKey) }

    /// Why the chosen backend cannot answer right now, or nil when it can.
    var availability: String? {
        switch kind {
        case .apple: return OnDeviceLM.availability
        case .gemma:
            if !Self.gemmaSupported { return ChatBackendError.notBuilt.localizedDescription }
            return gemmaInstalled ? nil : "Gemma 4 is not downloaded yet. Download it under Settings › Chat."
        case .endpoint:
            if endpoint.chatURL == nil { return "Enter the endpoint URL under Settings › Chat." }
            if endpointModel.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the model name under Settings › Chat." }
            return nil
        }
    }
    var isAvailable: Bool { availability == nil }

    /// Short label for the UI, e.g. "Gemma 4 E2B" or "llama3.2 via localhost".
    var displayName: String {
        switch kind {
        case .apple: "Apple Intelligence"
        case .gemma: "Gemma 4 E2B"
        case .endpoint: endpointModel.isEmpty ? "your endpoint" : "\(endpointModel) via \(URL(string: endpointURL)?.host() ?? "endpoint")"
        }
    }

    func makeConversation(instructions: String) throws -> any ChatConversation {
        if let availability { throw ChatBackendError.unavailable(availability) }
        switch kind {
        case .apple: return AppleConversation(instructions: instructions)
        case .endpoint: return EndpointConversation(config: endpoint, instructions: instructions)
        case .gemma:
            #if canImport(MLXLLM)
            return GemmaConversation(instructions: instructions)
            #else
            throw ChatBackendError.notBuilt
            #endif
        }
    }

    /// One prompt, one answer, no history.
    func respond(instructions: String, prompt: String) async throws -> String {
        try await makeConversation(instructions: instructions).send(prompt)
    }

    func downloadGemma() {
        #if canImport(MLXLLM)
        guard !downloadingGemma else { return }
        downloadingGemma = true; gemmaProgress = 0; error = nil
        Task {
            do {
                _ = try await GemmaModel.shared.load { p in Task { @MainActor in self.gemmaProgress = p } }
                gemmaInstalled = true
            } catch {
                self.error = "Gemma 4: \(error.localizedDescription)"
            }
            downloadingGemma = false
        }
        #endif
    }

    /// Sends a one-word prompt to the endpoint and reports what came back.
    func testEndpoint() async -> String {
        do {
            let reply = try await EndpointConversation.complete(config: endpoint, messages: [["role": "user", "content": "Reply with the single word OK."]])
            return "Reply: " + reply.prefix(80)
        } catch {
            return error.localizedDescription
        }
    }
}
