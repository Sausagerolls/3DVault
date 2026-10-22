import SwiftUI
import VaultKit

@main
struct VaultApp: App {
    @State private var state = AppState()
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(appearance.colorScheme)
                // "Open in 3DVault" from Files or another app.
                .onOpenURL { url in
                    guard url.isFileURL, state.client != nil else { return }
                    state.stageForUpload([url])
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            if state.isRestoring {
                ProgressView()
            } else if state.user == nil {
                LoginView()
            } else {
                MainView()
            }
        }
        .overlay(alignment: .bottom) {
            if let b = state.banner {
                Text(b.text)
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .foregroundStyle(b.isError ? .white : .primary)
                    .glassEffect(b.isError ? .regular.tint(.red) : .regular, in: Capsule())
                    .padding(.bottom, 70)
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { state.banner = nil }
            }
        }
        .overlay {
            if let text = state.preparing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(text).font(.callout)
                }
                .padding(24)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .animation(.spring(duration: 0.3), value: state.banner)
        .sheet(item: $state.share) { req in
            ShareSheet(urls: req.urls, airDrop: req.airDrop)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { !state.pendingUpload.isEmpty }, set: { if !$0 { state.pendingUpload = [] } })) {
            UploadSheet(urls: state.pendingUpload)
        }
        .modifier(Prompts())
    }
}

/// Shows AppState's naming prompt and destructive confirmation.
private struct Prompts: ViewModifier {
    @Environment(AppState.self) private var state
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(state.prompt?.title ?? "", isPresented: Binding(get: { state.prompt != nil }, set: { if !$0 { state.prompt = nil } }), presenting: state.prompt) { p in
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button(p.action) {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    Task {
                        do { try await p.run(n) } catch { state.report(error) }
                    }
                }
            } message: { p in
                if !p.message.isEmpty { Text(p.message) }
            }
            .onChange(of: state.prompt?.id) { name = state.prompt?.initial ?? "" }
            .confirmationDialog(state.confirm?.title ?? "", isPresented: Binding(get: { state.confirm != nil }, set: { if !$0 { state.confirm = nil } }), titleVisibility: .visible, presenting: state.confirm) { c in
                Button(c.action, role: .destructive) {
                    Task {
                        do { try await c.run() } catch { state.report(error) }
                    }
                }
            } message: { c in
                Text(c.message)
            }
    }
}
