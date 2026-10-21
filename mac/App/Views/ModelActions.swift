import AppKit
import VaultKit

/// Actions used from the grid, context menus and detail pane.
@MainActor
enum ModelActions {
    static func detail(_ id: Int, state: AppState) async throws -> ModelDetail {
        if state.offline, let pinned = state.pins.pinned[id] { return pinned }
        guard let client = state.client else { throw URLError(.notConnectedToInternet) }
        return try await client.model(id)
    }

    static func openInSlicer(_ ids: [Int], slicer: Slicer? = nil, state: AppState) async {
        guard let slicer = slicer ?? Slicer.preferred else {
            state.show("No slicer found. Install Bambu Studio, OrcaSlicer, PrusaSlicer or Cura.", isError: true)
            return
        }
        do {
            var urls: [URL] = []
            for id in ids {
                let m = try await detail(id, state: state)
                for f in Slicer.filesToOpen(m) { urls.append(try await state.files.local(f, modelId: m.id)) }
            }
            guard !urls.isEmpty else {
                state.show("Nothing a slicer can open in this model.", isError: true)
                return
            }
            try await slicer.open(urls)
        } catch {
            state.report(error)
        }
    }

    static func openFile(_ file: VaultFile, modelId: Int, slicer: Slicer? = nil, state: AppState) async {
        do {
            let url = try await state.files.local(file, modelId: modelId)
            if let slicer { try await slicer.open([url]) } else { NSWorkspace.shared.open(url) }
        } catch {
            state.report(error)
        }
    }

    static func download(_ ids: [Int], state: AppState) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            for id in ids {
                let m = try await detail(id, state: state)
                for f in m.files {
                    let src = try await state.files.local(f, modelId: m.id)
                    let dest = dir.appending(path: "\(m.slug)/\(f.relPath)")
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.copyItem(at: src, to: dest)
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
            state.show("Downloaded \(ids.count) model\(ids.count == 1 ? "" : "s")")
        } catch {
            state.report(error)
        }
    }

    static func togglePin(_ ids: [Int], state: AppState) async {
        let allPinned = ids.allSatisfy(state.pins.isPinned)
        if allPinned {
            ids.forEach(state.pins.unpin)
            state.show("Removed \(ids.count) from this Mac")
            return
        }
        guard let client = state.client else { return }
        do {
            for id in ids where !state.pins.isPinned(id) {
                try await state.pins.pin(try await client.model(id), client: client, thumbnails: state.thumbnails)
            }
            state.show("Kept \(ids.count) model\(ids.count == 1 ? "" : "s") on this Mac")
        } catch {
            state.report(error)
        }
    }

    static func bulk(_ ids: [Int], _ body: [String: JSONValue], message: String, state: AppState) async {
        do {
            try await state.client?.bulk(ids, body)
            state.show(message)
            state.changed()
        } catch {
            state.report(error)
        }
    }
}
