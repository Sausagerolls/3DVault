import SwiftUI
import VaultKit

/// Stage picked files on the server, review the proposed grouping, then commit.
struct UploadSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]

    struct Group: Identifiable {
        let id = UUID()
        var name: String
        var fileIds: [String]
        var categoryId: Int = -1
        var tags = ""
        var sourceUrl = ""
        var skipDuplicates = true
    }

    @State private var batch: UploadBatch?
    @State private var groups: [Group] = []
    @State private var progress: (done: Int, total: Int)?
    @State private var error: String?
    @State private var committing = false

    private var files: [String: StagedFile] { Dictionary(uniqueKeysWithValues: (batch?.files ?? []).map { ($0.id, $0) }) }

    var body: some View {
        NavigationStack {
            Form {
                if let progress {
                    Section {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                            Text("Uploading \(progress.done) of \(progress.total) files…")
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if groups.count > 1 {
                    Section {
                        Picker("Category for all", selection: Binding(get: { -2 }, set: { v in
                            for i in groups.indices { groups[i].categoryId = v }
                        })) {
                            Text("Choose…").tag(-2)
                            CategoryOptions(noneLabel: "Untriaged")
                        }
                    }
                }
                ForEach($groups) { $g in
                    Section {
                        TextField("Model name", text: $g.name).font(.headline)
                        Picker("Category", selection: $g.categoryId) { CategoryOptions(noneLabel: "Untriaged") }
                        TextField("Tags, comma separated", text: $g.tags)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Source link (optional)", text: $g.sourceUrl)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        ForEach(g.fileIds, id: \.self) { fid in
                            if let f = files[fid] {
                                HStack {
                                    Text(f.path).lineLimit(1).truncationMode(.middle)
                                    if f.dupModelId != nil {
                                        Text("duplicate").font(.caption).padding(.horizontal, 6).background(Color.red.opacity(0.2), in: Capsule())
                                    }
                                    Spacer()
                                    Text(formatBytes(f.size)).foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                .swipeActions {
                                    if g.fileIds.count > 1 {
                                        Button("Split") { split(fid, from: g.id) }.tint(.blue)
                                    }
                                }
                            }
                        }
                        if g.fileIds.contains(where: { files[$0]?.dupModelId != nil }) {
                            Toggle("Skip files already in the library", isOn: $g.skipDuplicates)
                        }
                    } header: {
                        HStack {
                            Text("\(g.fileIds.count) file\(g.fileIds.count == 1 ? "" : "s")")
                            Spacer()
                            Menu {
                                ForEach(groups.filter { $0.id != g.id }) { other in
                                    Button("Merge into “\(other.name)”") { merge(g.id, into: other.id) }
                                }
                                Divider()
                                Button("Remove from Upload", role: .destructive) { groups.removeAll { $0.id == g.id } }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                }
                if !groups.isEmpty {
                    Section {} footer: {
                        Text("Models without a category go to Untriaged. Swipe a file to split it into its own model.")
                    }
                }
            }
            .overlay {
                if groups.isEmpty && progress == nil && error == nil { ProgressView() }
            }
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Task { await cancel() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(groups.count)") { Task { await commit() } }
                        .disabled(groups.isEmpty || committing || progress != nil)
                }
            }
        }
        .interactiveDismissDisabled(progress != nil || committing)
        .task { await upload() }
    }

    private func upload() async {
        guard let client = state.client else { return }
        let all = Uploader.expand(urls)
        guard !all.isEmpty else {
            error = "Nothing to upload."
            return
        }
        do {
            var b = try await client.createBatch()
            progress = (0, all.count)
            for chunk in Uploader.chunks(all) {
                b = try await client.uploadToBatch(b.id, files: chunk)
                progress = ((progress?.done ?? 0) + chunk.count, all.count)
            }
            batch = b
            groups = b.groups.map { Group(name: $0.name, fileIds: $0.fileIds) }
            progress = nil
        } catch {
            progress = nil
            self.error = "Upload failed: \(error.localizedDescription)"
        }
    }

    private func merge(_ id: UUID, into target: UUID) {
        guard let src = groups.first(where: { $0.id == id }), let t = groups.firstIndex(where: { $0.id == target }) else { return }
        groups[t].fileIds += src.fileIds
        groups.removeAll { $0.id == id }
    }

    private func split(_ fid: String, from id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }), let f = files[fid] else { return }
        groups[i].fileIds.removeAll { $0 == fid }
        let name = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        groups.insert(Group(name: name, fileIds: [fid], categoryId: groups[i].categoryId), at: i + 1)
    }

    private func commit() async {
        guard let client = state.client, let batch else { return }
        committing = true
        defer { committing = false }
        let body = groups.map { g in
            CommitGroup(
                name: g.name, fileIds: g.fileIds, categoryId: g.categoryId == -1 ? nil : g.categoryId,
                tags: g.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty },
                sourceUrl: g.sourceUrl, skipDuplicates: g.skipDuplicates)
        }
        do {
            let ids = try await client.commitBatch(batch.id, groups: body)
            cleanUp()
            state.show("Added \(ids.count) model\(ids.count == 1 ? "" : "s")")
            state.changed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancel() async {
        if let batch { try? await state.client?.discardBatch(batch.id) }
        cleanUp()
        dismiss()
    }

    /// Staged copies live in a temporary folder of their own.
    private func cleanUp() {
        if let dir = urls.first?.deletingLastPathComponent(), dir.lastPathComponent.hasPrefix("upload-") {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
