import Foundation

/// Typed persistence on top of `Database`. Everything the UI shows comes from here.
actor Store {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Backchannel", isDirectory: true)
    }()

    private let db: Database

    init() throws {
        db = try Database(url: Store.appSupport.appendingPathComponent("backchannel.sqlite"))
    }

    // MARK: Sources

    func sources() async throws -> [Source] {
        try await db.query("SELECT id,path,title,kind,text,embedding,label,label_rationale,proj_x,proj_y,created_at,modified_at FROM sources ORDER BY created_at DESC") { r in
            Source(id: r.int(0), path: r.text(1), title: r.text(2), kind: SourceKind(rawValue: r.text(3)) ?? .text,
                   text: r.text(4), embedding: r.blob(5).floatVector, label: r.optionalText(6), labelRationale: r.optionalText(7),
                   projection: r.optionalText(8) == nil ? nil : CGPoint(x: r.double(8), y: r.double(9)),
                   createdAt: Date(timeIntervalSince1970: r.double(10)),
                   modifiedAt: r.optionalText(11).map { _ in Date(timeIntervalSince1970: r.double(11)) })
        }
    }

    func insertSource(path: String, title: String, kind: SourceKind, text: String, modifiedAt: Date?, embedding: [Float], chunks: [(String, [Float])]) async throws -> Int64 {
        try await db.run("DELETE FROM sources WHERE path=?", [.text(path)])
        let id = try await db.run("INSERT INTO sources(path,title,kind,text,modified_at,embedding,created_at) VALUES(?,?,?,?,?,?,?)",
                                  [.text(path), .text(title), .text(kind.rawValue), .text(text), modifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                                   .blob(Data(vector: embedding)), .double(Date().timeIntervalSince1970)])
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

    /// Titles come from the start minute, so two meetings started in the same minute get " (2)",
    /// " (3)" and so on instead of sharing a name.
    func createMeeting(title: String) async throws -> Meeting {
        let now = Date()
        let taken = try await db.query("SELECT COUNT(*) FROM meetings WHERE title=? OR title LIKE ?",
                                       [.text(title), .text(title + " (%)")]) { r in Int(r.int(0)) }.first ?? 0
        let title = taken == 0 ? title : "\(title) (\(taken + 1))"
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
        try await db.run("INSERT INTO segments(meeting_id,speaker,speaker_name,text,start_sec,end_sec) VALUES(?,?,?,?,?,?)",
                         [.int(meetingId), .text(s.speaker.rawValue), .text(s.name), .text(s.text), .double(s.startSec), .double(s.endSec)])
    }

    func segments(meetingId: Int64) async throws -> [TranscriptSegment] {
        try await db.query("SELECT speaker,text,start_sec,end_sec,speaker_name FROM segments WHERE meeting_id=? ORDER BY start_sec", [.int(meetingId)]) { r in
            let sp = Speaker(rawValue: r.text(0)) ?? .them
            return TranscriptSegment(id: "\(sp.rawValue)-\(r.double(2))", speaker: sp, name: r.optionalText(4) ?? sp.rawValue,
                                     text: r.text(1), startSec: r.double(2), endSec: r.double(3), isFinal: true)
        }
    }

    /// Names one stored line after speaker recognition. Lines are addressed by stream and start time.
    func setSpeakerName(meetingId: Int64, speaker: Speaker, startSec: Double, name: String) async throws {
        try await db.run("UPDATE segments SET speaker_name=? WHERE meeting_id=? AND speaker=? AND start_sec=?",
                         [.text(name), .int(meetingId), .text(speaker.rawValue), .double(startSec)])
    }

    // MARK: Speakers

    func speakers() async throws -> [KnownSpeaker] {
        try await db.query("SELECT id,name,embedding FROM speakers ORDER BY id") { r in
            KnownSpeaker(id: r.int(0), name: r.text(1), embedding: r.blob(2).floatVector)
        }
    }

    func insertSpeaker(name: String, embedding: [Float]) async throws -> KnownSpeaker {
        let id = try await db.run("INSERT INTO speakers(name,embedding) VALUES(?,?)", [.text(name), .blob(Data(vector: embedding))])
        return KnownSpeaker(id: id, name: name, embedding: embedding)
    }

    func updateSpeakerEmbedding(id: Int64, _ embedding: [Float]) async throws {
        try await db.run("UPDATE speakers SET embedding=? WHERE id=?", [.blob(Data(vector: embedding)), .int(id)])
    }

    /// Renames a voice everywhere: the speaker table and every transcript line carrying the old name.
    func renameSpeaker(from old: String, to new: String) async throws {
        try await db.run("UPDATE speakers SET name=? WHERE name=?", [.text(new), .text(old)])
        try await db.run("UPDATE segments SET speaker_name=? WHERE speaker_name=?", [.text(new), .text(old)])
        try await db.run("UPDATE meeting_chunks SET text=REPLACE(text, ?, ?)", [.text("\n" + old + ": "), .text("\n" + new + ": ")])
    }

    // MARK: Meeting passages

    func replaceMeetingChunks(meetingId: Int64, _ chunks: [(String, [Float]?)]) async throws {
        try await db.run("DELETE FROM meeting_chunks WHERE meeting_id=?", [.int(meetingId)])
        for (i, c) in chunks.enumerated() {
            try await db.run("INSERT INTO meeting_chunks(meeting_id,idx,text,embedding) VALUES(?,?,?,?)",
                             [.int(meetingId), .int(Int64(i)), .text(c.0), c.1.map { .blob(Data(vector: $0)) } ?? .null])
        }
    }

    func updateMeetingChunkEmbedding(id: Int64, _ embedding: [Float]) async throws {
        try await db.run("UPDATE meeting_chunks SET embedding=? WHERE id=?", [.blob(Data(vector: embedding)), .int(id)])
    }

    func allMeetingChunks() async throws -> [MeetingChunk] {
        try await db.query("SELECT id,meeting_id,text,embedding FROM meeting_chunks") { r in
            let blob = r.blob(3)
            return MeetingChunk(id: r.int(0), meetingId: r.int(1), text: r.text(2), embedding: blob.isEmpty ? nil : blob.floatVector)
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
