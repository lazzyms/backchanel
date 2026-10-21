import Foundation
import AVFoundation
import FluidAudio

/// Writes the system-audio stream to a 16 kHz mono WAV while a meeting runs, so the other
/// participants' voices can be told apart after it stops. The mic stream is the user and needs none.
final class SpeakerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let url: URL
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("backchannel-\(UUID().uuidString).wav")
    }

    /// Called from the tap's queue with buffers in the tap's native format.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            guard let f = try? AVAudioFile(forWriting: url, settings: Self.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
            file = f
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
        }
        guard let converter, let file else { return }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        if error == nil, out.frameLength > 0 { try? file.write(from: out) }
    }

    /// Closes the file and hands back its URL, or nil when nothing was recorded.
    func finish() -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard file != nil else { return nil }
        file = nil; converter = nil
        return url
    }
}

/// Who spoke which transcript line, from FluidAudio's offline diarization (pyannote segmentation +
/// WeSpeaker embeddings, Core ML). Clusters are matched to voices heard in earlier meetings and
/// otherwise named "Speaker N"; the user can rename them afterwards.
enum SpeakerRecognizer {
    static let modelsDirectory = Store.appSupport.appendingPathComponent("models/diarization", isDirectory: true)
    /// Cosine similarity needed to call a cluster the same person as a stored voice. The diarizer's
    /// own clustering threshold is about 0.82 cosine; cross-meeting matching is looser on purpose.
    static let matchThreshold: Float = 0.75

    /// Whether `prepareModels(directory:)` would find everything on disk. Mirrors FluidAudio's own
    /// cache check: every required offline-diarizer file under `<directory>/<repo folder>`.
    static var modelsInstalled: Bool {
        let repo = modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: repo.appendingPathComponent($0).path)
        }
    }

    struct Assignment: Sendable {
        /// Transcript segment id → speaker name.
        var names: [String: String]
        /// Names heard for the first time, with the voice to remember.
        var newSpeakers: [(name: String, embedding: [Float])]
        /// Existing speakers whose voice embedding should drift towards this meeting's sample.
        var refreshed: [(id: Int64, embedding: [Float])]
    }

    static func recognize(audio url: URL, segments: [TranscriptSegment], known: [KnownSpeaker]) async throws -> Assignment {
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels(directory: modelsDirectory)
        let result = try await manager.process(url)
        return assign(result, segments: segments, known: known)
    }

    static func assign(_ result: DiarizationResult, segments: [TranscriptSegment], known: [KnownSpeaker]) -> Assignment {
        // One embedding per cluster: the diarizer's database when present, else the mean of its segments.
        var clusters: [String: [Float]] = result.speakerDatabase ?? [:]
        if clusters.isEmpty {
            for (id, segs) in Dictionary(grouping: result.segments, by: \.speakerId) {
                clusters[id] = Vectors.mean(segs.map(\.embedding))
            }
        }
        // Name each cluster: best known voice above the threshold (each known voice used once), else Speaker N.
        var names: [String: String] = [:]
        var assignment = Assignment(names: [:], newSpeakers: [], refreshed: [])
        var usedKnown = Set<Int64>()
        var candidates: [(cluster: String, known: KnownSpeaker, score: Float)] = []
        for (cluster, emb) in clusters {
            for k in known { candidates.append((cluster, k, Vectors.cosine(emb, k.embedding))) }
        }
        for c in candidates.sorted(by: { $0.score > $1.score }) where c.score >= matchThreshold {
            guard names[c.cluster] == nil, !usedKnown.contains(c.known.id) else { continue }
            names[c.cluster] = c.known.name; usedKnown.insert(c.known.id)
            assignment.refreshed.append((c.known.id, Vectors.normalized(Vectors.mean([c.known.embedding, c.known.embedding, clusters[c.cluster]!]))))
        }
        let taken = Set(known.map(\.name))
        var n = 1
        // Unnamed clusters in order of first appearance.
        let order = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }.map(\.speakerId)
        for cluster in order where names[cluster] == nil {
            while taken.contains("Speaker \(n)") || names.values.contains("Speaker \(n)") { n += 1 }
            names[cluster] = "Speaker \(n)"
            if let emb = clusters[cluster] { assignment.newSpeakers.append(("Speaker \(n)", emb)) }
            n += 1
        }
        // Each transcript line takes the cluster that overlaps it most in time.
        for seg in segments where seg.speaker == .them && seg.isFinal {
            var overlap: [String: Float] = [:]
            for d in result.segments {
                let o = min(Float(seg.endSec), d.endTimeSeconds) - max(Float(seg.startSec), d.startTimeSeconds)
                if o > 0 { overlap[d.speakerId, default: 0] += o }
            }
            if let best = overlap.max(by: { $0.value < $1.value }), let name = names[best.key] {
                assignment.names[seg.id] = name
            }
        }
        return assignment
    }
}
