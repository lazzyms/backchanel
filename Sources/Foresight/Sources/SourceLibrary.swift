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

    /// Top chunks for a query, with their source titles.
    func retrieve(_ query: String, limit: Int = 5) async throws -> [(title: String, text: String, score: Float)] {
        guard let embedder else { throw EmbedderError.notInstalled }
        let q = try await embedder.embed([query], task: .query)[0]
        let chunks = try await store.allChunks()
        let titles = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.title) })
        return chunks.map { (title: titles[$0.sourceId] ?? "?", text: $0.text, score: Vectors.cosine(q, $0.embedding)) }
            .sorted { $0.score > $1.score }
            .prefix(limit).map { $0 }
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
