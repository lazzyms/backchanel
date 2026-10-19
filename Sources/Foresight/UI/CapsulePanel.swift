import AppKit
import SwiftUI

/// Small always-on-top capsule: red dot, elapsed time, Stop. Lives over every space and full-screen app.
@MainActor
final class CapsulePanel {
    private var panel: NSPanel?

    func show(session: MeetingSession) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = NSHostingView(rootView: CapsuleView(session: session))
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - 120, y: f.maxY - 60))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct CapsuleView: View {
    @Bindable var session: MeetingSession

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                    .opacity(session.state == .recording ? 1 : 0.4)
                Text(session.elapsed.clock)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Button {
                    Task { await session.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            }
            if session.checkpointPromptVisible {
                HStack(spacing: 8) {
                    Text("\(session.checkpointMinutes) min in. Keep going?").font(.caption)
                    Spacer(minLength: 0)
                    Button("Keep going") { session.continueSession() }.controlSize(.mini)
                    Button("Stop") { Task { await session.stop() } }.controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(width: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.15)))
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension TimeInterval {
    var clock: String {
        let s = Int(self)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
