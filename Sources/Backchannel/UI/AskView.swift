import SwiftUI

/// Ask: the original's chat page. Empty state headline, bubbles, and a capsule composer at the bottom.
struct AskView: View {
    @Bindable var model: AppModel
    private var chat: ChatSession { model.chat }
    private var meetings: [Meeting] { model.meetings }
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { m in bubble(m).id(m.id) }
                        if chat.thinking {
                            HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .overlay {
                    if chat.messages.isEmpty {
                        VStack(spacing: 10) {
                            Text("Get answers from your\npersonalised knowledge sources.")
                                .font(.title2).multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                            Text(emptyHint).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        }
                    }
                }
            }
            composer
        }
        .navigationTitle("Ask")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("New chat", systemImage: "square.and.pencil") { chat.newChat() }.disabled(chat.messages.isEmpty && chat.meeting == nil)
            }
        }
        .onAppear { focused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Scope").font(.caption).foregroundStyle(.secondary)
                Picker("Scope", selection: Bindable(chat).meeting) {
                    Text("All sources and meetings").tag(Meeting?.none)
                    ForEach(meetings) { m in Text(m.title).tag(Meeting?.some(m)) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                .accessibilityIdentifier("askScope")
                .help("Which meeting to answer from, besides your sources")
            }

            HStack(spacing: 8) {
                TextField("Ask Backchannel about your meetings", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    /// What to try first, from what the library actually holds.
    private var emptyHint: String {
        let n = chat.library.sources.count
        if n == 0 && meetings.isEmpty { return "Add documents under Sources or record a meeting first, then ask about them here." }
        if let m = chat.meeting { return "Answers come from “\(m.title)” and your \(n) sources. Try “What did we decide?”" }
        if meetings.isEmpty { return "Answers come from your \(n) sources. Try “What does my guide say about…”" }
        return "Answers come from your \(n) sources and \(meetings.count) meetings. Pick a meeting under Scope to focus on it."
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.thinking }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await chat.ask(text) }
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        if m.role == .user {
            Text(m.text).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(m.text)).textSelection(.enabled)
                CitationRow(titles: m.sourceTitles) { model.openSource(titled: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The sources an answer cited, each a button that opens the document under Sources.
struct CitationRow: View {
    let titles: [String]
    let open: (String) -> Void

    var body: some View {
        if !titles.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                ForEach(titles, id: \.self) { t in
                    Button(t) { open(t) }
                        .buttonStyle(.plain).foregroundStyle(.tint).lineLimit(1)
                        .help("Open “\(t)” under Sources")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Sources: \(titles.joined(separator: ", "))")
        }
    }
}
