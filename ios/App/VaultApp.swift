import SwiftUI
import VaultKit

@main
struct VaultApp: App {
    @State private var state = AppState()
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .preferredColorScheme(appearance.colorScheme)
                // "Open in 3DVault" from Files or another app.
                .onOpenURL { url in
                    // threedvault://model/<id> from the print Live Activity.
                    if url.scheme == "threedvault", url.host() == "model", let id = Int(url.lastPathComponent) {
                        state.openModel = id
                        return
                    }
                    // threedvault://printers from the printer widget.
                    if url.scheme == "threedvault", url.host() == "printers" {
                        state.openPrinters = true
                        return
                    }
                    guard url.isFileURL, state.client != nil else { return }
                    state.stageForUpload([url])
                }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { PrintTracker.shared.scheduleRefresh() }
            // Pick up categories, tags and models changed from other devices.
            if scenePhase == .active { state.returnedToForeground() }
        }
        // iOS wakes the app now and then while prints run; check them and update the Live Activity.
        .backgroundTask(.appRefresh(PrintTracker.refreshTask)) {
            await PrintTracker.shared.sync()
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
        .task(id: state.user?.id) {
            guard state.user != nil, state.client != nil else { return }
            PrintTracker.shared.start(state: state)
            #if DEBUG
            PrintTracker.shared.testActivity()
            #endif
            // Keep prints' Live Activities current while the app is open.
            while !Task.isCancelled {
                await PrintTracker.shared.sync()
                try? await Task.sleep(for: .seconds(30))
                if state.offline {
                    await state.reconnect(delays: [0])
                } else {
                    await state.refreshTaxonomy()
                }
            }
        }
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
