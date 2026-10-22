import SwiftUI
import AppKit

@main
struct BackchannelApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // Files opened from Finder or the Dock go to the app delegate as imports; without this
        // every open-file event also spawned a second main window.
        .handlesExternalEvents(matching: [])
        // The status item keeps the app alive with no window open. Without this, a launch after
        // quitting with the window closed restores nothing and the app looks like it did not start.
        .defaultLaunchBehavior(.presented)
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

/// Files dropped on the Dock icon or opened with `open -a Backchannel file.md` become sources.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in await AppModel.shared.library.importFiles(urls) }
    }

    /// The status item keeps the app alive with no window open, so a quit (or a kill) after the
    /// last window closed leaves saved state with no windows and the next launch restores none.
    /// `defaultLaunchBehavior(.presented)` does not override that on macOS 27.0.1, so reopen
    /// ourselves, the same event a Dock click sends, which SwiftUI answers with a main window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            let hasMain = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main-AppWindow") == true }
            guard !hasMain else { return }
            let me = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
            let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                                targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                                                transactionID: AETransactionID(kAnyTransactionID))
            _ = try? reopen.sendEvent(options: [.noReply], timeout: 1)
        }
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
    let chatModels = ChatModelManager()
    let capsule = CapsulePanel()
    let watcher: FolderWatcher
    let setup: SetupChecker
    /// Setup, embedding model, chat model, then watched folders. Shown until finished once, and again if the embedding model goes missing.
    var showOnboarding: Bool
    /// The one window that presents the onboarding sheet. Every main window shares this model, so
    /// without a host each restored or new window would open its own copy of the sheet.
    var onboardingHost: UUID?
    var meetings: [Meeting] = []
    var insightCount = 0
    var settingsTab: SettingsTab = .setup
    /// Which page the main window shows. Lives here so a citation in Ask can open Sources.
    var page: Page = .meetings
    /// A source another page asked Sources to show. Sources reads it once and clears it.
    var requestedSource: Source?
    var fatalError: String?

    /// The one background job to show in the window, longest-running kinds first. nil when idle.
    /// Replaces alerts for work that needs no answer from the user.
    var backgroundWork: (text: String, progress: Double?)? {
        if let id = models.downloading { return ("Downloading \(id)…", models.progress) }
        if let id = chatModels.downloading { return ("Downloading \(id)…", chatModels.progress) }
        if library.reembedding { return ("Re-embedding \(library.sources.count) sources with \(library.embedderName)…", nil) }
        if let n = library.importing.first {
            let more = library.importing.count - 1
            return (more > 0 ? "Importing \(n) and \(more) more…" : "Importing \(n)…", nil)
        }
        if watcher.scanning { return ("Scanning watched folders…", nil) }
        return nil
    }

    /// Opens the source with this title under Sources. A title no source has does nothing.
    func openSource(titled title: String) {
        guard let s = library.sources.first(where: { $0.title == title }) else { return }
        requestedSource = s
        page = .sources
    }

    private init() {
        let store: Store
        do { store = try Store() } catch { fatalError = error.localizedDescription; store = try! Store() }
        self.store = store
        library = SourceLibrary(store: store, model: models.selected)
        session = MeetingSession(store: store, chat: chatModels, library: library)
        watcher = FolderWatcher(library: library)
        setup = SetupChecker(session: session)
        showOnboarding = models.needsOnboarding || !UserDefaults.standard.bool(forKey: "onboardingDone")
        chat = ChatSession(library: library, store: store, chat: chatModels)
        session.liveQA = LiveQAService(library: library, store: store)
        Task { await reloadMeetings(); await library.reload(); watcher.start() }
    }

    /// Switches the embedding model, re-embeds, then lets the watcher import what it could not before.
    func useEmbeddingModel(_ model: EmbeddingModel) async {
        await library.useModel(model)
        watcher.start()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        showOnboarding = false
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
        case .recording:
            Task { await session.stop() }
        default: break
        }
    }

    /// Mirrors session state into the floating capsule.
    func syncCapsule() {
        if session.state == .recording { capsule.show(session: session) }
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
    @State private var windowID = UUID()

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Page?>(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
                ForEach(Page.allCases) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if let work = model.backgroundWork {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(work.text).font(.caption).lineLimit(2)
                            }
                            if let p = work.progress { ProgressView(value: p).controlSize(.small) }
                        }
                        .accessibilityIdentifier("backgroundWork")
                        .transition(.opacity)
                    }
                    Label("Powered by \(model.models.selected.name)", systemImage: "cpu")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Embeddings run on this Mac with \(model.models.selected.name). Summaries and chat use \(model.chatModels.displayName).")
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.plain)
                        .keyboardShortcut(",", modifiers: .command)
                }
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch model.page {
            case .meetings: MeetingsView(model: model)
            case .ask: AskView(model: model)
            case .sources: SourcesView(model: model)
            case .stats: StatsView(model: model)
            }
        }
        .toolbar { TranscribeToolbar(model: model) }
        .onAppear { if model.onboardingHost == nil { model.onboardingHost = windowID } }
        .onDisappear { if model.onboardingHost == windowID { model.onboardingHost = nil } }
        .sheet(isPresented: Binding(get: { model.showOnboarding && model.onboardingHost == windowID },
                                    set: { if !$0 { model.showOnboarding = false } })) { OnboardingView(model: model) }
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
        case .recognizing: "Recognizing speakers…"
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
        Button("Open Backchannel") { NSApp.activate(); openWindow(id: "main") }
        Button("Quit Backchannel") { NSApp.terminate(nil) }
    }
}
