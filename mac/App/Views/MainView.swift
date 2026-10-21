import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// Loads pages of models for the current section and filters.
@MainActor
@Observable
final class LibraryModel {
    var items: [ModelSummary] = []
    var total = 0
    var loading = false
    var error: String?
    private var page = 0
    private var query = ModelQuery()
    private var token = UUID()

    func reload(_ q: ModelQuery, state: AppState, section: LibrarySection) async {
        query = q
        page = 0
        token = UUID()
        if section == .pinned || state.offline {
            items = state.pins.summaries.filter { q.q.isEmpty || $0.name.localizedCaseInsensitiveContains(q.q) }
            total = items.count
            return
        }
        items = []
        await loadMore(state: state)
    }

    func loadMore(state: AppState) async {
        guard let client = state.client, !loading, page == 0 || items.count < total else { return }
        let t = token
        loading = true
        defer { loading = false }
        do {
            let p = try await client.models(query, page: page + 1)
            guard t == token else { return }
            page = p.page
            total = p.total
            items += p.items
            error = nil
        } catch {
            guard t == token else { return }
            self.error = error.localizedDescription
            state.report(error)
        }
    }

    /// Refresh one model in place after an edit.
    func update(_ m: ModelSummary) {
        if let i = items.firstIndex(where: { $0.id == m.id }) { items[i] = m }
    }
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var section: LibrarySection? = .all
    @State private var search = ""
    @State private var sort = "new"
    @State private var statuses: Set<PrintStatus> = []
    @State private var printerId: Int?
    @State private var tagFilter: [String] = []
    @State private var selection: Set<Int> = []
    @State private var library = LibraryModel()
    @State private var dropTargeted = false
    @AppStorage("cardSize") private var cardSize = 180.0

    var query: ModelQuery {
        var q = ModelQuery()
        q.q = search
        q.sort = sort
        q.statuses = statuses.map(\.rawValue)
        q.printerId = printerId
        q.tags = tagFilter
        switch section ?? .all {
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

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView(section: $section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            LibraryGrid(library: library, selection: $selection, cardSize: cardSize, trashed: section == .trash)
                .navigationSplitViewColumnWidth(min: 380, ideal: 720)
                .navigationTitle(title)
                .navigationSubtitle(library.loading && library.items.isEmpty ? "Loading…" : "\(library.total) models")
                .toolbar { toolbar }
        } detail: {
            DetailPane(selection: selection, library: library, trashed: section == .trash)
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search models, tags, files")
        .task(id: ReloadKey(query: query, revision: state.revision, section: section ?? .all, offline: state.offline)) {
            // Debounce typing in the search field.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            selection = selection.filter { id in library.items.contains { $0.id == id } }
            await library.reload(query, state: state, section: section ?? .all)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { state.pendingUpload = await fileURLs(from: providers) }
            return !state.offline
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.orange.opacity(0.08))
                    .overlay(Text("Drop to upload").font(.title2.bold()).foregroundStyle(.orange))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: Binding(get: { !state.pendingUpload.isEmpty }, set: { if !$0 { state.pendingUpload = [] } })) {
            UploadSheet(urls: state.pendingUpload)
        }
        .onChange(of: section) { selection = [] }
        .modifier(Prompts())
    }

    struct ReloadKey: Hashable {
        let query: ModelQuery
        let revision: Int
        let section: LibrarySection
        let offline: Bool
    }

    private var title: String {
        switch section ?? .all {
        case .all: "Library"
        case .untriaged: "Untriaged"
        case .favourites: "Favourites"
        case .flagged: "Has problems"
        case .trash: "Trash"
        case .pinned: "On this Mac"
        case .category(let id): state.categories.first { $0.id == id }?.name ?? "Category"
        case .collection(let id): state.collections.first { $0.id == id }?.name ?? "Collection"
        case .tag(let name): "#\(name)"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { state.chooseUpload() } label: {
                Label("Upload", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Upload model files or folders (⌘U). You can also drag files onto the window.")
            .disabled(state.offline)
        }
        ToolbarItemGroup {
            if state.offline {
                Label("Offline", systemImage: "wifi.slash").foregroundStyle(.secondary)
            }
            Menu {
                Section("My print status") {
                    ForEach(PrintStatus.allCases) { s in
                        Toggle(s.label, isOn: Binding(get: { statuses.contains(s) }, set: { on in
                            if on { statuses.insert(s) } else { statuses.remove(s) }
                        }))
                    }
                }
                Section("Fits printer") {
                    Picker("Fits printer", selection: $printerId) {
                        Text("Any printer").tag(Int?.none)
                        ForEach(state.printers) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Tags") {
                    ForEach(state.tags.prefix(30)) { t in
                        Toggle("\(t.name) (\(t.count ?? 0))", isOn: Binding(get: { tagFilter.contains(t.name) }, set: { on in
                            if on { tagFilter.append(t.name) } else { tagFilter.removeAll { $0 == t.name } }
                        }))
                    }
                }
                Divider()
                Button("Save as Smart Collection…") { state.newSmartCollection(query) { section = .collection($0) } }
                if !statuses.isEmpty || printerId != nil || !tagFilter.isEmpty {
                    Button("Clear filters") {
                        statuses = []
                        printerId = nil
                        tagFilter = []
                    }
                }
            } label: {
                Label("Filter", systemImage: statuses.isEmpty && printerId == nil && tagFilter.isEmpty
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            Picker("Sort", selection: $sort) {
                Text("Newest").tag("new")
                Text("Oldest").tag("old")
                Text("Name").tag("name")
                Text("Recently edited").tag("updated")
                Text("My rating").tag("rating")
                Text("Largest").tag("size")
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            Slider(value: $cardSize, in: 120...320)
                .frame(width: 90)
                .help("Thumbnail size")
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
            .confirmationDialog(state.confirm?.title ?? "", isPresented: Binding(get: { state.confirm != nil }, set: { if !$0 { state.confirm = nil } }), presenting: state.confirm) { c in
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

func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
    var out: [URL] = []
    for p in providers {
        if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
           let u = URL(dataRepresentation: url, relativeTo: nil) {
            out.append(u)
        }
    }
    return out
}
