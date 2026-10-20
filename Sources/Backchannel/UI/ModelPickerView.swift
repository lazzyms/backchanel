import SwiftUI

/// Onboarding and settings sheet: pick the embedding model, downloading its weights if needed.
/// The built-in EmbeddingGemma 2 variants come first; below them, any repo added from the Hub search.
struct ModelPickerView: View {
    enum Mode { case onboarding, settings }

    @Bindable var models: ModelManager
    let mode: Mode
    let onDone: (EmbeddingModel) -> Void
    @State private var choice: EmbeddingModel.ID

    init(models: ModelManager, mode: Mode = .onboarding, onDone: @escaping (EmbeddingModel) -> Void) {
        self.models = models
        self.mode = mode
        self.onDone = onDone
        _choice = State(initialValue: models.selected.id)
    }

    private var chosen: EmbeddingModel? { models.all.first { $0.id == choice } }
    private var canContinue: Bool { chosen.map { $0.isSupported && $0.isInstalled } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .onboarding { Text("Choose an embedding model").font(.title2.bold()) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Turns your sources and questions into vectors for matching, on the GPU, fully on-device. Summaries and chat use the model picked under Settings › Chat. Switching later re-embeds your sources.")
                        .foregroundStyle(.secondary)
                    VStack(spacing: 10) {
                        ForEach(models.all) { m in row(m) }
                    }
                    if let error = models.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("Add from Hugging Face").font(.headline)
                    HubSearchView(role: .embedding, added: Set(models.hubModels.map(\.id))) { hub in
                        models.add(hub: hub)
                        choice = EmbeddingModel.hub(hub).id
                    }
                }
                .padding(.horizontal, 1)
            }
            HStack {
                Spacer()
                Button(mode == .onboarding ? "Continue" : "Use this model") { if let chosen { models.select(chosen); onDone(chosen) } }
                    .keyboardShortcut(.defaultAction).disabled(!canContinue || (mode == .settings && choice == models.selected.id))
            }
        }
        .padding(mode == .onboarding ? 0 : 24).frame(width: mode == .onboarding ? 512 : nil, height: mode == .onboarding ? 460 : nil)
    }

    @ViewBuilder
    private func row(_ m: EmbeddingModel) -> some View {
        let selected = m.id == choice
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(m.name).font(.headline)
                    Spacer()
                    status(m)
                    if m.hub != nil, m.id != models.selected.id {
                        Button { models.remove(m); if choice == m.id { choice = models.selected.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(m.name)")
                            .help("Remove from this list. Downloaded weights stay in the Hub cache.")
                    }
                }
                Text(m.summary).font(.caption).foregroundStyle(.secondary)
                if models.downloading == m.id {
                    ProgressView(value: models.progress).progressViewStyle(.linear)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .contentShape(Rectangle())
        .opacity(m.isSupported ? 1 : 0.5)
        .onTapGesture { if m.isSupported { choice = m.id } }
    }

    @ViewBuilder
    private func status(_ m: EmbeddingModel) -> some View {
        if !m.isSupported {
            Text(m.hub == nil ? "Not in this build" : "Not supported").font(.caption).foregroundStyle(.secondary)
        } else if m.isInstalled {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else if models.downloading == m.id {
            Text("\(Int(models.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Button(m.downloadBytes.map { "Download \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "Download") {
                choice = m.id; models.download(m)
            }
            .controlSize(.small).disabled(models.downloading != nil).accessibilityLabel("Download \(m.name)")
        }
    }
}
