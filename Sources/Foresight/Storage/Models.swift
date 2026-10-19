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

enum Speaker: String, Sendable, Codable {
    case me = "You"
    case them = "Others"
}

struct TranscriptSegment: Identifiable, Hashable, Sendable {
    var id: String          // "\(speaker)-\(startSec)" keeps volatile → final updates stable
    var speaker: Speaker
    var text: String
    var startSec: Double
    var endSec: Double
    var isFinal: Bool
}

struct Insight: Identifiable, Hashable, Sendable {
    let id: Int64
    let meetingId: Int64
    let question: String
    let answer: String
    let sourceTitles: [String]
    let createdAt: Date
}
