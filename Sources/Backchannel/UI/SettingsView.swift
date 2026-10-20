import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("Setup", systemImage: "checklist") {
                SetupView(checker: model.setup)
            }
            Tab("Embedding", systemImage: "point.3.connected.trianglepath.dotted") {
                ModelPickerView(models: model.models, mode: .settings) { chosen in
                    Task { await model.useEmbeddingModel(chosen) }
                }
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                ChatSettingsView(chat: model.chatModels)
            }
            Tab("Folders", systemImage: "folder.badge.gearshape") {
                WatchedFoldersView(watcher: model.watcher)
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
            case .mlx:
                if !ChatModelManager.mlxSupported {
                    Text(ChatBackendError.notBuilt.localizedDescription).foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $chat.mlxModelID) {
                        ForEach(chat.mlxModels) { Text($0.name).tag($0.id) }
                    }
                    if let m = chat.mlxModel {
                        LabeledContent("Status") {
                            if chat.downloading == m.id {
                                ProgressView(value: chat.progress).frame(width: 140)
                                Text("\(Int(chat.progress * 100))%").font(.caption.monospacedDigit())
                            } else if chat.installed.contains(m.id) {
                                Text("Downloaded")
                            } else if !m.isSupported(for: .chat) {
                                Text("Not supported (\(m.modelType ?? "no model_type"))")
                            } else {
                                Button(m.id == HubModel.gemma4.id ? "Download (about 3 GB)" : "Download") { chat.download(m) }
                                    .disabled(chat.downloading != nil).accessibilityLabel("Download \(m.name)")
                            }
                        }
                        LabeledContent("Repo") {
                            HStack {
                                Text(m.id).textSelection(.enabled)
                                if m.id != HubModel.gemma4.id {
                                    Button("Remove") { chat.removeMLXModel(m) }.controlSize(.small).accessibilityLabel("Remove \(m.name)")
                                        .help("Remove from this list. Downloaded weights stay in the Hub cache.")
                                }
                            }
                        }
                    }
                    Section("Add from Hugging Face") {
                        HubSearchView(role: .chat, added: Set(chat.mlxModels.map(\.id))) { hub in
                            chat.addMLXModel(hub)
                            chat.mlxModelID = hub.id
                        }
                    }
                    Text("Runs on the GPU with MLX. Weights come from the Hugging Face Hub once and stay in Application Support. Gemma 4 E2B is the default; any chat repo tagged mlx whose architecture this app knows can be added.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

/// Folders Backchannel keeps in sync with the library; see `FolderWatcher`.
struct WatchedFoldersView: View {
    @Bindable var watcher: FolderWatcher

    var body: some View {
        Form {
            Section {
                if watcher.folders.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach(watcher.folders, id: \.self) { folder in
                    LabeledContent {
                        Button("Remove") { watcher.remove(folder) }.controlSize(.small)
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button("Add folder…") { pickFolder() }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("New or changed markdown, text, PDF and image files in these folders are imported and embedded while Backchannel runs, in the background too. Sources added one by one are watched for changes as well. Nothing is removed from the library on its own.")
            }
            if let last = watcher.lastScan {
                LabeledContent("Last scan", value: watcher.scanning ? "Scanning…" : last.formatted(date: .omitted, time: .shortened))
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        if panel.runModal() == .OK { panel.urls.forEach { watcher.add($0) } }
    }
}
