import SwiftUI
import VaultKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    /// Files dropped on the Dock icon or opened with "Open With > 3DVault".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            state?.pendingUpload = urls
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct VaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some Scene {
        Window("3DVault", id: "main") {
            RootView()
                .environment(state)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { delegate.state = state }
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Upload Files…") { state.chooseUpload() }
                    .keyboardShortcut("u")
                    .disabled(state.client == nil || state.offline)
                Divider()
                Button("New Collection…") { state.newCollection() }
                    .disabled(state.client == nil || state.offline)
                Button("New Category…") { state.newCategory() }
                    .disabled(state.client == nil || state.offline)
            }
            CommandGroup(after: .sidebar) {
                Button("Reload") { state.changed() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(state)
                .preferredColorScheme(appearance.colorScheme)
        }
    }

}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.isRestoring {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.user == nil {
                LoginView()
            } else {
                MainView()
            }
        }
        .overlay(alignment: .bottom) {
            if let b = state.banner {
                Text(b.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(b.isError ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(.regularMaterial), in: Capsule())
                    .foregroundStyle(b.isError ? .white : .primary)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: state.banner)
    }
}
