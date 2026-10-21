import SwiftUI
import VaultKit

struct LoginView: View {
    @Environment(AppState.self) private var state
    @State private var server = SharedConfig.defaults.string(forKey: "lastServer") ?? ""
    @State private var username = SharedConfig.username ?? ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    enum Field { case server, username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.orange.gradient)
                        Text("Connect to 3DVault").font(.title2.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Server", text: $server, prompt: Text("http://nas.local:8000"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .focused($focus, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("Use the address you open 3DVault at in your browser. Over Tailscale use the NAS's tailnet name.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Text(busy ? "Connecting…" : "Sign In").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
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
            SharedConfig.defaults.set(text, forKey: "lastServer")
            password = ""
        } catch let e as URLError {
            error = "Can't reach the server: \(e.localizedDescription)"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
