import Foundation
import Observation

/// All imported sources, their embeddings, labels and 2-D layout for the graph.
@MainActor
@Observable
final class SourceLibrary {
    private(set) var sources: [Source] = []
    private(set) var edges: [(Int64, Int64, Float)] = []
    private(set) var importing: [String] = []
    var errorMessage: String?
    private(set) var embedderName: String
    /// Sources being re-embedded after a model switch, for the UI.
    private(set) var reembedding = false

    private let store: Store
    /// Nil until an EmbeddingGemma model is installed; importing and retrieval then fail with a clear message.
    private var embedder: (any Embedder)?

    init(store: Store, model: EmbeddingModel) {
        self.store = store
        let e = Embedders.make(for: model)
        self.embedder = e
        self.embedderName = e?.name ?? "none installed"
    }

    /// Switches the embedding model and re-embeds every stored source with it.
    func useModel(_ model: EmbeddingModel) async {
        guard let next = Embedders.make(for: model), next.name != embedderName else { return }
        embedder = next; embedderName = next.name
        reembedding = true
        defer { reembedding = false }
        for source in sources {
            do {
                let v = try await vectors(forText: source.text, kind: source.kind, at: source.url)
                try await store.replaceEmbeddings(sourceId: source.id, embedding: v.document, chunks: v.chunks)
            } catch {
                errorMessage = "\(source.title): \(error.localizedDescription)"
            }
        }
        // Meeting passages live in the same vector space, so they move with the model too.
        if let chunks = try? await store.allMeetingChunks() {
            for chunk in chunks {
                if let v = try? await next.embed([chunk.text], task: .document).first {
                    try? await store.updateMeetingChunkEmbedding(id: chunk.id, v)
                }
            }
        }
        await reload()
        await relayout()
    }

    /// Document and chunk vectors for one source. Images (and the file behind them) also get a vision
    /// embedding when the model has one, stored as an extra chunk so retrieval can hit what the picture shows.
    private func vectors(forText text: String, kind: SourceKind, at url: URL) async throws -> (document: [Float], chunks: [(String, [Float])]) {
        guard let embedder else { throw EmbedderError.notInstalled }
        let texts = SourceImporter.chunk(text)
        var chunks = Array(zip(texts, try await embedder.embed(texts, task: .document)))
        if kind == .image, let image = try await embedder.embedImage(at: url) {
            chunks.append(("[Image] \(url.lastPathComponent)\n\(text.prefix(300))", image))
        }
        return (Vectors.mean(chunks.map(\.1)), chunks)
    }

    func reload() async {
        sources = (try? await store.sources()) ?? []
        recomputeEdges()
        await labelMissing()
        await indexUnindexedMeetings()
    }

    /// Meetings recorded before indexing existed, or whose indexing was interrupted, get their chunks now.
    func indexUnindexedMeetings() async {
        guard let meetings = try? await store.meetings(), let indexed = try? await store.allMeetingChunks() else { return }
        let done = Set(indexed.map(\.meetingId))
        for m in meetings where !done.contains(m.id) && m.endedAt != nil {
            let segments = (try? await store.segments(meetingId: m.id)) ?? []
            guard !segments.isEmpty else { continue }
            await indexMeeting(m, segments: segments)
        }
    }

    /// Labels sources that have none yet (imported while Apple Intelligence was unavailable, or before labelling existed).
    private func labelMissing() async {
        let missing = sources.filter { $0.label == nil }
        guard !missing.isEmpty else { return }
        for source in missing {
            let l = await Self.label(for: source.text, title: source.title)
            try? await store.setLabel(sourceId: source.id, label: l.label, rationale: l.rationale)
        }
        sources = (try? await store.sources()) ?? sources
    }

    /// On-device model label, or the first heading / the file name when the model is unavailable or
    /// declines the text (its guardrails trip on ordinary business documents now and then).
    private static func label(for text: String, title: String) async -> (label: String, rationale: String) {
        if OnDeviceLM.isAvailable, let l = try? await OnDeviceLM.label(for: text) {
            return (l.label, l.rationale)
        }
        let heading = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let label = String((heading?.isEmpty == false ? heading! : title).prefix(40))
        return (label, "Taken from the document heading; the on-device model did not label it.")
    }

    func importFiles(_ urls: [URL]) async {
        for url in urls {
            importing.append(url.lastPathComponent)
            defer { importing.removeAll { $0 == url.lastPathComponent } }
            do {
                let extracted = try await SourceImporter.extract(from: url)
                let v = try await vectors(forText: extracted.text, kind: extracted.kind, at: url)
                let title = url.deletingPathExtension().lastPathComponent
                let id = try await store.insertSource(path: url.path, title: title, kind: extracted.kind, text: extracted.text,
                                                      embedding: v.document, chunks: v.chunks)
                let l = await Self.label(for: extracted.text, title: title)
                try await store.setLabel(sourceId: id, label: l.label, rationale: l.rationale)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        await reload()
        await relayout()
    }

    func delete(_ source: Source) async {
        try? await store.deleteSource(id: source.id)
        await reload()
    }

    /// Best passages for a query across every source and every finished meeting: embedding similarity
    /// plus BM25, fused by rank. Works without an embedding model (keyword search only).
    func retrieve(_ query: String, limit: Int = 5) async throws -> [RetrievedPassage] {
        let queryVector = try? await embedder?.embed([query], task: .query).first
        let titles = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.title) })
        var passages = try await store.allChunks().map {
            Passage(title: titles[$0.sourceId] ?? "?", text: $0.text, embedding: $0.embedding)
        }
        let meetings = Dictionary(uniqueKeysWithValues: try await store.meetings().map { ($0.id, $0) })
        passages += try await store.allMeetingChunks().map {
            let m = meetings[$0.meetingId]
            let title = m.map { "\($0.title) · \($0.startedAt.formatted(date: .abbreviated, time: .omitted))" } ?? "Meeting"
            return Passage(title: title, text: $0.text, embedding: $0.embedding)
        }
        return Retrieval.search(query: query, queryVector: queryVector, passages: passages, limit: limit)
    }

    /// Makes a finished meeting searchable: the transcript in windows that keep speaker names and the
    /// meeting date, plus the summary. Called when a meeting stops and whenever its summary is rewritten.
    func indexMeeting(_ meeting: Meeting, segments: [TranscriptSegment]) async {
        let day = meeting.startedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let header = "Meeting “\(meeting.title)” on \(day)."
        var texts: [String] = []
        var window = ""
        for seg in segments where seg.isFinal {
            let line = "\(seg.name): \(seg.text)"
            if window.count + line.count > 900, !window.isEmpty { texts.append(header + "\n" + window); window = "" }
            window += (window.isEmpty ? "" : "\n") + line
        }
        if !window.isEmpty { texts.append(header + "\n" + window) }
        if let summary = meeting.summary { texts.append(header + "\nSummary:\n" + summary) }
        let vectors: [[Float]?]
        if let embedder, let vs = try? await embedder.embed(texts, task: .document) { vectors = vs }
        else { vectors = [[Float]?](repeating: nil, count: texts.count) }
        try? await store.replaceMeetingChunks(meetingId: meeting.id, Array(zip(texts, vectors)))
    }

    // MARK: Graph

    private func recomputeEdges() {
        var out: [(Int64, Int64, Float)] = []
        for i in sources.indices {
            for j in (i + 1)..<sources.count {
                let s = Vectors.cosine(sources[i].embedding, sources[j].embedding)
                if s > 0.55 { out.append((sources[i].id, sources[j].id, s)) }
            }
        }
        edges = out
    }

    /// PCA to two components (power iteration), scaled to the unit square.
    private func relayout() async {
        let vs = sources.map(\.embedding).filter { !$0.isEmpty }
        guard vs.count >= 2, let dim = vs.first?.count, vs.allSatisfy({ $0.count == dim }) else { return }
        let mean = (0..<dim).map { d in vs.reduce(0) { $0 + $1[d] } / Float(vs.count) }
        let centered = vs.map { v in (0..<dim).map { v[$0] - mean[$0] } }
        func project(_ dir: [Float]) -> [Float] { centered.map { zip($0, dir).reduce(0) { $0 + $1.0 * $1.1 } } }
        func powerIteration(excluding: [Float]?) -> [Float] {
            var w = (0..<dim).map { _ in Float.random(in: -1...1) }
            for _ in 0..<40 {
                var next = [Float](repeating: 0, count: dim)
                for row in centered {
                    let dot = zip(row, w).reduce(0) { $0 + $1.0 * $1.1 }
                    for d in 0..<dim { next[d] += dot * row[d] }
                }
                if let ex = excluding {
                    let dot = zip(next, ex).reduce(0) { $0 + $1.0 * $1.1 }
                    for d in 0..<dim { next[d] -= dot * ex[d] }
                }
                w = Vectors.normalized(next)
            }
            return w
        }
        let pc1 = powerIteration(excluding: nil)
        let pc2 = powerIteration(excluding: pc1)
        let xs = project(pc1), ys = project(pc2)
        func scale(_ a: [Float]) -> [Double] {
            let lo = a.min() ?? 0, hi = a.max() ?? 1
            let span = max(hi - lo, 1e-6)
            return a.map { Double(($0 - lo) / span) }
        }
        let sx = scale(xs), sy = scale(ys)
        var points: [Int64: CGPoint] = [:]
        var k = 0
        for s in sources where !s.embedding.isEmpty { points[s.id] = CGPoint(x: sx[k], y: sy[k]); k += 1 }
        try? await store.setProjections(points)
        await reload()
    }
}
