import SwiftUI
import VaultKit

struct LoginView: View {
    @Environment(AppState.self) private var state
    @State private var server = UserDefaults.standard.string(forKey: "lastServer") ?? "http://"
    @State private var username = UserDefaults.standard.string(forKey: AppState.userKey) ?? ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cube.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange.gradient)
            Text("Connect to 3DVault").font(.title2.bold())
            Form {
                TextField("Server", text: $server, prompt: Text("http://nas.local:8000"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .formStyle(.columns)
            .frame(width: 340)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).frame(width: 340)
            }
            Button {
                Task { await signIn() }
            } label: {
                Text(busy ? "Connecting…" : "Sign In").frame(width: 120)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(busy || username.isEmpty || password.isEmpty)
            Text("Use the address you open 3DVault at in your browser.\nOver Tailscale use the NAS's tailnet name.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() async {
        var text = server.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text.hasSuffix("/") ? String(text.dropLast()) : text), url.host != nil else {
            error = "That server address doesn't look right."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await state.signIn(server: url, username: username, password: password)
            UserDefaults.standard.set(text, forKey: "lastServer")
        } catch let e as URLError {
            error = "Can't reach the server: \(e.localizedDescription)"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
