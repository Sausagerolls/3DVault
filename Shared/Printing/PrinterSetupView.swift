import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// Pair printers and change their settings, the same as Settings › Printers in the web app.
/// Only admins get here; the server refuses everyone else as well.
struct PrinterSetupView: View {
    @Environment(AppState.self) private var state
    @State private var machines: [Machine] = []
    @State private var kinds: [MachineKind] = []
    @State private var found: [DiscoveredPrinter]?
    @State private var searching = false
    @State private var slicerAvailable = false
    @State private var importing = false
    @State private var slicerKey: String?
    @State private var editing: MachineDraft?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Button {
                    findPrinters()
                } label: {
                    HStack {
                        Label(searching ? "Searching…" : "Find Printers", systemImage: "dot.radiowaves.left.and.right")
                        if searching {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(searching)
                Button {
                    editing = MachineDraft(kind: kinds.first?.kind ?? "")
                } label: {
                    Label("Add Printer by Address", systemImage: "plus")
                }
                .disabled(kinds.isEmpty)
                if let found {
                    if found.isEmpty {
                        Text("No printers answered. Check the printer is on the same network. The 3DVault server needs host networking to hear printer announcements; otherwise add the printer by address.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(found) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text([p.model, p.host, p.lanMode ? nil : "Not in LAN mode"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.added {
                                Text("Added").foregroundStyle(.secondary)
                            } else {
                                Button("Set Up") { editing = MachineDraft(discovered: p) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            } header: {
                Text("Pair a Printer")
            }

            Section {
                ForEach(machines) { m in
                    Button { editing = MachineDraft(machine: m) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).foregroundStyle(.primary)
                                Text(kinds.first { $0.kind == m.kind }?.label ?? m.kind)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.enabled {
                                StateBadge(state: m.status.state)
                            } else {
                                Text("Disabled").font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if machines.isEmpty {
                    Text("No printers yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Connected Printers")
            } footer: {
                Text("Printers 3DVault can send prints to. Everyone signed in can print to them and see their status.")
            }

            Section {
                if slicerAvailable {
                    Button { importing = true } label: { Label("Import Presets…", systemImage: "square.and.arrow.down") }
                } else {
                    Text("Slicing isn't available in this server's image, so only pre-sliced files can be printed.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Slicer Presets")
            } footer: {
                if slicerAvailable {
                    Text("Printer, process or filament presets exported from OrcaSlicer or Bambu Studio.")
                }
            }

            if !machines.isEmpty, let server = state.client?.baseURL {
                Section {
                    ForEach(machines) { m in
                        LabeledContent(m.name) {
                            Text(server.appending(path: "print-host/\(m.id)").absoluteString)
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let slicerKey {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API key. Copy it now, as it isn't shown again.").font(.caption).foregroundStyle(.secondary)
                            Text(slicerKey).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } else {
                        Button("Create API Key") { createKey() }
                    }
                } header: {
                    Text("Send from a Slicer")
                } footer: {
                    Text("OrcaSlicer can send prints to the queue here. In the printer's connection settings choose OctoPrint, then enter the address above and an API key. For a Bambu Lab printer, first turn on “Use 3rd-party print host” in its printer settings.")
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Manage Printers")
        .inlineTitle()
        .task {
            await load()
            #if DEBUG
            // Testing: VAULT_TEST_SETUP=edit opens the first printer.
            if ProcessInfo.processInfo.environment["VAULT_TEST_SETUP"] == "edit", let m = machines.first {
                try? await Task.sleep(for: .seconds(1))
                editing = MachineDraft(machine: m)
            }
            #endif
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                MachineEditor(draft: draft, kinds: kinds) { await load() }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 520, minHeight: 460, idealHeight: 620, maxHeight: 680)
            #endif
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .zip, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importPresets(urls) }
        }
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            async let m = client.machines()
            async let k = client.machineKinds()
            async let s = client.slicerAvailable()
            (machines, kinds, slicerAvailable) = try await (m, k, s)
            error = nil
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func findPrinters() {
        guard let client = state.client else { return }
        searching = true
        Task {
            defer { searching = false }
            do {
                found = try await client.discoverMachines()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func createKey() {
        guard let client = state.client else { return }
        Task {
            do {
                slicerKey = try await client.createToken(name: "Slicer")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func importPresets(_ urls: [URL]) {
        guard let client = state.client else { return }
        Task {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let names = try await client.importSlicerPresets(urls)
                state.show("Imported \(names.count) preset\(names.count == 1 ? "" : "s")")
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A text field that keeps its label once it has text in it, which a form's own doesn't on iOS.
private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }
}

/// Add a printer or change one. Fields come from the server, as they vary by type of printer.
struct MachineEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var draft: MachineDraft
    let kinds: [MachineKind]
    let changed: () async -> Void
    @State private var suggestions: [SlicerPrinterProfile] = []
    @State private var filaments: [SlicerProfile] = []
    @State private var colour = Color.gray
    @State private var saving = false
    @State private var confirmRemove = false
    @State private var error: String?

    private var kind: MachineKind? { kinds.first { $0.kind == draft.kind } }
    private var printerProfile: String { draft.slicerPrinter.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                LabeledField(label: "Name", text: $draft.name, prompt: "A1 mini")
                Picker("Type", selection: $draft.kind) {
                    ForEach(kinds) { Text($0.label).tag($0.kind) }
                }
            } footer: {
                if draft.kind == "bambu" {
                    Text("On the printer, turn on LAN Only mode and Developer Mode (Settings › Network on the A1, P1 and X1). The access code is shown on the same screen. Bambu Handy and Bambu cloud stop working with the printer while LAN Only mode is on.")
                }
            }

            if let kind, !kind.fields.isEmpty {
                Section("Connection") {
                    ForEach(kind.fields) { f in
                        if f.secret {
                            LabeledContent(f.label) {
                                SecureField(f.label, text: $draft.secret, prompt: Text(draft.hasSecret ? "Unchanged" : ""))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                            }
                        } else {
                            LabeledField(label: f.label, text: f.key == "serial" ? $draft.serial : $draft.host, prompt: "")
                        }
                    }
                }
            }

            Section {
                LabeledField(label: "Slicer profile", text: $draft.slicerPrinter, prompt: "Bambu Lab A1 mini 0.4 nozzle")
                ForEach(suggestions.filter { $0.name != printerProfile }.prefix(8)) { p in
                    Button {
                        draft.slicerPrinter = p.name
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).foregroundStyle(.primary)
                            Text(p.user ? "Imported" : p.vendor).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !printerProfile.isEmpty {
                    Picker("Filament in the printer", selection: $draft.installedFilament) {
                        Text("The profile's default").tag("")
                        if !draft.installedFilament.isEmpty, !filaments.contains(where: { $0.name == draft.installedFilament }) {
                            Text(draft.installedFilament).tag(draft.installedFilament)
                        }
                        ForEach(filaments) { f in
                            Text(f.name.components(separatedBy: " @").first ?? f.name).tag(f.name)
                        }
                    }
                    Toggle("Set the filament's colour", isOn: Binding(
                        get: { !draft.installedColour.isEmpty },
                        set: { draft.installedColour = $0 ? colour.hexString : "" }
                    ))
                    if !draft.installedColour.isEmpty {
                        // Bound to the colour itself, not to the saved text. Turning each change into
                        // text and back rounds it, which moved the picker's point as it was dragged.
                        ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                            .onChange(of: colour) { draft.installedColour = colour.hexString }
                    }
                }
            } header: {
                Text("Slicing")
            } footer: {
                Text("The OrcaSlicer printer used when 3DVault slices for this printer. Slicing starts with the filament and colour set here, unless an AMS slot is chosen for the print.")
            }

            Section {
                Picker("Bed size", selection: $draft.printerId) {
                    Text("Unknown").tag(Int?.none)
                    ForEach(state.printers) { Text($0.name).tag(Int?.some($0.id)) }
                }
                Toggle("Enabled", isOn: $draft.enabled)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if draft.id != nil {
                Section {
                    Button("Remove Printer", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.id == nil ? "Add Printer" : "Edit Printer")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.kind.isEmpty)
            }
        }
        .confirmationDialog("Remove \(draft.name)? Its print history is deleted too.", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Printer", role: .destructive) { remove() }
        }
        .onAppear { colour = Color(hex: draft.installedColour) ?? .gray }
        .task(id: printerProfile) {
            // Typing a name looks up matching profiles, a moment after typing stops.
            guard let client = state.client, printerProfile.count >= 2 else {
                suggestions = []
                filaments = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestions = (try? await client.slicerPrinters(query: printerProfile)) ?? []
            filaments = (try? await client.slicerFilaments(printer: printerProfile)) ?? []
        }
    }

    private func save() {
        guard let client = state.client else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await client.saveMachine(draft)
                await changed()
                state.changed()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func remove() {
        guard let client = state.client, let id = draft.id else { return }
        Task {
            do {
                try await client.deleteMachine(id)
                await changed()
                state.changed()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
