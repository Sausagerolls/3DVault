import SceneKit
import SwiftUI
import VaultKit

/// SceneKit view of a server preview mesh. Z-up print coordinates, orange flat-shaded material.
struct MeshPreview: NSViewRepresentable {
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

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = interactive
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.scene = SCNScene()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
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

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }
}
