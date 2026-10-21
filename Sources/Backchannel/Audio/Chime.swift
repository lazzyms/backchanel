import Foundation
import AppKit

/// The checkpoint tone. Meetings start and stop silently.
enum Chime {
    @MainActor static func play() {
        NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)?.play()
    }
}
