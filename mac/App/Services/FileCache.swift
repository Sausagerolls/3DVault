import AppKit
import UniformTypeIdentifiers
import VaultKit

/// Local copies of model files, used for "Open in slicer", drag-out and offline pins.
@MainActor
final class FileCache {
    var client: APIClient?
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "3DVault/files")
    var pinnedDir: URL { PinStore.root }

    /// Returns a local URL for the file, downloading it if needed. Files are keyed by hash so
    /// renamed or re-uploaded copies reuse the same download.
    func local(_ file: VaultFile, modelId: Int) async throws -> URL {
        let pinned = pinnedDir.appending(path: "\(modelId)/files/\(file.relPath)")
        if FileManager.default.fileExists(atPath: pinned.path) { return pinned }
        let dest = cacheDir.appending(path: "\(file.sha256.prefix(16))/\(file.name)")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let client else { throw URLError(.notConnectedToInternet) }
        try await client.download(client.fileDownloadURL(file.id), to: dest)
        return dest
    }

    func localZip(model: ModelDetail) async throws -> URL {
        let dest = cacheDir.appending(path: "zips/\(client?.cacheNamespace ?? "none")/\(model.id)-\(Int(model.updatedAt.timeIntervalSince1970))/\(model.slug).zip")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let client else { throw URLError(.notConnectedToInternet) }
        try await client.download(client.modelZipURL(model.id), to: dest)
        return dest
    }

    /// Item provider that downloads lazily when the drop lands (Finder, slicer, Desktop).
    func dragProvider(_ file: VaultFile, modelId: Int) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        let type = UTType(filenameExtension: file.ext) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do { completion(try await self.local(file, modelId: modelId), false, nil) }
                catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }

    var size: Int {
        guard let e = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return e.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }

    func clear() { try? FileManager.default.removeItem(at: cacheDir) }
}
