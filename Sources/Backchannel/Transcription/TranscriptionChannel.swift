import Foundation
import AVFoundation
import Speech

/// One on-device SpeechAnalyzer pipeline for one audio stream (mic or system audio).
/// Fully offline once the locale assets are installed.
final class TranscriptionChannel: @unchecked Sendable {
    let speaker: Speaker
    /// Name written on every line: the user's name for the mic, "Others" for system audio until voices are recognised.
    let name: String
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var converter: AnalyzerInputConverter?
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let inputSequence: AsyncStream<AnalyzerInput>
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()

    init(speaker: Speaker, name: String, locale: Locale) {
        self.speaker = speaker
        self.name = name
        transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [.audioTimeRange])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    static func preferredLocale() async -> Locale? {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return l }
        return await SpeechTranscriber.supportedLocales.first { $0.identifier(.bcp47).hasPrefix("en") }
    }

    /// Downloads the speech model for the locale if it is not installed yet (one-time, then offline).
    func ensureAssets() async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        try await ensureAssets()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noFormat
        }
        converter = AnalyzerInputConverter(analyzerFormat: format)
        try await analyzer.prepareToAnalyze(in: format)
        let speaker = self.speaker, name = self.name
        let transcriber = self.transcriber
        resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    onSegment(TranscriptSegment(id: "\(speaker.rawValue)-\(start)", speaker: speaker, name: name, text: text,
                                                startSec: start, endSec: end, isFinal: result.isFinal))
                }
            } catch {
                NSLog("[\(speaker.rawValue)] transcription ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: inputSequence)
    }

    /// Called from the audio thread. Conversion is cheap; yield is non-blocking.
    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard let converter else { return }
        do {
            for input in try converter.convert(buffer, at: nil) { inputBuilder.yield(input) }
        } catch {
            NSLog("[\(speaker.rawValue)] convert failed: \(error)")
        }
    }

    func stop() async {
        lock.withLock {
            if let converter, let rest = try? converter.flush() { rest.forEach { inputBuilder.yield($0) } }
            converter = nil
        }
        inputBuilder.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
    }
}

enum TranscriptionError: Error, LocalizedError {
    case noFormat, noLocale, unavailable
    var errorDescription: String? {
        switch self {
        case .noFormat: "No compatible audio format for the speech model."
        case .noLocale: "On-device transcription does not support your language."
        case .unavailable: "On-device speech transcription is not available on this Mac."
        }
    }
}
