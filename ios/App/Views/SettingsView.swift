import SwiftUI
import VaultKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize = 0
    @State private var confirmSignOut = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let user = state.user {
                        LabeledContent("Signed in as", value: user.displayName)
                        LabeledContent("Username", value: user.username)
                        LabeledContent("Server", value: state.serverURL?.host() ?? "")
                        if state.offline {
                            Label("Can't reach the server. Showing offline models.", systemImage: "wifi.slash").foregroundStyle(.orange)
                        }
                        if let url = state.serverURL {
                            Link(destination: url) { Label("Open Web Library", systemImage: "safari") }
                        }
                    }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if let s = state.stats {
                    Section("Library") {
                        LabeledContent("Models", value: s.models.formatted())
                        LabeledContent("Untriaged", value: s.untriaged.formatted())
                    }
                }
                Section {
                    LabeledContent("Download cache", value: formatBytes(cacheSize))
                    LabeledContent("Offline models", value: "\(state.pins.pinned.count)")
                    Button("Clear Download Cache") {
                        state.files.clear()
                        state.thumbnails.clearDisk()
                        cacheSize = state.files.size
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Offline models are kept until you remove them. The cache holds files you've shared and can be cleared any time.")
                }
                Section {
                    Text("Share files from Safari, Files or Mail with **3DVault** to upload them. Long-press a model in the library for a spinning 3D preview.")
                        .font(.callout)
                } header: { Text("Tips") }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Sign out of 3DVault?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        await state.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text("Offline models stay on this device.")
            }
            .onAppear { cacheSize = state.files.size }
        }
    }
}
