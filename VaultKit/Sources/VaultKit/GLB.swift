import Foundation
import SceneKit
import simd

/// Minimal glTF-binary reader for the server's preview meshes: positions and
/// triangle indices only, with node transforms applied. No textures or materials.
public struct GLBMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var indices: [UInt32]

    public enum ParseError: Error { case notGLB, missingChunk, badAccessor(String) }

    public init(data: Data) throws {
        guard data.count >= 20, data.readU32(0) == 0x4654_6C67 else { throw ParseError.notGLB } // "glTF"
        var offset = 12
        var json: [String: Any]?
        var bin: Data?
        while offset + 8 <= data.count {
            let length = Int(data.readU32(offset))
            let type = data.readU32(offset + 4)
            let chunk = data.subdata(in: (offset + 8)..<min(offset + 8 + length, data.count))
            if type == 0x4E4F_534A { json = try JSONSerialization.jsonObject(with: chunk) as? [String: Any] } // JSON
            if type == 0x004E_4942 { bin = chunk } // BIN
            offset += 8 + length
        }
        guard let json, let bin else { throw ParseError.missingChunk }
        let gltf = GLTF(json: json, bin: bin)

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func visit(_ nodeIndex: Int, _ parent: simd_float4x4) throws {
            guard let node = gltf.nodes[safe: nodeIndex] else { return }
            let m = parent * GLTF.matrix(of: node)
            if let meshIndex = node["mesh"] as? Int, let mesh = gltf.meshes[safe: meshIndex] {
                for prim in mesh["primitives"] as? [[String: Any]] ?? [] {
                    guard let attrs = prim["attributes"] as? [String: Any], let posAcc = attrs["POSITION"] as? Int else { continue }
                    let base = UInt32(positions.count)
                    let pos = try gltf.floats3(posAcc)
                    positions.append(contentsOf: pos.map { p in
                        let v = m * SIMD4<Float>(p, 1)
                        return SIMD3<Float>(v.x, v.y, v.z)
                    })
                    if let idxAcc = prim["indices"] as? Int {
                        indices.append(contentsOf: try gltf.indices(idxAcc).map { $0 + base })
                    } else {
                        indices.append(contentsOf: (0..<UInt32(pos.count)).map { $0 + base })
                    }
                }
            }
            for child in node["children"] as? [Int] ?? [] { try visit(child, m) }
        }
        let sceneIndex = json["scene"] as? Int ?? 0
        let roots = (gltf.scenes[safe: sceneIndex]?["nodes"] as? [Int]) ?? Array(gltf.nodes.indices)
        for r in roots { try visit(r, matrix_identity_float4x4) }
        self.positions = positions
        self.indices = indices
    }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// Flat-shaded SceneKit geometry. Vertices are split per triangle for crisp edges.
    public func geometry() -> SCNGeometry {
        let triCount = indices.count / 3
        var verts = [SIMD3<Float>](repeating: .zero, count: triCount * 3)
        var normals = [SIMD3<Float>](repeating: .zero, count: triCount * 3)
        for t in 0..<triCount {
            let a = positions[Int(indices[t * 3])], b = positions[Int(indices[t * 3 + 1])], c = positions[Int(indices[t * 3 + 2])]
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : SIMD3(0, 0, 1)
            verts[t * 3] = a; verts[t * 3 + 1] = b; verts[t * 3 + 2] = c
            normals[t * 3] = n; normals[t * 3 + 1] = n; normals[t * 3 + 2] = n
        }
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let vData = verts.withUnsafeBytes { Data($0) }
        let nData = normals.withUnsafeBytes { Data($0) }
        let vSource = SCNGeometrySource(data: vData, semantic: .vertex, vectorCount: verts.count, usesFloatComponents: true,
                                        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let nSource = SCNGeometrySource(data: nData, semantic: .normal, vectorCount: normals.count, usesFloatComponents: true,
                                        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let element = SCNGeometryElement(indices: Array(0..<UInt32(verts.count)), primitiveType: .triangles)
        return SCNGeometry(sources: [vSource, nSource], elements: [element])
    }
}

private struct GLTF {
    let nodes: [[String: Any]]
    let meshes: [[String: Any]]
    let scenes: [[String: Any]]
    let accessors: [[String: Any]]
    let views: [[String: Any]]
    let bin: Data

    init(json: [String: Any], bin: Data) {
        nodes = json["nodes"] as? [[String: Any]] ?? []
        meshes = json["meshes"] as? [[String: Any]] ?? []
        scenes = json["scenes"] as? [[String: Any]] ?? []
        accessors = json["accessors"] as? [[String: Any]] ?? []
        views = json["bufferViews"] as? [[String: Any]] ?? []
        self.bin = bin
    }

    static func matrix(of node: [String: Any]) -> simd_float4x4 {
        if let m = node["matrix"] as? [Double], m.count == 16 {
            let f = m.map(Float.init)
            return simd_float4x4(columns: (
                SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
        }
        var m = matrix_identity_float4x4
        if let s = node["scale"] as? [Double], s.count == 3 {
            m = simd_float4x4(diagonal: SIMD4(Float(s[0]), Float(s[1]), Float(s[2]), 1))
        }
        if let r = node["rotation"] as? [Double], r.count == 4 {
            m = simd_float4x4(simd_quatf(ix: Float(r[0]), iy: Float(r[1]), iz: Float(r[2]), r: Float(r[3]))) * m
        }
        if let t = node["translation"] as? [Double], t.count == 3 {
            var tm = matrix_identity_float4x4
            tm.columns.3 = SIMD4(Float(t[0]), Float(t[1]), Float(t[2]), 1)
            m = tm * m
        }
        return m
    }

    private func slice(_ accessor: Int) throws -> (Data, Int, Int, Int) {
        guard let acc = accessors[safe: accessor], let viewIndex = acc["bufferView"] as? Int, let view = views[safe: viewIndex],
              let count = acc["count"] as? Int, let componentType = acc["componentType"] as? Int
        else { throw GLBMesh.ParseError.badAccessor("accessor \(accessor)") }
        let start = (view["byteOffset"] as? Int ?? 0) + (acc["byteOffset"] as? Int ?? 0)
        let stride = view["byteStride"] as? Int ?? 0
        return (bin, start, count, componentType * 1000 + stride)
    }

    func floats3(_ accessor: Int) throws -> [SIMD3<Float>] {
        let (data, start, count, packed) = try slice(accessor)
        guard packed / 1000 == 5126 else { throw GLBMesh.ParseError.badAccessor("POSITION must be float") }
        let stride = packed % 1000 == 0 ? 12 : packed % 1000
        guard start + stride * (count - 1) + 12 <= data.count else { throw GLBMesh.ParseError.badAccessor("out of range") }
        return data.withUnsafeBytes { raw in
            (0..<count).map { i in
                let o = start + i * stride
                return SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                             raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                             raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
            }
        }
    }

    func indices(_ accessor: Int) throws -> [UInt32] {
        let (data, start, count, packed) = try slice(accessor)
        let type = packed / 1000
        let size = type == 5125 ? 4 : type == 5123 ? 2 : type == 5121 ? 1 : 0
        guard size > 0, start + size * count <= data.count else { throw GLBMesh.ParseError.badAccessor("indices") }
        return data.withUnsafeBytes { raw in
            (0..<count).map { i in
                let o = start + i * size
                switch size {
                case 4: return raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                case 2: return UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                default: return UInt32(raw.load(fromByteOffset: o, as: UInt8.self))
                }
            }
        }
    }
}

extension Data {
    func readU32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
