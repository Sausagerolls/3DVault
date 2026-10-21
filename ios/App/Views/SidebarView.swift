import SwiftUI
import VaultKit

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var section: LibrarySection?
    @AppStorage("sidebar.collections") private var showCollections = true
    @AppStorage("sidebar.categories") private var showCategories = true
    @AppStorage("sidebar.tags") private var showTags = false
    @State private var showSettings = false

    var body: some View {
        List(selection: $section) {
            Section {
                row("Library", "square.grid.2x2", state.stats?.models).tag(LibrarySection.all)
                row("Untriaged", "tray", state.stats?.untriaged).tag(LibrarySection.untriaged)
                row("Favourites", "heart", nil).tag(LibrarySection.favourites)
                row("Has Problems", "flag", nil).tag(LibrarySection.flagged)
                row("Offline", "arrow.down.circle", state.pins.pinned.count).tag(LibrarySection.pinned)
            }

            if !pinnedRows.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedRows, id: \.pin) { r in
                        row(r.name, r.icon, r.count)
                            .tag(r.pin.section)
                            .contextMenu { menu(for: r.pin) }
                    }
                    .onMove { state.movePins(from: $0, to: $1) }
                }
            }

            Section("Collections", isExpanded: $showCollections) {
                ForEach(state.collections) { c in
                    row(c.name, c.isSmart ? "gearshape.2" : "rectangle.stack", c.count)
                        .tag(LibrarySection.collection(c.id))
                        .contextMenu { menu(for: .collection(c.id)) }
                }
                if !state.offline {
                    newRow("New Collection") { state.newCollection { section = .collection($0) } }
                }
            }

            Section("Categories", isExpanded: $showCategories) {
                ForEach(state.categoryTree, id: \.category.id) { item in
                    row(item.category.name, "folder", item.category.count)
                        .padding(.leading, CGFloat(item.depth) * 16)
                        .tag(LibrarySection.category(item.category.id))
                        .contextMenu { menu(for: .category(item.category.id)) }
                }
                if !state.offline {
                    newRow("New Category") { state.newCategory { section = .category($0) } }
                }
            }

            Section("Tags", isExpanded: $showTags) {
                ForEach(state.tags) { t in
                    row(t.name, "tag", t.count)
                        .tag(LibrarySection.tag(t.name))
                        .contextMenu { menu(for: .tag(t.name)) }
                }
                if state.tags.isEmpty {
                    Text("Tags appear here once models have them.").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                row("Trash", "trash", nil).tag(LibrarySection.trash)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("3DVault")
        .refreshable { await state.refreshTaxonomy() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: state.offline ? "wifi.slash" : "person.crop.circle")
                }
            }
            if state.offline {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Retry") { Task { await state.refreshTaxonomy(); state.changed() } }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func row(_ title: String, _ icon: String, _ count: Int?) -> some View {
        Label(title, systemImage: icon).badge(count ?? 0)
    }

    private func newRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus").foregroundStyle(.tint)
        }
    }

    private struct PinnedRow {
        let pin: SidebarPin
        let name: String
        let icon: String
        let count: Int?
    }

    /// Pins whose target still exists, in the user's order.
    private var pinnedRows: [PinnedRow] {
        state.sidebarPins.compactMap { pin in
            switch pin {
            case .category(let id):
                guard let c = state.categories.first(where: { $0.id == id }) else { return nil }
                return PinnedRow(pin: pin, name: c.name, icon: "folder", count: c.count)
            case .collection(let id):
                guard let c = state.collections.first(where: { $0.id == id }) else { return nil }
                return PinnedRow(pin: pin, name: c.name, icon: c.isSmart ? "gearshape.2" : "rectangle.stack", count: c.count)
            case .tag(let name):
                guard let t = state.tags.first(where: { $0.name == name }) else { return nil }
                return PinnedRow(pin: pin, name: t.name, icon: "tag", count: t.count)
            }
        }
    }

    @ViewBuilder
    private func menu(for pin: SidebarPin) -> some View {
        Button {
            state.togglePin(pin)
        } label: {
            state.isPinned(pin) ? Label("Unpin from Sidebar", systemImage: "pin.slash") : Label("Pin to Sidebar", systemImage: "pin")
        }
        if !state.offline {
            switch pin {
            case .category(let id):
                if let c = state.categories.first(where: { $0.id == id }) {
                    Button { state.newCategory(parent: c) { section = .category($0) } } label: { Label("New Subcategory…", systemImage: "folder.badge.plus") }
                    Button { state.renameCategory(c) } label: { Label("Rename…", systemImage: "pencil") }
                    Button(role: .destructive) { state.deleteCategory(c) { leave(.category(id)) } } label: { Label("Delete…", systemImage: "trash") }
                }
            case .collection(let id):
                if let c = state.collections.first(where: { $0.id == id }), state.canEditCollection(c) {
                    Button { state.renameCollection(c) } label: { Label("Rename…", systemImage: "pencil") }
                    Toggle(isOn: Binding(get: { c.shared }, set: { state.setCollectionShared(c, $0) })) {
                        Label("Shared with Everyone", systemImage: "person.2")
                    }
                    Button(role: .destructive) { state.deleteCollection(c) { leave(.collection(id)) } } label: { Label("Delete…", systemImage: "trash") }
                }
            case .tag(let name):
                if let t = state.tags.first(where: { $0.name == name }) {
                    Button { state.renameTag(t) } label: { Label("Rename…", systemImage: "pencil") }
                    Button(role: .destructive) { state.deleteTag(t) { leave(.tag(name)) } } label: { Label("Delete…", systemImage: "trash") }
                }
            }
        }
    }

    /// Go back to the library if the section being shown was deleted.
    private func leave(_ s: LibrarySection) {
        if section == s { section = .all }
    }
}
