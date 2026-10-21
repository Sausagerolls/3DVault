import SwiftUI
import VaultKit

/// Organise several selected models at once.
struct BulkSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let ids: [Int]
    let trashed: Bool
    let finished: () -> Void
    @State private var addTags = ""
    @State private var removeTags = ""

    var body: some View {
        let n = ids.count
        NavigationStack {
            Form {
                if trashed {
                    Button("Restore \(n) Model\(n == 1 ? "" : "s")") { run(["restore": .bool(true)], "Restored \(n)", finish: true) }
                } else {
                    Section {
                        Button { dismiss(); Task { await ModelActions.share(ids, state: state) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        Button { dismiss(); Task { await ModelActions.share(ids, airDrop: true, state: state) } } label: { Label("Send to Mac", systemImage: "laptopcomputer.and.arrow.down") }
                        Button { Task { await ModelActions.togglePin(ids, state: state) } } label: {
                            ids.allSatisfy(state.pins.isPinned)
                                ? Label("Remove Offline Copies", systemImage: "arrow.down.circle.dotted")
                                : Label("Keep Offline", systemImage: "arrow.down.circle")
                        }
                    }
                    if !state.offline {
                        Section("Category") {
                            Menu {
                                Button("None") { run(["clear_category": .bool(true)], "Cleared category") }
                                ForEach(state.categoryTree, id: \.category.id) { item in
                                    Button(String(repeating: "    ", count: item.depth) + item.category.name) {
                                        run(["category_id": .number(Double(item.category.id))], "Moved \(n) to \(item.category.name)")
                                    }
                                }
                            } label: { Label("Set Category", systemImage: "folder") }
                            Button { run(["untriaged": .bool(false)], "Marked \(n) as triaged") } label: { Label("Mark as Triaged", systemImage: "tray.and.arrow.down") }
                        }
                        Section("Tags") {
                            HStack {
                                TextField("Add tags, comma separated", text: $addTags)
                                Button("Add") { run(["add_tags": tagList(addTags)], "Tagged \(n)"); addTags = "" }.disabled(addTags.isEmpty)
                            }
                            HStack {
                                TextField("Remove tags", text: $removeTags)
                                Button("Remove") { run(["remove_tags": tagList(removeTags)], "Updated tags"); removeTags = "" }.disabled(removeTags.isEmpty)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Section("My print status") {
                            Menu {
                                ForEach(PrintStatus.allCases) { s in
                                    Button(s.label) { run(["status": .string(s.rawValue)], "Marked \(n) as \(s.label)") }
                                }
                                Divider()
                                Button("Clear") { run(["status": .string("")], "Cleared status") }
                            } label: { Label("Set Status", systemImage: "checkmark.circle") }
                            Button { run(["favourite": .bool(true)], "Favourited \(n)") } label: { Label("Favourite", systemImage: "heart") }
                        }
                        Section("Collections") {
                            Menu {
                                ForEach(state.collections.filter { !$0.isSmart }) { c in
                                    Button(c.name) { run(["add_to_collection": .number(Double(c.id))], "Added to \(c.name)") }
                                }
                            } label: { Label("Add to Collection", systemImage: "rectangle.stack.badge.plus") }
                            Button { state.newCollection(adding: ids) } label: { Label("New Collection with Selection…", systemImage: "plus") }
                        }
                        Section {
                            Button(role: .destructive) { run(["delete": .bool(true)], "Moved \(n) to trash", finish: true) } label: {
                                Label("Move \(n) to Trash", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(n) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tagList(_ s: String) -> JSONValue {
        .array(s.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces).lowercased()) }.filter { $0 != .string("") })
    }

    private func run(_ body: [String: JSONValue], _ message: String, finish: Bool = false) {
        Task {
            await ModelActions.bulk(ids, body, message: message, state: state)
            if finish {
                finished()
                dismiss()
            }
        }
    }
}
