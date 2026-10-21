import AppKit
import VaultKit

struct Slicer: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIds: [String]
    let appNames: [String]

    static let all: [Slicer] = [
        Slicer(id: "bambu", name: "Bambu Studio", bundleIds: ["com.bambulab.bambu-studio"], appNames: ["BambuStudio.app", "Bambu Studio.app"]),
        Slicer(id: "orca", name: "OrcaSlicer", bundleIds: ["com.softfever3d.orca-slicer"], appNames: ["OrcaSlicer.app"]),
        Slicer(id: "prusa", name: "PrusaSlicer", bundleIds: ["com.prusa3d.slic3r", "com.prusa3d.slic3r/"], appNames: ["PrusaSlicer.app", "Original Prusa Drivers/PrusaSlicer.app"]),
        Slicer(id: "cura", name: "UltiMaker Cura", bundleIds: ["nl.ultimaker.cura", "com.ultimaker.cura"], appNames: ["UltiMaker Cura.app", "Ultimaker Cura.app"]),
    ]

    static let preferenceKey = "preferredSlicer"

    var appURL: URL? {
        for id in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        // Fallback for copies Launch Services has not registered yet.
        let dir = URL(filePath: "/Applications")
        return appNames.map { dir.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var installed: [Slicer] { all.filter { $0.appURL != nil } }

    static var preferred: Slicer? {
        let id = UserDefaults.standard.string(forKey: preferenceKey)
        return installed.first { $0.id == id } ?? installed.first
    }

    /// Which files to hand to a slicer: a slicer project if there is one, else every mesh.
    static func filesToOpen(_ model: ModelDetail) -> [VaultFile] { model.printableFiles }

    @MainActor
    func open(_ urls: [URL]) async throws {
        guard let app = appURL else { throw CocoaError(.fileNoSuchFile) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config)
    }
}
