import SwiftUI
import VaultKit

struct LibraryView: View {
    @Environment(AppState.self) private var state
    let section: LibrarySection
    let library: LibraryModel
    let opened: Int?
    let open: (Int) -> Void

    @State private var search = ""
    @AppStorage("sort") private var sort = "new"
    @State private var statuses: Set<PrintStatus> = []
    @State private var printerId: Int?
    @State private var tagFilter: [String] = []
    @State private var selecting = false
    @State private var selection: Set<Int> = []
    @State private var importing = false
    @State private var showBulk = false
    @AppStorage("cardSize") private var cardSize = 160.0

    private var trashed: Bool { section == .trash }

    var query: ModelQuery {
        var q = ModelQuery()
        q.q = search
        q.sort = sort
        q.statuses = statuses.map(\.rawValue)
        q.printerId = printerId
        q.tags = tagFilter
        switch section {
        case .all, .pinned: break
        case .untriaged: q.untriaged = true
        case .favourites: q.favourite = true
        case .flagged: q.flagged = true
        case .trash: q.trashed = true
        case .category(let id): q.categoryId = id
        case .collection(let id): q.collectionId = id
        case .tag(let name): if !q.tags.contains(name) { q.tags.append(name) }
        }
        return q
    }

    struct ReloadKey: Hashable {
        let query: ModelQuery
        let revision: Int
        let section: LibrarySection
        let offline: Bool
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.5), spacing: 12)], spacing: 12) {
                ForEach(library.items) { m in
                    ModelCard(model: m, selecting: selecting, selected: selection.contains(m.id),
                              highlighted: opened == m.id && !selecting, pinned: state.pins.isPinned(m.id))
                        .onTapGesture {
                            if selecting {
                                if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
                            } else {
                                open(m.id)
                            }
                        }
                        .contextMenu {
                            ModelMenu(ids: selecting && selection.contains(m.id) ? Array(selection) : [m.id], trashed: trashed) {
                                selection = []
                            }
                        } preview: {
                            CardPreview(model: m)
                        }
                        .onAppear {
                            if m.id == library.items.last?.id { Task { await library.loadMore(state: state) } }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if library.loading && !library.items.isEmpty { ProgressView().padding() }
        }
        .overlay {
            if !library.loading && library.items.isEmpty { empty }
        }
        .navigationTitle(title)
        .navigationSubtitle(library.total == 0 ? "" : "\(library.total) model\(library.total == 1 ? "" : "s")")
        .searchable(text: $search, prompt: "Models, tags, files")
        .refreshable {
            state.changed()
            await library.reload(query, state: state, section: section)
        }
        .toolbar { toolbar }
        .task(id: ReloadKey(query: query, revision: state.revision, section: section, offline: state.offline)) {
            // Debounce typing in the search field.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await library.reload(query, state: state, section: section)
            selection = selection.filter { id in library.items.contains { $0.id == id } }
        }
        .onChange(of: section) {
            selecting = false
            selection = []
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): state.stageForUpload(urls)
            case .failure(let error): state.report(error)
            }
        }
        .sheet(isPresented: $showBulk) {
            BulkSheet(ids: Array(selection), trashed: trashed) {
                selection = []
                selecting = false
            }
        }
    }

    private var title: String {
        switch section {
        case .all: "Library"
        case .untriaged: "Untriaged"
        case .favourites: "Favourites"
        case .flagged: "Has Problems"
        case .trash: "Trash"
        case .pinned: "Offline"
        case .category(let id): state.categories.first { $0.id == id }?.name ?? "Category"
        case .collection(let id): state.collections.first { $0.id == id }?.name ?? "Collection"
        case .tag(let name): "#\(name)"
        }
    }

    @ViewBuilder
    private var empty: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView {
                Label(state.offline ? "Offline" : trashed ? "Trash Is Empty" : "No Models", systemImage: state.offline ? "wifi.slash" : "cube.transparent")
            } description: {
                Text(state.offline ? "Showing models saved on this device." : trashed ? "" : "Upload model files or folders from Files, or share them to 3DVault from another app.")
            } actions: {
                if !state.offline && !trashed {
                    Button("Upload Files…") { importing = true }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == library.items.count ? "Deselect All" : "Select All") {
                    selection = selection.count == library.items.count ? [] : Set(library.items.map(\.id))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    selecting = false
                    selection = []
                }
                .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await ModelActions.share(Array(selection), state: state) }
                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .disabled(selection.isEmpty || trashed)
                Spacer()
                Text(selection.isEmpty ? "Select Models" : "\(selection.count) Selected").font(.headline)
                Spacer()
                Button { showBulk = true } label: { Label("Actions", systemImage: "ellipsis.circle") }
                    .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu
                Button("Select") { selecting = true }
                    .disabled(library.items.isEmpty)
                if !state.offline {
                    Menu {
                        Button { importing = true } label: { Label("Upload Files…", systemImage: "square.and.arrow.up.on.square") }
                        Divider()
                        Button { state.newCollection() } label: { Label("New Collection…", systemImage: "rectangle.stack.badge.plus") }
                        Button { state.newCategory() } label: { Label("New Category…", systemImage: "folder.badge.plus") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    } primaryAction: {
                        importing = true
                    }
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Newest").tag("new")
                Text("Oldest").tag("old")
                Text("Name").tag("name")
                Text("Recently Edited").tag("updated")
                Text("My Rating").tag("rating")
                Text("Largest").tag("size")
            }
            .pickerStyle(.menu)
            Menu("My Print Status") {
                ForEach(PrintStatus.allCases) { s in
                    Toggle(s.label, isOn: Binding(get: { statuses.contains(s) }, set: { on in
                        if on { statuses.insert(s) } else { statuses.remove(s) }
                    }))
                }
            }
            Picker("Fits Printer", selection: $printerId) {
                Text("Any Printer").tag(Int?.none)
                ForEach(state.printers) { p in Text(p.name).tag(Optional(p.id)) }
            }
            .pickerStyle(.menu)
            Menu("Tags") {
                ForEach(state.tags.prefix(40)) { t in
                    Toggle("\(t.name) (\(t.count ?? 0))", isOn: Binding(get: { tagFilter.contains(t.name) }, set: { on in
                        if on { tagFilter.append(t.name) } else { tagFilter.removeAll { $0 == t.name } }
                    }))
                }
            }
            Section("Card Size") {
                ControlGroup {
                    Button { cardSize = max(110, cardSize - 30) } label: { Label("Smaller", systemImage: "minus.magnifyingglass") }
                    Button { cardSize = min(300, cardSize + 30) } label: { Label("Larger", systemImage: "plus.magnifyingglass") }
                }
            }
            if !state.offline {
                Button { state.newSmartCollection(query) } label: { Label("Save as Smart Collection…", systemImage: "gearshape.2") }
            }
            if !statuses.isEmpty || printerId != nil || !tagFilter.isEmpty {
                Button("Clear Filters", role: .destructive) {
                    statuses = []
                    printerId = nil
                    tagFilter = []
                }
            }
        } label: {
            Label("Filter", systemImage: statuses.isEmpty && printerId == nil && tagFilter.isEmpty
                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

/// Long-press preview: the model spinning in 3D, or its thumbnail if it has no mesh.
private struct CardPreview: View {
    let model: ModelSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let pid = model.previewFileId {
                    MeshView(fileId: pid, lod: true, interactive: false, spin: true)
                } else {
                    Thumbnail(fileId: model.coverFileId)
                }
            }
            .frame(width: 320, height: 320)
            .background(Color(.secondarySystemBackground))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.headline)
                if let d = model.dimensions { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(12)
        }
        .frame(width: 320)
    }
}

struct ModelCard: View {
    let model: ModelSummary
    let selecting: Bool
    let selected: Bool
    let highlighted: Bool
    let pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Square slot first, then the image inside it, so photo covers filling the slot can't widen the card.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { Thumbnail(fileId: model.coverFileId, fill: !model.coverHasPreview) }
                .background(RadialGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.02)], center: .center, startRadius: 5, endRadius: 200))
                .clipped()
                .overlay(alignment: .top) {
                    HStack(spacing: 4) {
                        if model.untriaged && model.deletedAt == nil { Badge(text: "New", color: .orange) }
                        if pinned { Badge(system: "arrow.down.circle.fill", color: .blue) }
                        Spacer()
                        if model.me.favourite { Badge(system: "heart.fill", color: .pink) }
                        if model.flagCount > 0 { Badge(system: "flag.fill", color: .red) }
                        if let s = model.me.status { Badge(text: s.label, color: s == .printed ? .green : s == .failed ? .red : .gray) }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.25))
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack {
                    if let d = model.dimensions { Text(d).lineLimit(1) } else { Text(model.partCount == 0 ? "No mesh" : "\(model.partCount) parts") }
                    Spacer(minLength: 0)
                    if let r = model.me.rating, r > 0 { Text("★\(r)").foregroundStyle(.yellow) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected || highlighted ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected || highlighted ? 2.5 : 1))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Actions for one or more models, used by the long-press menu.
struct ModelMenu: View {
    @Environment(AppState.self) private var state
    let ids: [Int]
    let trashed: Bool
    var cleared: () -> Void = {}

    var body: some View {
        let n = ids.count
        if trashed {
            Button { run(["restore": .bool(true)], "Restored \(n)") } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
        } else {
            Button { Task { await ModelActions.share(ids, state: state) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            Button { Task { await ModelActions.share(ids, airDrop: true, state: state) } } label: { Label("Send to Mac", systemImage: "laptopcomputer.and.arrow.down") }
            Button { Task { await ModelActions.togglePin(ids, state: state) } } label: {
                ids.allSatisfy(state.pins.isPinned)
                    ? Label("Remove Offline Copy", systemImage: "arrow.down.circle.dotted")
                    : Label("Keep Offline", systemImage: "arrow.down.circle")
            }
            .disabled(state.offline && !ids.allSatisfy(state.pins.isPinned))
            if !state.offline {
                Divider()
                Button { run(["favourite": .bool(true)], "Favourited \(n)") } label: { Label("Favourite", systemImage: "heart") }
                Menu {
                    ForEach(PrintStatus.allCases) { s in
                        Button(s.label) { run(["status": .string(s.rawValue)], "Marked \(n) as \(s.label)") }
                    }
                    Divider()
                    Button("Clear") { run(["status": .string("")], "Cleared status") }
                } label: { Label("Print Status", systemImage: "checkmark.circle") }
                Menu {
                    Button("None") { run(["clear_category": .bool(true)], "Cleared category") }
                    ForEach(state.categoryTree, id: \.category.id) { item in
                        Button(String(repeating: "    ", count: item.depth) + item.category.name) {
                            run(["category_id": .number(Double(item.category.id))], "Moved \(n) to \(item.category.name)")
                        }
                    }
                } label: { Label("Category", systemImage: "folder") }
                Menu {
                    ForEach(state.collections.filter { !$0.isSmart }) { c in
                        Button(c.name) { run(["add_to_collection": .number(Double(c.id))], "Added to \(c.name)") }
                    }
                    Divider()
                    Button("New Collection…") { state.newCollection(adding: ids) }
                } label: { Label("Add to Collection", systemImage: "rectangle.stack.badge.plus") }
                Button { run(["untriaged": .bool(false)], "Marked \(n) as triaged") } label: { Label("Mark as Triaged", systemImage: "tray.and.arrow.down") }
                Divider()
                Button(role: .destructive) {
                    run(["delete": .bool(true)], "Moved \(n) to trash")
                    cleared()
                } label: { Label("Move to Trash", systemImage: "trash") }
            }
        }
    }

    private func run(_ body: [String: JSONValue], _ message: String) {
        Task { await ModelActions.bulk(ids, body, message: message, state: state) }
    }
}
