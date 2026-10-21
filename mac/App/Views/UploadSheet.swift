import SwiftUI
import VaultKit

/// Stage dropped files on the server, review the proposed grouping, then commit.
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
    @State private var allCategory = -1

    private var files: [String: StagedFile] { Dictionary(uniqueKeysWithValues: (batch?.files ?? []).map { ($0.id, $0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upload").font(.title2.bold())
                Spacer()
                if !groups.isEmpty {
                    Picker("Category for all", selection: $allCategory) {
                        Text("Category for all…").tag(-1)
                        ForEach(state.categoryTree, id: \.category.id) { item in
                            Text(String(repeating: "   ", count: item.depth) + item.category.name).tag(item.category.id)
                        }
                    }
                    .frame(width: 220)
                    .onChange(of: allCategory) { _, v in if v != -1 { for i in groups.indices { groups[i].categoryId = v } } }
                }
            }

            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("Uploading \(progress.done) of \(progress.total) files…")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }

            List {
                ForEach($groups) { $g in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Model name", text: $g.name).font(.headline)
                            Picker("", selection: $g.categoryId) {
                                Text("Untriaged").tag(-1)
                                ForEach(state.categoryTree, id: \.category.id) { item in
                                    Text(String(repeating: "   ", count: item.depth) + item.category.name).tag(item.category.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            Menu {
                                ForEach(groups.filter { $0.id != g.id }) { other in
                                    Button("Merge into “\(other.name)”") { merge(g.id, into: other.id) }
                                }
                                Divider()
                                Button("Remove from Upload", role: .destructive) { groups.removeAll { $0.id == g.id } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                        }
                        HStack {
                            TextField("Tags, comma separated", text: $g.tags)
                            TextField("Source link (optional)", text: $g.sourceUrl)
                        }
                        .textFieldStyle(.roundedBorder)
                        ForEach(g.fileIds, id: \.self) { fid in
                            if let f = files[fid] {
                                HStack {
                                    Text(f.path).lineLimit(1).truncationMode(.middle)
                                    if f.dupModelId != nil {
                                        Text("duplicate").font(.caption).padding(.horizontal, 5).background(Color.red.opacity(0.2), in: Capsule())
                                    }
                                    Spacer()
                                    Text(formatBytes(f.size)).foregroundStyle(.secondary)
                                    if g.fileIds.count > 1 {
                                        Button("Split") { split(fid, from: g.id) }.controlSize(.small)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                        if g.fileIds.contains(where: { files[$0]?.dupModelId != nil }) {
                            Toggle("Skip files already in the library", isOn: $g.skipDuplicates).font(.caption)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(minHeight: 300)
            .overlay {
                if groups.isEmpty && progress == nil && error == nil { ProgressView() }
            }

            HStack {
                Text("Models without a category go to Untriaged.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { Task { await cancel() } }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(groups.count) Model\(groups.count == 1 ? "" : "s")") { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(groups.isEmpty || committing || progress != nil)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
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
            state.show("Added \(ids.count) model\(ids.count == 1 ? "" : "s")")
            state.changed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancel() async {
        if let batch { try? await state.client?.discardBatch(batch.id) }
        dismiss()
    }
}
