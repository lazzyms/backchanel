import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("Models", systemImage: "cpu") {
                ModelPickerView(models: model.models, mode: .settings) { chosen in
                    Task { await model.library.useModel(chosen) }
                }
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                ChatSettingsView(chat: model.chatModels)
            }
            Tab("Meetings", systemImage: "waveform") {
                MeetingSettingsView(session: model.session)
            }
        }
        .frame(width: 560, height: 480)
    }
}

/// Which model answers chat and writes summaries. Retrieval is the same for all of them.
struct ChatSettingsView: View {
    @Bindable var chat: ChatModelManager
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Picker("Answer with", selection: $chat.kind) {
                ForEach(ChatBackendKind.allCases) { Text($0.title).tag($0) }
            }
            switch chat.kind {
            case .apple:
                LabeledContent("Status", value: OnDeviceLM.availability ?? "Ready")
                Text("Runs on this Mac only. Short context, so long transcripts are summarized in parts.")
                    .font(.caption).foregroundStyle(.secondary)
            case .gemma:
                if !ChatModelManager.gemmaSupported {
                    Text(ChatBackendError.notBuilt.localizedDescription).foregroundStyle(.secondary)
                } else if chat.downloadingGemma {
                    ProgressView("Downloading Gemma 4 E2B (4-bit)…", value: chat.gemmaProgress)
                } else if chat.gemmaInstalled {
                    LabeledContent("Status", value: "Downloaded")
                } else {
                    LabeledContent("Status") {
                        Button("Download (about 3 GB)") { chat.downloadGemma() }
                    }
                }
                Text("Google's Gemma 4 E2B runs on the GPU with MLX. Weights come from the Hugging Face Hub once and stay in Application Support.")
                    .font(.caption).foregroundStyle(.secondary)
            case .endpoint:
                TextField("Base URL", text: $chat.endpointURL, prompt: Text("http://localhost:11434/v1"))
                TextField("Model", text: $chat.endpointModel, prompt: Text("llama3.2, gpt-5-mini…"))
                SecureField("API key (optional)", text: $chat.apiKey)
                LabeledContent("Connection") {
                    HStack {
                        Button(testing ? "Testing…" : "Test") {
                            testing = true
                            Task { testResult = await chat.testEndpoint(); testing = false }
                        }
                        .disabled(testing || !chat.isAvailable)
                        if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                Text("Any OpenAI-compatible chat endpoint: Ollama or LM Studio on this Mac, or a hosted API. The key is kept in your Keychain and sent only to this URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = chat.error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .formStyle(.grouped)
    }
}

struct MeetingSettingsView: View {
    @Bindable var session: MeetingSession
    @AppStorage("userName") private var userName = ""

    var body: some View {
        Form {
            TextField("Your name", text: $userName, prompt: Text("You"))
            Text("Labels your microphone in transcripts. Other voices are recognized after each meeting and named Speaker 1, 2…; right-click a line to rename one.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Ask whether to keep going", isOn: $session.checkpointEnabled)
            Stepper("Every \(session.checkpointMinutes) minutes", value: $session.checkpointMinutes, in: 10...120, step: 10)
                .disabled(!session.checkpointEnabled)
            Text("Transcription never stops on its own. When on, the floating capsule chimes and asks at each checkpoint; ignoring it keeps recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
