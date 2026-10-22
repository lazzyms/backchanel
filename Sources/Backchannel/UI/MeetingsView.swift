import SwiftUI

/// Home: every meeting on the left, the chosen one on the right with Transcript / Summary / Insights tabs.
struct MeetingsView: View {
    @Bindable var model: AppModel
    @State private var selected: Meeting?
    @State private var tab: Tab = .transcript
    @State private var pendingDelete: Meeting?
    @State private var insightDraft = ""

    enum Tab: String, CaseIterable { case transcript = "Transcript", summary = "Summary", insights = "Insights", notes = "Notes" }

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
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { m in
            Button("Delete Meeting", role: .destructive) { Task { await model.deleteMeeting(m) } }
        } message: { _ in
            Text("The transcript, summary, insights and notes are removed. This cannot be undone.")
        }
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
        .accessibilityLabel("Meetings")
        .accessibilityIdentifier("meetingsList")
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                       description: Text("Your first one appears here when you stop it."))
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
                Button("Delete Meeting…", role: .destructive) { pendingDelete = m }
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
                case .transcript: TranscriptList(session: session, userName: MeetingSession.userName)
                case .summary: summary
                case .insights: insights
                case .notes: NotesEditor(session: session)
                }
            }
        } else if model.meetings.isEmpty {
            FirstMeetingGuide(model: model)
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
            Button { Task { await session.export() } } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .help("Export this meeting as Markdown: notes, summary, insights and transcript (⌘E)")
                .accessibilityLabel("Export meeting")
                .accessibilityIdentifier("exportMeeting")
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Transcript is what was heard. Summary is written when the meeting stops. Insights are questions heard in the meeting, answered from your sources.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Count in the segment label so the picker says what is behind it before it is opened.
    private func label(_ t: Tab) -> String {
        switch t {
        case .transcript: t.rawValue
        case .summary: t.rawValue
        case .insights: session.insights.isEmpty ? t.rawValue : "\(t.rawValue) (\(session.insights.count))"
        case .notes: (session.meeting?.notes.isEmpty ?? true) ? t.rawValue : "\(t.rawValue) •"
        }
    }

    /// Every state the summary pane can be in, derived once so the strip and the action agree.
    private enum SummaryState {
        case working(String), written(String), blocked(String), waiting(String), ready
    }

    private var summaryState: SummaryState {
        if session.state == .recognizing { return .working("Recognizing speakers…") }
        if session.state == .summarizing { return .working("Writing summary with \(model.chatModels.displayName)…") }
        if let s = session.meeting?.summary { return .written(s) }
        if let why = model.chatModels.availability { return .blocked(why) }
        if session.segments.isEmpty { return .waiting("Nothing to summarize yet.") }
        if session.isActive { return .waiting("Written when the meeting stops.") }
        return .ready
    }

    private var summary: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                switch summaryState {
                case .working(let text):
                    ProgressView().controlSize(.small); Text(text)
                case .written:
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Summary by \(model.chatModels.displayName)")
                    Spacer()
                    Button("Summarize again") { Task { await session.summarize() } }.disabled(session.state != .idle)
                case .blocked(let why):
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text(why)
                    Spacer()
                    Button("Chat settings") { model.settingsTab = .chat; openSettings() }
                case .waiting(let text):
                    Image(systemName: "clock").foregroundStyle(.secondary); Text(text)
                case .ready:
                    Image(systemName: "text.badge.checkmark").foregroundStyle(.secondary); Text("Not summarized yet.")
                    Spacer()
                    Button("Summarize meeting") { Task { await session.summarize() } }
                }
            }
            .font(.callout).foregroundStyle(.secondary).controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
            .accessibilityIdentifier("summaryStatus")
            Divider()
            ScrollView {
                if case .written(let s) = summaryState {
                    Text(LocalizedStringKey(s)).textSelection(.enabled)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @Environment(\.openSettings) private var openSettings

    private var insights: some View {
        VStack(spacing: 0) {
            List(session.insights) { ins in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ins.question).font(.subheadline.weight(.semibold))
                    Text(LocalizedStringKey(ins.answer)).textSelection(.enabled)
                    CitationRow(titles: ins.sourceTitles) { model.openSource(titled: $0) }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            .accessibilityLabel("Insights")
            .overlay {
                if session.insights.isEmpty {
                    ContentUnavailableView("No insights yet", systemImage: "questionmark.bubble",
                                           description: Text("Questions heard in the meeting are answered here from your sources. Type one below to ask now."))
                }
            }
            Divider()
            HStack(spacing: 8) {
                if session.answering { ProgressView().controlSize(.small) }
                TextField("Ask a question about your sources", text: $insightDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(askInsight)
                    .disabled(session.answering)
                    .accessibilityIdentifier("insightQuestion")
                Button("Ask", action: askInsight)
                    .disabled(session.answering || insightDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
    }

    private func askInsight() {
        let q = insightDraft
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.answering else { return }
        insightDraft = ""
        Task { await session.ask(q) }
    }
}

/// Free text per meeting, saved as it is typed. Markdown is kept as written and exported as such.
struct NotesEditor: View {
    @Bindable var session: MeetingSession
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(12)
            .accessibilityIdentifier("meetingNotes")
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Your own notes for this meeting. Saved as you type; included when the meeting is exported.")
                        .foregroundStyle(.tertiary).padding(.top, 12).padding(.leading, 17).allowsHitTesting(false)
                }
            }
            .onAppear { text = session.meeting?.notes ?? "" }
            .onChange(of: session.meeting?.id) { text = session.meeting?.notes ?? "" }
            .onChange(of: text) { Task { await session.setNotes(text) } }
    }
}

struct TranscriptList: View {
    @Bindable var session: MeetingSession
    var userName: String
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        ScrollViewReader { proxy in
            List(session.segments) { seg in
                HStack(alignment: .top, spacing: 10) {
                    Text(seg.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(seg.speaker == .me ? Color.accentColor : .secondary)
                        .frame(width: 80, alignment: .trailing)
                        .lineLimit(1)
                        .help(seg.speaker == .me ? "\(seg.name) · your microphone" : "\(seg.name) · system audio")
                        .accessibilityLabel(seg.speaker == .me ? "\(seg.name), microphone" : "\(seg.name), system audio")
                    Text(seg.text).foregroundStyle(seg.isFinal ? .primary : .secondary).textSelection(.enabled)
                        .help(seg.heard.map { "Heard as “\($0)”; corrected from your vocabulary" } ?? "")
                    if seg.heard != nil {
                        Image(systemName: "text.badge.checkmark").font(.caption2).foregroundStyle(.tertiary)
                            .help("Corrected from your vocabulary").accessibilityLabel("corrected")
                    }
                    Spacer(minLength: 0)
                    Text(seg.startSec.clock).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                .id(seg.id)
                .contextMenu {
                    if seg.speaker == .them, seg.name != Speaker.them.rawValue {
                        Button("Rename “\(seg.name)”…") { newName = seg.name; renaming = seg.name }
                    }
                }
            }
            .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let old = renaming { Task { await session.renameSpeaker(from: old, to: newName) } }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Applies to every meeting where this voice was recognized.")
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

/// What the detail pane shows before any meeting exists: the three steps of a first meeting and
/// whether this Mac is ready for one. Replaces the bare button a new user otherwise faced.
struct FirstMeetingGuide: View {
    @Bindable var model: AppModel

    private var notReady: [SetupItem] {
        SetupItem.allCases.filter { if case .ready = model.setup.status[$0] { false } else { true } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Your first meeting", systemImage: "waveform").font(.title2.weight(.semibold))
            Text("Backchannel listens to your microphone and to the audio of any call on this Mac, writes the transcript as it goes, and summarizes when you stop. Nothing leaves this Mac.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Start transcribing", "Press the button in the toolbar, or ⇧⌘R. A floating capsule shows the time and a Stop button over every app.")
                step(2, "Talk, or play a call", "Lines appear as they are heard. Your microphone is “\(MeetingSession.userName)”; everyone else is “Others” until their voices are recognized.")
                step(3, "Stop", "The summary and the questions answered from your sources appear under the meeting.")
            }
            if model.setup.status.isEmpty {
                ProgressView().controlSize(.small)
            } else if notReady.isEmpty {
                Button("Start transcribing") { model.toggleTranscribing() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not ready yet: \(notReady.map(\.title).joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Open Setup") { model.settingsTab = .setup; openSettings() }
                }
            }
        }
        .padding(28).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.setup.refresh() }
    }

    @Environment(\.openSettings) private var openSettings

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
