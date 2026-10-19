import Foundation
import CoreAudio
import AVFoundation

/// Captures everything the Mac plays (the other side of a call) through a CoreAudio process tap,
/// without joining the meeting. Needs the "Screen & System Audio Recording" permission.
final class SystemAudioTap: @unchecked Sendable {
    private let system = AudioHardwareSystem.shared
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.maulik.backchannel.systemtap")
    private(set) var format: AVAudioFormat?

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Backchannel meeting tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard let tap = try system.makeProcessTap(description: desc) else { throw AudioError.tapUnavailable }
        self.tap = tap

        guard let output = try system.defaultOutputDevice else { throw AudioError.noOutputDevice }
        let outputUID = try output.uid
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Backchannel Tap",
            kAudioAggregateDeviceUIDKey: "dev.maulik.backchannel.tap.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard let aggregate = try system.makeAggregateDevice(description: composition) else { throw AudioError.aggregateFailed }
        self.aggregate = aggregate

        var asbd = try tap.format
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw AudioError.badFormat }
        self.format = format

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, queue) { _, inInputData, inInputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            let time = AVAudioTime(audioTimeStamp: inInputTime, sampleRate: format.sampleRate)
            onBuffer(buffer, time)
        }
        guard status == noErr else { throw AudioError.osStatus(status) }
        try aggregate.start(IOProcID: procID)
    }

    func stop() {
        if let aggregate {
            try? aggregate.stop(IOProcID: procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregate.id, procID) }
            try? system.destroyAggregateDevice(aggregate)
        }
        if let tap { try? system.destroyProcessTap(tap) }
        procID = nil; aggregate = nil; tap = nil
    }
}

enum AudioError: Error, LocalizedError {
    case tapUnavailable, noOutputDevice, aggregateFailed, badFormat, osStatus(OSStatus), micDenied
    var errorDescription: String? {
        switch self {
        case .tapUnavailable: "Could not create a system audio tap. Allow Backchannel under System Settings › Privacy & Security › Screen & System Audio Recording."
        case .noOutputDevice: "No default output device."
        case .aggregateFailed: "Could not create the capture device."
        case .badFormat: "Unsupported tap audio format."
        case .osStatus(let s): "CoreAudio error \(s)."
        case .micDenied: "Microphone access was denied. Allow it in System Settings › Privacy & Security › Microphone."
        }
    }
}
