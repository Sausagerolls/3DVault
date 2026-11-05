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

    private var reconnecting = false
    private var foregroundedAt = Date.distantPast

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
        #if DEBUG
        // Testing: VAULT_TEST_SERVER/USER/PASSWORD sign in for this run only, leaving the saved
        // account alone, since this build shares its keychain with the installed app.
        let env = ProcessInfo.processInfo.environment
        if let s = env["VAULT_TEST_SERVER"].flatMap(URL.init(string:)), let u = env["VAULT_TEST_USER"], let p = env["VAULT_TEST_PASSWORD"],
           let (token, me) = try? await APIClient.login(server: s, username: u, password: p, deviceName: "3DVault test") {
            serverURL = s
            user = me
            connect(APIClient(baseURL: s, token: token))
            return
        }
        #endif
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
            Task { await reconnect() }
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

    // MARK: connection

    /// The app became active or the Mac woke up. The network often isn't back for a few seconds
    /// after waking, so failures around now don't mean the server is down.
    func returnedToForeground() {
        foregroundedAt = .now
        guard user != nil else { return }
        if offline {
            Task { await reconnect() }
        } else {
            changed()
        }
    }

    /// Checks the server after a failed request, trying a few times before going offline.
    /// Also brings the app back from offline as soon as the server answers.
    func reconnect(delays: [Double] = [0, 1, 2, 4]) async {
        guard !reconnecting, let client else { return }
        reconnecting = true
        defer { reconnecting = false }
        for delay in delays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if Task.isCancelled { return }
            do {
                let me = try await client.me(timeout: 5)
                // After starting offline, `user` is a placeholder until now.
                if user != me { user = me }
                offline = false
                // Starting offline skips the inbox, so start it now. Starting it twice would
                // forget which files it has seen.
                if inbox.state == nil {
                    inbox.state = self
                    if InboxWatcher.enabled { inbox.start() }
                }
                await refreshTaxonomy()
                // Lists that failed to load try again.
                revision += 1
                return
            } catch let e as APIError where e.isUnauthorised {
                await signOut()
                return
            } catch {
                if Self.isCancellation(error) { return }
            }
        }
        offline = true
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
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
            let (c, t, p, l, s) = try await (cats, tags, printers, colls, stats)
            // Assign only what changed so periodic refreshes don't redraw the sidebar.
            if c != self.categories { self.categories = c }
            if t != self.tags { self.tags = t }
            if p != self.printers { self.printers = p }
            if l != self.collections { self.collections = l }
            self.stats = s
            offline = false
        } catch is URLError {
            await reconnect()
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
        if Self.isCancellation(error) { return }
        if error is URLError {
            Task { await reconnect() }
            // Reconnecting reloads whatever failed just after returning to the app.
            if Date.now.timeIntervalSince(foregroundedAt) < 10 { return }
        }
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
