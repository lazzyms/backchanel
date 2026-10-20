import SwiftUI

/// Search of the Hugging Face Hub for one role, with an Add button per repo this app can run.
/// Used by the embedding picker and the chat settings; the role decides which pipeline tags are searched.
struct HubSearchView: View {
    let role: HubModel.Role
    /// Repo ids already in the role's list, shown as added instead of offering the button again.
    let added: Set<String>
    let onAdd: (HubModel) -> Void

    @State private var query = ""
    @State private var results: [HubModel]?
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search Hugging Face", text: $query, prompt: Text(role == .chat ? "qwen3, llama, phi…" : "nomic, bge, qwen3-embedding…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button(searching ? "Searching…" : "Search", action: search)
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let results {
                if results.isEmpty {
                    Text("No MLX models match.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) { ForEach(results) { row($0) } }
                    }
                    .frame(maxHeight: 180)
                }
            }
            Text(role == .chat
                 ? "Repos tagged mlx under text-generation, most downloaded first. Only architectures this app can run get an Add button."
                 : "Repos tagged mlx under feature-extraction and sentence-similarity, most downloaded first. Only architectures this app can run get an Add button.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ m: HubModel) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.body.weight(.medium))
                Text(m.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if added.contains(m.id) {
                Label("Added", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else if m.isSupported(for: role) {
                Button("Add") { onAdd(m) }.controlSize(.small).accessibilityLabel("Add \(m.name)")
            } else {
                Text("Not supported").font(.caption).foregroundStyle(.secondary)
                    .help("\(m.modelType ?? "No model_type") is not an architecture the bundled MLX loader knows.")
            }
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching else { return }
        searching = true; error = nil
        Task {
            do { results = try await HubSearch.search(q, role: role) } catch { self.error = error.localizedDescription }
            searching = false
        }
    }
}
