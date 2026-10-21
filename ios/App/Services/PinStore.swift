import Foundation
import Observation
import VaultKit

/// Models kept on this device for offline use: detail JSON, every file and the cover thumbnail.
@MainActor
@Observable
final class PinStore {
    static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "3DVault/Pinned")
    /// The signed-in server's folder. Model ids are only unique per server.
    private(set) static var root = base.appending(path: "none")

    private(set) var pinned: [Int: ModelDetail] = [:]
    private(set) var downloading: Set<Int> = []

    /// Switch to a server's saved models.
    func use(_ client: APIClient) {
        Self.root = Self.base.appending(path: client.cacheNamespace)
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        pinned = [:]
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: Self.root.path)) ?? []
        for id in ids.compactMap(Int.init) {
            if let data = try? Data(contentsOf: Self.root.appending(path: "\(id)/detail.json")),
               let m = try? APIClient.decoder.decode(ModelDetail.self, from: data) {
                pinned[id] = m
            }
        }
    }

    func isPinned(_ id: Int) -> Bool { pinned[id] != nil }

    var summaries: [ModelSummary] {
        pinned.values.map(\.summary).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func pin(_ model: ModelDetail, client: APIClient, thumbnails: ThumbnailLoader) async throws {
        downloading.insert(model.id)
        defer { downloading.remove(model.id) }
        let dir = Self.root.appending(path: "\(model.id)")
        for f in model.files {
            try await client.download(client.fileDownloadURL(f.id), to: dir.appending(path: "files/\(f.relPath)"))
            if f.hasThumb { _ = await thumbnails.image(f.id) }
        }
        if let p = model.previewFileId { _ = try? await thumbnails.preview(p) }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, enc in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        try encoder.encode(model).write(to: dir.appending(path: "detail.json"))
        pinned[model.id] = model
    }

    func unpin(_ id: Int) {
        try? FileManager.default.removeItem(at: Self.root.appending(path: "\(id)"))
        pinned[id] = nil
    }

    func folder(_ id: Int) -> URL { Self.root.appending(path: "\(id)/files") }
}
