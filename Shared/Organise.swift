import Foundation
import VaultKit

// Shared by the Mac and iOS apps. Each app's AppState provides client, user, categories, tags,
// collections, prompt, confirm, sidebarPins, changed() and report(_:).

/// Which list the library grid is showing.
enum LibrarySection: Hashable {
    case all, untriaged, favourites, flagged, trash, pinned
    case category(Int)
    case collection(Int)
    case tag(String)
}

/// A text prompt shown as an alert by MainView, used for naming categories, collections and tags.
struct NamePrompt: Identifiable {
    let id = UUID()
    let title: String
    var message = ""
    var initial = ""
    var action = "Create"
    let run: @MainActor (String) async throws -> Void
}

/// A destructive confirmation shown by MainView.
struct ConfirmPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    let run: @MainActor () async throws -> Void
}

/// A category, collection or tag the user has pinned to the top of the sidebar. Pins are stored per device.
enum SidebarPin: Hashable {
    case category(Int)
    case collection(Int)
    case tag(String)

    static let key = "sidebarPins"

    init?(_ raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "category": guard let id = Int(parts[1]) else { return nil }; self = .category(id)
        case "collection": guard let id = Int(parts[1]) else { return nil }; self = .collection(id)
        case "tag": self = .tag(parts[1])
        default: return nil
        }
    }

    var raw: String {
        switch self {
        case .category(let id): "category:\(id)"
        case .collection(let id): "collection:\(id)"
        case .tag(let name): "tag:\(name)"
        }
    }

    var section: LibrarySection {
        switch self {
        case .category(let id): .category(id)
        case .collection(let id): .collection(id)
        case .tag(let name): .tag(name)
        }
    }
}

extension AppState {
    // MARK: pins

    static func loadPins() -> [SidebarPin] {
        (UserDefaults.standard.stringArray(forKey: SidebarPin.key) ?? []).compactMap(SidebarPin.init)
    }

    func isPinned(_ pin: SidebarPin) -> Bool { sidebarPins.contains(pin) }

    func togglePin(_ pin: SidebarPin) {
        if let i = sidebarPins.firstIndex(of: pin) { sidebarPins.remove(at: i) } else { sidebarPins.append(pin) }
        savePins()
    }

    func movePins(from: IndexSet, to: Int) {
        sidebarPins.move(fromOffsets: from, toOffset: to)
        savePins()
    }

    private func replacePin(_ old: SidebarPin, with new: SidebarPin?) {
        guard let i = sidebarPins.firstIndex(of: old) else { return }
        if let new, !sidebarPins.contains(new) { sidebarPins[i] = new } else { sidebarPins.remove(at: i) }
        savePins()
    }

    private func savePins() {
        UserDefaults.standard.set(sidebarPins.map(\.raw), forKey: SidebarPin.key)
    }

    private func canEdit(_ c: VaultCollection) -> Bool {
        user?.isAdmin == true || user?.id == c.ownerId
    }

    // MARK: categories

    func newCategory(parent: VaultKit.Category? = nil, then open: ((Int) -> Void)? = nil) {
        guard let client else { return }
        prompt = NamePrompt(title: parent.map { "New Subcategory in \($0.name)" } ?? "New Category",
                            message: "Categories form a tree. Each model sits in one category.") { name in
            let c = try await client.createCategory(name: name, parentId: parent?.id)
            self.changed()
            open?(c.id)
        }
    }

    func renameCategory(_ c: VaultKit.Category) {
        guard let client else { return }
        prompt = NamePrompt(title: "Rename \(c.name)", initial: c.name, action: "Rename") { name in
            try await client.updateCategory(c.id, name: name, parentId: c.parentId)
            self.changed()
        }
    }

    func deleteCategory(_ c: VaultKit.Category, then done: (() -> Void)? = nil) {
        guard let client else { return }
        let parent = categories.first { $0.id == c.parentId }?.name
        confirm = ConfirmPrompt(title: "Delete \(c.name)?",
                                message: "Its models and subcategories move up to \(parent ?? "the top level"). No models are deleted.",
                                action: "Delete Category") {
            try await client.deleteCategory(c.id)
            self.replacePin(.category(c.id), with: nil)
            done?()
            self.changed()
        }
    }

    // MARK: collections

    func newCollection(adding ids: [Int] = [], then open: ((Int) -> Void)? = nil) {
        guard let client else { return }
        prompt = NamePrompt(title: "New Collection",
                            message: ids.isEmpty ? "Add models from their right-click menu or the detail pane." : "The \(ids.count) selected models will be added.") { name in
            let c = try await client.createCollection(name: name)
            if !ids.isEmpty { try await client.bulk(ids, ["add_to_collection": .number(Double(c.id))]) }
            self.changed()
            open?(c.id)
        }
    }

    func newSmartCollection(_ query: ModelQuery, then open: ((Int) -> Void)? = nil) {
        guard let client else { return }
        var q = query
        q.collectionId = nil
        q.trashed = false
        prompt = NamePrompt(title: "New Smart Collection",
                            message: "Saves the current search, section and filters. Matching models appear automatically.") { name in
            let c = try await client.createCollection(name: name, smartQuery: q.json)
            self.changed()
            open?(c.id)
        }
    }

    func renameCollection(_ c: VaultCollection) {
        guard let client, canEdit(c) else { return }
        prompt = NamePrompt(title: "Rename \(c.name)", initial: c.name, action: "Rename") { name in
            try await client.updateCollection(c, name: name, shared: c.shared)
            self.changed()
        }
    }

    func setCollectionShared(_ c: VaultCollection, _ shared: Bool) {
        guard let client, canEdit(c) else { return }
        Task {
            do {
                try await client.updateCollection(c, name: c.name, shared: shared)
                changed()
            } catch { report(error) }
        }
    }

    func deleteCollection(_ c: VaultCollection, then done: (() -> Void)? = nil) {
        guard let client, canEdit(c) else { return }
        confirm = ConfirmPrompt(title: "Delete \(c.name)?",
                                message: c.isSmart ? "The saved filters are removed. No models are deleted." : "The collection is removed. Its models stay in the library.",
                                action: "Delete Collection") {
            try await client.deleteCollection(c.id)
            self.replacePin(.collection(c.id), with: nil)
            done?()
            self.changed()
        }
    }

    func canEditCollection(_ c: VaultCollection) -> Bool { canEdit(c) }

    // MARK: tags

    func renameTag(_ t: Tag) {
        guard let client else { return }
        prompt = NamePrompt(title: "Rename tag \(t.name)", message: "Renaming to an existing tag merges the two.", initial: t.name, action: "Rename") { name in
            try await client.renameTag(t.id, to: name)
            self.replacePin(.tag(t.name), with: .tag(name.lowercased()))
            self.changed()
        }
    }

    func deleteTag(_ t: Tag, then done: (() -> Void)? = nil) {
        guard let client else { return }
        confirm = ConfirmPrompt(title: "Delete tag \(t.name)?", message: "The tag is removed from \(t.count ?? 0) models. No models are deleted.", action: "Delete Tag") {
            try await client.deleteTag(t.id)
            self.replacePin(.tag(t.name), with: nil)
            done?()
            self.changed()
        }
    }
}
