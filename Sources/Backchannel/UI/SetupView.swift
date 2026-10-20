import SwiftUI
import AppKit

/// One row per `SetupItem` with its status and, when something is needed, its single action.
/// Shown as the first onboarding step and as Settings › Setup.
struct SetupView: View {
    let checker: SetupChecker

    var body: some View {
        Form {
            ForEach(SetupItem.allCases) { item in
                LabeledContent {
                    statusView(item, checker.status[item])
                } label: {
                    Text(item.title)
                    Text(item.explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await checker.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checker.refresh() }
        }
    }

    @ViewBuilder
    private func statusView(_ item: SetupItem, _ status: SetupStatus?) -> some View {
        switch status {
        case nil:
            ProgressView().controlSize(.small)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .working(let fraction):
            ProgressView(value: fraction).frame(width: 120)
        case .needsAction(let message, let action):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Button(action.buttonTitle) { Task { await checker.perform(item) } }.controlSize(.small)
            }
            .frame(maxWidth: 260, alignment: .trailing)
        case .unavailable(let message):
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .frame(maxWidth: 260, alignment: .trailing)
        }
    }
}
