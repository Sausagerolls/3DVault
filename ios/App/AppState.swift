import Observation
import UIKit
import VaultKit

@MainActor
@Observable
final class AppState {
    var serverURL: URL? = SharedConfig.serverURL
    var client: APIClient?
    var user: VaultUser?
    var isRestoring = true
    /// True when the server cannot be reached; the app then shows offline models only.
    var offline = false

    var categories: [VaultKit.Category] = []
    var tags: [Tag] = []
    var printers: [Printer] = []
    var collections: [VaultCollection] = []
    var stats: Stats?

    /// Local files waiting for the upload sheet (from the Files picker or "Open in 3DVault").
    var pendingUpload: [URL] = []
    var banner: Banner?
    var prompt: NamePrompt?
    var confirm: ConfirmPrompt?
    var sidebarPins: [SidebarPin] = AppState.loadPins()
    /// Files ready for the share sheet. `airDrop` narrows the sheet towards AirDrop for "Send to Mac".
    var share: ShareRequest?
    /// Shown while files download before sharing.
    var preparing: String?
    /// Bumped after any change so lists reload.
    var revision = 0

    let thumbnails = ThumbnailLoader()
    let pins = PinStore()
    let files = FileCache()

    struct ShareRequest: Identifiable {
        let id = UUID()
        let urls: [URL]
        let airDrop: Bool
    }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    init() {
        SharedConfig.configure()
        Task { await restore() }
    }

    // MARK: session

    func restore() async {
        defer { isRestoring = false }
        #if DEBUG
        // Simulator testing: launch with VAULT_TEST_SERVER/USER/PASSWORD in the environment to sign in automatically.
        let env = ProcessInfo.processInfo.environment
        if let s = env["VAULT_TEST_SERVER"].flatMap(URL.init(string:)), let u = env["VAULT_TEST_USER"], let p = env["VAULT_TEST_PASSWORD"] {
            try? await signIn(server: s, username: u, password: p)
            if user != nil { return }
        }
        #endif
        guard let serverURL, let account = SharedConfig.username, let c = SharedConfig.client() else { return }
        do {
            user = try await c.me()
            connect(c)
        } catch let e as APIError where e.isUnauthorised {
            SharedConfig.forget(server: serverURL, username: account)
        } catch {
            // Server unreachable: keep the token, run offline from saved models.
            client = c
            offline = true
            user = VaultUser(id: 0, username: account, displayName: account, role: "member")
            thumbnails.client = c
            files.client = c
            pins.use(c)
        }
    }

    func signIn(server: URL, username: String, password: String) async throws {
        let (token, user) = try await APIClient.login(server: server, username: username, password: password,
                                                      deviceName: "3DVault for \(UIDevice.current.model) – \(UIDevice.current.name)")
        SharedConfig.save(server: server, username: user.username, token: token)
        serverURL = server
        self.user = user
        connect(APIClient(baseURL: server, token: token))
    }

    func signOut() async {
        await client?.logout()
        if let serverURL, let user { SharedConfig.forget(server: serverURL, username: user.username) }
        client = nil
        user = nil
    }

    private func connect(_ c: APIClient) {
        client = c
        offline = false
        thumbnails.client = c
        files.client = c
        pins.use(c)
        Task { await refreshTaxonomy() }
    }

    // MARK: data

    func refreshTaxonomy() async {
        guard let client else { return }
        async let cats = client.categories()
        async let tags = client.tags()
        async let printers = client.printers()
        async let colls = client.collections()
        async let stats = client.stats()
        do {
            (self.categories, self.tags, self.printers, self.collections, self.stats) = try await (cats, tags, printers, colls, stats)
            offline = false
        } catch {
            report(error)
        }
    }

    func changed() {
        revision += 1
        Task { await refreshTaxonomy() }
    }

    func report(_ error: Error) {
        if let e = error as? APIError, e.isUnauthorised {
            Task { await signOut() }
            return
        }
        if (error as? URLError) != nil { offline = true }
        show(error.localizedDescription, isError: true)
    }

    func show(_ text: String, isError: Bool = false) {
        let b = Banner(text: text, isError: isError)
        banner = b
        if isError {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            if banner == b { banner = nil }
        }
    }

    // MARK: categories

    func categoryPath(_ id: Int?) -> String {
        guard var id else { return "" }
        var names: [String] = []
        let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        while let c = byId[id] {
            names.insert(c.name, at: 0)
            guard let p = c.parentId else { break }
            id = p
        }
        return names.joined(separator: " › ")
    }

    /// Categories in tree order with depth, for pickers and the sidebar.
    var categoryTree: [(category: VaultKit.Category, depth: Int)] {
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

    // MARK: uploads

    /// Copies picked files and folders out of their security scope into a staging folder, then
    /// opens the upload sheet. The picker's URLs stop being readable once the picker closes.
    func stageForUpload(_ urls: [URL]) {
        let dir = SharedConfig.stagingFolder()
        var staged: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = dir.appending(path: url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                staged.append(dest)
            } catch {
                report(error)
            }
        }
        if !staged.isEmpty { pendingUpload = staged }
    }
}
