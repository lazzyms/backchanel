import Foundation
import AVFoundation
import AppKit

/// Spoken announcement plus a tone, so everyone present knows a transcript is being made.
@MainActor
final class Announcer: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    override init() { super.init(); synth.delegate = self }

    func playTone() async {
        guard let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true) else { return }
        sound.play()
        try? await Task.sleep(for: .milliseconds(900))
    }

    func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            synth.speak(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
}
