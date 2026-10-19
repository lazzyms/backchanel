import Foundation

/// One searchable passage: a source chunk, a window of a meeting transcript, or a meeting summary.
struct Passage: Sendable {
    let title: String
    let text: String
    /// Nil when the passage was stored without an embedding model; BM25 still finds it.
    let embedding: [Float]?
}

struct RetrievedPassage: Sendable {
    let title: String
    let text: String
    /// Fused rank score (reciprocal rank fusion); only useful for ordering.
    let score: Float
    /// Cosine similarity to the query, 0 when either side has no embedding.
    let similarity: Float
    /// BM25 score, 0 when no query term occurs in the passage.
    let lexical: Float
}

/// Hybrid search: embedding similarity and BM25 over the same passages, merged with reciprocal rank
/// fusion. Either side alone still works, so retrieval degrades to keyword search without a model.
enum Retrieval {
    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .filter { $0.count > 1 }
            .map(String.init)
    }

    /// Okapi BM25 for every document, given tokenised query and documents.
    static func bm25(query: [String], docs: [[String]], k1: Float = 1.2, b: Float = 0.75) -> [Float] {
        guard !docs.isEmpty, !query.isEmpty else { return [Float](repeating: 0, count: docs.count) }
        let n = Float(docs.count)
        let avgLen = docs.reduce(0) { $0 + Float($1.count) } / n
        let terms = Set(query)
        var docFreq: [String: Int] = [:]
        let termCounts: [[String: Int]] = docs.map { doc in
            var counts: [String: Int] = [:]
            for t in doc where terms.contains(t) { counts[t, default: 0] += 1 }
            for t in counts.keys { docFreq[t, default: 0] += 1 }
            return counts
        }
        return docs.indices.map { i in
            let len = Float(docs[i].count)
            var score: Float = 0
            for t in terms {
                guard let tf = termCounts[i][t] else { continue }
                let df = Float(docFreq[t] ?? 0)
                let idf = log((n - df + 0.5) / (df + 0.5) + 1)
                let f = Float(tf)
                score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * len / avgLen))
            }
            return score
        }
    }

    static func search(query: String, queryVector: [Float]?, passages: [Passage], limit: Int) -> [RetrievedPassage] {
        guard !passages.isEmpty else { return [] }
        let q = tokenize(query)
        let lexical = bm25(query: q, docs: passages.map { tokenize($0.text) })
        let similarity: [Float] = passages.map { p in
            guard let queryVector, let e = p.embedding else { return 0 }
            return Vectors.cosine(queryVector, e)
        }
        // Rank lists: only passages that actually matched on that side take part.
        let lexicalRank = lexical.indices.filter { lexical[$0] > 0 }.sorted { lexical[$0] > lexical[$1] }
        let vectorRank = similarity.indices.filter { similarity[$0] > 0 }.sorted { similarity[$0] > similarity[$1] }
        var fused: [Int: Float] = [:]
        let k: Float = 60
        for (rank, i) in lexicalRank.enumerated() { fused[i, default: 0] += 1 / (k + Float(rank + 1)) }
        for (rank, i) in vectorRank.enumerated() { fused[i, default: 0] += 1 / (k + Float(rank + 1)) }
        return fused
            .sorted { $0.value == $1.value ? similarity[$0.key] > similarity[$1.key] : $0.value > $1.value }
            .prefix(limit)
            .map { i, score in
                RetrievedPassage(title: passages[i].title, text: passages[i].text, score: score,
                                 similarity: similarity[i], lexical: lexical[i])
            }
    }
}
