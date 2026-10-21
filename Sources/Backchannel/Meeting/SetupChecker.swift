import Foundation
import AppKit
import AVFoundation
import Observation
import Speech
import FluidAudio

/// One thing the Mac needs before meetings work. The table of cases is the whole feature: a row
/// in onboarding and in Settings › Setup per case, a check and one action per case in `SetupChecker`.
enum SetupItem: CaseIterable, Identifiable {
    case appleIntelligence, microphone, speechModel, systemAudio, speakerModels

    var id: Self { self }

    var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .microphone: "Microphone"
        case .speechModel: "Speech model"
        case .systemAudio: "System audio"
        case .speakerModels: "Voice models"
        }
    }

    var explanation: String {
        switch self {
        case .appleIntelligence: "Labels sources, spots questions during a meeting and writes summaries on this Mac."
        case .microphone: "Your side of the meeting."
        case .speechModel: "Transcribes speech on this Mac, offline once downloaded."
        case .systemAudio: "The other side of the meeting, captured from what the Mac plays."
        case .speakerModels: "Tells the other voices apart after each meeting."
        }
    }
}

enum SetupAction: Equatable {
    case allow, download, openSystemSettings(URL)

    var buttonTitle: String {
        switch self {
        case .allow: "Allow"
        case .download: "Download"
        case .openSystemSettings: "Open System Settings"
        }
    }
}

enum SetupStatus: Equatable {
    case ready
    case needsAction(String, SetupAction)
    /// In progress; the fraction is nil when the work reports no progress.
    case working(Double?)
    case unavailable(String)
}

/// Readiness of every `SetupItem`. `refresh()` only reads; `perform(_:)` runs the item's single
/// action, which may raise a system permission prompt or start a download.
@MainActor
@Observable
final class SetupChecker {
    private(set) var status: [SetupItem: SetupStatus] = [:]
    private let session: MeetingSession
    private static let systemAudioGrantedKey = "systemAudioGranted"

    init(session: MeetingSession) {
        self.session = session
    }

    var allReady: Bool { SetupItem.allCases.allSatisfy { status[$0] == .ready } }

    /// Re-evaluates every item that is not mid-action. Cheap, read-only, raises no prompts.
    func refresh() async {
        for item in SetupItem.allCases {
            if case .working = status[item] { continue }
            status[item] = await check(item)
        }
    }

    func perform(_ item: SetupItem) async {
        guard case .needsAction(_, let action) = status[item] else { return }
        if case .openSystemSettings(let url) = action {
            NSWorkspace.shared.open(url)
            return
        }
        let failure: SetupStatus?
        switch item {
        case .appleIntelligence:
            failure = nil
        case .microphone:
            _ = await MicrophoneCapture.requestAccess()
            failure = nil
        case .speechModel:
            failure = await downloadSpeechModel()
        case .systemAudio:
            failure = probeSystemAudio()
        case .speakerModels:
            status[item] = .working(nil)
            do {
                try await OfflineDiarizerManager().prepareModels(directory: SpeakerRecognizer.modelsDirectory)
                failure = nil
            } catch {
                failure = .needsAction(error.localizedDescription, .download)
            }
        }
        status[item] = if let failure { failure } else { await check(item) }
    }

    // MARK: - Checks

    private func check(_ item: SetupItem) async -> SetupStatus {
        switch item {
        case .appleIntelligence:
            guard let message = OnDeviceLM.availability else { return .ready }
            if message.contains("does not support") { return .unavailable(message) }
            return .needsAction(message, .openSystemSettings(Self.appleIntelligenceSettings))
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .ready
            case .notDetermined: return .needsAction("Backchannel needs the microphone for your side of the meeting.", .allow)
            default: return .needsAction("Microphone access was denied.", .openSystemSettings(Self.microphoneSettings))
            }
        case .speechModel:
            guard SpeechTranscriber.isAvailable else { return .unavailable(TranscriptionError.unavailable.localizedDescription) }
            guard let locale = await TranscriptionChannel.preferredLocale() else { return .unavailable(TranscriptionError.noLocale.localizedDescription) }
            switch await AssetInventory.status(forModules: [TranscriptionChannel.makeTranscriber(locale: locale)]) {
            case .installed: return .ready
            case .downloading: return .working(nil)
            case .supported:
                let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                return .needsAction("The speech model for \(name) is not downloaded yet.", .download)
            case .unsupported: return .unavailable(TranscriptionError.noLocale.localizedDescription)
            @unknown default: return .unavailable(TranscriptionError.unavailable.localizedDescription)
            }
        case .systemAudio:
            if UserDefaults.standard.bool(forKey: Self.systemAudioGrantedKey) { return .ready }
            return .needsAction("macOS asks for Screen & System Audio Recording the first time the other side of a meeting is captured. Allow it now so the first meeting starts clean.", .allow)
        case .speakerModels:
            if SpeakerRecognizer.modelsInstalled { return .ready }
            return .needsAction("Voice models for naming who spoke (downloaded once, used after each meeting).", .download)
        }
    }

    // MARK: - Actions

    /// Returns the failure to show, or nil when the download finished.
    private func downloadSpeechModel() async -> SetupStatus? {
        guard let locale = await TranscriptionChannel.preferredLocale() else { return nil }
        status[.speechModel] = .working(nil)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [TranscriptionChannel.makeTranscriber(locale: locale)]) else { return nil }
            let progress = request.progress
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    self?.status[.speechModel] = .working(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
            return nil
        } catch {
            return .needsAction(error.localizedDescription, .download)
        }
    }

    /// Creating and starting a tap is what makes macOS ask for Screen & System Audio Recording.
    /// Never during a meeting: the session owns the only tap then.
    private func probeSystemAudio() -> SetupStatus? {
        guard session.state == .idle else { return nil }
        let tap = SystemAudioTap()
        do {
            try tap.start { _, _ in }
            tap.stop()
            UserDefaults.standard.set(true, forKey: Self.systemAudioGrantedKey)
            return nil
        } catch {
            tap.stop()
            return .needsAction(error.localizedDescription, .openSystemSettings(Self.screenCaptureSettings))
        }
    }

    private static let appleIntelligenceSettings = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
    private static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!
    private static let screenCaptureSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
}
