import Foundation
import AVFoundation
import Observation

/// Coordinates one live meeting: capture → transcription → storage, then on stop speaker
/// recognition → summary → search index. It never stops on its own. Every `checkpointMinutes`
/// it asks whether to keep going and keeps going.
@MainActor
@Observable
final class MeetingSession {
    enum State: Equatable { case idle, preparing, recording, stopping, recognizing, summarizing }

    private(set) var state: State = .idle
    private(set) var meeting: Meeting?
    private(set) var elapsed: TimeInterval = 0
    private(set) var segments: [TranscriptSegment] = []
    private(set) var insights: [Insight] = []
    /// A question typed under Insights is being answered.
    private(set) var answering = false
    var errorMessage: String?

    /// Whether to ask at all, and how often. The prompt only asks; nothing stops unless the user stops it.
    var checkpointEnabled: Bool = UserDefaults.standard.object(forKey: "checkpointEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkpointEnabled, forKey: "checkpointEnabled"); if !checkpointEnabled { checkpointPromptVisible = false } }
    }
    var checkpointMinutes: Int = (UserDefaults.standard.object(forKey: "checkpointMinutes") as? Int).map { max(10, $0) } ?? 30 {
        didSet { UserDefaults.standard.set(checkpointMinutes, forKey: "checkpointMinutes") }
    }
    private(set) var checkpointPromptVisible = false
    private var nextCheckpoint: TimeInterval = 0

    var liveQA: LiveQA?

    private let store: Store
    private let chat: ChatModelManager
    private let library: SourceLibrary
    private let mic = MicrophoneCapture()
    private let systemTap = SystemAudioTap()
    private var micChannel: TranscriptionChannel?
    private var systemChannel: TranscriptionChannel?
    private var recorder: SpeakerRecorder?
    private var ticker: Task<Void, Never>?
    private var startDate: Date?

    init(store: Store, chat: ChatModelManager, library: SourceLibrary) {
        self.store = store; self.chat = chat; self.library = library
    }

    var isActive: Bool { state != .idle }

    /// How the user's own lines are labelled; set under Settings › Meetings.
    static var userName: String {
        let n = UserDefaults.standard.string(forKey: "userName")?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "You" : n
    }

    func start(title: String) async {
        guard state == .idle else { return }
        state = .preparing
        errorMessage = nil
        segments = []; insights = []; elapsed = 0
        do {
            guard await MicrophoneCapture.requestAccess() else { throw AudioError.micDenied }
            guard SpeechTranscriber_isAvailable() else { throw TranscriptionError.unavailable }
            guard let locale = await TranscriptionChannel.preferredLocale() else { throw TranscriptionError.noLocale }

            let meeting = try await store.createMeeting(title: title)
            self.meeting = meeting

            let micChannel = TranscriptionChannel(speaker: .me, name: Self.userName, locale: locale)
            let systemChannel = TranscriptionChannel(speaker: .them, name: Speaker.them.rawValue, locale: locale)
            self.micChannel = micChannel; self.systemChannel = systemChannel
            let handler: @Sendable (TranscriptSegment) -> Void = { [weak self] seg in
                Task { @MainActor in self?.receive(seg) }
            }
            try await micChannel.start(onSegment: handler)
            try await systemChannel.start(onSegment: handler)

            let recorder = SpeakerRecorder()
            self.recorder = recorder
            try systemTap.start { buffer, time in
                systemChannel.feed(buffer, at: time)
                recorder.append(buffer)
            }
            try mic.start { buffer, time in micChannel.feed(buffer, at: time) }

            startDate = Date()
            nextCheckpoint = TimeInterval(checkpointMinutes * 60)
            state = .recording
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await self?.tick()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            await teardown()
        }
    }

    func stop() async {
        guard state == .recording else { return }
        state = .stopping
        await teardown()
        await recognizeSpeakers()
        await index()
        await summarize()
    }

    /// Names the other participants' lines by voice. Errors here are not fatal: lines stay "Others".
    private func recognizeSpeakers() async {
        guard state == .idle, let meeting, let audio = recorder?.finish() else { return }
        recorder = nil
        defer { try? FileManager.default.removeItem(at: audio) }
        guard segments.contains(where: { $0.speaker == .them && $0.isFinal }) else { return }
        state = .recognizing
        defer { state = .idle }
        do {
            // The mic is the user, so a saved voice carrying the user's name never labels system audio.
            let me = Self.userName
            let known = try await store.speakers().filter { $0.name.caseInsensitiveCompare(me) != .orderedSame }
            let result = try await SpeakerRecognizer.recognize(audio: audio, segments: segments, known: known, meeting: meeting.title)
            for (name, emb) in result.newSpeakers { _ = try await store.insertSpeaker(name: name, embedding: emb) }
            for (id, emb) in result.refreshed { try await store.updateSpeakerEmbedding(id: id, emb) }
            for i in segments.indices {
                guard let name = result.names[segments[i].id] else { continue }
                segments[i].name = name
                try await store.setSpeakerName(meetingId: meeting.id, speaker: segments[i].speaker, startSec: segments[i].startSec, name: name)
            }
        } catch {
            errorMessage = "Speaker recognition failed: \(error.localizedDescription)"
        }
    }

    /// Writes the meeting summary with the chosen chat model. Runs after every stop; can be re-run on history.
    func summarize() async {
        guard state == .idle, let meeting, chat.isAvailable else { return }
        let lines = transcriptLines
        guard !lines.isEmpty else { return }
        state = .summarizing
        defer { state = .idle }
        do {
            let summary = try await MeetingSummarizer.summarize(lines, using: chat)
            try await store.setSummary(meetingId: meeting.id, summary)
            self.meeting?.summary = summary
            await library.indexMeeting(self.meeting!, segments: segments.filter(\.isFinal))
        } catch {
            errorMessage = "Summary failed: \(error.localizedDescription)"
        }
    }

    /// Puts the transcript into the chat's search corpus; the summary is added when it is written.
    private func index() async {
        guard let meeting else { return }
        await library.indexMeeting(meeting, segments: segments.filter(\.isFinal))
    }

    /// Transcript lines for chat and summaries.
    var transcriptLines: [String] { segments.filter(\.isFinal).map { "\($0.name): \($0.text)" } }

    /// Renames a recognised voice everywhere: this transcript, stored lines, the voice library and the search index.
    func renameSpeaker(from old: String, to new: String) async {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        for i in segments.indices where segments[i].name == old { segments[i].name = new }
        try? await store.renameSpeaker(from: old, to: new)
    }

    /// The user answered the checkpoint prompt with "keep going". Nothing else changes.
    func continueSession() {
        checkpointPromptVisible = false
        nextCheckpoint = elapsed + TimeInterval(checkpointMinutes * 60)
    }

    func loadHistory(_ meeting: Meeting) async {
        guard state == .idle else { return }
        self.meeting = meeting
        segments = (try? await store.segments(meetingId: meeting.id)) ?? []
        insights = (try? await store.insights(meetingId: meeting.id)) ?? []
    }

    // MARK: - Private

    private func tick() async {
        guard let startDate, state == .recording else { return }
        elapsed = Date().timeIntervalSince(startDate)
        if checkpointEnabled, elapsed >= nextCheckpoint, !checkpointPromptVisible {
            checkpointPromptVisible = true
            nextCheckpoint = elapsed + TimeInterval(checkpointMinutes * 60)
            Chime.play()
        }
    }

    private func receive(_ segment: TranscriptSegment) {
        var segment = segment
        if segment.isFinal, let fixed = library.vocabulary.correct(segment.text) {
            segment.heard = segment.text; segment.text = fixed
        }
        if let i = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[i] = segment
        } else {
            // Drop the previous volatile segment of this speaker: the engine re-emits the growing phrase.
            segments.removeAll { $0.speaker == segment.speaker && !$0.isFinal }
            segments.append(segment)
            segments.sort { $0.startSec < $1.startSec }
        }
        guard segment.isFinal, let meeting else { return }
        Task { try? await store.appendSegment(meetingId: meeting.id, segment) }
        Task { await liveQA?.consider(segment, in: meeting, session: self) }
    }

    func addInsight(_ insight: Insight) { insights.append(insight) }

    /// A question typed under Insights: answered from the sources with the chat model, kept with the
    /// meeting like one heard in the audio. Live questions come from `LiveQAService` instead.
    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let meeting, !q.isEmpty, !answering else { return }
        answering = true
        defer { answering = false }
        do {
            if let why = chat.availability { throw ChatBackendError.unavailable(why) }
            let hits = try await library.retrieve(q, limit: 4)
            let passages = hits.enumerated().map { i, h in "[\(i + 1)] \(h.title)\n\(String(h.text.prefix(1500)))" }.joined(separator: "\n\n")
            let conversation = try chat.makeConversation(instructions: """
            Answer the question using only the provided passages. Be concise (2-4 sentences). \
            If the passages do not contain the answer, say so in one sentence.
            """)
            let answer = try await conversation.send("Passages:\n\(passages)\n\nQuestion: \(q)")
            let titles = hits.citedTitles(in: answer)
            let insight = try await store.appendInsight(meetingId: meeting.id, question: q, answer: answer, sourceTitles: titles)
            insights.append(insight)
        } catch {
            errorMessage = "Couldn't answer: \(error.localizedDescription)"
        }
    }

    private func teardown() async {
        ticker?.cancel(); ticker = nil
        checkpointPromptVisible = false
        mic.stop()
        systemTap.stop()
        await micChannel?.stop()
        await systemChannel?.stop()
        micChannel = nil; systemChannel = nil
        if let meeting { try? await store.endMeeting(id: meeting.id) }
        if let startDate { elapsed = Date().timeIntervalSince(startDate) }
        startDate = nil
        state = .idle
    }
}

/// Live question detection and answering, attached by the app once sources and the language model exist.
protocol LiveQA: AnyObject, Sendable {
    func consider(_ segment: TranscriptSegment, in meeting: Meeting, session: MeetingSession) async
}

import Speech
private func SpeechTranscriber_isAvailable() -> Bool { SpeechTranscriber.isAvailable }
