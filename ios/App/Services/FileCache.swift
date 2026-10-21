import Foundation
import VaultKit

/// Local copies of model files for sharing, AirDrop and offline use.
@MainActor
final class FileCache {
    var client: APIClient?
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "3DVault/files")

    /// Returns a local URL for the file, downloading it if needed. Files are keyed by hash so
    /// renamed or re-uploaded copies reuse the same download.
    func local(_ file: VaultFile, modelId: Int) async throws -> URL {
        let pinned = PinStore.root.appending(path: "\(modelId)/files/\(file.relPath)")
        if FileManager.default.fileExists(atPath: pinned.path) { return pinned }
        let dest = cacheDir.appending(path: "\(file.sha256.prefix(16))/\(file.name)")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let client else { throw URLError(.notConnectedToInternet) }
        try await client.download(client.fileDownloadURL(file.id), to: dest)
        return dest
    }

    var size: Int {
        guard let e = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return e.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }

    func clear() { try? FileManager.default.removeItem(at: cacheDir) }
}
