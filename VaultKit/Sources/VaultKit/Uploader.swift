import Foundation

/// Turns picked or dropped files and folders into upload requests. Shared by the Mac and iOS apps.
public enum Uploader {
    public static let junk: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    /// Expand dropped files and folders into (file, folder-relative path). Loose files get "".
    public static func expand(_ urls: [URL]) -> [(url: URL, path: String)] {
        var out: [(URL, String)] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let base = url.deletingLastPathComponent().path
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, !junk.contains(f.lastPathComponent) else { continue }
                    out.append((f, String(f.path.dropFirst(base.count + 1))))
                }
            } else if !junk.contains(url.lastPathComponent) {
                out.append((url, ""))
            }
        }
        return out
    }

    /// Split into requests of at most 40 files / 256 MB.
    public static func chunks(_ files: [(url: URL, path: String)]) -> [[(url: URL, path: String)]] {
        var out: [[(url: URL, path: String)]] = []
        var cur: [(url: URL, path: String)] = []
        var bytes = 0
        for f in files {
            let size = (try? f.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if !cur.isEmpty && (cur.count >= 40 || bytes + size > 256 << 20) {
                out.append(cur)
                cur = []
                bytes = 0
            }
            cur.append(f)
            bytes += size
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
