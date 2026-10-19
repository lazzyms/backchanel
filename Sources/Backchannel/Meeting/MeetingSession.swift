import Foundation
import AVFoundation
import Observation

/// Coordinates one live meeting: announcement → capture → transcription → storage.
/// It never stops on its own. Every `checkpointMinutes` it asks whether to keep going and keeps going.
@MainActor
@Observable
final class MeetingSession {
    enum State: Equatable { case idle, preparing, announcing, recording, stopping, summarizing }

    private(set) var state: State = .idle
    private(set) var meeting: Meeting?
    private(set) var elapsed: TimeInterval = 0
    private(set) var segments: [TranscriptSegment] = []
    private(set) var insights: [Insight] = []
    var errorMessage: String?

    /// Prompt cadence. The prompt only asks; nothing stops unless the user stops it.
    var checkpointMinutes: Int = 30
    private(set) var checkpointPromptVisible = false
    private var nextCheckpoint: TimeInterval = 0

    var liveQA: LiveQA?

    private let store: Store
    private let announcer = Announcer()
    private let mic = MicrophoneCapture()
    private let systemTap = SystemAudioTap()
    private var micChannel: TranscriptionChannel?
    private var systemChannel: TranscriptionChannel?
    private var ticker: Task<Void, Never>?
    private var startDate: Date?

    init(store: Store) { self.store = store }

    var isActive: Bool { state != .idle }

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

            let micChannel = TranscriptionChannel(speaker: .me, locale: locale)
            let systemChannel = TranscriptionChannel(speaker: .them, locale: locale)
            self.micChannel = micChannel; self.systemChannel = systemChannel
            let handler: @Sendable (TranscriptSegment) -> Void = { [weak self] seg in
                Task { @MainActor in self?.receive(seg) }
            }
            try await micChannel.start(onSegment: handler)
            try await systemChannel.start(onSegment: handler)

            state = .announcing
            await announcer.playTone()
            await announcer.speak("Backchannel is now transcribing this meeting.")

            try systemTap.start { buffer, time in systemChannel.feed(buffer, at: time) }
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
        guard state == .recording || state == .announcing else { return }
        state = .stopping
        await teardown()
        await summarize()
    }

    /// Writes the meeting summary with the on-device model. Runs after every stop; can be re-run on history.
    func summarize() async {
        guard state == .idle, let meeting, OnDeviceLM.isAvailable else { return }
        let lines = segments.filter(\.isFinal).map { "\($0.speaker.rawValue): \($0.text)" }
        guard !lines.isEmpty else { return }
        state = .summarizing
        defer { state = .idle }
        do {
            let summary = try await OnDeviceLM.summarize(transcript: lines)
            try await store.setSummary(meetingId: meeting.id, summary)
            self.meeting?.summary = summary
        } catch {
            errorMessage = "Summary failed: \(error.localizedDescription)"
        }
    }

    /// Transcript lines for chat and summaries.
    var transcriptLines: [String] { segments.filter(\.isFinal).map { "\($0.speaker.rawValue): \($0.text)" } }

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
        if elapsed >= nextCheckpoint, !checkpointPromptVisible {
            checkpointPromptVisible = true
            nextCheckpoint = elapsed + TimeInterval(checkpointMinutes * 60)
            await announcer.playTone()
        }
    }

    private func receive(_ segment: TranscriptSegment) {
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
