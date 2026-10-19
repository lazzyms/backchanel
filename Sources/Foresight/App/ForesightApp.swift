import SwiftUI
import AppKit

@main
struct ForesightApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.session.isActive ? "Stop transcribing" : "Start transcribing") { model.toggleTranscribing() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.session.state != .idle && model.session.state != .recording)
            }
        }

        Settings { SettingsView(model: model) }

        // Status item, like the original app: a glance at the state and the same start/stop.
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.session.state == .recording ? "waveform.badge.mic" : "waveform")
        }
    }
}

/// Files dropped on the Dock icon or opened with `open -a Foresight file.md` become sources.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in await AppModel.shared.library.importFiles(urls) }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    let store: Store
    let session: MeetingSession
    let library: SourceLibrary
    let chat: ChatSession
    let models = ModelManager()
    let capsule = CapsulePanel()
    var showModelPicker: Bool
    var meetings: [Meeting] = []
    var insightCount = 0
    var fatalError: String?

    private init() {
        let store: Store
        do { store = try Store() } catch { fatalError = error.localizedDescription; store = try! Store() }
        self.store = store
        session = MeetingSession(store: store)
        library = SourceLibrary(store: store, model: models.selected)
        showModelPicker = models.needsOnboarding
        chat = ChatSession(library: library, store: store)
        session.liveQA = LiveQAService(library: library, store: store)
        Task { await reloadMeetings(); await library.reload() }
    }

    func reloadMeetings() async {
        meetings = (try? await store.meetings()) ?? []
        insightCount = (try? await store.insightCount()) ?? 0
    }

    func deleteMeeting(_ meeting: Meeting) async {
        try? await store.deleteMeeting(id: meeting.id)
        await reloadMeetings()
    }

    /// One action for the toolbar, the menu bar item and ⌘⇧R.
    func toggleTranscribing() {
        switch session.state {
        case .idle:
            let title = "Meeting " + Date().formatted(date: .abbreviated, time: .shortened)
            Task { await session.start(title: title) }
        case .recording, .announcing:
            Task { await session.stop() }
        default: break
        }
    }

    /// Mirrors session state into the floating capsule.
    func syncCapsule() {
        if session.state == .recording || session.state == .announcing { capsule.show(session: session) }
        else { capsule.hide() }
    }
}

/// The original app's pages, in its order. Settings is a window of its own (⌘,).
enum Page: String, CaseIterable, Identifiable {
    case meetings, ask, sources, stats
    var id: String { rawValue }
    var title: String {
        switch self { case .meetings: "Meetings"; case .ask: "Ask"; case .sources: "Sources"; case .stats: "Stats" }
    }
    var symbol: String {
        switch self {
        case .meetings: "rectangle.stack"
        case .ask: "bubble.left.and.text.bubble.right"
        case .sources: "folder"
        case .stats: "chart.bar"
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var page: Page? = .meetings

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.allCases) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Powered by \(model.models.selected.name)", systemImage: "cpu")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Embeddings run on this Mac with \(model.models.selected.name). Summaries and chat use Apple Intelligence.")
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.plain)
                        .keyboardShortcut(",", modifiers: .command)
                }
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch page ?? .meetings {
            case .meetings: MeetingsView(model: model)
            case .ask: AskView(chat: model.chat, meetings: model.meetings)
            case .sources: SourcesView(library: model.library)
            case .stats: StatsView(model: model)
            }
        }
        .toolbar { TranscribeToolbar(model: model) }
        .sheet(isPresented: $model.showModelPicker) {
            ModelPickerView(models: model.models) { chosen in
                model.showModelPicker = false
                Task { await model.library.useModel(chosen) }
            }
        }
        .onChange(of: model.session.state) { _, _ in
            model.syncCapsule()
            if model.session.state == .idle { Task { await model.reloadMeetings() } }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.session.errorMessage != nil },
                                                              set: { if !$0 { model.session.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.session.errorMessage ?? "") }
    }
}

/// The header control the original shows on every page: the big Start transcribing button.
struct TranscribeToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch model.session.state {
            case .recording:
                Text(model.session.elapsed.clock).monospacedDigit().foregroundStyle(.secondary)
                Button(role: .destructive) { model.toggleTranscribing() } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent).tint(.red)
            case .idle:
                Button { model.toggleTranscribing() } label: {
                    Label("Start transcribing", systemImage: "waveform").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .help("Transcribe microphone and system audio (⇧⌘R)")
            default:
                ProgressView().controlSize(.small)
                Text(statusText).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch model.session.state {
        case .preparing: "Loading speech model…"
        case .announcing: "Announcing…"
        case .stopping: "Finishing…"
        case .summarizing: "Summarizing…"
        default: ""
        }
    }
}

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.session.state {
        case .recording:
            Text("Transcribing · \(model.session.elapsed.clock)")
            Button("Stop transcribing") { model.toggleTranscribing() }
        case .idle:
            Text("Not transcribing")
            Button("Start transcribing") { model.toggleTranscribing() }
        default:
            Text("Working…")
        }
        Divider()
        Button("Open Foresight") { NSApp.activate(); openWindow(id: "main") }
        Button("Quit Foresight") { NSApp.terminate(nil) }
    }
}
