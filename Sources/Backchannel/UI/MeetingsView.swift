import SwiftUI

/// Home: every meeting on the left, the chosen one on the right with Transcript / Summary / Insights tabs.
struct MeetingsView: View {
    @Bindable var model: AppModel
    @State private var selected: Meeting?
    @State private var tab: Tab = .transcript

    enum Tab: String, CaseIterable { case transcript = "Transcript", summary = "Summary", insights = "Insights" }

    private var session: MeetingSession { model.session }
    /// The meeting shown in the detail: the live one while transcribing, else the selection.
    private var shown: Meeting? { session.isActive ? session.meeting : selected }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Meetings")
        .onChange(of: selected) { _, m in if let m { Task { await session.loadHistory(m) } } }
        .onChange(of: session.state) { _, s in if s == .recording { selected = session.meeting } }
        .onChange(of: model.meetings) { _, ms in
            if let selected, !ms.contains(where: { $0.id == selected.id }) { self.selected = nil }
            if let selected, let fresh = ms.first(where: { $0.id == selected.id }) { self.selected = fresh }
        }
    }

    // MARK: List

    private var list: some View {
        List(selection: $selected) {
            ForEach(model.meetings) { m in row(m).tag(m) }
        }
        .listStyle(.inset)
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView {
                    Label("No meetings yet", systemImage: "waveform")
                } description: {
                    Text("Start transcribing to record a meeting. Your mic is “You”, system audio is “Others”.")
                } actions: {
                    Button("Start transcribing") { model.toggleTranscribing() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func row(_ m: Meeting) -> some View {
        let live = session.isActive && session.meeting?.id == m.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if live { Circle().fill(.red).frame(width: 8, height: 8) }
                Text(m.title).font(.body.weight(.medium)).lineLimit(1)
            }
            Text(subtitle(m)).font(.caption).foregroundStyle(.secondary)
            if let s = m.summary {
                Text(s.replacingOccurrences(of: "**", with: "")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !live {
                Button("Delete Meeting", role: .destructive) { Task { await model.deleteMeeting(m) } }
            }
        }
    }

    private func subtitle(_ m: Meeting) -> String {
        var s = m.startedAt.formatted(date: .abbreviated, time: .shortened)
        if let end = m.endedAt { s += " · " + end.timeIntervalSince(m.startedAt).clock }
        else if session.isActive && session.meeting?.id == m.id { s += " · live" }
        return s
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let shown {
            VStack(spacing: 0) {
                header(shown)
                Divider()
                switch tab {
                case .transcript: TranscriptList(session: session)
                case .summary: summary
                case .insights: insights
                }
            }
        } else {
            ContentUnavailableView("Select a meeting", systemImage: "rectangle.stack",
                                   description: Text("Pick a meeting to read its transcript, summary and live answers."))
        }
    }

    private func header(_ m: Meeting) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.title3.weight(.semibold))
                Text(subtitle(m)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if session.state == .summarizing {
                    HStack { ProgressView().controlSize(.small); Text("Writing summary with Apple Intelligence…").foregroundStyle(.secondary) }
                } else if let s = session.meeting?.summary {
                    Text(LocalizedStringKey(s)).textSelection(.enabled)
                    Button("Summarize again") { Task { await session.summarize() } }.disabled(session.state != .idle)
                } else if !OnDeviceLM.isAvailable {
                    Text(OnDeviceLM.availability ?? "Apple Intelligence is not available.").foregroundStyle(.secondary)
                } else if session.segments.isEmpty {
                    Text("Nothing to summarize yet.").foregroundStyle(.secondary)
                } else if session.isActive {
                    Text("The summary is written when the meeting stops.").foregroundStyle(.secondary)
                } else {
                    Button("Summarize meeting") { Task { await session.summarize() } }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var insights: some View {
        List(session.insights) { ins in
            VStack(alignment: .leading, spacing: 4) {
                Text(ins.question).font(.subheadline.weight(.semibold))
                Text(LocalizedStringKey(ins.answer)).textSelection(.enabled)
                if !ins.sourceTitles.isEmpty {
                    Text(ins.sourceTitles.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
        .overlay {
            if session.insights.isEmpty {
                ContentUnavailableView("No insights yet", systemImage: "questionmark.bubble",
                                       description: Text("Questions heard in the meeting are answered here from your sources."))
            }
        }
    }
}

struct TranscriptList: View {
    @Bindable var session: MeetingSession

    var body: some View {
        ScrollViewReader { proxy in
            List(session.segments) { seg in
                HStack(alignment: .top, spacing: 10) {
                    Text(seg.speaker.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(seg.speaker == .me ? Color.accentColor : .secondary)
                        .frame(width: 52, alignment: .trailing)
                    Text(seg.text).foregroundStyle(seg.isFinal ? .primary : .secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Text(seg.startSec.clock).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                .id(seg.id)
            }
            .listStyle(.inset)
            .overlay {
                if session.segments.isEmpty {
                    ContentUnavailableView(session.isActive ? "Listening…" : "No transcript", systemImage: "waveform",
                                           description: Text(session.isActive ? "Words appear here as they are heard." : "This meeting has no transcript."))
                }
            }
            .onChange(of: session.segments.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }
}
