import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    private var library: SourceLibrary { model.library }
    @State private var selected: Source?
    @State private var showGraph = true
    @State private var isDropTarget = false
    @State private var query = ""
    /// nil shows every label.
    @State private var labelFilter: String?

    private var labels: [String] {
        Array(Set(library.sources.compactMap(\.label))).sorted()
    }

    /// The list after search and label filter. Search matches title, label or path, case-insensitively.
    private var shown: [Source] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return library.sources.filter { s in
            (labelFilter == nil || s.label == labelFilter)
            && (q.isEmpty || s.title.localizedCaseInsensitiveContains(q)
                || (s.label?.localizedCaseInsensitiveContains(q) ?? false)
                || s.path.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 240, idealWidth: 280)
            Group {
                if showGraph { GraphView(library: library, selected: $selected) }
                else if let selected { detail(selected) }
                else { ContentUnavailableView("Select a source", systemImage: "doc.text", description: Text("Pick a document to read it.")) }
            }
            .frame(minWidth: 400)
        }
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Picker("View", selection: $showGraph) {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").tag(true).accessibilityLabel("Graph")
                    Label("Document", systemImage: "doc.plaintext").tag(false).accessibilityLabel("Document")
                }
                .pickerStyle(.segmented).help("Show the knowledge graph or the selected document")
                .accessibilityLabel("View").accessibilityIdentifier("viewPicker")
                Button { pickFiles() } label: { Label("Add source", systemImage: "plus") }
                    .help("Add markdown, text, PDF or image files")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                await library.importFiles(urls)
            }
            return true
        }
        .task { await library.reload() }
        .onAppear(perform: showRequested)
        .onChange(of: model.requestedSource) { _, _ in showRequested() }
        .alert("Import failed", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(library.errorMessage ?? "") }
    }

    private func showRequested() {
        guard let s = model.requestedSource else { return }
        selected = s
        showGraph = false
        model.requestedSource = nil
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search sources", text: $query)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .accessibilityIdentifier("sourceSearch")
                if !labels.isEmpty {
                    Picker("Label", selection: $labelFilter) {
                        Text("All labels").tag(String?.none)
                        ForEach(labels, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    .accessibilityIdentifier("labelFilter")
                    .help("Show only sources with this label")
                }
            }
            .padding(8)
            Divider()
            sourceRows
        }
    }

    private var sourceRows: some View {
        List(selection: $selected) {
            if !library.importing.isEmpty {
                Section { ForEach(library.importing, id: \.self) { n in HStack { ProgressView().controlSize(.small); Text("Importing \(n)…").font(.caption) } } }
            }
            ForEach(shown) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: icon(s.kind)).foregroundStyle(.secondary)
                        Text(s.title).lineLimit(1)
                    }
                    if let l = s.label {
                        Text(l).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                .tag(s)
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                    Button("Remove from library", role: .destructive) { Task { await library.delete(s) } }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("Sources")
        .accessibilityIdentifier("sourcesList")
        .overlay {
            if shown.isEmpty && !library.sources.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? (labelFilter ?? "") : query)
            } else if library.sources.isEmpty && library.importing.isEmpty {
                ContentUnavailableView {
                    Label("Build your knowledge library", systemImage: "folder")
                } description: {
                    Text("Build your knowledge library with your own documents. Imported data is stored locally on your device.")
                } actions: {
                    Button("Add source") { pickFiles() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(library.reembedding ? "Re-embedding with \(library.embedderName)…"
                     : shown.count == library.sources.count ? "\(library.sources.count) sources · \(library.embedderName)"
                     : "\(shown.count) of \(library.sources.count) sources · \(library.embedderName)")
                Spacer()
                Button("Models…") { model.settingsTab = .embedding; openSettings() }.buttonStyle(.link)
                    .help("Choose the embedding model under Settings › Embedding")
            }
            .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private func detail(_ s: Source) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title).font(.title2.weight(.semibold))
                if let l = s.label {
                    Text(l).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    if let r = s.labelRationale { Text(r).font(.caption).foregroundStyle(.secondary) }
                }
                Text(s.path).font(.caption2).foregroundStyle(.tertiary)
                Divider()
                Text(s.text).textSelection(.enabled).font(.body)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func icon(_ k: SourceKind) -> String {
        switch k { case .markdown: "doc.richtext"; case .text: "doc.plaintext"; case .pdf: "doc.fill"; case .image: "photo" }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SourceImporter.supportedTypes
        if panel.runModal() == .OK { Task { await library.importFiles(panel.urls) } }
    }
}

/// Sources as nodes placed by PCA of their embeddings; edges join similar documents; colour = label.
struct GraphView: View {
    @Bindable var library: SourceLibrary
    @Binding var selected: Source?

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 60
            let rect = CGRect(x: inset, y: inset, width: max(geo.size.width - 2 * inset, 1), height: max(geo.size.height - 2 * inset, 1))
            let positions = Dictionary(uniqueKeysWithValues: library.sources.map { s -> (Int64, CGPoint) in
                let p = s.projection ?? CGPoint(x: 0.5, y: 0.5)
                return (s.id, CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height))
            })
            ZStack {
                Canvas { ctx, _ in
                    for (a, b, w) in library.edges {
                        guard let pa = positions[a], let pb = positions[b] else { continue }
                        var path = Path(); path.move(to: pa); path.addLine(to: pb)
                        ctx.stroke(path, with: .color(.secondary.opacity(Double(w) * 0.6)), lineWidth: 1 + CGFloat(w) * 2)
                    }
                }
                ForEach(library.sources) { s in
                    let p = positions[s.id] ?? .zero
                    let isSelected = selected?.id == s.id
                    VStack(spacing: 3) {
                        Circle().fill(color(for: s.label)).frame(width: nodeSize, height: nodeSize)
                            .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 3 : 1))
                        if !dense || isSelected {
                            Text(s.title).font(.caption2).lineLimit(1).frame(maxWidth: 110)
                            if let l = s.label { Text(l).font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                    }
                    .position(p)
                    .zIndex(isSelected ? 1 : 0)
                    .onTapGesture { selected = s }
                    .help(dense ? "\(s.title)\n\(s.label ?? "")" : (s.labelRationale ?? s.title))
                    .accessibilityLabel(s.title)
                }
            }
            .overlay(alignment: .bottomLeading) { legend.padding(8) }
            .overlay(alignment: .topLeading) {
                if dense {
                    Text("\(library.sources.count) sources. Hover a dot for its title, click to select.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if library.sources.count < 2 {
                ContentUnavailableView("Graph needs two or more sources", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    /// Above this many sources the titles overlap into noise, so only dots are drawn and the legend is capped.
    private static let denseThreshold = 120
    private static let legendLimit = 12
    private var dense: Bool { library.sources.count > Self.denseThreshold }
    private var nodeSize: CGFloat { dense ? 9 : 16 }

    /// The most common labels, largest first; the rest are counted. Many labels share a colour.
    private var legend: some View {
        let counts = Dictionary(library.sources.compactMap(\.label).map { ($0, 1) }, uniquingKeysWith: +)
        let ordered = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let shown = ordered.prefix(Self.legendLimit)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown, id: \.key) { l, n in
                HStack(spacing: 4) {
                    Circle().fill(color(for: l)).frame(width: 8, height: 8)
                    Text(dense ? "\(l) (\(n))" : l).font(.caption2)
                }
            }
            if ordered.count > shown.count {
                Text("+\(ordered.count - shown.count) more labels").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Legend")
    }

    private func color(for label: String?) -> Color {
        guard let label else { return .gray }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint, .red, .yellow]
        return palette[abs(label.hashValue) % palette.count]
    }
}
