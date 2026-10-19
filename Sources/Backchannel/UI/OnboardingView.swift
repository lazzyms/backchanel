import SwiftUI

/// First-run sheet in three separate steps: the embedding model (vectors for matching), the chat
/// model (answers and summaries), and the folders to keep watching. Each step is the same control
/// the matching Settings tab shows, so anything chosen here can be changed later.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step = 0

    private let titles = ["Embedding model", "Chat model", "Watched folders"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Text("\(i + 1). \(titles[i])")
                        .font(.caption.weight(i == step ? .semibold : .regular))
                        .foregroundStyle(i == step ? .primary : .secondary)
                    if i < titles.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            switch step {
            case 0:
                ModelPickerView(models: model.models, mode: .onboarding) { chosen in
                    Task { await model.useEmbeddingModel(chosen) }
                    step = 1
                }
            case 1:
                Text("Choose a chat model").font(.title2.bold())
                Text("Answers in Ask, live meeting answers and summaries come from this model. It is separate from the embedding model and can be changed under Settings › Chat.")
                    .foregroundStyle(.secondary)
                ChatSettingsView(chat: model.chatModels).frame(height: 300)
                HStack {
                    Button("Back") { step = 0 }
                    Spacer()
                    Button("Continue") { step = 2 }.keyboardShortcut(.defaultAction)
                }
            default:
                Text("Which folders should Backchannel watch?").font(.title2.bold())
                Text("Files in these folders are imported and embedded automatically, now and whenever they change, while the app runs. You can skip this and add folders under Settings › Folders.")
                    .foregroundStyle(.secondary)
                WatchedFoldersView(watcher: model.watcher).frame(height: 300)
                HStack {
                    Button("Back") { step = 1 }
                    Spacer()
                    Button(model.watcher.folders.isEmpty ? "Skip" : "Finish") { model.finishOnboarding() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
