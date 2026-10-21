import Foundation
import UserNotifications
import VaultKit

/// Uploads anything saved into ~/3DVault/Inbox. Imported items move to Inbox/Imported,
/// so nothing is ever deleted.
@MainActor
final class InboxWatcher {
    static let enabledKey = "inboxEnabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "3DVault/Inbox")
    static let importedName = "Imported"

    weak var state: AppState?
    private var timer: Timer?
    private var seen: [String: (Int, Date)] = [:]
    private var busy = false
    private(set) var lastImport: String?

    func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func signature(_ url: URL) -> (Int, Date) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var size = 0
        var newest = Date.distantPast
        let items: [URL] = (try? url.resourceValues(forKeys: keys).isDirectory) == true
            ? (FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))?.compactMap { $0 as? URL } ?? [])
            : [url]
        for item in items {
            guard let v = try? item.resourceValues(forKeys: keys), v.isDirectory != true else { continue }
            size += v.fileSize ?? 0
            newest = max(newest, v.contentModificationDate ?? .distantPast)
        }
        return (size, newest)
    }

    func scan() async {
        guard !busy, let state, let client = state.client, !state.offline else { return }
        let entries = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != Self.importedName }
        // Only take entries that are unchanged since the last scan and at least 5 s old.
        var ready: [URL] = []
        for e in entries {
            let sig = signature(e)
            if sig.0 > 0, let prev = seen[e.path], prev == sig, Date().timeIntervalSince(sig.1) > 5 {
                ready.append(e)
            } else {
                seen[e.path] = sig
            }
        }
        guard !ready.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let files = Uploader.expand(ready)
            let batch = try await client.createBatch()
            var latest = batch
            for chunk in Uploader.chunks(files) {
                latest = try await client.uploadToBatch(batch.id, files: chunk)
            }
            let groups = latest.groups.map { CommitGroup(name: $0.name, fileIds: $0.fileIds) }
            let ids = try await client.commitBatch(batch.id, groups: groups)
            let dest = Self.folder.appending(path: "\(Self.importedName)/\(Date().formatted(.iso8601.year().month().day()))")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for e in ready {
                var target = dest.appending(path: e.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = dest.appending(path: "\(e.deletingPathExtension().lastPathComponent) (\(n)).\(e.pathExtension)")
                    n += 1
                }
                try? FileManager.default.moveItem(at: e, to: target)
                seen[e.path] = nil
            }
            let msg = "Inbox: added \(ids.count) model\(ids.count == 1 ? "" : "s")"
            lastImport = msg
            state.show(msg)
            state.changed()
            let content = UNMutableNotificationContent()
            content.title = "3DVault"
            content.body = msg
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            state.report(error)
        }
    }
}
