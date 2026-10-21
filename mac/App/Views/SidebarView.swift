import SwiftUI
import VaultKit

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var section: LibrarySection?
    @AppStorage("sidebar.collections") private var showCollections = true
    @AppStorage("sidebar.categories") private var showCategories = true
    @AppStorage("sidebar.tags") private var showTags = false

    var body: some View {
        List(selection: $section) {
            Section {
                Label("Library", systemImage: "square.grid.2x2")
                    .badge(state.stats?.models ?? 0)
                    .tag(LibrarySection.all)
                Label("Untriaged", systemImage: "tray")
                    .badge(state.stats?.untriaged ?? 0)
                    .tag(LibrarySection.untriaged)
                Label("Favourites", systemImage: "heart").tag(LibrarySection.favourites)
                Label("Has problems", systemImage: "flag").tag(LibrarySection.flagged)
                Label("On this Mac", systemImage: "pin")
                    .badge(state.pins.pinned.count)
                    .tag(LibrarySection.pinned)
            }

            if !pinnedRows.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedRows, id: \.pin) { row in
                        Label(row.name, systemImage: row.icon)
                            .badge(row.count ?? 0)
                            .tag(row.pin.section)
                            .contextMenu { menu(for: row.pin) }
                    }
                    .onMove { state.movePins(from: $0, to: $1) }
                }
            }

            Section("Collections", isExpanded: $showCollections) {
                ForEach(state.collections) { c in
                    Label(c.name, systemImage: c.isSmart ? "gearshape.2" : "rectangle.stack")
                        .badge(c.count ?? 0)
                        .tag(LibrarySection.collection(c.id))
                        .contextMenu { menu(for: .collection(c.id)) }
                }
                if !state.offline {
                    newRow("New Collection…") { state.newCollection { section = .collection($0) } }
                }
            }

            Section("Categories", isExpanded: $showCategories) {
                ForEach(state.categoryTree, id: \.category.id) { item in
                    Label(item.category.name, systemImage: "folder")
                        .padding(.leading, CGFloat(item.depth) * 14)
                        .badge(item.category.count)
                        .tag(LibrarySection.category(item.category.id))
                        .contextMenu { menu(for: .category(item.category.id)) }
                }
                if !state.offline {
                    newRow("New Category…") { state.newCategory { section = .category($0) } }
                }
            }

            Section("Tags", isExpanded: $showTags) {
                ForEach(state.tags) { t in
                    Label(t.name, systemImage: "tag")
                        .badge(t.count ?? 0)
                        .tag(LibrarySection.tag(t.name))
                        .contextMenu { menu(for: .tag(t.name)) }
                }
                if state.tags.isEmpty {
                    Text("Tags appear here once models have them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Label("Trash", systemImage: "trash").tag(LibrarySection.trash)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: rows

    private func newRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    // MARK: context menus

    @ViewBuilder
    private func menu(for pin: SidebarPin) -> some View {
        Button(state.isPinned(pin) ? "Unpin from Sidebar" : "Pin to Sidebar") { state.togglePin(pin) }
        if !state.offline {
            Divider()
            switch pin {
            case .category(let id):
                if let c = state.categories.first(where: { $0.id == id }) {
                    Button("New Subcategory…") { state.newCategory(parent: c) { section = .category($0) } }
                    Button("Rename…") { state.renameCategory(c) }
                    Divider()
                    Button("Delete…", role: .destructive) { state.deleteCategory(c) { leave(.category(id)) } }
                }
            case .collection(let id):
                if let c = state.collections.first(where: { $0.id == id }), state.canEditCollection(c) {
                    Button("Rename…") { state.renameCollection(c) }
                    Toggle("Shared with Everyone", isOn: Binding(get: { c.shared }, set: { state.setCollectionShared(c, $0) }))
                    Divider()
                    Button("Delete…", role: .destructive) { state.deleteCollection(c) { leave(.collection(id)) } }
                }
            case .tag(let name):
                if let t = state.tags.first(where: { $0.name == name }) {
                    Button("Rename…") { state.renameTag(t) }
                    Divider()
                    Button("Delete…", role: .destructive) { state.deleteTag(t) { leave(.tag(name)) } }
                }
            }
        }
    }

    /// Go back to the library if the section being shown was deleted.
    private func leave(_ s: LibrarySection) {
        if section == s { section = .all }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            if !state.offline {
                HStack(spacing: 8) {
                    Menu {
                        Button("New Collection…") { state.newCollection { section = .collection($0) } }
                        Button("New Category…") { state.newCategory { section = .category($0) } }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.large)
                    .help("New collection or category")

                    Button { state.chooseUpload() } label: {
                        Label("Upload Files…", systemImage: "square.and.arrow.up.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                Text("or drag files anywhere onto the window")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            if let user = state.user {
                HStack {
                    Image(systemName: state.offline ? "wifi.slash" : "person.crop.circle")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(user.displayName).font(.callout)
                        Text(state.serverURL?.host() ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.offline {
                        Button("Retry") { Task { await state.refreshTaxonomy(); state.changed() } }
                            .controlSize(.small)
                    }
                }
                .padding(10)
            }
        }
    }
}
