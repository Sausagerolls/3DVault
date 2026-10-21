import PhotosUI
import SwiftUI
import VaultKit

struct ModelDetailView: View {
    @Environment(AppState.self) private var state
    let modelId: Int
    let library: LibraryModel
    @State private var model: ModelDetail?
    @State private var error: String?
    @State private var viewFile: Int?
    @State private var wireframe = false
    @State private var fullScreen = false
    @State private var notes = ""
    @State private var showFlag = false
    @State private var addingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @FocusState private var notesFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var readOnly: Bool { state.offline }

    var body: some View {
        Group {
            if let m = model {
                content(m)
            } else if let error {
                ContentUnavailableView("Couldn't Load Model", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
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
            if !notesFocused { notes = m.printNotes }
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
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                state.report(error)
            }
        }
    }

    private func shownFile(_ m: ModelDetail) -> VaultFile? {
        m.files.first { $0.id == viewFile } ?? m.files.first { $0.id == m.previewFileId } ?? m.files.first { $0.hasPreview } ?? m.files.first { $0.hasThumb }
    }

    @ViewBuilder
    private func content(_ m: ModelDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                viewer(shownFile(m), height: 340)
                header(m)
                actions(m)
                if !readOnly { statusBox(m) }
                photosBox(m)
                filesBox(m)
                detailsBox(m)
                notesBox(m)
                flagsBox(m)
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(m.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { setMe(favourite: !m.me.favourite) } label: {
                    Label("Favourite", systemImage: m.me.favourite ? "heart.fill" : "heart")
                }
                .tint(m.me.favourite ? .pink : nil)
                .disabled(readOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ModelMenu(ids: [m.id], trashed: m.deletedAt != nil)
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        .fullScreenCover(isPresented: $fullScreen) { fullScreenViewer(m) }
        .fileImporter(isPresented: $addingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let dir = SharedConfig.stagingFolder()
            let copies = urls.compactMap { url -> URL? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let dest = dir.appending(path: url.lastPathComponent)
                return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
            }
            upload(copies, photos: false)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let dir = SharedConfig.stagingFolder()
                var urls: [URL] = []
                for (i, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        let url = dir.appending(path: "print-photo-\(Self.stamp())-\(i + 1).\(ext)")
                        try? data.write(to: url)
                        urls.append(url)
                    }
                }
                photoItems = []
                upload(urls, photos: true)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                let url = SharedConfig.stagingFolder().appending(path: "print-photo-\(Self.stamp()).jpg")
                if let data = image.jpegData(compressionQuality: 0.85), (try? data.write(to: url)) != nil {
                    upload([url], photos: true)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFlag) {
            FlagSheet(modelId: m.id) { Task { await load(); state.changed() } }
        }
    }

    /// Keeps photo file names unique within a model.
    private static func stamp() -> String {
        Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.dash))
    }

    private func upload(_ urls: [URL], photos: Bool) {
        guard !urls.isEmpty, let client = state.client else { return }
        Task {
            state.preparing = photos ? "Adding photo…" : "Uploading \(urls.count) file\(urls.count == 1 ? "" : "s")…"
            defer { state.preparing = nil }
            do {
                apply(try await client.addFiles(to: modelId, files: urls, asPhotos: photos))
                state.changed()
                state.show(photos ? "Photo added" : "Files added")
            } catch {
                state.report(error)
            }
        }
    }

    // MARK: viewer

    private func viewer(_ file: VaultFile?, height: CGFloat?) -> some View {
        ZStack(alignment: .topTrailing) {
            if let file, file.hasPreview {
                MeshView(fileId: file.id, wireframe: wireframe)
                    .id(file.id)
                HStack(spacing: 8) {
                    Button { wireframe.toggle() } label: {
                        Image(systemName: wireframe ? "cube.fill" : "squareshape.split.3x3")
                    }
                    .accessibilityLabel("Wireframe")
                    if height != nil {
                        Button { fullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .accessibilityLabel("Full Screen")
                    }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(10)
            } else if let file, file.hasThumb {
                Thumbnail(fileId: file.id)
            } else {
                Image(systemName: "cube.transparent").font(.system(size: 48)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .background(RadialGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.02)], center: .center, startRadius: 10, endRadius: 320))
        .clipShape(RoundedRectangle(cornerRadius: height == nil ? 0 : 20))
        .overlay(alignment: .bottomLeading) {
            if let file, let d = formatDims(file.sizeX, file.sizeY, file.sizeZ) {
                Text("\(d)\(file.triCount.map { " · \($0.formatted()) triangles" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
    }

    private func fullScreenViewer(_ m: ModelDetail) -> some View {
        NavigationStack {
            viewer(shownFile(m), height: nil)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(m.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { fullScreen = false }
                    }
                }
        }
        .environment(state)
    }

    // MARK: sections

    private func header(_ m: ModelDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !m.categoryPath.isEmpty {
                Text(m.categoryPath.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
            }
            if readOnly {
                Text(m.name).font(.title2.bold())
            } else {
                TextField("Name", text: Binding(get: { model?.name ?? m.name }, set: { model?.name = $0 }), axis: .vertical)
                    .font(.title2.bold())
                    .submitLabel(.done)
                    .onSubmit { patch(["name": .string(model?.name ?? m.name)]) }
            }
            if m.untriaged && !readOnly {
                HStack {
                    Text("New: pick a category to file it.").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Mark Triaged") { patch(["untriaged": .bool(false)]) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func actions(_ m: ModelDetail) -> some View {
        let pinned = state.pins.isPinned(m.id)
        return HStack(spacing: 10) {
            Button { Task { await ModelActions.share([m.id], state: state) } } label: {
                Label("Share", systemImage: "square.and.arrow.up").lineLimit(1).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            Button { Task { await ModelActions.share([m.id], airDrop: true, state: state) } } label: {
                Label(sizeClass == .compact ? "To Mac" : "Send to Mac", systemImage: "laptopcomputer.and.arrow.down").lineLimit(1).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            Button { Task { await ModelActions.togglePin([m.id], state: state) } } label: {
                if state.pins.downloading.contains(m.id) {
                    ProgressView()
                } else {
                    Image(systemName: pinned ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
            }
            .buttonStyle(.glass)
            .accessibilityLabel(pinned ? "Remove offline copy" : "Keep offline")
            .disabled(readOnly && !pinned)
        }
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
    }

    private func statusBox(_ m: ModelDetail) -> some View {
        Box("My print status") {
            let picker = Picker("Status", selection: Binding(get: { m.me.status?.rawValue ?? "" }, set: { setMe(status: $0) })) {
                Text("None").tag("")
                ForEach(PrintStatus.allCases) { Text($0.label).tag($0.rawValue) }
            }
            // Five segments don't fit a phone's width.
            if sizeClass == .compact {
                LabeledContent("Status") { picker.pickerStyle(.menu) }
            } else {
                picker.pickerStyle(.segmented)
            }
            HStack {
                Text("My rating").foregroundStyle(.secondary)
                Spacer()
                ForEach(1...5, id: \.self) { n in
                    Button { setMe(rating: m.me.rating == n ? 0 : n) } label: {
                        Image(systemName: (m.me.rating ?? 0) >= n ? "star.fill" : "star").foregroundStyle(.yellow).font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
                }
            }
        }
    }

    @ViewBuilder
    private func photosBox(_ m: ModelDetail) -> some View {
        let photos = m.files.filter { $0.kind == "photo" && $0.hasThumb }
        if !photos.isEmpty || !readOnly {
            Box("Print photos") {
                if !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photos) { f in
                                Thumbnail(fileId: f.id, fill: true)
                                    .frame(width: 110, height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .contextMenu {
                                        Button { Task { await ModelActions.shareFile(f, modelId: m.id, state: state) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                                        if !readOnly {
                                            Button { patch(["cover_file_id": .number(Double(f.id))]) } label: { Label("Use as Cover", systemImage: "photo") }
                                        }
                                    }
                            }
                        }
                    }
                }
                if !readOnly {
                    HStack {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                            Label("Add from Photos", systemImage: "photo.on.rectangle")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func filesBox(_ m: ModelDetail) -> some View {
        Box("Files (\(m.files.filter { $0.kind != "photo" }.count))") {
            ForEach(m.files.filter { $0.kind != "photo" }) { f in
                HStack(spacing: 10) {
                    Group {
                        if f.hasThumb { Thumbnail(fileId: f.id) } else {
                            Text(f.ext.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.relPath).lineLimit(1).truncationMode(.middle).font(.subheadline)
                        HStack(spacing: 6) {
                            Text(formatBytes(f.size))
                            if let t = f.meta["print_time"] { Text(t.description) }
                            if let g = f.meta["filament_g"] { Text("\(g.description) g") }
                            if f.meta["slicer_project"] == .bool(true) { Text("slicer project") }
                            if f.status == "pending" { Text("processing…") }
                            if f.status == "error" { Text("error").foregroundStyle(.red) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if f.id == shownFile(m)?.id && (f.hasPreview || f.hasThumb) {
                        Image(systemName: "eye").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if f.hasThumb || f.hasPreview { viewFile = f.id } }
                .contextMenu {
                    if f.hasPreview || f.hasThumb {
                        Button { viewFile = f.id } label: { Label("View", systemImage: "eye") }
                    }
                    Button { Task { await ModelActions.shareFile(f, modelId: m.id, state: state) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    Button { Task { await ModelActions.shareFile(f, modelId: m.id, airDrop: true, state: state) } } label: { Label("Send to Mac", systemImage: "laptopcomputer.and.arrow.down") }
                    if f.hasThumb && !readOnly {
                        Button { patch(["cover_file_id": .number(Double(f.id))]) } label: { Label("Use as Cover", systemImage: "photo") }
                    }
                }
            }
            if !readOnly {
                Button { addingFiles = true } label: { Label("Add Files…", systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Tap a file to view it. Touch and hold to share it.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func detailsBox(_ m: ModelDetail) -> some View {
        Box("Details") {
            if !readOnly {
                LabeledContent("Category") {
                    Picker("Category", selection: Binding(get: { m.categoryId ?? -1 }, set: { id in
                        patch(id == -1 ? ["clear_category": .bool(true)] : ["category_id": .number(Double(id))])
                    })) {
                        CategoryOptions()
                    }
                    .labelsHidden()
                }
                TagEditor(tags: m.tags) { patch(["tags": .array($0.map(JSONValue.string))]) }
            } else if !m.tags.isEmpty {
                Text(m.tags.map { "#\($0)" }.joined(separator: "  ")).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
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
            TextField("Settings that worked, supports, filament…", text: $notes, axis: .vertical)
                .lineLimit(3...12)
                .focused($notesFocused)
                .disabled(readOnly)
            if notes != m.printNotes && !readOnly {
                HStack {
                    Spacer()
                    Button("Revert") { notes = m.printNotes; notesFocused = false }
                    Button("Save Notes") {
                        patch(["print_notes": .string(notes)])
                        notesFocused = false
                    }
                    .buttonStyle(.borderedProminent)
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
                    Text(f.kind.label).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .opacity(f.resolved ? 0.5 : 1)
            }
            if !readOnly {
                Button { showFlag = true } label: { Label("Flag a Problem…", systemImage: "flag") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

private struct FlagSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let modelId: Int
    let done: () -> Void
    @State private var kind: FlagKind = .brokenMesh
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Problem", selection: $kind) { ForEach(FlagKind.allCases) { Text($0.label).tag($0) } }
                TextField("What's wrong?", text: $note, axis: .vertical).lineLimit(2...6)
            }
            .navigationTitle("Flag a Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                try await state.client?.addFlag(modelId, kind: kind, note: note)
                                done()
                                dismiss()
                            } catch {
                                state.report(error)
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct TagEditor: View {
    @Environment(AppState.self) private var state
    let tags: [String]
    let onChange: ([String]) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout {
                    ForEach(tags, id: \.self) { t in
                        Button { onChange(tags.filter { $0 != t }) } label: {
                            HStack(spacing: 4) {
                                Text(t)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(t)")
                    }
                }
            }
            TextField("Add tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
                    if !t.isEmpty && !tags.contains(t) { onChange(tags + [t]) }
                    text = ""
                }
            let matches = state.tags.filter { !text.isEmpty && $0.name.contains(text.lowercased()) && !tags.contains($0.name) }.prefix(8)
            if !matches.isEmpty {
                FlowLayout {
                    ForEach(matches) { t in
                        Button(t.name) {
                            onChange(tags + [t.name])
                            text = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Camera capture for print photos.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let picked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.picked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
