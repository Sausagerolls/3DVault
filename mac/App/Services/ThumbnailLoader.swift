import AppKit
import VaultKit

/// Authenticated thumbnail and preview loading with memory and disk caches.
@MainActor
final class ThumbnailLoader {
    var client: APIClient? {
        didSet {
            // Ids restart on every server, so another server's images must never be reused.
            if client?.baseURL != oldValue?.baseURL {
                memory.removeAllObjects()
                inflight = [:]
            }
        }
    }
    private let memory = NSCache<NSNumber, NSImage>()
    private var inflight: [Int: Task<NSImage?, Never>] = [:]
    static let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "3DVault")

    /// This server's cache folder.
    private var root: URL { Self.base.appending(path: "servers/\(client?.cacheNamespace ?? "none")") }

    var dir: URL {
        let d = root.appending(path: "thumbs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() {
        // Before 1.0.1 thumbnails and previews were cached by file id alone, mixing servers.
        for legacy in ["thumbs", "previews"] {
            try? FileManager.default.removeItem(at: Self.base.appending(path: legacy))
        }
        memory.countLimit = 600
    }

    func cached(_ fileId: Int) -> NSImage? { memory.object(forKey: fileId as NSNumber) }

    func image(_ fileId: Int) async -> NSImage? {
        if let img = cached(fileId) { return img }
        if let t = inflight[fileId] { return await t.value }
        let path = dir.appending(path: "\(fileId).webp")
        let client = client
        let task = Task<NSImage?, Never> {
            if let img = NSImage(contentsOf: path) { return img }
            // Pinned models keep their thumbnails for offline use.
            guard let client, let data = try? await client.data(from: client.thumbURL(fileId)) else { return nil }
            try? data.write(to: path)
            return NSImage(data: data)
        }
        inflight[fileId] = task
        let img = await task.value
        inflight[fileId] = nil
        if let img { memory.setObject(img, forKey: fileId as NSNumber) }
        return img
    }

    /// Preview meshes are cached on disk; they are immutable per file id.
    func preview(_ fileId: Int, lod: Bool = false) async throws -> GLBMesh {
        let previews = root.appending(path: "previews")
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let path = previews.appending(path: "\(fileId)\(lod ? "_lod2" : "").glb")
        let data: Data
        if let d = try? Data(contentsOf: path) {
            data = d
        } else {
            guard let client else { throw URLError(.notConnectedToInternet) }
            data = try await client.data(from: client.previewURL(fileId, lod: lod))
            try? data.write(to: path)
        }
        return try await Task.detached { try GLBMesh(data: data) }.value
    }

    func clearDisk() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: root)
    }
}
