import SwiftUI
import VaultKit

/// A button showing the chosen category's path that opens a searchable chooser.
/// `selection` uses -1 for no category. Set `prompt` to show fixed text instead of
/// the current value, for "apply to all" pickers.
struct CategoryPicker: View {
    @Binding var selection: Int
    var noneLabel = "None"
    var prompt: String?
    @Environment(AppState.self) private var state
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Text(prompt ?? (selection == -1 ? noneLabel : state.categoryPath(selection)))
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        #if DEBUG
        .task {
            // VAULT_TEST_CATEGORY=1 opens the chooser, =<text> also searches, for screenshots.
            if prompt == nil, ProcessInfo.processInfo.environment["VAULT_TEST_CATEGORY"] != nil { open = true }
        }
        #endif
        #if os(macOS)
        .buttonStyle(.bordered)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            CategoryChooser(selection: $selection, noneLabel: noneLabel)
                .frame(width: 340, height: 440)
        }
        #else
        .sheet(isPresented: $open) {
            NavigationStack {
                CategoryChooser(selection: $selection, noneLabel: noneLabel)
            }
            .presentationDetents([.medium, .large])
        }
        #endif
    }
}

/// Search, recently used categories and a collapsible tree.
struct CategoryChooser: View {
    @Binding var selection: Int
    let noneLabel: String
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded: Set<Int> = []
    @AppStorage("categoryPicker.recent") private var recentRaw = ""

    private static let recentLimit = 6

    private var byId: [Int: VaultKit.Category] {
        Dictionary(uniqueKeysWithValues: state.categories.map { ($0.id, $0) })
    }

    private var recent: [Int] {
        let known = byId
        return recentRaw.split(separator: ",").compactMap { Int($0) }.filter { known[$0] != nil }
    }

    /// Categories whose full path contains every search word, sorted by path.
    private var matches: [(id: Int, name: String, parent: String)] {
        let words = query.split(separator: " ").map(String.init)
        return state.categories
            .map { c in (id: c.id, name: c.name, path: state.categoryPath(c.id)) }
            .filter { item in words.allSatisfy { item.path.localizedStandardContains($0) } }
            // Names that match come before categories that only match through a parent.
            .sorted { a, b in
                let an = words.allSatisfy { a.name.localizedStandardContains($0) }
                let bn = words.allSatisfy { b.name.localizedStandardContains($0) }
                if an != bn { return an }
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
            .map { item in
                let parent = item.path.count > item.name.count ? String(item.path.dropLast(item.name.count + 3)) : ""
                return (item.id, item.name, parent)
            }
    }

    /// Tree rows whose ancestors are all expanded.
    private var visibleTree: [(category: VaultKit.Category, depth: Int, hasChildren: Bool)] {
        let parents = Set(state.categories.compactMap(\.parentId))
        var out: [(VaultKit.Category, Int, Bool)] = []
        var hiddenBelow: Int?
        for item in state.categoryTree {
            if let d = hiddenBelow, item.depth > d { continue }
            hiddenBelow = nil
            let hasChildren = parents.contains(item.category.id)
            out.append((item.category, item.depth, hasChildren))
            if hasChildren, !expanded.contains(item.category.id) { hiddenBelow = item.depth }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            TextField("Search categories", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .onSubmit { if let first = matches.first, !query.isEmpty { choose(first.id) } }
            #endif
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        row(id: -1, title: noneLabel, subtitle: nil)
                    }
                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent, id: \.self) { id in
                                let path = state.categoryPath(id)
                                let name = byId[id]?.name ?? path
                                row(id: id, title: name, subtitle: path == name ? nil : String(path.dropLast(name.count + 3)))
                            }
                        }
                    }
                    Section("All Categories") {
                        ForEach(visibleTree, id: \.category.id) { item in
                            treeRow(item.category, depth: item.depth, hasChildren: item.hasChildren)
                        }
                    }
                } else {
                    let found = matches
                    if found.isEmpty {
                        Text("No matching categories").foregroundStyle(.secondary)
                    }
                    ForEach(found, id: \.id) { item in
                        row(id: item.id, title: item.name, subtitle: item.parent.isEmpty ? nil : item.parent)
                    }
                }
            }
        }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
        .onSubmit(of: .search) { if let first = matches.first { choose(first.id) } }
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        #endif
        .onAppear {
            expandToSelection()
            #if DEBUG
            if let q = ProcessInfo.processInfo.environment["VAULT_TEST_CATEGORY"], q != "1" { query = q }
            #endif
        }
    }

    private func row(id: Int, title: String, subtitle: String?) -> some View {
        Button { choose(id) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer()
                if id == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func treeRow(_ c: VaultKit.Category, depth: Int, hasChildren: Bool) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
            if hasChildren {
                Button {
                    if expanded.contains(c.id) { expanded.remove(c.id) } else { expanded.insert(c.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded.contains(c.id) ? 90 : 0))
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 20, height: 1)
            }
            row(id: c.id, title: c.name, subtitle: nil)
        }
    }

    private func choose(_ id: Int) {
        selection = id
        if id != -1 {
            let ids = [id] + recent.filter { $0 != id }
            recentRaw = ids.prefix(Self.recentLimit).map(String.init).joined(separator: ",")
        }
        dismiss()
    }

    /// Open the tree down to the current choice so it is visible.
    private func expandToSelection() {
        var id = byId[selection]?.parentId
        while let p = id {
            expanded.insert(p)
            id = byId[p]?.parentId
        }
    }
}

/// Menu items for choosing a category, nested by parent so long trees stay short.
/// A parent's submenu lists the parent itself first, then its children.
struct CategoryMenuItems: View {
    var parent: Int?
    let action: (VaultKit.Category) -> Void
    @Environment(AppState.self) private var state

    var body: some View {
        let children = state.categories
            .filter { $0.parentId == parent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        ForEach(children) { c in
            if state.categories.contains(where: { $0.parentId == c.id }) {
                Menu(c.name) {
                    Button(c.name) { action(c) }
                    Divider()
                    CategoryMenuItems(parent: c.id, action: action)
                }
            } else {
                Button(c.name) { action(c) }
            }
        }
    }
}
