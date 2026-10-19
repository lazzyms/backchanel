import Foundation

/// Typed persistence on top of `Database`. Everything the UI shows comes from here.
actor Store {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Foresight", isDirectory: true)
    }()

    private let db: Database

    init() throws {
        db = try Database(url: Store.appSupport.appendingPathComponent("foresight.sqlite"))
    }

    // MARK: Sources

    func sources() async throws -> [Source] {
        try await db.query("SELECT id,path,title,kind,text,embedding,label,label_rationale,proj_x,proj_y,created_at FROM sources ORDER BY created_at DESC") { r in
            Source(id: r.int(0), path: r.text(1), title: r.text(2), kind: SourceKind(rawValue: r.text(3)) ?? .text,
                   text: r.text(4), embedding: r.blob(5).floatVector, label: r.optionalText(6), labelRationale: r.optionalText(7),
                   projection: r.optionalText(8) == nil ? nil : CGPoint(x: r.double(8), y: r.double(9)),
                   createdAt: Date(timeIntervalSince1970: r.double(10)))
        }
    }

    func insertSource(path: String, title: String, kind: SourceKind, text: String, embedding: [Float], chunks: [(String, [Float])]) async throws -> Int64 {
        try await db.run("DELETE FROM sources WHERE path=?", [.text(path)])
        let id = try await db.run("INSERT INTO sources(path,title,kind,text,embedding,created_at) VALUES(?,?,?,?,?,?)",
                                  [.text(path), .text(title), .text(kind.rawValue), .text(text), .blob(Data(vector: embedding)), .double(Date().timeIntervalSince1970)])
        for (i, c) in chunks.enumerated() {
            try await db.run("INSERT INTO chunks(source_id,idx,text,embedding) VALUES(?,?,?,?)",
                             [.int(id), .int(Int64(i)), .text(c.0), .blob(Data(vector: c.1))])
        }
        return id
    }

    /// Re-embeds a source after the embedding model changed. Vectors from different models never mix.
    func replaceEmbeddings(sourceId: Int64, embedding: [Float], chunks: [(String, [Float])]) async throws {
        try await db.run("DELETE FROM chunks WHERE source_id=?", [.int(sourceId)])
        try await db.run("UPDATE sources SET embedding=?, proj_x=NULL, proj_y=NULL WHERE id=?", [.blob(Data(vector: embedding)), .int(sourceId)])
        for (i, c) in chunks.enumerated() {
            try await db.run("INSERT INTO chunks(source_id,idx,text,embedding) VALUES(?,?,?,?)",
                             [.int(sourceId), .int(Int64(i)), .text(c.0), .blob(Data(vector: c.1))])
        }
    }

    func setLabel(sourceId: Int64, label: String, rationale: String) async throws {
        try await db.run("UPDATE sources SET label=?, label_rationale=? WHERE id=?", [.text(label), .text(rationale), .int(sourceId)])
    }

    func setProjections(_ points: [Int64: CGPoint]) async throws {
        for (id, p) in points {
            try await db.run("UPDATE sources SET proj_x=?, proj_y=? WHERE id=?", [.double(p.x), .double(p.y), .int(id)])
        }
    }

    func deleteSource(id: Int64) async throws {
        try await db.run("DELETE FROM sources WHERE id=?", [.int(id)])
    }

    func allChunks() async throws -> [Chunk] {
        try await db.query("SELECT id,source_id,idx,text,embedding FROM chunks") { r in
            Chunk(id: r.int(0), sourceId: r.int(1), index: Int(r.int(2)), text: r.text(3), embedding: r.blob(4).floatVector)
        }
    }

    // MARK: Meetings

    func meetings() async throws -> [Meeting] {
        try await db.query("SELECT id,title,started_at,ended_at,summary FROM meetings ORDER BY started_at DESC") { r in
            Meeting(id: r.int(0), title: r.text(1), startedAt: Date(timeIntervalSince1970: r.double(2)),
                    endedAt: r.optionalText(3).map { _ in Date(timeIntervalSince1970: r.double(3)) }, summary: r.optionalText(4))
        }
    }

    func setSummary(meetingId: Int64, _ summary: String) async throws {
        try await db.run("UPDATE meetings SET summary=? WHERE id=?", [.text(summary), .int(meetingId)])
    }

    func createMeeting(title: String) async throws -> Meeting {
        let now = Date()
        let id = try await db.run("INSERT INTO meetings(title,started_at) VALUES(?,?)", [.text(title), .double(now.timeIntervalSince1970)])
        return Meeting(id: id, title: title, startedAt: now, endedAt: nil, summary: nil)
    }

    func endMeeting(id: Int64) async throws {
        try await db.run("UPDATE meetings SET ended_at=? WHERE id=?", [.double(Date().timeIntervalSince1970), .int(id)])
    }

    func deleteMeeting(id: Int64) async throws {
        try await db.run("DELETE FROM meetings WHERE id=?", [.int(id)])
    }

    func insightCount() async throws -> Int {
        try await db.query("SELECT COUNT(*) FROM insights") { r in Int(r.int(0)) }.first ?? 0
    }

    func appendSegment(meetingId: Int64, _ s: TranscriptSegment) async throws {
        try await db.run("INSERT INTO segments(meeting_id,speaker,text,start_sec,end_sec) VALUES(?,?,?,?,?)",
                         [.int(meetingId), .text(s.speaker.rawValue), .text(s.text), .double(s.startSec), .double(s.endSec)])
    }

    func segments(meetingId: Int64) async throws -> [TranscriptSegment] {
        try await db.query("SELECT speaker,text,start_sec,end_sec FROM segments WHERE meeting_id=? ORDER BY start_sec", [.int(meetingId)]) { r in
            let sp = Speaker(rawValue: r.text(0)) ?? .them
            return TranscriptSegment(id: "\(sp.rawValue)-\(r.double(2))", speaker: sp, text: r.text(1), startSec: r.double(2), endSec: r.double(3), isFinal: true)
        }
    }

    func appendInsight(meetingId: Int64, question: String, answer: String, sourceTitles: [String]) async throws -> Insight {
        let now = Date()
        let titles = sourceTitles.joined(separator: "\u{1F}")
        let id = try await db.run("INSERT INTO insights(meeting_id,question,answer,source_titles,created_at) VALUES(?,?,?,?,?)",
                                  [.int(meetingId), .text(question), .text(answer), .text(titles), .double(now.timeIntervalSince1970)])
        return Insight(id: id, meetingId: meetingId, question: question, answer: answer, sourceTitles: sourceTitles, createdAt: now)
    }

    func insights(meetingId: Int64) async throws -> [Insight] {
        try await db.query("SELECT id,question,answer,source_titles,created_at FROM insights WHERE meeting_id=? ORDER BY created_at", [.int(meetingId)]) { r in
            Insight(id: r.int(0), meetingId: meetingId, question: r.text(1), answer: r.text(2),
                    sourceTitles: r.text(3).split(separator: "\u{1F}").map(String.init), createdAt: Date(timeIntervalSince1970: r.double(4)))
        }
    }
}
