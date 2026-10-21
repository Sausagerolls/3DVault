import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VaultKit

/// "Share → 3DVault": uploads shared files as new models. The fixed Objective-C name keeps the
/// Info.plist principal class independent of the module name.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let host = UIHostingController(rootView: ShareView(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareView: View {
    let providers: [NSItemProvider]
    let close: () -> Void

    struct Group: Identifiable {
        let id = UUID()
        var name: String
        var fileIds: [String]
    }

    @State private var client = SharedConfig.client()
    @State private var categories: [VaultKit.Category] = []
    @State private var batch: UploadBatch?
    @State private var groups: [Group] = []
    @State private var categoryId = -1
    @State private var tags = ""
    @State private var sourceUrl = ""
    @State private var status = "Preparing files…"
    @State private var error: String?
    @State private var busy = true
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                if client == nil {
                    Section {
                        Label("Open 3DVault and sign in first, then share again.", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                } else if done {
                    Section {
                        Label("Added to your library", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    if busy {
                        Section { HStack { ProgressView(); Text(status).padding(.leading, 8) } }
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                    if !groups.isEmpty {
                        Section(groups.count == 1 ? "Model" : "\(groups.count) models") {
                            ForEach($groups) { $g in
                                VStack(alignment: .leading, spacing: 2) {
                                    TextField("Model name", text: $g.name).font(.headline)
                                    Text(fileSummary(g)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Picker("Category", selection: $categoryId) {
                                Text("Untriaged").tag(-1)
                                ForEach(tree, id: \.0.id) { c, depth in
                                    Text(String(repeating: "    ", count: depth) + c.name).tag(c.id)
                                }
                            }
                            TextField("Tags, comma separated", text: $tags)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Source link (optional)", text: $sourceUrl)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } footer: {
                            Text("Files already in the library are skipped.")
                        }
                    }
                }
            }
            .navigationTitle("Add to 3DVault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done || client == nil ? "Close" : "Cancel") { Task { await cancel() } }
                }
                if client != nil && !done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { Task { await commit() } }
                            .disabled(busy || groups.isEmpty)
                    }
                }
            }
        }
        .task { await start() }
    }

    private var tree: [(VaultKit.Category, Int)] {
        var out: [(VaultKit.Category, Int)] = []
        func walk(_ parent: Int?, _ depth: Int) {
            for c in categories.filter({ $0.parentId == parent }).sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                out.append((c, depth))
                walk(c.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    private func fileSummary(_ g: Group) -> String {
        let files = g.fileIds.compactMap { id in batch?.files.first { $0.id == id } }
        let dups = files.filter { $0.dupModelId != nil }.count
        let names = files.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
        return dups > 0 ? "\(names) · \(dups) already in library" : names
    }

    private func start() async {
        guard let client else { busy = false; return }
        do {
            async let cats = client.categories()
            let urls = try await collect()
            guard !urls.isEmpty else {
                error = "Nothing here 3DVault can upload. Share files, not web pages."
                busy = false
                return
            }
            status = "Uploading \(urls.count) file\(urls.count == 1 ? "" : "s")…"
            var b = try await client.createBatch()
            for chunk in Uploader.chunks(urls.map { ($0, "") }) {
                b = try await client.uploadToBatch(b.id, files: chunk)
            }
            batch = b
            groups = b.groups.map { Group(name: $0.name, fileIds: $0.fileIds) }
            categories = (try? await cats) ?? []
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    /// Copies each shared file into a staging folder. A shared web link becomes the source link.
    private func collect() async throws -> [URL] {
        let dir = SharedConfig.stagingFolder()
        var out: [URL] = []
        for p in providers {
            let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
            if let type = types.first(where: { $0.conforms(to: .data) }) {
                let copy: URL? = try await withCheckedThrowingContinuation { cont in
                    _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                        guard let url else { return cont.resume(returning: nil) }
                        // Photos and some apps hand over temporary names; prefer the suggested one.
                        var name = p.suggestedName ?? url.lastPathComponent
                        if (name as NSString).pathExtension.isEmpty {
                            name += "." + (url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "bin") : url.pathExtension)
                        }
                        let dest = dir.appending(path: Self.unique(name, in: dir))
                        do {
                            try FileManager.default.copyItem(at: url, to: dest)
                            cont.resume(returning: dest)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                if let copy { out.append(copy) }
            } else if types.contains(where: { $0.conforms(to: .url) }),
                      let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                if url.isFileURL {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let dest = dir.appending(path: Self.unique(url.lastPathComponent, in: dir))
                    try FileManager.default.copyItem(at: url, to: dest)
                    out.append(dest)
                } else {
                    sourceUrl = url.absoluteString
                }
            }
        }
        return out
    }

    private static func unique(_ name: String, in dir: URL) -> String {
        guard FileManager.default.fileExists(atPath: dir.appending(path: name).path) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appending(path: "\(base) \(n).\(ext)").path) { n += 1 }
        return "\(base) \(n).\(ext)"
    }

    private func commit() async {
        guard let client, let batch else { return }
        busy = true
        status = "Adding…"
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        do {
            _ = try await client.commitBatch(batch.id, groups: groups.map {
                CommitGroup(name: $0.name, fileIds: $0.fileIds, categoryId: categoryId == -1 ? nil : categoryId,
                            tags: tagList, sourceUrl: sourceUrl, skipDuplicates: true)
            })
            done = true
            busy = false
            try? await Task.sleep(for: .seconds(1))
            close()
        } catch {
            self.error = error.localizedDescription
            busy = false
        }
    }

    private func cancel() async {
        if let batch, !done { try? await client?.discardBatch(batch.id) }
        close()
    }
}
