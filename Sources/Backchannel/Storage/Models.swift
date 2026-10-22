import Foundation

enum SourceKind: String, Codable, Sendable { case markdown, text, pdf, image }

struct Source: Identifiable, Hashable, Sendable {
    let id: Int64
    var path: String
    var title: String
    var kind: SourceKind
    var text: String
    var embedding: [Float]
    var label: String?
    var labelRationale: String?
    var projection: CGPoint?
    var createdAt: Date
    /// The file's modification date when it was imported; watched folders re-import when it moves on.
    var modifiedAt: Date?
    var url: URL { URL(fileURLWithPath: path) }
}

struct Chunk: Identifiable, Sendable {
    let id: Int64
    let sourceId: Int64
    let index: Int
    let text: String
    let embedding: [Float]
}

struct Meeting: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var startedAt: Date
    var endedAt: Date?
    /// Markdown written by the on-device model after the meeting ends.
    var summary: String?
}

/// Which audio stream a line came from. The mic is always the user; system audio is everyone else,
/// split into named voices after the meeting (see `SpeakerRecognizer`).
enum Speaker: String, Sendable, Codable {
    case me = "You"
    case them = "Others"
}

struct TranscriptSegment: Identifiable, Hashable, Sendable {
    var id: String          // "\(speaker)-\(startSec)" keeps volatile → final updates stable
    var speaker: Speaker
    /// Shown next to the line: the user's name, a recognised voice ("Alice", "Speaker 2") or "Others".
    var name: String
    var text: String
    var startSec: Double
    var endSec: Double
    var isFinal: Bool
    /// The engine's words before a vocabulary correction changed `text`; nil when nothing was changed.
    var heard: String? = nil
}

/// A voice heard in earlier meetings, with its wespeaker embedding so it is recognised again.
struct KnownSpeaker: Identifiable, Sendable {
    let id: Int64
    var name: String
    var embedding: [Float]
}

/// A searchable window of one meeting's transcript (or its summary), embedded like a source chunk.
struct MeetingChunk: Identifiable, Sendable {
    let id: Int64
    let meetingId: Int64
    let text: String
    /// Nil when the chunk was written without an embedding model; BM25 still finds it.
    let embedding: [Float]?
}

struct Insight: Identifiable, Hashable, Sendable {
    let id: Int64
    let meetingId: Int64
    let question: String
    let answer: String
    let sourceTitles: [String]
    let createdAt: Date
}
