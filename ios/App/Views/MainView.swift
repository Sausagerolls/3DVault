import SwiftUI
import VaultKit

/// Loads pages of models for the current section and filters.
@MainActor
@Observable
final class LibraryModel {
    var items: [ModelSummary] = []
    var total = 0
    var loading = false
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
        await loadMore(state: state, replacing: true)
    }

    func loadMore(state: AppState, replacing: Bool = false) async {
        guard let client = state.client, !loading, replacing || items.count < total else { return }
        let t = token
        loading = true
        defer { loading = false }
        do {
            let p = try await client.models(query, page: page + 1)
            guard t == token else { return }
            page = p.page
            total = p.total
            items = replacing ? p.items : items + p.items
        } catch {
            guard t == token else { return }
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
    // On iPhone, going back to the sidebar clears the list selection. Keep showing the last section.
    @State private var shown: LibrarySection = .all
    @State private var path: [Int] = []
    @State private var library = LibraryModel()
    @State private var column: NavigationSplitViewColumn = .detail

    var body: some View {
        // Sidebar plus a full-width library; models push on top of the grid so it keeps the space.
        NavigationSplitView(preferredCompactColumn: $column) {
            SidebarView(section: $section)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if shown == .printers {
                        PrintersView { path = [$0] }
                    } else {
                        LibraryView(section: shown, library: library, opened: path.last) { path = [$0] }
                    }
                }
                .navigationDestination(for: Int.self) { id in
                    ModelDetailView(modelId: id, library: library)
                }
            }
        }
        .onChange(of: state.openPrinters) {
            guard state.openPrinters else { return }
            state.openPrinters = false
            section = .printers
            column = .detail
        }
        .onChange(of: state.openModel) {
            guard let id = state.openModel else { return }
            state.openModel = nil
            column = .detail
            path = [id]
        }
        .onChange(of: section) {
            // A nil selection means the user went back to the sidebar, so stay there.
            guard let section else { return }
            shown = section
            path = []
            column = .detail
        }
        #if DEBUG
        .task {
            // Simulator testing: VAULT_TEST_MODEL=<id> opens that model at launch.
            if let id = ProcessInfo.processInfo.environment["VAULT_TEST_MODEL"].flatMap(Int.init) { path = [id] }
            // VAULT_TEST_SECTION=printers opens the Printers screen.
            if ProcessInfo.processInfo.environment["VAULT_TEST_SECTION"] == "printers" { section = .printers }
        }
        #endif
    }
}
