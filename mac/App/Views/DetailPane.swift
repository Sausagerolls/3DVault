import SwiftUI
import VaultKit

struct DetailPane: View {
    let selection: Set<Int>
    let library: LibraryModel
    let trashed: Bool

    var body: some View {
        if selection.count == 1, let id = selection.first {
            ModelDetailView(modelId: id, library: library).id(id)
        } else if selection.count > 1 {
            BulkPanel(ids: Array(selection), trashed: trashed)
        } else {
            ContentUnavailableView("No Selection", systemImage: "cube", description: Text("Select a model to see it in 3D.\nCmd-click or Shift-click to select several."))
        }
    }
}

// MARK: - single model

struct ModelDetailView: View {
    @Environment(AppState.self) private var state
    let modelId: Int
    let library: LibraryModel
    @State private var model: ModelDetail?
    @State private var error: String?
    @State private var viewFile: Int?
    @State private var wireframe = false
    @State private var notes = ""
    @State private var newTag = ""
    @State private var flagKind: FlagKind = .brokenMesh
    @State private var flagNote = ""
    @State private var showFlag = false

    private var readOnly: Bool { state.offline }

    var body: some View {
        Group {
            if let m = model {
                content(m)
            } else if let error {
                ContentUnavailableView("Couldn't load model", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .task(id: model?.files.contains { $0.status == "pending" }) {
            // Poll while the server is still generating previews.
            while model?.files.contains(where: { $0.status == "pending" }) == true, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
    }

    private func load() async {
        do {
            let m = try await ModelActions.detail(modelId, state: state)
            model = m
            notes = m.printNotes
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ m: ModelDetail) {
        model = m
        library.update(m.summary)
    }

    private func patch(_ body: [String: JSONValue]) {
        Task {
            do {
                guard let m = try await state.client?.patchModel(modelId, body) else { return }
                apply(m)
                state.changed()
            } catch {
                state.report(error)
            }
        }
    }

    private func setMe(favourite: Bool? = nil, rating: Int? = nil, status: String? = nil) {
        Task {
            do {
                guard let me = try await state.client?.setMyState(modelId, favourite: favourite, rating: rating, status: status), var m = model else { return }
                m.me = me
                apply(m)
            } catch {
                state.report(error)
            }
        }
    }

    @ViewBuilder
    private func content(_ m: ModelDetail) -> some View {
        let shown = m.files.first { $0.id == viewFile } ?? m.files.first { $0.id == m.previewFileId } ?? m.files.first { $0.hasPreview } ?? m.files.first { $0.hasThumb }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                viewer(shown)
                header(m)
                actions(m)
                if !readOnly { statusBox(m) }
                filesBox(m)
                detailsBox(m)
                notesBox(m)
                flagsBox(m)
            }
            .padding(16)
        }
    }

    private func viewer(_ file: VaultFile?) -> some View {
        ZStack(alignment: .topTrailing) {
            if let file, file.hasPreview {
                MeshPreview(fileId: file.id, wireframe: wireframe)
                    .id(file.id)
                Toggle(isOn: $wireframe) { Image(systemName: "squareshape.split.3x3") }
                    .toggleStyle(.button)
                    .padding(8)
                    .help("Wireframe")
            } else if let file, file.hasThumb {
                Thumbnail(fileId: file.id)
            } else {
                Image(systemName: "cube.transparent").font(.system(size: 48)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 300)
        .background(RadialGradient(colors: [Color.primary.opacity(0.07), Color.primary.opacity(0.02)], center: .center, startRadius: 10, endRadius: 300))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if let file, let d = formatDims(file.sizeX, file.sizeY, file.sizeZ) {
                Text("\(d)\(file.triCount.map { " · \($0.formatted()) triangles" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    private func header(_ m: ModelDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !m.categoryPath.isEmpty {
                Text(m.categoryPath.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                if readOnly {
                    Text(m.name).font(.title2.bold())
                } else {
                    TextField("Name", text: Binding(get: { m.name }, set: { model?.name = $0 }))
                        .font(.title2.bold())
                        .textFieldStyle(.plain)
                        .onSubmit { patch(["name": .string(model?.name ?? m.name)]) }
                }
                Spacer()
                Button { setMe(favourite: !m.me.favourite) } label: {
                    Image(systemName: m.me.favourite ? "heart.fill" : "heart").foregroundStyle(m.me.favourite ? .pink : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(readOnly)
            }
            if m.untriaged && !readOnly {
                HStack {
                    Text("New: pick a category to file it.").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Mark Triaged") { patch(["untriaged": .bool(false)]) }.controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func actions(_ m: ModelDetail) -> some View {
        HStack {
            if let preferred = Slicer.preferred {
                Button {
                    Task { await ModelActions.openInSlicer([m.id], slicer: preferred, state: state) }
                } label: {
                    Label("Open in \(preferred.name)", systemImage: "printer")
                }
                .buttonStyle(.borderedProminent)
                Menu {
                    ForEach(Slicer.installed) { s in
                        Button(s.name) { Task { await ModelActions.openInSlicer([m.id], slicer: s, state: state) } }
                    }
                } label: { EmptyView() }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button { Task { await ModelActions.download([m.id], state: state) } } label: { Label("Download", systemImage: "arrow.down.circle") }
            Spacer()
            let pinned = state.pins.isPinned(m.id)
            Button { Task { await ModelActions.togglePin([m.id], state: state) } } label: {
                if state.pins.downloading.contains(m.id) { ProgressView().controlSize(.small) } else {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
            }
            .help(pinned ? "Remove from this Mac" : "Keep on this Mac for offline use")
            .disabled(readOnly && !pinned)
            if pinned {
                Button { NSWorkspace.shared.open(state.pins.folder(m.id)) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
        }
    }

    private func statusBox(_ m: ModelDetail) -> some View {
        Box("My print status") {
            Picker("Status", selection: Binding(get: { m.me.status?.rawValue ?? "" }, set: { setMe(status: $0) })) {
                Text("None").tag("")
                ForEach(PrintStatus.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 2) {
                Text("My rating").foregroundStyle(.secondary)
                Spacer()
                ForEach(1...5, id: \.self) { n in
                    Button { setMe(rating: m.me.rating == n ? 0 : n) } label: {
                        Image(systemName: (m.me.rating ?? 0) >= n ? "star.fill" : "star").foregroundStyle(.yellow)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func filesBox(_ m: ModelDetail) -> some View {
        Box("Files (\(m.files.count))") {
            ForEach(m.files) { f in
                HStack(spacing: 8) {
                    Group {
                        if f.hasThumb { Thumbnail(fileId: f.id) } else {
                            Text(f.ext.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.relPath).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(formatBytes(f.size))
                            if let t = f.meta["print_time"] { Text(t.description) }
                            if let g = f.meta["filament_g"] { Text("\(g.description) g") }
                            if f.meta["slicer_project"] == .bool(true) { Text("slicer project") }
                            if f.status == "pending" { Text("processing…") }
                            if f.status == "error" { Text("error").foregroundStyle(.red).help(f.error) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if f.isSliceable, let s = Slicer.preferred {
                        Button { Task { await ModelActions.openFile(f, modelId: m.id, slicer: s, state: state) } } label: { Image(systemName: "printer") }
                            .buttonStyle(.borderless)
                            .help("Open in \(s.name)")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if f.hasThumb || f.hasPreview { viewFile = f.id } }
                .onDrag { state.files.dragProvider(f, modelId: m.id) }
                .contextMenu {
                    Button("Open") { Task { await ModelActions.openFile(f, modelId: m.id, state: state) } }
                    ForEach(Slicer.installed) { s in
                        Button("Open in \(s.name)") { Task { await ModelActions.openFile(f, modelId: m.id, slicer: s, state: state) } }
                    }
                    if f.hasThumb && !readOnly {
                        Button("Use as Cover") { patch(["cover_file_id": .number(Double(f.id))]) }
                    }
                    if !readOnly && state.canDeleteFiles(m) {
                        Divider()
                        Button("Delete…", role: .destructive) { state.deleteFile(f) { await load() } }
                    }
                }
            }
            if !readOnly {
                HStack {
                    Button("Add Files…") { addFiles(m, photos: false) }
                    Button("Add Print Photo…") { addFiles(m, photos: true) }
                }
                .controlSize(.small)
            }
            Text("Drag a file out to Finder or a slicer.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func addFiles(_ m: ModelDetail, photos: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if photos { panel.allowedContentTypes = [.image] }
        guard panel.runModal() == .OK, let client = state.client else { return }
        Task {
            do {
                apply(try await client.addFiles(to: m.id, files: panel.urls, asPhotos: photos))
                state.changed()
            } catch {
                state.report(error)
            }
        }
    }

    private func detailsBox(_ m: ModelDetail) -> some View {
        Box("Details") {
            if !readOnly {
                Picker("Category", selection: Binding(get: { m.categoryId ?? -1 }, set: { id in
                    patch(id == -1 ? ["clear_category": .bool(true)] : ["category_id": .number(Double(id))])
                })) {
                    Text("None").tag(-1)
                    ForEach(state.categoryTree, id: \.category.id) { item in
                        Text(String(repeating: "   ", count: item.depth) + item.category.name).tag(item.category.id)
                    }
                }
                TagEditor(tags: m.tags) { patch(["tags": .array($0.map(JSONValue.string))]) }
            } else if !m.tags.isEmpty {
                Text(m.tags.map { "#\($0)" }.joined(separator: "  ")).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if !m.sourceUrl.isEmpty, let url = URL(string: m.sourceUrl) {
                    row("Source") { Link(url.host() ?? m.sourceUrl, destination: url) }
                }
                if !m.author.isEmpty { row("Author") { Text(m.author) } }
                if !m.license.isEmpty { row("License") { Text(m.license) } }
                row("Largest part") { Text(m.dimensions ?? "—") }
                row("Parts") { Text("\(m.partCount) · \(m.triCount.formatted()) triangles") }
                row("Fits") { Text(fits(m)) }
                row("Added") {
                    Text("\(m.createdAt.formatted(date: .abbreviated, time: .omitted))\(m.uploader.map { " by \($0.displayName)" } ?? "")")
                }
            }
            .font(.callout)
            if !m.description.isEmpty {
                Text(m.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }

    private func fits(_ m: ModelDetail) -> String {
        guard let x = m.sizeX, let y = m.sizeY, let z = m.sizeZ else { return "—" }
        let dims = [x, y, z].sorted(by: >)
        let names = state.printers.filter { p in
            let bed = [p.x, p.y, p.z].sorted(by: >)
            return zip(dims, bed).allSatisfy { $0 <= $1 }
        }.map(\.name)
        return names.isEmpty ? "No saved printer" : names.joined(separator: ", ")
    }

    private func notesBox(_ m: ModelDetail) -> some View {
        Box("Print notes") {
            TextEditor(text: $notes)
                .font(.callout)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .disabled(readOnly)
            if notes != m.printNotes && !readOnly {
                HStack {
                    Spacer()
                    Button("Revert") { notes = m.printNotes }
                    Button("Save Notes") { patch(["print_notes": .string(notes)]) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
    }

    private func flagsBox(_ m: ModelDetail) -> some View {
        Box("Problems") {
            if m.flags.isEmpty { Text("No problems reported.").foregroundStyle(.secondary).font(.callout) }
            ForEach(m.flags) { f in
                HStack {
                    Text(f.kind.label).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background((f.resolved ? Color.gray : Color.red).opacity(0.2), in: Capsule())
                    Text(f.note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if !readOnly {
                        Button(f.resolved ? "Reopen" : "Resolve") {
                            Task {
                                try? await state.client?.resolveFlag(f.id, resolved: !f.resolved)
                                await load()
                                state.changed()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .opacity(f.resolved ? 0.5 : 1)
            }
            if !readOnly {
                Button("Flag a Problem…") { showFlag = true }
                    .controlSize(.small)
                    .popover(isPresented: $showFlag) {
                        VStack(alignment: .leading) {
                            Picker("Problem", selection: $flagKind) { ForEach(FlagKind.allCases) { Text($0.label).tag($0) } }
                            TextField("What's wrong?", text: $flagNote)
                            Button("Add Flag") {
                                Task {
                                    try? await state.client?.addFlag(m.id, kind: flagKind, note: flagNote)
                                    flagNote = ""
                                    showFlag = false
                                    await load()
                                    state.changed()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                        .frame(width: 280)
                    }
            }
        }
    }
}

struct Box<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TagEditor: View {
    @Environment(AppState.self) private var state
    let tags: [String]
    let onChange: ([String]) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { t in
                    HStack(spacing: 2) {
                        Text(t)
                        Button { onChange(tags.filter { $0 != t }) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                }
            }
            TextField("Add tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
                    if !t.isEmpty && !tags.contains(t) { onChange(tags + [t]) }
                    text = ""
                }
            let matches = state.tags.filter { !text.isEmpty && $0.name.contains(text.lowercased()) && !tags.contains($0.name) }.prefix(8)
            if !matches.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(matches) { t in
                        Button(t.name) {
                            onChange(tags + [t.name])
                            text = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }
}

/// Simple wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - several models

struct BulkPanel: View {
    @Environment(AppState.self) private var state
    let ids: [Int]
    let trashed: Bool
    @State private var addTags = ""
    @State private var removeTags = ""

    var body: some View {
        let n = ids.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(n) models selected").font(.title2.bold())
                if trashed {
                    Button("Restore \(n)") { run(["restore": .bool(true)], "Restored \(n)") }.buttonStyle(.borderedProminent)
                } else {
                    HStack {
                        Button { Task { await ModelActions.openInSlicer(ids, state: state) } } label: { Label("Open in Slicer", systemImage: "printer") }
                            .buttonStyle(.borderedProminent)
                            .disabled(Slicer.preferred == nil)
                        Button { Task { await ModelActions.download(ids, state: state) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                        Button { Task { await ModelActions.togglePin(ids, state: state) } } label: { Label("Keep on Mac", systemImage: "pin") }
                    }
                    if !state.offline {
                        Box("Category") {
                            Menu("Set Category") {
                                Button("None") { run(["clear_category": .bool(true)], "Cleared category") }
                                ForEach(state.categoryTree, id: \.category.id) { item in
                                    Button(String(repeating: "    ", count: item.depth) + item.category.name) {
                                        run(["category_id": .number(Double(item.category.id))], "Moved \(n) to \(item.category.name)")
                                    }
                                }
                            }
                        }
                        Box("Tags") {
                            HStack {
                                TextField("Add tags, comma separated", text: $addTags).textFieldStyle(.roundedBorder)
                                Button("Add") { run(["add_tags": tagList(addTags)], "Tagged \(n)"); addTags = "" }.disabled(addTags.isEmpty)
                            }
                            HStack {
                                TextField("Remove tags", text: $removeTags).textFieldStyle(.roundedBorder)
                                Button("Remove") { run(["remove_tags": tagList(removeTags)], "Updated tags"); removeTags = "" }.disabled(removeTags.isEmpty)
                            }
                        }
                        Box("My print status") {
                            HStack {
                                ForEach(PrintStatus.allCases) { s in
                                    Button(s.label) { run(["status": .string(s.rawValue)], "Marked \(n) as \(s.label)") }
                                }
                            }
                            .controlSize(.small)
                        }
                        Box("More") {
                            HStack {
                                Button("Favourite") { run(["favourite": .bool(true)], "Favourited \(n)") }
                                Button("Mark Triaged") { run(["untriaged": .bool(false)], "Marked \(n) as triaged") }
                                Menu("Add to Collection") {
                                    ForEach(state.collections.filter { !$0.isSmart }) { c in
                                        Button(c.name) { run(["add_to_collection": .number(Double(c.id))], "Added to \(c.name)") }
                                    }
                                    Divider()
                                    Button("New Collection…") { state.newCollection(adding: ids) }
                                }
                                .fixedSize()
                            }
                            Button("Move \(n) to Trash", role: .destructive) { run(["delete": .bool(true)], "Moved \(n) to trash") }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func tagList(_ s: String) -> JSONValue {
        .array(s.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces).lowercased()) }.filter { $0 != .string("") })
    }

    private func run(_ body: [String: JSONValue], _ message: String) {
        Task { await ModelActions.bulk(ids, body, message: message, state: state) }
    }
}
