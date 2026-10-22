import AppKit
import UniformTypeIdentifiers

/// One Markdown document for a meeting: notes, summary, insights with their sources, then the
/// transcript with timestamps. Saved where the user chooses; nothing else leaves the Mac.
enum MeetingExport {
    static func markdown(_ meeting: Meeting, segments: [TranscriptSegment], insights: [Insight]) -> String {
        var out = "# \(meeting.title)\n\n"
        out += "- Started: \(meeting.startedAt.formatted(date: .long, time: .shortened))\n"
        if let end = meeting.endedAt { out += "- Duration: \(end.timeIntervalSince(meeting.startedAt).clock)\n" }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += "\n## Notes\n\n\(notes)\n" }
        if let s = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out += "\n## Summary\n\n\(s)\n" }
        if !insights.isEmpty {
            out += "\n## Insights\n"
            for i in insights {
                out += "\n**Q: \(i.question)**\n\n\(i.answer)\n"
                if !i.sourceTitles.isEmpty { out += "\n_Sources: \(i.sourceTitles.joined(separator: ", "))_\n" }
            }
        }
        let lines = segments.filter(\.isFinal)
        if !lines.isEmpty {
            out += "\n## Transcript\n\n"
            for s in lines { out += "`\(s.startSec.clock)` **\(s.name):** \(s.text)\n\n" }
        }
        return out
    }

    /// A file name safe for every file system: the title with path separators and colons replaced.
    static func fileName(for meeting: Meeting) -> String {
        let day = meeting.startedAt.formatted(.iso8601.year().month().day())
        let title = meeting.title.map { "/\\:".contains($0) ? "-" : $0 }
        return "\(day) \(String(title)).md"
    }

    /// Asks where to save and writes the file. Errors come back as a message for the usual alert.
    @MainActor
    static func save(_ meeting: Meeting, segments: [TranscriptSegment], insights: [Insight]) async -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileName(for: meeting)
        panel.canCreateDirectories = true
        panel.title = "Export Meeting"
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        do {
            try markdown(meeting, segments: segments, insights: insights).write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }
}
