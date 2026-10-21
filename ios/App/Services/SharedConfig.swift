import Foundation
import VaultKit

/// Sign-in details shared between the app and its Share extension through the App Group
/// and a shared keychain access group.
enum SharedConfig {
    static let serverKey = "serverURL"
    static let userKey = "username"

    static var defaults: UserDefaults {
        let group = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String
        return group.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Call once at launch, before touching the keychain.
    static func configure() {
        Keychain.accessGroup = Bundle.main.object(forInfoDictionaryKey: "KeychainGroup") as? String
    }

    static var serverURL: URL? { defaults.string(forKey: serverKey).flatMap(URL.init(string:)) }
    static var username: String? { defaults.string(forKey: userKey) }

    static func keychainAccount(_ server: URL, _ user: String) -> String { "\(user)@\(server.absoluteString)" }

    /// A client for the signed-in user, or nil when nobody is signed in.
    static func client() -> APIClient? {
        configure()
        guard let server = serverURL, let user = username,
              let token = Keychain.load(account: keychainAccount(server, user)) else { return nil }
        return APIClient(baseURL: server, token: token)
    }

    static func save(server: URL, username: String, token: String) {
        configure()
        Keychain.save(token, account: keychainAccount(server, username))
        defaults.set(server.absoluteString, forKey: serverKey)
        defaults.set(username, forKey: userKey)
    }

    static func forget(server: URL, username: String) {
        Keychain.delete(account: keychainAccount(server, username))
    }

    /// A fresh temporary folder for files being prepared for upload.
    static func stagingFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
