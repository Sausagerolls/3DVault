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
    @State private var path: [Int] = []
    @State private var library = LibraryModel()
    @State private var column: NavigationSplitViewColumn = .detail

    var body: some View {
        // Sidebar plus a full-width library; models push on top of the grid so it keeps the space.
        NavigationSplitView(preferredCompactColumn: $column) {
            SidebarView(section: $section)
        } detail: {
            NavigationStack(path: $path) {
                LibraryView(section: section ?? .all, library: library, opened: path.last) { path = [$0] }
                    .navigationDestination(for: Int.self) { id in
                        ModelDetailView(modelId: id, library: library)
                    }
            }
        }
        .onChange(of: section) {
            path = []
            column = .detail
        }
        #if DEBUG
        .task {
            // Simulator testing: VAULT_TEST_MODEL=<id> opens that model at launch.
            if let id = ProcessInfo.processInfo.environment["VAULT_TEST_MODEL"].flatMap(Int.init) { path = [id] }
        }
        #endif
    }
}
