import SwiftUI
import VaultKit

/// Drag a sidebar category onto another to nest it, or onto the Categories header to move it to the top level.
/// The payload is a plain string so it can't be confused with dragged files or models.
enum CategoryDrag {
    static let prefix = "3dvault-category:"

    static func payload(_ id: Int) -> String { prefix + String(id) }

    static func id(from payload: String) -> Int? {
        payload.hasPrefix(prefix) ? Int(payload.dropFirst(prefix.count)) : nil
    }
}

extension AppState {
    /// True when the category can move under `parent` (nil for the top level).
    func canMoveCategory(_ id: Int, to parent: Int?) -> Bool {
        guard let c = categories.first(where: { $0.id == id }), c.parentId != parent else { return false }
        // Refuse moving a category into itself or one of its own subcategories.
        var p = parent
        while let pid = p {
            if pid == id { return false }
            p = categories.first { $0.id == pid }?.parentId
        }
        return true
    }

    func moveCategory(_ id: Int, to parent: Int?) {
        guard let client, canMoveCategory(id, to: parent),
              let c = categories.first(where: { $0.id == id }) else { return }
        Task {
            do {
                try await client.updateCategory(c.id, name: c.name, parentId: parent)
                changed()
            } catch {
                report(error)
            }
        }
    }
}

private struct CategoryDropTarget: ViewModifier {
    @Environment(AppState.self) private var state
    let parent: Int?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.compactMap(CategoryDrag.id(from:)).first,
                      state.canMoveCategory(id, to: parent) else { return false }
                state.moveCategory(id, to: parent)
                return true
            } isTargeted: { targeted = $0 }
            .background(targeted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

extension View {
    /// Makes this view accept a dragged category and move it under `parent` (nil for the top level).
    func categoryDropTarget(_ parent: Int?) -> some View {
        modifier(CategoryDropTarget(parent: parent))
    }
}
