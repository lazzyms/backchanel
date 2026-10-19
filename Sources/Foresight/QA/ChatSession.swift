import Foundation
import FoundationModels
import Observation

struct ChatMessage: Identifiable, Hashable, Sendable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var sourceTitles: [String] = []
}

/// Multi-turn chat with the on-device model over the sources and, optionally, one meeting.
/// Each question is answered with retrieved passages (EmbeddingGemma) handed to Apple Intelligence.
/// History lives in memory for the app's lifetime; nothing leaves the Mac.
@MainActor
@Observable
final class ChatSession {
    private(set) var messages: [ChatMessage] = []
    private(set) var thinking = false
    /// Meeting whose summary and transcript are added to every question; nil for sources only.
    var meeting: Meeting? { didSet { if meeting?.id != oldValue?.id { reset() } } }

    private let library: SourceLibrary
    private let store: Store
    private var session: LanguageModelSession?

    init(library: SourceLibrary, store: Store) {
        self.library = library; self.store = store
    }

    func reset() {
        messages = []
        session = nil
    }

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        messages.append(ChatMessage(role: .user, text: q))
        thinking = true
        defer { thinking = false }
        guard OnDeviceLM.isAvailable else {
            messages.append(ChatMessage(role: .assistant, text: OnDeviceLM.availability ?? "Apple Intelligence is unavailable."))
            return
        }
        do {
            let hits = (try? await library.retrieve(q, limit: 5)) ?? []
            let prompt = try await buildPrompt(question: q, hits: hits)
            let answer = try await respond(prompt)
            messages.append(ChatMessage(role: .assistant, text: answer, sourceTitles: Array(Set(hits.map(\.title))).sorted()))
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "Couldn't answer: \(error.localizedDescription)"))
        }
    }

    private func buildPrompt(question: String, hits: [(title: String, text: String, score: Float)]) async throws -> String {
        var parts: [String] = []
        if !hits.isEmpty {
            parts.append("Passages from the user's sources:\n" +
                         hits.enumerated().map { i, h in "[\(i + 1)] \(h.title)\n\(String(h.text.prefix(1200)))" }.joined(separator: "\n\n"))
        }
        if let meeting {
            var notes = "Meeting “\(meeting.title)” (\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)))"
            if let summary = meeting.summary { notes += "\nSummary:\n\(summary)" }
            let lines = try await store.segments(meetingId: meeting.id).map { "\($0.speaker.rawValue): \($0.text)" }
            if !lines.isEmpty {
                // Keep the transcript tail; the model's window is small and the summary covers the rest.
                var tail: [String] = [], chars = 0
                for line in lines.reversed() { if chars + line.count > 3000 { break }; tail.insert(line, at: 0); chars += line.count }
                notes += "\nTranscript (last part):\n" + tail.joined(separator: "\n")
            }
            parts.append(notes)
        }
        if parts.isEmpty { parts.append("No sources or meeting notes matched.") }
        return parts.joined(separator: "\n\n") + "\n\nQuestion: \(question)"
    }

    /// Keeps the multi-turn session; starts a fresh one when the context window fills up.
    private func respond(_ prompt: String) async throws -> String {
        if session == nil { session = LanguageModelSession(instructions: OnDeviceLM.chatInstructions) }
        do {
            return try await session!.respond(to: prompt).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            session = LanguageModelSession(instructions: OnDeviceLM.chatInstructions)
            return try await session!.respond(to: prompt).content
        }
    }
}
