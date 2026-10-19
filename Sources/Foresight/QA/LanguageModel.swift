import Foundation
import FoundationModels

/// Apple's on-device foundation model (Apple Intelligence). Used for labels, meeting answers, summaries and chat.
/// It only runs on this Mac: Apple offers no Private Cloud Compute to third-party apps.
/// Everything here degrades gracefully when the model is unavailable.
enum OnDeviceLM {
    static var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): return "Apple Intelligence model is still downloading."
        case .unavailable: return "Apple Intelligence is unavailable."
        }
    }
    static var isAvailable: Bool { availability == nil }

    @Generable
    struct Label {
        @Guide(description: "A two or three word topic label, Title Case, no punctuation")
        var label: String
        @Guide(description: "One short sentence saying why this label fits")
        var rationale: String
    }

    static func label(for text: String) async throws -> Label {
        let session = LanguageModelSession(instructions: "You label documents for a personal knowledge graph. Reply with a short topic label.")
        let excerpt = String(text.prefix(2500))
        return try await session.respond(to: "Label this document:\n\n\(excerpt)", generating: Label.self).content
    }

    @Generable
    struct QuestionCheck {
        @Guide(description: "true only if the text is a question someone would want answered from notes or documents")
        var isQuestion: Bool
        @Guide(description: "The question, rewritten as a clear standalone question")
        var question: String
    }

    static func detectQuestion(_ utterance: String, recent: [String]) async throws -> QuestionCheck {
        let session = LanguageModelSession(instructions: """
        You listen to a meeting transcript and spot questions that could be answered from the user's documents. \
        Ignore small talk, rhetorical questions and 'how are you'.
        """)
        let context = recent.suffix(6).joined(separator: "\n")
        return try await session.respond(to: "Recent transcript:\n\(context)\n\nLatest utterance:\n\(utterance)", generating: QuestionCheck.self).content
    }

    static func answer(question: String, passages: [(title: String, text: String)]) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Answer the question using only the provided passages. Be concise (2-4 sentences). \
        If the passages do not contain the answer, say so in one sentence.
        """)
        let body = passages.enumerated().map { i, p in "[\(i + 1)] \(p.title)\n\(String(p.text.prefix(1500)))" }.joined(separator: "\n\n")
        return try await session.respond(to: "Passages:\n\(body)\n\nQuestion: \(question)").content
    }

    // MARK: Meeting summary

    @Generable
    struct Summary {
        @Guide(description: "Two or three sentences saying what the meeting was about and what was concluded")
        var overview: String
        @Guide(description: "The main points discussed, each one short sentence", .count(3...8))
        var keyPoints: [String]
        @Guide(description: "Decisions made or tasks someone agreed to do; empty if none")
        var actionItems: [String]

        var markdown: String {
            var out = overview + "\n\n**Key points**\n" + keyPoints.map { "- " + $0 }.joined(separator: "\n")
            if !actionItems.isEmpty { out += "\n\n**Action items**\n" + actionItems.map { "- " + $0 }.joined(separator: "\n") }
            return out
        }
    }

    /// Summarises a transcript as markdown. Long transcripts are summarised in windows first, then
    /// the window summaries are merged, because the on-device model sees about 4,000 tokens at once.
    static func summarize(transcript lines: [String]) async throws -> String {
        let windows = Self.windows(lines, maxChars: 6000)
        let instructions = "You write concise, factual meeting summaries from transcripts. 'You' is the user; 'Others' are the other participants. Never invent details."
        if windows.count == 1 {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: "Transcript:\n\(windows[0])", generating: Summary.self).content.markdown
        }
        var partials: [String] = []
        for (i, w) in windows.enumerated() {
            let session = LanguageModelSession(instructions: instructions)
            let part = try await session.respond(to: "Part \(i + 1) of \(windows.count) of a transcript. Summarise this part in 3-6 sentences.\n\n\(w)").content
            partials.append(part)
        }
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: "Summaries of consecutive parts of one meeting:\n\n\(partials.joined(separator: "\n\n"))",
                                         generating: Summary.self).content.markdown
    }

    private static func windows(_ lines: [String], maxChars: Int) -> [String] {
        var out: [String] = [], current = ""
        for line in lines {
            if current.count + line.count > maxChars, !current.isEmpty { out.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: Chat

    static let chatInstructions = """
    You are Foresight's assistant on the user's Mac. Answer from the passages and meeting notes supplied with each \
    message; they come from the user's own documents and transcripts. Be concise and concrete. Cite the passage \
    titles you used. If the material does not cover the question, say so, then answer from general knowledge \
    only if clearly marked as such.
    """
}
