import AppKit
import Observation
import VaultKit

@MainActor
@Observable
final class AppState {
    static let serverKey = "serverURL"
    static let userKey = "username"

    var serverURL: URL? = UserDefaults.standard.string(forKey: serverKey).flatMap(URL.init(string:))
    var client: APIClient?
    var user: VaultUser?
    var isRestoring = true
    /// True when the server cannot be reached; the app then shows pinned models only.
    var offline = false

    var categories: [VaultKit.Category] = []
    var tags: [Tag] = []
    var printers: [Printer] = []
    var collections: [VaultCollection] = []
    var stats: Stats?

    /// Files dropped on the window or Dock icon, waiting for the upload sheet.
    var pendingUpload: [URL] = []
    var banner: Banner?
    var prompt: NamePrompt?
    var confirm: ConfirmPrompt?
    var sidebarPins: [SidebarPin] = AppState.loadPins()
    /// Bumped after any change so lists reload.
    var revision = 0

    let thumbnails = ThumbnailLoader()
    let pins = PinStore()
    let files = FileCache()
    let inbox = InboxWatcher()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    init() {
        Task { await restore() }
    }

    // MARK: session

    func restore() async {
        defer { isRestoring = false }
        guard let serverURL, let account = UserDefaults.standard.string(forKey: Self.userKey),
              let token = Keychain.load(account: Self.keychainAccount(serverURL, account))
        else { return }
        let c = APIClient(baseURL: serverURL, token: token)
        do {
            user = try await c.me()
            connect(c)
        } catch let e as APIError where e.isUnauthorised {
            Keychain.delete(account: Self.keychainAccount(serverURL, account))
        } catch {
            // Server unreachable: keep the token, run offline from pinned models.
            client = c
            offline = true
            user = VaultUser(id: 0, username: account, displayName: account, role: "member")
            thumbnails.client = c
            files.client = c
            pins.use(c)
        }
    }

    func signIn(server: URL, username: String, password: String) async throws {
        let device = Host.current().localizedName ?? "Mac"
        let (token, user) = try await APIClient.login(server: server, username: username, password: password, deviceName: "3DVault for Mac – \(device)")
        Keychain.save(token, account: Self.keychainAccount(server, user.username))
        UserDefaults.standard.set(server.absoluteString, forKey: Self.serverKey)
        UserDefaults.standard.set(user.username, forKey: Self.userKey)
        serverURL = server
        self.user = user
        connect(APIClient(baseURL: server, token: token))
    }

    func signOut() async {
        await client?.logout()
        if let serverURL, let user { Keychain.delete(account: Self.keychainAccount(serverURL, user.username)) }
        inbox.stop()
        client = nil
        user = nil
    }

    private func connect(_ c: APIClient) {
        client = c
        offline = false
        thumbnails.client = c
        files.client = c
        pins.use(c)
        inbox.state = self
        if InboxWatcher.enabled { inbox.start() }
        Task { await refreshTaxonomy() }
    }

    static func keychainAccount(_ server: URL, _ user: String) -> String { "\(user)@\(server.absoluteString)" }

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
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            if banner == b { banner = nil }
        }
    }

    /// Shows an open panel and queues the chosen files and folders for the upload sheet.
    func chooseUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        panel.message = "Choose model files or folders. Folders are grouped into models for you to review."
        if panel.runModal() == .OK { pendingUpload = panel.urls }
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
}
