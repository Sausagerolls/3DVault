import SwiftUI
import VaultKit
import WebKit

/// The server's 3D plate editor, shared with the web app, in a web view signed in with this
/// device's token. It reports back through the "vault" message handler.
struct PrepareView: View {
    let client: APIClient
    let modelId: Int
    let fileIds: [Int]
    let machineId: Int
    let onSliced: (Int) -> Void
    let onClose: () -> Void

    private var url: URL {
        var c = URLComponents(url: client.baseURL.appending(path: "models/\(modelId)/prepare"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "machine", value: String(machineId)),
            .init(name: "files", value: fileIds.map(String.init).joined(separator: ",")),
            .init(name: "embed", value: "1"),
        ]
        return c.url!
    }

    var body: some View {
        PrepareWebView(url: url, baseURL: client.baseURL, token: client.token, onSliced: onSliced, onClose: onClose)
    }
}

#if os(iOS)
private typealias WebViewRepresentable = UIViewRepresentable
#else
private typealias WebViewRepresentable = NSViewRepresentable
#endif

fileprivate struct PrepareWebView: WebViewRepresentable {
    let url: URL
    let baseURL: URL
    let token: String
    let onSliced: (Int) -> Void
    let onClose: () -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onSliced: (Int) -> Void = { _ in }
        var onClose: () -> Void = {}

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "sliced", let id = body["file_id"] as? Int {
                onSliced(id)
            } else if type == "close" {
                onClose()
            } else if type == "groups", let value = body["value"] as? String {
                UserDefaults.standard.set(value, forKey: PrepareWebView.groupsKey)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    fileprivate static let groupsKey = "prepare.groups"

    /// Restores which setting groups were open, since this web view's storage isn't kept.
    private static var restoreGroups: WKUserScript? {
        guard let saved = UserDefaults.standard.string(forKey: groupsKey),
              let data = try? JSONEncoder().encode(saved), let literal = String(data: data, encoding: .utf8) else { return nil }
        return WKUserScript(source: "localStorage.setItem('prepare.groups', \(literal));", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        coordinator.onSliced = onSliced
        coordinator.onClose = onClose
        let config = WKWebViewConfiguration()
        // Kept in memory only, so the token doesn't outlive this editor in a cookie store.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(coordinator, name: "vault")
        if let script = Self.restoreGroups { config.userContentController.addUserScript(script) }
        let web = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        web.isInspectable = true
        #endif
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "vault_session", .value: token, .domain: baseURL.host() ?? "", .path: "/",
        ]
        if baseURL.scheme == "https" { properties[.secure] = "TRUE" }
        let request = URLRequest(url: url)
        if let cookie = HTTPCookie(properties: properties) {
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { web.load(request) }
        } else {
            web.load(request)
        }
        return web
    }

    private static func tearDown(_ web: WKWebView) {
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "vault")
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) {}
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { tearDown(web) }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) {}
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { tearDown(web) }
    #endif
}
