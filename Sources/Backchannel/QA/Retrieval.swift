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

extension Array where Element == RetrievedPassage {
    /// Titles of the passages the answer cites as `[n]`, in passage order. Every title when it cites none,
    /// so a model that drops the markers still shows what it read.
    func citedTitles(in answer: String) -> [String] {
        let cited = Set(answer.matches(of: /\[(\d+)\]/).compactMap { Int($0.output.1) })
        let picked = cited.isEmpty ? self : enumerated().filter { cited.contains($0.offset + 1) }.map(\.element)
        var seen = Set<String>()
        return picked.map(\.title).filter { seen.insert($0).inserted }
    }
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

    /// Below this cosine similarity a passage is not counted as a vector match. Nearly every
    /// passage scores above zero against any query, so without a floor the vector list is as long
    /// as the library and random passages pick up rank credit.
    static let similarityFloor: Float = 0.2
    /// At most this many passages from one source or meeting, so one long document cannot fill the answer.
    static let perTitleLimit = 2

    static func search(query: String, queryVector: [Float]?, passages: [Passage], limit: Int) -> [RetrievedPassage] {
        guard !passages.isEmpty else { return [] }
        let q = tokenize(query)
        // The title takes part in the keyword match: a question naming a document should find it.
        let lexical = bm25(query: q, docs: passages.map { tokenize($0.title + " " + $0.text) })
        let similarity: [Float] = passages.map { p in
            guard let queryVector, let e = p.embedding else { return 0 }
            return Vectors.cosine(queryVector, e)
        }
        // Rank lists: only passages that actually matched on that side take part.
        let lexicalRank = lexical.indices.filter { lexical[$0] > 0 }.sorted { lexical[$0] > lexical[$1] }
        let vectorRank = similarity.indices.filter { similarity[$0] >= similarityFloor }.sorted { similarity[$0] > similarity[$1] }
        var fused: [Int: Float] = [:]
        let k: Float = 60
        for (rank, i) in lexicalRank.enumerated() { fused[i, default: 0] += 1 / (k + Float(rank + 1)) }
        for (rank, i) in vectorRank.enumerated() { fused[i, default: 0] += 1 / (k + Float(rank + 1)) }
        var perTitle: [String: Int] = [:]
        var out: [RetrievedPassage] = []
        for (i, score) in fused.sorted(by: { $0.value == $1.value ? similarity[$0.key] > similarity[$1.key] : $0.value > $1.value }) {
            let title = passages[i].title
            guard perTitle[title, default: 0] < perTitleLimit else { continue }
            perTitle[title, default: 0] += 1
            out.append(RetrievedPassage(title: title, text: passages[i].text, score: score,
                                        similarity: similarity[i], lexical: lexical[i]))
            if out.count == limit { break }
        }
        return out
    }
}
