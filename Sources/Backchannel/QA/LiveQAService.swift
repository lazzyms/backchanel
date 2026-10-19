import Foundation

/// Watches final transcript segments, spots questions, answers them from the sources with the on-device model.
final class LiveQAService: LiveQA, @unchecked Sendable {
    private let library: SourceLibrary
    private let store: Store
    private var recent: [String] = []
    private var answered: Set<String> = []

    init(library: SourceLibrary, store: Store) {
        self.library = library; self.store = store
    }

    func consider(_ segment: TranscriptSegment, in meeting: Meeting, session: MeetingSession) async {
        recent.append("\(segment.speaker.rawValue): \(segment.text)")
        if recent.count > 12 { recent.removeFirst() }
        guard looksLikeQuestion(segment.text), OnDeviceLM.isAvailable else { return }
        guard let check = try? await OnDeviceLM.detectQuestion(segment.text, recent: recent), check.isQuestion else { return }
        let key = check.question.lowercased()
        guard !answered.contains(key) else { return }
        answered.insert(key)
        do {
            let hits = try await library.retrieve(check.question, limit: 4)
            guard let best = hits.first, best.score > 0.25 else { return }
            let answer = try await OnDeviceLM.answer(question: check.question, passages: hits.map { ($0.title, $0.text) })
            let titles = Array(Set(hits.map(\.title)))
            let insight = try await store.appendInsight(meetingId: meeting.id, question: check.question, answer: answer, sourceTitles: titles)
            await session.addInsight(insight)
        } catch {
            NSLog("live QA failed: \(error)")
        }
    }

    /// Cheap pre-filter so the language model only sees plausible questions.
    private func looksLikeQuestion(_ t: String) -> Bool {
        let s = t.lowercased()
        if s.hasSuffix("?") { return true }
        let starters = ["what", "when", "where", "who", "why", "how", "which", "can you", "could you", "do we", "did we", "is there", "are there", "does", "remind me"]
        return starters.contains { s.hasPrefix($0 + " ") }
    }
}
