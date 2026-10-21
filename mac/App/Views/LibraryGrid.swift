import SwiftUI
import VaultKit

struct LibraryGrid: View {
    @Environment(AppState.self) private var state
    var library: LibraryModel
    @Binding var selection: Set<Int>
    var cardSize: Double
    var trashed: Bool
    @State private var anchor: Int?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.4), spacing: 14)], spacing: 14) {
                ForEach(library.items) { m in
                    ModelCell(model: m, selected: selection.contains(m.id), pinned: state.pins.isPinned(m.id))
                        .onTapGesture(count: 2) { Task { await ModelActions.openInSlicer([m.id], state: state) } }
                        .onTapGesture {
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.command) { toggle(m.id) } else if mods.contains(.shift) { extend(to: m.id) } else { select(m.id) }
                        }
                        .contextMenu { menu(for: m.id) }
                        .onDrag { dragProvider(m) }
                        .onAppear {
                            if m.id == library.items.last?.id { Task { await library.loadMore(state: state) } }
                        }
                }
            }
            .padding(16)
            if library.loading && !library.items.isEmpty { ProgressView().padding() }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if !library.loading && library.items.isEmpty {
                ContentUnavailableView {
                    Label(state.offline ? "Offline" : "No models", systemImage: state.offline ? "wifi.slash" : "cube.transparent")
                } description: {
                    Text(state.offline ? "Showing models kept on this Mac." : "Drag model files or folders here, or choose them to upload.")
                } actions: {
                    if !state.offline && !trashed {
                        Button("Upload Files…") { state.chooseUpload() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onKeyPress(.escape) {
            selection = []
            return .handled
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection = Set(library.items.map(\.id)) }
    }

    private func select(_ id: Int) {
        selection = [id]
        anchor = id
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        anchor = id
    }

    private func extend(to id: Int) {
        guard let anchor, let a = library.items.firstIndex(where: { $0.id == anchor }),
              let b = library.items.firstIndex(where: { $0.id == id }) else { return select(id) }
        selection.formUnion(library.items[min(a, b)...max(a, b)].map(\.id))
    }

    /// Dragging a model hands over its main printable file.
    private func dragProvider(_ m: ModelSummary) -> NSItemProvider {
        if let pinned = state.pins.pinned[m.id], let f = Slicer.filesToOpen(pinned).first {
            return state.files.dragProvider(f, modelId: m.id)
        }
        let provider = NSItemProvider()
        provider.suggestedName = m.name
        provider.registerFileRepresentation(forTypeIdentifier: "public.data", fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let detail = try await ModelActions.detail(m.id, state: state)
                    guard let f = Slicer.filesToOpen(detail).first else { throw CocoaError(.fileNoSuchFile) }
                    completion(try await state.files.local(f, modelId: m.id), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    @ViewBuilder
    private func menu(for id: Int) -> some View {
        let ids = selection.contains(id) ? Array(selection) : [id]
        let n = ids.count
        if trashed {
            Button("Restore \(n == 1 ? "" : "\(n) Models")") {
                Task { await ModelActions.bulk(ids, ["restore": .bool(true)], message: "Restored \(n)", state: state) }
            }
        } else {
            Menu("Open in Slicer") {
                ForEach(Slicer.installed) { s in
                    Button(s.name) { Task { await ModelActions.openInSlicer(ids, slicer: s, state: state) } }
                }
                if Slicer.installed.isEmpty { Text("No slicers installed") }
            }
            Button("Download…") { Task { await ModelActions.download(ids, state: state) } }
            Button(ids.allSatisfy(state.pins.isPinned) ? "Remove from This Mac" : "Keep on This Mac") {
                Task { await ModelActions.togglePin(ids, state: state) }
            }
            .disabled(state.offline && !ids.allSatisfy(state.pins.isPinned))
            if !state.offline {
                Divider()
                Menu("Category") {
                    Button("None") { Task { await ModelActions.bulk(ids, ["clear_category": .bool(true)], message: "Cleared category", state: state) } }
                    ForEach(state.categoryTree, id: \.category.id) { item in
                        Button(String(repeating: "    ", count: item.depth) + item.category.name) {
                            Task { await ModelActions.bulk(ids, ["category_id": .number(Double(item.category.id))], message: "Moved \(n) to \(item.category.name)", state: state) }
                        }
                    }
                }
                Menu("Print Status") {
                    ForEach(PrintStatus.allCases) { s in
                        Button(s.label) { Task { await ModelActions.bulk(ids, ["status": .string(s.rawValue)], message: "Marked \(n) as \(s.label)", state: state) } }
                    }
                    Divider()
                    Button("Clear") { Task { await ModelActions.bulk(ids, ["status": .string("")], message: "Cleared status", state: state) } }
                }
                Menu("Add to Collection") {
                    ForEach(state.collections.filter { !$0.isSmart }) { c in
                        Button(c.name) { Task { await ModelActions.bulk(ids, ["add_to_collection": .number(Double(c.id))], message: "Added to \(c.name)", state: state) } }
                    }
                    Divider()
                    Button("New Collection…") { state.newCollection(adding: ids) }
                }
                Button("Favourite") { Task { await ModelActions.bulk(ids, ["favourite": .bool(true)], message: "Favourited \(n)", state: state) } }
                Button("Mark as Triaged") { Task { await ModelActions.bulk(ids, ["untriaged": .bool(false)], message: "Marked \(n) as triaged", state: state) } }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    Task { await ModelActions.bulk(ids, ["delete": .bool(true)], message: "Moved \(n) to trash", state: state); selection = [] }
                }
            }
        }
    }
}

struct ModelCell: View {
    @Environment(AppState.self) private var state
    let model: ModelSummary
    let selected: Bool
    let pinned: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Square slot first, then the image inside it, so photo covers filling the slot can't widen the card.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Thumbnail(fileId: model.coverFileId, fill: !model.coverHasPreview) }
                    .background(
                        RadialGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.02)], center: .center, startRadius: 5, endRadius: 200)
                    )
                    .clipped()
                    .overlay {
                        if hovering, let pid = model.previewFileId {
                            MeshPreview(fileId: pid, lod: true, interactive: false, spin: true)
                                .background(.background)
                                .transition(.opacity)
                        }
                    }
                HStack(spacing: 4) {
                    if model.untriaged && model.deletedAt == nil { Badge(text: "New", color: .orange) }
                    if pinned { Badge(system: "pin.fill", color: .blue) }
                    Spacer()
                    if model.me.favourite { Badge(system: "heart.fill", color: .pink) }
                    if model.flagCount > 0 { Badge(system: "flag.fill", color: .red) }
                    if let s = model.me.status { Badge(text: s.label, color: s == .printed ? .green : s == .failed ? .red : .gray) }
                }
                .padding(6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.callout.weight(.semibold)).lineLimit(1)
                HStack {
                    Text(model.partCount == 0 ? "No mesh" : "\(model.partCount) part\(model.partCount == 1 ? "" : "s")")
                    if let d = model.dimensions { Text(d).lineLimit(1) }
                    Spacer()
                    if let r = model.me.rating, r > 0 { Text("★\(r)").foregroundStyle(.yellow) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { h in
            // Small delay so sweeping the mouse across the grid doesn't load every mesh.
            if h {
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if !Task.isCancelled { withAnimation(.easeIn(duration: 0.15)) { hovering = isStillHovering } }
                }
            } else {
                hovering = false
            }
            isStillHovering = h
        }
    }

    @State private var isStillHovering = false
}

struct Badge: View {
    var text: String?
    var system: String?
    var color: Color

    var body: some View {
        Group {
            if let system { Image(systemName: system) } else { Text(text ?? "") }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(color.opacity(0.85), in: Capsule())
    }
}

struct Thumbnail: View {
    @Environment(AppState.self) private var state
    let fileId: Int?
    var fill = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else if fileId == nil {
                Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.tertiary)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: fileId) {
            guard let fileId else { image = nil; return }
            image = state.thumbnails.cached(fileId)
            if image == nil { image = await state.thumbnails.image(fileId) }
        }
    }
}
