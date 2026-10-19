import Foundation
import Observation

struct ChatMessage: Identifiable, Hashable, Sendable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var sourceTitles: [String] = []
}

/// Multi-turn chat over every source and meeting transcript, optionally focused on one meeting.
/// Each question is answered with retrieved passages (BM25 + embeddings) handed to the chosen
/// chat model: Apple Intelligence, Gemma 4 on MLX, or the user's own endpoint.
@MainActor
@Observable
final class ChatSession {
    private(set) var messages: [ChatMessage] = []
    private(set) var thinking = false
    /// Meeting whose summary and transcript are added to every question; nil for everything.
    var meeting: Meeting? { didSet { if meeting?.id != oldValue?.id { reset() } } }

    private let library: SourceLibrary
    private let store: Store
    private let chat: ChatModelManager
    private var conversation: (kind: ChatBackendKind, conversation: any ChatConversation)?

    init(library: SourceLibrary, store: Store, chat: ChatModelManager) {
        self.library = library; self.store = store; self.chat = chat
    }

    func reset() {
        messages = []
        conversation = nil
    }

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        messages.append(ChatMessage(role: .user, text: q))
        thinking = true
        defer { thinking = false }
        if let why = chat.availability {
            messages.append(ChatMessage(role: .assistant, text: why))
            return
        }
        do {
            let hits = (try? await library.retrieve(q, limit: 6)) ?? []
            let prompt = try await buildPrompt(question: q, hits: hits)
            if conversation?.kind != chat.kind { conversation = (chat.kind, try chat.makeConversation(instructions: OnDeviceLM.chatInstructions)) }
            let answer = try await conversation!.conversation.send(prompt)
            messages.append(ChatMessage(role: .assistant, text: answer, sourceTitles: Array(Set(hits.map(\.title))).sorted()))
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "Couldn't answer: \(error.localizedDescription)"))
        }
    }

    private func buildPrompt(question: String, hits: [RetrievedPassage]) async throws -> String {
        var parts: [String] = []
        if !hits.isEmpty {
            parts.append("Passages from the user's sources and meeting transcripts:\n" +
                         hits.enumerated().map { i, h in "[\(i + 1)] \(h.title)\n\(String(h.text.prefix(1200)))" }.joined(separator: "\n\n"))
        }
        if let meeting {
            var notes = "Meeting “\(meeting.title)” (\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)))"
            if let summary = meeting.summary { notes += "\nSummary:\n\(summary)" }
            let lines = try await store.segments(meetingId: meeting.id).map { "\($0.name): \($0.text)" }
            if !lines.isEmpty {
                // Keep the transcript tail; the model's window is small and the summary covers the rest.
                var tail: [String] = [], chars = 0
                for line in lines.reversed() { if chars + line.count > 3000 { break }; tail.insert(line, at: 0); chars += line.count }
                notes += "\nTranscript (last part):\n" + tail.joined(separator: "\n")
            }
            parts.append(notes)
        }
        if parts.isEmpty { parts.append("No sources or meeting notes matched.") }
        return parts.joined(separator: "\n\n") + "\n\nToday is \(Date().formatted(date: .complete, time: .omitted)).\nQuestion: \(question)"
    }
}
