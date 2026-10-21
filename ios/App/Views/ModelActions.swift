import UIKit
import VaultKit

/// Actions used from the grid, context menus, selection bar and detail view.
@MainActor
enum ModelActions {
    static func detail(_ id: Int, state: AppState) async throws -> ModelDetail {
        if state.offline, let pinned = state.pins.pinned[id] { return pinned }
        guard let client = state.client else { throw URLError(.notConnectedToInternet) }
        return try await client.model(id)
    }

    /// Downloads the printable files of each model (or every file with `allFiles`) and opens the share sheet.
    static func share(_ ids: [Int], allFiles: Bool = false, airDrop: Bool = false, state: AppState) async {
        state.preparing = "Preparing \(ids.count == 1 ? "files" : "\(ids.count) models")…"
        defer { state.preparing = nil }
        do {
            var urls: [URL] = []
            for id in ids {
                let m = try await detail(id, state: state)
                let files = allFiles || m.printableFiles.isEmpty ? m.files.filter { $0.kind != "photo" } : m.printableFiles
                for f in files { urls.append(try await state.files.local(f, modelId: m.id)) }
            }
            guard !urls.isEmpty else {
                state.show("This model has no files to share.", isError: true)
                return
            }
            state.share = .init(urls: urls, airDrop: airDrop)
        } catch {
            state.report(error)
        }
    }

    static func shareFile(_ file: VaultFile, modelId: Int, airDrop: Bool = false, state: AppState) async {
        state.preparing = "Preparing \(file.name)…"
        defer { state.preparing = nil }
        do {
            state.share = .init(urls: [try await state.files.local(file, modelId: modelId)], airDrop: airDrop)
        } catch {
            state.report(error)
        }
    }

    static func togglePin(_ ids: [Int], state: AppState) async {
        if ids.allSatisfy(state.pins.isPinned) {
            ids.forEach(state.pins.unpin)
            state.show("Removed \(ids.count) from this device")
            return
        }
        guard let client = state.client else { return }
        do {
            for id in ids where !state.pins.isPinned(id) {
                try await state.pins.pin(try await client.model(id), client: client, thumbnails: state.thumbnails)
            }
            state.show("Saved \(ids.count) model\(ids.count == 1 ? "" : "s") for offline use")
        } catch {
            state.report(error)
        }
    }

    static func bulk(_ ids: [Int], _ body: [String: JSONValue], message: String, state: AppState) async {
        do {
            try await state.client?.bulk(ids, body)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            state.show(message)
            state.changed()
        } catch {
            state.report(error)
        }
    }
}
