import Foundation

/// Words the speech model does not know but the user's sources do: product names, trade terms,
/// people. Built from source titles and labels plus the list under Settings › Meetings, and used to
/// repair transcript lines and questions before they reach retrieval ("hola sale" → "wholesale").
struct Vocabulary: Sendable {
    /// Terms worth correcting towards, lowercased, with the display spelling kept.
    private let terms: [String: String]
    /// Sound key → terms that share it, so a span is compared with a handful of terms, not all.
    private let byKey: [String: [String]]

    static let userDefaultsKey = "vocabulary"
    static let empty = Vocabulary(words: [])

    /// Words typed under Settings, one per line or comma-separated.
    static var userWords: [String] {
        (UserDefaults.standard.string(forKey: userDefaultsKey) ?? "")
            .split { $0 == "\n" || $0 == "," }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init(words: [String]) {
        var terms: [String: String] = [:]
        for w in words {
            let letters = w.filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
            guard letters.count >= 5 else { continue }
            terms[letters.lowercased()] = terms[letters.lowercased()] ?? letters
        }
        self.terms = terms
        self.byKey = Dictionary(grouping: terms.keys, by: Self.soundKey)
    }

    /// Titles and labels of the sources, split into words long enough to be worth correcting.
    static func fromSources(_ sources: [Source]) -> Vocabulary {
        var words = userWords
        for s in sources {
            words += s.title.split { !($0.isLetter || $0.isNumber) }.map(String.init)
            if let l = s.label { words += l.split { !($0.isLetter || $0.isNumber) }.map(String.init) }
        }
        return Vocabulary(words: words)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// The text with misheard spans replaced, or nil when nothing changed. Spans of one to three
    /// words are compared by sound key and by letters; a single word must match the sound key
    /// exactly, since short words have many near neighbours in ordinary English.
    func correct(_ text: String) -> String? {
        guard !terms.isEmpty else { return nil }
        let lower = text.lowercased()
        let words = Self.wordRanges(in: text)
        var replacements: [(Range<String.Index>, String)] = []
        var i = 0
        while i < words.count {
            var matched = false
            // A span never starts on a function word, so "the hole sale" corrects "hole sale", not all three.
            if !Self.stopWords.contains(String(lower[words[i]])) {
                for span in stride(from: min(3, words.count - i), through: 1, by: -1) {
                    let range = words[i].lowerBound..<words[i + span - 1].upperBound
                    let joined = lower[range].filter { $0.isLetter || $0.isNumber }
                    guard joined.count >= 5, terms[joined] == nil, let term = best(for: joined, words: span) else { continue }
                    replacements.append((range, Self.cased(term, like: String(text[range]))))
                    i += span; matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        guard !replacements.isEmpty else { return nil }
        var out = text
        for (range, term) in replacements.reversed() { out.replaceSubrange(range, with: term) }
        return out
    }

    static let stopWords: Set<String> = ["the", "a", "an", "of", "is", "are", "was", "our", "at", "in", "on", "to", "and", "or", "for", "we", "i", "it", "my", "your", "that", "this", "with", "be"]

    /// The closest term by letters among those that sound alike. One word must share the sound key
    /// exactly and three words too; two words may differ by one key letter, where the engine's word
    /// split hides most mishearings. Letter distance is bounded by the term, not the span.
    private func best(for joined: String, words: Int) -> String? {
        let key = Self.soundKey(joined)
        var candidates = byKey[key] ?? []
        if words == 2 {
            for (k, ts) in byKey where k != key && Self.distance(k, key) <= 1 { candidates += ts }
        }
        var bestTerm: String?
        var bestDistance = Int.max
        let heard = Self.normalized(joined)
        for t in candidates {
            let letters = Self.normalized(t)
            let d = Self.distance(heard, letters)
            let budget = Self.soundKey(letters) == key ? letters.count / 2 : letters.count / 3
            if d <= budget, d < bestDistance { bestTerm = t; bestDistance = d }
        }
        return bestTerm.map { terms[$0] ?? $0 }
    }

    /// Capitalises the replacement like the span it replaces, so a sentence start stays one.
    private static func cased(_ term: String, like original: String) -> String {
        guard let first = original.first, first.isUppercase, let t = term.first, t.isLowercase else { return term }
        return term.prefix(1).uppercased() + term.dropFirst()
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for i in text.indices {
            let c = text[i]
            if c.isLetter || c.isNumber || (c == "'" && start != nil) {
                if start == nil { start = i }
            } else if let s = start {
                ranges.append(s..<i); start = nil
            }
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }

    /// A consonant skeleton: common English confusions collapse to one key, vowels drop after the
    /// first letter, doubles collapse. "wholesale" and "hola sale" both become "HLSL".
    static func soundKey(_ word: String) -> String {
        var out = ""
        for (i, c) in normalized(word).enumerated() {
            if i > 0, "aeiou".contains(c) { continue }
            if let last = out.last, last == c { continue }
            out.append(c)
        }
        return out.uppercased()
    }

    /// Letters with the common confusions folded ("wh"→"h", "ck"→"k", "x"→"ks"…), vowels kept.
    static func normalized(_ word: String) -> String {
        var s = word.lowercased().filter { $0.isLetter }
        for (from, to) in [("wh", "h"), ("w", "h"), ("ph", "f"), ("ck", "k"), ("sch", "sk"), ("gh", ""), ("kn", "n"), ("wr", "r"), ("qu", "k"), ("x", "ks"), ("z", "s"), ("v", "f"), ("c", "k"), ("q", "k"), ("y", "i")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
