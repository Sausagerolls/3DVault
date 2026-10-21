import SceneKit
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias SCNFloat = Float
#else
import AppKit
typealias PlatformColor = NSColor
typealias SCNFloat = CGFloat
#endif

/// SceneKit scene for a preview mesh: Z-up print coordinates, orange material, bed grid and a framing camera
/// named "camera". Shared by the Mac and iOS apps.
public enum MeshScene {
    public static func make(_ mesh: GLBMesh, spin: Bool) -> SCNScene {
        let scene = SCNScene()
        let geometry = mesh.geometry()
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = PlatformColor(red: 0.94, green: 0.55, blue: 0.23, alpha: 1)
        material.roughness.contents = 0.55
        material.metalness.contents = 0.05
        material.isDoubleSided = true
        geometry.materials = [material]

        let (lo, hi) = mesh.bounds
        let centre = (lo + hi) / 2
        let size = hi - lo
        let radius = max(simd_length(size) / 2, 1)

        // Model sits in a Z-up holder; the holder is rotated so Z points up in SceneKit's Y-up world.
        let model = SCNNode(geometry: geometry)
        model.position = SCNVector3(-centre.x, -centre.y, -lo.z)
        let holder = SCNNode()
        holder.eulerAngles.x = -.pi / 2
        holder.addChildNode(model)
        let turntable = SCNNode()
        turntable.addChildNode(holder)
        if spin { turntable.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 9))) }
        scene.rootNode.addChildNode(turntable)

        // Bed grid under the model.
        let grid = SCNNode(geometry: Self.grid(extent: SCNFloat(max(size.x, size.y) * 1.6), step: Self.gridStep(Double(max(size.x, size.y)))))
        scene.rootNode.addChildNode(grid)

        let camera = SCNCamera()
        camera.fieldOfView = 35
        camera.zNear = Double(radius) / 100
        camera.zFar = Double(radius) * 100
        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = camera
        let dist = radius / Float(sin(35.0 / 2 * .pi / 180)) * 1.05
        let target = SCNVector3(0, size.z / 2, 0)
        let dir = simd_normalize(SIMD3<Float>(0.75, 0.55, 1))
        cam.position = SCNVector3(dir.x * dist, Float(target.y) + dir.y * dist, dir.z * dist)
        cam.look(at: target)
        scene.rootNode.addChildNode(cam)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, -0.5, 0)
        cam.addChildNode(key)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 450
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    static func gridStep(_ extent: Double) -> SCNFloat { extent > 300 ? 50 : extent > 80 ? 10 : 5 }

    static func grid(extent: SCNFloat, step: SCNFloat) -> SCNGeometry {
        let n = max(2, Int((extent / step).rounded(.up)))
        let half = SCNFloat(n) * step / 2
        var verts: [SCNVector3] = []
        for i in 0...n {
            let p = -half + SCNFloat(i) * step
            verts += [SCNVector3(p, 0, -half), SCNVector3(p, 0, half), SCNVector3(-half, 0, p), SCNVector3(half, 0, p)]
        }
        let source = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: (0..<Int32(verts.count)).map { $0 }, primitiveType: .line)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = PlatformColor.gray.withAlphaComponent(0.35)
        geo.materials = [m]
        return geo
    }
}
