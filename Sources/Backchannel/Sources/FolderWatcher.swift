import Foundation
import CoreServices
import Observation

/// Keeps the library in step with the disk while the app runs, also in the background.
/// Two things are watched: the folders chosen at onboarding or under Settings › Folders (every
/// supported file in them, new or changed, is imported), and every source already in the library,
/// however it got there (re-imported when its file changes). FSEvents wakes a scan; a scan also
/// runs at launch and whenever the folder list changes. Nothing is ever removed from the library.
@MainActor
@Observable
final class FolderWatcher {
    private static let key = "watchedFolders"

    private(set) var folders: [URL]
    private(set) var lastScan: Date?
    private(set) var scanning = false

    private let library: SourceLibrary
    private var stream: FSEventStreamRef?
    private var defaultsObserver: NSKeyValueObservation?
    private var scanTask: Task<Void, Never>?
    private var rescanWanted = false
    /// Files already tried at a given modification date, so a file that fails to import is not retried every scan.
    private var attempted: [String: Date] = [:]

    init(library: SourceLibrary) {
        self.library = library
        folders = Self.storedFolders
    }

    private static var storedFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Call once the library has loaded; starts listening and runs the first scan.
    func start() {
        restartStream()
        scheduleScan()
        // The folder list is also edited outside the app (`defaults write`, a restored preference
        // file). Pick that up while running instead of at the next launch.
        defaultsObserver = UserDefaults.standard.observe(\.watchedFolders) { [weak self] _, _ in
            Task { @MainActor in self?.reloadFolders() }
        }
    }

    private func reloadFolders() {
        let stored = Self.storedFolders
        guard stored != folders else { return }
        folders = stored
        restartStream()
        scheduleScan()
    }

    func add(_ url: URL) {
        let folder = url.standardizedFileURL
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        save()
        restartStream()
        scheduleScan()
    }

    func remove(_ url: URL) {
        folders.removeAll { $0 == url }
        save()
        restartStream()
    }

    /// Runs a scan now, or right after the one in progress.
    func scheduleScan() {
        if scanTask != nil { rescanWanted = true; return }
        scanTask = Task { [weak self] in
            await self?.scan()
            guard let self else { return }
            self.scanTask = nil
            if self.rescanWanted { self.rescanWanted = false; self.scheduleScan() }
        }
    }

    private func save() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.key)
    }

    // MARK: Scanning

    private func scan() async {
        guard library.canImport else { return }
        scanning = true
        defer { scanning = false; lastScan = Date() }
        let known = Dictionary(library.sources.map { ($0.path, $0.modifiedAt) }, uniquingKeysWith: { a, _ in a })
        var candidates: [URL] = []
        for folder in folders { candidates += Self.supportedFiles(in: folder) }
        candidates += library.sources.map(\.url)
        var stale: [URL] = []
        var seen = Set<String>()
        for url in candidates {
            let path = url.path
            guard seen.insert(path).inserted,
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if let imported = known[path] ?? nil, modified.timeIntervalSince(imported) < 1 { continue }
            if let tried = attempted[path], tried == modified { continue }
            attempted[path] = modified
            stale.append(url)
        }
        guard !stale.isEmpty else { return }
        await library.importFiles(stale)
    }

    private static func supportedFiles(in folder: URL) -> [URL] {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in items {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  SourceImporter.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            out.append(url)
        }
        return out
    }

    // MARK: FSEvents

    /// Listens on the chosen folders and on the folders holding individually added sources.
    private func restartStream() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        var paths = Set(folders.map(\.path))
        for source in library.sources { paths.insert(source.url.deletingLastPathComponent().path) }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scheduleScan() }
        }, &context, Array(paths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}

extension UserDefaults {
    /// KVO-visible view of the watched folder list, so external edits reach `FolderWatcher`.
    @objc dynamic var watchedFolders: [String]? {
        get { stringArray(forKey: "watchedFolders") }
        set { set(newValue, forKey: "watchedFolders") }
    }
}
