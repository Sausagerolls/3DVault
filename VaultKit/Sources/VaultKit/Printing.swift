import Foundation

// MARK: - Printing types

public struct PrinterTemp: Codable, Hashable, Sendable {
    public let temp: Double?
    public let target: Double?
}

public struct AmsSlot: Codable, Hashable, Sendable {
    public let unit: Int
    public let slot: Int
    public let type: String
    public let color: String
    public let remaining: Int?
}

public struct PrinterStatus: Codable, Hashable, Sendable {
    /// offline | idle | preparing | printing | paused | finished | failed
    public let state: String
    public let progress: Double?
    public let layer: Int?
    public let totalLayers: Int?
    public let remainingS: Int?
    public let file: String?
    public let nozzle: PrinterTemp?
    public let bed: PrinterTemp?
    public let ams: [AmsSlot]?
    public let message: String?

    public var isBusy: Bool { ["preparing", "printing", "paused"].contains(state) }
}

public struct BedSize: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
}

/// A printer 3DVault can send jobs to.
public struct Machine: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let kind: String
    public let bed: BedSize?
    public let slicerPrinter: String?
    public let enabled: Bool
    public let needsClear: Bool
    public let hasCamera: Bool
    public let formats: [String]
    public let status: PrinterStatus
    public let activeJob: PrintJob?
    public let queued: Int
}

public struct PrintJob: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let machineId: Int
    public let machineName: String
    public let modelId: Int?
    public let modelName: String
    public let fileId: Int?
    public let fileName: String
    public let plate: Int
    public let user: String?
    /// queued | uploading | printing | paused | finished | failed | cancelled
    public let state: String
    public let progress: Double
    public let layer: Int?
    public let totalLayers: Int?
    public let remainingS: Int?
    public let error: String
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?

    public var isActive: Bool { ["uploading", "printing", "paused"].contains(state) }
}

public struct SlicedFilament: Codable, Hashable, Sendable {
    public let id: Int
    public let type: String
    public let color: String
    public let usedG: Double
}

public struct SlicedPlate: Codable, Hashable, Sendable, Identifiable {
    public let index: Int
    public let timeS: Int?
    public let weightG: Double?
    public let filaments: [SlicedFilament]
    public var id: Int { index }
}

public struct PrintInfo: Codable, Hashable, Sendable {
    public struct MachineChoice: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let compatible: Bool
    }

    public let fileId: Int
    /// gcode | bgcode | gcode3mf, or nil when the file must be sliced first.
    public let format: String?
    /// True when the server can slice this file.
    public let sliceable: Bool?
    public let plates: [SlicedPlate]
    public let printTime: String?
    public let filamentG: String?
    public let filamentType: String?
    public let printerModel: String?
    public let machines: [MachineChoice]
}

public struct SlicerProfile: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let vendor: String
    public let user: Bool
    public let type: String?
    public var id: String { name }
}

public struct SliceDefaults: Codable, Hashable, Sendable {
    public let layerHeight: Double?
    public let sparseInfillDensity: Double?
    public let wallLoops: Double?
    public let enableSupport: Bool?
    public let supportType: String?
    public let brimType: String?
}

public struct SlicerOptions: Codable, Hashable, Sendable {
    public let printer: String
    public let processes: [SlicerProfile]
    public let filaments: [SlicerProfile]
    public let bedTypes: [String]
    public let defaultProcess: String
    public let defaultFilament: String
    public let defaultBedType: String
    public let defaults: SliceDefaults
}

public struct SliceTask: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let modelId: Int
    /// queued | slicing | done | failed
    public let state: String
    public let error: String
    public let outputFileId: Int?
    public let ahead: Int?
}

public struct ToolpathSummary: Codable, Hashable, Sendable {
    public let layers: Int
    public let z: [Double]
    public let bounds: [Double]?
    public let features: [String]
}

public struct ToolpathLayer: Codable, Hashable, Sendable {
    public struct Path: Codable, Hashable, Sendable {
        /// Index into ToolpathSummary.features.
        public let f: Int
        /// Flat x, y pairs in millimetres.
        public let p: [Double]
    }

    public let index: Int
    public let z: Double
    public let paths: [Path]
}

/// "1h 05m" style duration.
public func formatDuration(_ seconds: Int?) -> String? {
    guard let seconds else { return nil }
    let h = seconds / 3600, m = seconds % 3600 / 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
}

// MARK: - Printing API

extension APIClient {
    public func machines() async throws -> [Machine] { try await get("machines") }
    public func machine(_ id: Int) async throws -> Machine { try await get("machines/\(id)") }

    public func printInfo(fileId: Int) async throws -> PrintInfo { try await get("files/\(fileId)/print-info") }

    @discardableResult
    public func print(fileId: Int, machineId: Int, plate: Int, amsMapping: [Int] = []) async throws -> PrintJob {
        try await decode(send("jobs", method: "POST", json: [
            "file_id": .number(Double(fileId)), "machine_id": .number(Double(machineId)),
            "plate": .number(Double(plate)), "ams_mapping": .array(amsMapping.map { .number(Double($0)) }),
        ]))
    }

    public func printJobs(machineId: Int? = nil, modelId: Int? = nil, active: Bool = false) async throws -> [PrintJob] {
        var q: [URLQueryItem] = []
        if let machineId { q.append(.init(name: "machine_id", value: String(machineId))) }
        if let modelId { q.append(.init(name: "model_id", value: String(modelId))) }
        if active { q.append(.init(name: "active", value: "true")) }
        return try await get("jobs", query: q)
    }

    @discardableResult
    public func cancelJob(_ id: Int) async throws -> PrintJob { try await decode(send("jobs/\(id)/cancel", method: "POST")) }

    /// pause | resume | cancel
    public func control(machine: Int, _ action: String) async throws {
        _ = try await send("machines/\(machine)/\(action)", method: "POST")
    }

    @discardableResult
    public func bedCleared(machine: Int) async throws -> Machine {
        try await decode(send("machines/\(machine)/bed-cleared", method: "POST"))
    }

    public func cameraURL(machine: Int) -> URL { url("machines/\(machine)/camera") }

    public func slicerOptions(machineId: Int) async throws -> SlicerOptions {
        try await get("slicer/options", query: [.init(name: "machine_id", value: String(machineId))])
    }

    public func slice(fileIds: [Int], machineId: Int, process: String, filaments: [String], overrides: [String: JSONValue]) async throws -> SliceTask {
        try await decode(send("slices", method: "POST", json: [
            "file_ids": .array(fileIds.map { .number(Double($0)) }), "machine_id": .number(Double(machineId)),
            "process": .string(process), "filaments": .array(filaments.map(JSONValue.string)), "overrides": .object(overrides),
        ]))
    }

    public func sliceTask(_ id: Int) async throws -> SliceTask { try await get("slices/\(id)") }

    public func toolpaths(fileId: Int, plate: Int) async throws -> ToolpathSummary {
        try await get("files/\(fileId)/toolpaths", query: [.init(name: "plate", value: String(plate))])
    }

    public func toolpathLayer(fileId: Int, plate: Int, index: Int) async throws -> ToolpathLayer {
        try await get("files/\(fileId)/toolpaths/\(index)", query: [.init(name: "plate", value: String(plate))])
    }
}
