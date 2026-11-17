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
    /// Older servers leave out the settings below, which only the printer setup needs.
    public let host: String?
    public let serial: String?
    public let hasSecret: Bool?
    public let printerId: Int?
    public let installedFilament: String?
    public let installedColour: String?
    public let enabled: Bool
    public let needsClear: Bool
    public let hasCamera: Bool
    public let formats: [String]
    public let status: PrinterStatus
    public let activeJob: PrintJob?
    public let queued: Int
}

/// A type of printer 3DVault can connect to, and the fields it needs to do so.
public struct MachineKind: Codable, Hashable, Identifiable, Sendable {
    public struct Field: Codable, Hashable, Identifiable, Sendable {
        public let key: String
        public let label: String
        public let secret: Bool
        public var id: String { key }
    }

    public let kind: String
    public let label: String
    public let fields: [Field]
    public var id: String { kind }
}

/// A printer that answered on the server's network.
public struct DiscoveredPrinter: Codable, Hashable, Identifiable, Sendable {
    public let kind: String
    public let serial: String
    public let host: String
    public let name: String
    public let model: String?
    public let lanMode: Bool
    public let added: Bool
    public var id: String { serial }
}

public struct SlicerPrinterProfile: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let vendor: String
    public let user: Bool
    public var id: String { vendor + name }
}

/// The editable settings of a printer, new or existing.
public struct MachineDraft: Hashable, Identifiable, Sendable {
    public var id: Int?
    public var name = ""
    public var kind = ""
    public var host = ""
    public var serial = ""
    /// Left empty on an existing printer, the server keeps the one it has.
    public var secret = ""
    public var hasSecret = false
    public var printerId: Int?
    public var enabled = true
    public var slicerPrinter = ""
    public var installedFilament = ""
    public var installedColour = ""

    public init(kind: String) {
        self.kind = kind
    }

    public init(discovered p: DiscoveredPrinter) {
        name = p.name
        kind = p.kind
        host = p.host
        serial = p.serial
    }

    public init(machine m: Machine) {
        id = m.id
        name = m.name
        kind = m.kind
        host = m.host ?? ""
        serial = m.serial ?? ""
        hasSecret = m.hasSecret ?? false
        printerId = m.printerId
        enabled = m.enabled
        slicerPrinter = m.slicerPrinter ?? ""
        installedFilament = m.installedFilament ?? ""
        installedColour = m.installedColour ?? ""
    }

    var json: [String: JSONValue] {
        [
            "name": .string(name), "kind": .string(kind), "host": .string(host), "serial": .string(serial),
            "secret": id != nil && secret.isEmpty ? .null : .string(secret),
            "printer_id": printerId.map { .number(Double($0)) } ?? .null,
            "enabled": .bool(enabled), "slicer_printer": .string(slicerPrinter),
            "installed_filament": .string(installedFilament), "installed_colour": .string(installedColour),
        ]
    }
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
    /// Started outside 3DVault, on the printer or in another app. Older servers leave it out.
    public let external: Bool?
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

/// When a print should finish: "17:42" today, "07:10 tomorrow", or "07:10 Wed" further out.
public func formatFinishTime(_ end: Date, from now: Date = .now, calendar: Calendar = .current) -> String {
    let time = end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
    if calendar.isDate(end, inSameDayAs: now) { return time }
    if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(end, inSameDayAs: next) {
        return "\(time) tomorrow"
    }
    return "\(time) \(end.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated)))"
}

// MARK: - Printing API

extension APIClient {
    public func machines() async throws -> [Machine] { try await get("machines") }
    public func machine(_ id: Int) async throws -> Machine { try await get("machines/\(id)") }

    // Printer setup. Everything that changes something is for admins, and the server checks.
    public func machineKinds() async throws -> [MachineKind] { try await get("machine-kinds") }

    /// The server listens for printers announcing themselves, which takes a few seconds.
    public func discoverMachines() async throws -> [DiscoveredPrinter] {
        try await decode(send("machines/discover", method: "POST"))
    }

    @discardableResult
    public func saveMachine(_ draft: MachineDraft) async throws -> Machine {
        if let id = draft.id {
            return try await decode(send("machines/\(id)", method: "PATCH", json: draft.json))
        }
        return try await decode(send("machines", method: "POST", json: draft.json))
    }

    public func deleteMachine(_ id: Int) async throws { _ = try await send("machines/\(id)", method: "DELETE") }

    public func slicerAvailable() async throws -> Bool {
        struct Out: Decodable { let available: Bool }
        let out: Out = try await get("slicer")
        return out.available
    }

    public func slicerPrinters(query: String) async throws -> [SlicerPrinterProfile] {
        try await get("slicer/printers", query: [.init(name: "q", value: query), .init(name: "limit", value: "30")])
    }

    public func slicerFilaments(printer: String) async throws -> [SlicerProfile] {
        try await get("slicer/filaments", query: [.init(name: "printer", value: printer)])
    }

    /// Returns the names of the presets imported.
    public func importSlicerPresets(_ files: [URL]) async throws -> [String] {
        struct Out: Decodable { let imported: [String] }
        let body = try MultipartBody(files: files.map { ("files", $0) }, fields: [])
        let out: Out = try decode(await upload("slicer/import", body: body))
        return out.imported
    }

    /// A long-lived token, such as a slicer's API key. The server only shows it this once.
    public func createToken(name: String) async throws -> String {
        struct Out: Decodable { let token: String }
        let out: Out = try decode(await send("tokens", method: "POST", query: [.init(name: "name", value: name)]))
        return out.token
    }

    public func printInfo(fileId: Int) async throws -> PrintInfo { try await get("files/\(fileId)/print-info") }

    @discardableResult
    public func print(fileId: Int, machineId: Int, plate: Int, amsMapping: [Int] = []) async throws -> PrintJob {
        try await decode(send("jobs", method: "POST", json: [
            "file_id": .number(Double(fileId)), "machine_id": .number(Double(machineId)),
            "plate": .number(Double(plate)), "ams_mapping": .array(amsMapping.map { .number(Double($0)) }),
        ]))
    }

    public func printJob(_ id: Int) async throws -> PrintJob { try await get("jobs/\(id)") }

    /// `mine` limits the list to prints sent by the signed-in person; with `external`, prints
    /// started outside 3DVault are included too.
    public func printJobs(machineId: Int? = nil, modelId: Int? = nil, active: Bool = false, mine: Bool = false, external: Bool = false) async throws -> [PrintJob] {
        var q: [URLQueryItem] = []
        if mine { q.append(.init(name: "mine", value: "true")) }
        if external { q.append(.init(name: "external", value: "true")) }
        if let machineId { q.append(.init(name: "machine_id", value: String(machineId))) }
        if let modelId { q.append(.init(name: "model_id", value: String(modelId))) }
        if active { q.append(.init(name: "active", value: "true")) }
        return try await get("jobs", query: q)
    }

    @discardableResult
    public func cancelJob(_ id: Int) async throws -> PrintJob { try await decode(send("jobs/\(id)/cancel", method: "POST")) }

    /// Queues a failed or cancelled print again on the same printer. Returns the new job.
    @discardableResult
    public func retryJob(_ id: Int) async throws -> PrintJob { try await decode(send("jobs/\(id)/retry", method: "POST")) }

    /// Sets the order of a printer's waiting jobs. `jobIds` must list every waiting job once.
    public func reorderQueue(machine: Int, jobIds: [Int]) async throws {
        _ = try await send("machines/\(machine)/queue", method: "PUT", json: ["job_ids": .array(jobIds.map { .number(Double($0)) })])
    }

    /// pause | resume | cancel
    public func control(machine: Int, _ action: String) async throws {
        _ = try await send("machines/\(machine)/\(action)", method: "POST")
    }

    @discardableResult
    public func bedCleared(machine: Int) async throws -> Machine {
        try await decode(send("machines/\(machine)/bed-cleared", method: "POST"))
    }

    /// Uploads a G-code file or sliced 3MF and adds it to this printer's queue.
    /// Returns how many plates the file holds; the first one is queued.
    @discardableResult
    public func queueFile(machine: Int, file: URL) async throws -> Int {
        struct Out: Decodable { let plates: Int }
        let body = try MultipartBody(files: [("file", file)], fields: [])
        let out: Out = try await decode(upload("machines/\(machine)/queue-file", body: body))
        return out.plates
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
