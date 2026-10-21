import Foundation

public struct VaultUser: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let username: String
    public let displayName: String
    public let role: String
    public var isAdmin: Bool { role == "admin" }

    public init(id: Int, username: String, displayName: String, role: String) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.role = role
    }
}

public enum PrintStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case toPrint = "to_print", printed, failed, needsRemix = "needs_remix"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .toPrint: "To print"
        case .printed: "Printed"
        case .failed: "Failed"
        case .needsRemix: "Needs remix"
        }
    }
}

public enum FlagKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case brokenMesh = "broken_mesh", missingParts = "missing_parts", badScale = "bad_scale", other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .brokenMesh: "Broken mesh"
        case .missingParts: "Missing parts"
        case .badScale: "Bad scale"
        case .other: "Other problem"
        }
    }
}

public struct MyState: Codable, Hashable, Sendable {
    public var favourite: Bool
    public var rating: Int?
    public var status: PrintStatus?
}

public struct ModelSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let slug: String
    public var name: String
    public var categoryId: Int?
    public var tags: [String]
    public var coverFileId: Int?
    public var coverHasPreview: Bool
    public var previewFileId: Int?
    public var untriaged: Bool
    public var sizeX: Double?
    public var sizeY: Double?
    public var sizeZ: Double?
    public var partCount: Int
    public var triCount: Int
    public var flagCount: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var me: MyState
    public var processing: Bool

    public var dimensions: String? { formatDims(sizeX, sizeY, sizeZ) }
}

extension ModelDetail {
    /// Files to hand to a slicer: a slicer project if there is one, else every mesh.
    public var printableFiles: [VaultFile] {
        let sliceable = files.filter(\.isSliceable)
        if let project = sliceable.first(where: { $0.meta["slicer_project"] == .bool(true) }) { return [project] }
        let meshes = sliceable.filter(\.isMesh)
        return meshes.isEmpty ? Array(sliceable.prefix(1)) : meshes
    }
}

public struct VaultFile: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let relPath: String
    public let kind: String
    public let ext: String
    public let size: Int
    public let sha256: String
    public let sizeX: Double?
    public let sizeY: Double?
    public let sizeZ: Double?
    public let triCount: Int?
    public let meta: [String: JSONValue]
    public let hasThumb: Bool
    public let hasPreview: Bool
    public let status: String
    public let error: String
    public let createdAt: Date

    public var name: String { (relPath as NSString).lastPathComponent }
    public var isMesh: Bool { kind == "mesh" || kind == "cad" }
    /// Files a slicer can open directly.
    public var isSliceable: Bool { ["stl", "3mf", "obj", "step", "stp", "ply", "gcode", "bgcode"].contains(ext) }
}

public struct Flag: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let kind: FlagKind
    public let note: String
    public let userId: Int?
    public let resolved: Bool
    public let createdAt: Date
}

public struct ModelDetail: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let slug: String
    public var name: String
    public var categoryId: Int?
    public var tags: [String]
    public var coverFileId: Int?
    public var previewFileId: Int?
    public var untriaged: Bool
    public var sizeX: Double?
    public var sizeY: Double?
    public var sizeZ: Double?
    public var partCount: Int
    public var triCount: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var me: MyState
    public var description: String
    public var sourceUrl: String
    public var author: String
    public var license: String
    public var printNotes: String
    public var printerIds: [Int]
    public var uploader: VaultUser?
    public var categoryPath: [String]
    public var files: [VaultFile]
    public var flags: [Flag]
    public var collectionIds: [Int]

    public var dimensions: String? { formatDims(sizeX, sizeY, sizeZ) }

    public var summary: ModelSummary {
        ModelSummary(
            id: id, slug: slug, name: name, categoryId: categoryId, tags: tags, coverFileId: coverFileId,
            coverHasPreview: false, previewFileId: previewFileId, untriaged: untriaged, sizeX: sizeX, sizeY: sizeY,
            sizeZ: sizeZ, partCount: partCount, triCount: triCount, flagCount: flags.filter { !$0.resolved }.count,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt, me: me,
            processing: files.contains { $0.status == "pending" })
    }
}

public struct Page<T: Codable & Sendable>: Codable, Sendable {
    public let items: [T]
    public let total: Int
    public let page: Int
    public let pageSize: Int
}

public struct Category: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let parentId: Int?
    public let count: Int
}

public struct Tag: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let count: Int?
}

public struct Printer: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let x: Double
    public let y: Double
    public let z: Double
    public let builtin: Bool
}

public struct VaultCollection: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let kind: String
    public let shared: Bool
    public let ownerId: Int
    public let count: Int?
    public let query: [String: JSONValue]?
    public var isSmart: Bool { kind == "smart" }

    /// The decoder's snake_case conversion also rewrites the query's keys; undo it before sending them back.
    var snakeCaseQuery: [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: (query ?? [:]).map { key, value in
            (key.reduce(into: "") { out, ch in out += ch.isUppercase ? "_" + ch.lowercased() : String(ch) }, value)
        })
    }
}

public struct StagedFile: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let size: Int
    public let sha256: String
    public let kind: String
    public let hint: String
    public let dupModelId: Int?
}

public struct ProposedGroup: Codable, Hashable, Sendable {
    public var name: String
    public var fileIds: [String]
}

public struct UploadBatch: Codable, Sendable {
    public let id: String
    public let files: [StagedFile]
    public let groups: [ProposedGroup]
}

public struct CommitGroup: Codable, Sendable {
    public var name: String
    public var fileIds: [String]
    public var categoryId: Int?
    public var tags: [String]
    public var sourceUrl: String
    public var skipDuplicates: Bool

    public init(name: String, fileIds: [String], categoryId: Int? = nil, tags: [String] = [], sourceUrl: String = "", skipDuplicates: Bool = true) {
        self.name = name
        self.fileIds = fileIds
        self.categoryId = categoryId
        self.tags = tags
        self.sourceUrl = sourceUrl
        self.skipDuplicates = skipDuplicates
    }
}

public struct Stats: Codable, Sendable {
    public let models: Int
    public let untriaged: Int
    public let trash: Int
}

/// Loosely typed JSON for file metadata.
public enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case .string(let s): s
        case .number(let n): n.formatted()
        case .bool(let b): b ? "yes" : "no"
        default: ""
        }
    }
}

public func formatDims(_ x: Double?, _ y: Double?, _ z: Double?) -> String? {
    guard let x, let y, let z else { return nil }
    return "\(Int(x.rounded())) × \(Int(y.rounded())) × \(Int(z.rounded())) mm"
}

public func formatBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}
