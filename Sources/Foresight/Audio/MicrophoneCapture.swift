import Foundation
import AVFoundation

/// Your own voice, from the default input device.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private(set) var format: AVAudioFormat?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        self.format = format
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in onBuffer(buffer, time) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
