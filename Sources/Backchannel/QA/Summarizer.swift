import Foundation

/// Meeting summary (topics, key points, action items) through whichever chat backend is chosen.
/// Apple Intelligence gets guided generation; the others answer a plain prompt in markdown.
@MainActor
enum MeetingSummarizer {
    static func summarize(_ lines: [String], using chat: ChatModelManager) async throws -> String {
        if chat.kind == .apple { return try await OnDeviceLM.summarize(transcript: lines) }
        let windows = OnDeviceLM.windows(lines, maxChars: 14_000)
        let format = """
        Reply in markdown with exactly these sections and nothing else:
        two or three sentences of overview, then **Topics** (2-6 bullets of two to five words), \
        **Key points** (3-8 short bullets), **Action items** (bullets naming the owner when known, or "- None").
        """
        if windows.count == 1 {
            return clean(try await chat.respond(instructions: OnDeviceLM.summaryInstructions, prompt: "Transcript:\n\(windows[0])\n\n\(format)"))
        }
        var partials: [String] = []
        for (i, w) in windows.enumerated() {
            partials.append(try await chat.respond(instructions: OnDeviceLM.summaryInstructions,
                                                   prompt: "Part \(i + 1) of \(windows.count) of a transcript. Summarise this part in 4-8 sentences, keeping who said what and any tasks agreed.\n\n\(w)"))
        }
        return clean(try await chat.respond(instructions: OnDeviceLM.summaryInstructions,
                                            prompt: "Summaries of consecutive parts of one meeting:\n\n\(partials.joined(separator: "\n\n"))\n\n\(format)"))
    }

    /// Small models like to wrap markdown in a code fence; the UI renders it as text.
    private static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
