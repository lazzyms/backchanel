import SwiftUI

/// Ask: the original's chat page. Empty state headline, bubbles, and a capsule composer at the bottom.
struct AskView: View {
    @Bindable var chat: ChatSession
    let meetings: [Meeting]
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
                        Text("Get answers from your\npersonalised knowledge sources.")
                            .font(.title2).multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            composer
        }
        .navigationTitle("Ask")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("New chat", systemImage: "square.and.pencil") { chat.reset() }.disabled(chat.messages.isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Picker("Scope", selection: $chat.meeting) {
                    Text("Sources only").tag(Meeting?.none)
                    ForEach(meetings) { m in Text(m.title).tag(Meeting?.some(m)) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(chat.meeting?.title ?? "Sources only", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
            .help("Which meeting to answer from, besides your sources")

            HStack(spacing: 8) {
                TextField("Ask Foresight about your meetings", text: $draft, axis: .vertical)
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
                if !m.sourceTitles.isEmpty {
                    Label(m.sourceTitles.joined(separator: " · "), systemImage: "doc.text")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
