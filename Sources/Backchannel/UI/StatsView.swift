import SwiftUI

/// Stats: what lives on this Mac. Everything here is computed locally; nothing leaves the device.
struct StatsView: View {
    @Bindable var model: AppModel

    private var recorded: TimeInterval {
        model.meetings.reduce(0) { total, m in total + (m.endedAt.map { $0.timeIntervalSince(m.startedAt) } ?? 0) }
    }
    private var labels: Int { Set(model.library.sources.compactMap(\.label)).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Everything is processed and stored on this Mac.").foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    card("Meetings", "\(model.meetings.count)", "rectangle.stack")
                    card("Recorded", recorded.clock, "clock")
                    card("Sources", "\(model.library.sources.count)", "folder")
                    card("Labels", "\(labels)", "tag")
                    card("Questions answered", "\(model.insightCount)", "questionmark.bubble")
                }
                GroupBox("Models") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Embeddings", value: model.library.embedderName)
                        LabeledContent("Summaries and chat", value: model.chatModels.availability ?? model.chatModels.displayName)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(20).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Stats")
        .task { await model.reloadMeetings() }
    }

    private func card(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
