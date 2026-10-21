import SceneKit
import SwiftUI
import VaultKit

/// SceneKit view of a server preview mesh.
struct MeshView: UIViewRepresentable {
    @Environment(AppState.self) private var state
    let fileId: Int
    var lod = false
    var interactive = true
    var spin = false
    var wireframe = false

    final class Coordinator {
        var loadedId: Int?
        var task: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = interactive
        view.antialiasingMode = .multisampling4X
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.debugOptions = wireframe ? [.renderAsWireframe] : []
        guard context.coordinator.loadedId != fileId else { return }
        context.coordinator.loadedId = fileId
        context.coordinator.task?.cancel()
        let loader = state.thumbnails
        context.coordinator.task = Task { @MainActor in
            guard let mesh = try? await loader.preview(fileId, lod: lod), !Task.isCancelled else { return }
            view.scene = MeshScene.make(mesh, spin: spin)
            view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
        }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }
}

struct Thumbnail: View {
    @Environment(AppState.self) private var state
    let fileId: Int?
    var fill = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
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

struct Badge: View {
    var text: String?
    var system: String?
    var color: Color

    var body: some View {
        Group {
            if let system { Image(systemName: system) } else { Text(text ?? "") }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(color.opacity(0.85), in: Capsule())
    }
}

/// UIActivityViewController for files. With `airDrop`, other share targets Apple lets us hide are
/// hidden so AirDrop is the obvious choice.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    var airDrop = false

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if airDrop {
            vc.excludedActivityTypes = [
                .addToReadingList, .assignToContact, .copyToPasteboard, .mail, .message, .openInIBooks,
                .postToFacebook, .postToFlickr, .postToTencentWeibo, .postToTwitter, .postToVimeo, .postToWeibo,
                .print, .saveToCameraRoll, .markupAsPDF, .sharePlay, .collaborationCopyLink, .collaborationInviteWithLink,
            ]
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Section card used on the detail and selection screens.
struct Box<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

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

/// Category picker rows indented by depth.
struct CategoryOptions: View {
    @Environment(AppState.self) private var state
    var noneLabel = "None"

    var body: some View {
        Text(noneLabel).tag(-1)
        ForEach(state.categoryTree, id: \.category.id) { item in
            Text(String(repeating: "    ", count: item.depth) + item.category.name).tag(item.category.id)
        }
    }
}
