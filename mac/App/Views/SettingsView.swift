import SwiftUI
import VaultKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(Slicer.preferenceKey) private var preferredSlicer = ""
    @State private var inboxEnabled = InboxWatcher.enabled && InboxWatcher.folder != nil
    @State private var inboxFolder = InboxWatcher.folder
    @State private var cacheSize = 0

    var body: some View {
        Form {
            Section("Account") {
                if let user = state.user {
                    LabeledContent("Signed in as", value: "\(user.displayName) (\(user.username))")
                    LabeledContent("Server", value: state.serverURL?.absoluteString ?? "")
                    if let url = state.serverURL {
                        Link("Open web library", destination: url)
                    }
                    Button("Sign Out") { Task { await state.signOut() } }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                }
            }

            Section("Slicer") {
                Picker("Open models in", selection: $preferredSlicer) {
                    ForEach(Slicer.installed) { Text($0.name).tag($0.id) }
                    if Slicer.installed.isEmpty { Text("No slicers found").tag("") }
                }
                Text("Double-click a model to open it. Slicer projects (3MF with settings) open as-is; otherwise every mesh opens together.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Inbox folder") {
                Toggle("Upload anything saved to the Inbox folder", isOn: $inboxEnabled)
                    .disabled(inboxFolder == nil)
                    .onChange(of: inboxEnabled) { _, on in
                        InboxWatcher.enabled = on
                        if on { state.inbox.start() } else { state.inbox.stop() }
                    }
                LabeledContent("Folder", value: inboxFolder?.path(percentEncoded: false) ?? "None chosen")
                HStack {
                    Button(inboxFolder == nil ? "Choose Folder…" : "Change Folder…") {
                        guard InboxWatcher.chooseFolder() else { return }
                        inboxFolder = InboxWatcher.folder
                        inboxEnabled = true
                        InboxWatcher.enabled = true
                        state.inbox.start()
                    }
                    if let inboxFolder {
                        Button("Show in Finder") { NSWorkspace.shared.open(inboxFolder) }
                    }
                    if let last = state.inbox.lastImport { Text(last).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Uploaded items move to Imported inside the folder. Files already in the library are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Download cache", value: formatBytes(cacheSize))
                LabeledContent("Kept on this Mac", value: "\(state.pins.pinned.count) models")
                HStack {
                    Button("Clear Cache") {
                        state.files.clear()
                        state.thumbnails.clearDisk()
                        cacheSize = state.files.size
                    }
                    Button("Show Pinned in Finder") { NSWorkspace.shared.open(PinStore.root) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear { cacheSize = state.files.size }
    }
}
