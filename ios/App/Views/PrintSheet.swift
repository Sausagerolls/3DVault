import SwiftUI
import VaultKit

/// Files on a model that can go to a printer without slicing, or might once checked by the server.
func printableFiles(_ m: ModelDetail) -> [VaultFile] {
    m.files.filter { f in
        ["gcode", "bgcode"].contains(f.ext) || (f.ext == "3mf" && (f.meta["sliced"] != nil || f.meta["slicer_project"] == .bool(true)))
    }
}

/// Choose printer, file, plate and filament slots, then send or queue the print.
struct PrintSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let model: ModelDetail
    var initialFile: VaultFile?

    @State private var fileId: Int?
    @State private var info: PrintInfo?
    @State private var machines: [Machine] = []
    @State private var machineId: Int?
    @State private var plate = 1
    /// Filament id in the sliced file -> AMS tray index (unit * 4 + slot), or -1 for the external spool.
    @State private var mapping: [Int: Int] = [:]
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?

    private var files: [VaultFile] { printableFiles(model) }
    private var machine: Machine? { machines.first { $0.id == machineId } }
    private var plateInfo: SlicedPlate? { info?.plates.first { $0.index == plate } }
    private var willQueue: Bool {
        guard let m = machine else { return false }
        return m.status.isBusy || m.needsClear || m.queued > 0 || m.activeJob != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if files.count > 1 {
                    Section("File") {
                        Picker("File", selection: $fileId) {
                            ForEach(files) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                if let info {
                    if info.format == nil {
                        Section {
                            Label("This file isn't sliced. Slice it in your slicer and add the G-code or sliced 3MF to the model.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        printerSection(info)
                        if info.plates.count > 1 {
                            Section("Plate") {
                                Picker("Plate", selection: $plate) {
                                    ForEach(info.plates) { p in
                                        Text("Plate \(p.index)\(formatDuration(p.timeS).map { " · \($0)" } ?? "")").tag(p.index)
                                    }
                                }
                            }
                        }
                        summarySection(info)
                        if let p = plateInfo, !p.filaments.isEmpty, let m = machine, !(m.status.ams ?? []).isEmpty {
                            amsSection(p, slots: m.status.ams ?? [])
                        }
                    }
                } else if loading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Print \(model.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(willQueue ? "Queue" : "Print") { send() }
                        .disabled(!canSend || sending)
                }
            }
            .task(id: fileId) { await loadInfo() }
            .task {
                if fileId == nil { fileId = initialFile?.id ?? files.first?.id }
                while !Task.isCancelled {
                    if let m = try? await state.client?.machines() { machines = m }
                    if machineId == nil { pickDefaultMachine() }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private var canSend: Bool {
        guard let info, info.format != nil, let id = machineId else { return false }
        return info.machines.first { $0.id == id }?.compatible == true
    }

    private func printerSection(_ info: PrintInfo) -> some View {
        Section("Printer") {
            if info.machines.isEmpty {
                Text("No printers are set up yet. An admin can add one in the web app under Settings › Printers.")
                    .foregroundStyle(.secondary)
            }
            Picker("Printer", selection: $machineId) {
                ForEach(info.machines) { c in
                    let m = machines.first { $0.id == c.id }
                    HStack {
                        Text(c.name)
                        Spacer()
                        if !c.compatible {
                            Text("Can't print this file").foregroundStyle(.secondary)
                        } else if let m {
                            StateBadge(state: m.needsClear ? "paused" : m.status.state)
                        }
                    }
                    .tag(Optional(c.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if let m = machine {
                if m.needsClear {
                    Text("The bed needs clearing. The print waits in the queue until someone taps Bed Cleared.")
                        .font(.footnote).foregroundStyle(.orange)
                } else if willQueue {
                    Text("\(m.name) is busy. The print joins the queue and starts after the current one, once the bed is cleared.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if m.status.state == "offline" {
                    Text("\(m.name) is offline. The print waits in the queue until it's back.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summarySection(_ info: PrintInfo) -> some View {
        Section("Summary") {
            let time = formatDuration(plateInfo?.timeS) ?? info.printTime
            let grams = plateInfo?.weightG.map { String(format: "%.1f g", $0) } ?? info.filamentG.map { "\($0) g" }
            LabeledContent("Print time", value: time ?? "Unknown")
            LabeledContent("Filament", value: grams ?? "Unknown")
            if let t = info.filamentType { LabeledContent("Material", value: t) }
            if let p = info.printerModel { LabeledContent("Sliced for", value: p) }
            if let fid = fileId {
                Thumbnail(fileId: fid).frame(height: 160).frame(maxWidth: .infinity)
            }
        }
    }

    private func amsSection(_ p: SlicedPlate, slots: [AmsSlot]) -> some View {
        Section {
            ForEach(p.filaments, id: \.id) { f in
                Picker(selection: Binding(get: { mapping[f.id] ?? -1 }, set: { mapping[f.id] = $0 })) {
                    Text("External spool").tag(-1)
                    ForEach(slots, id: \.self) { s in
                        HStack {
                            Circle().fill(Color(hex: s.color) ?? .gray).frame(width: 12, height: 12)
                            Text("AMS \(s.unit + 1) · Slot \(s.slot + 1) · \(s.type)")
                        }
                        .tag(s.unit * 4 + s.slot)
                    }
                } label: {
                    HStack {
                        Circle().fill(Color(hex: f.color) ?? .gray).frame(width: 14, height: 14)
                        Text("\(f.type) · \(String(format: "%.1f g", f.usedG))")
                    }
                }
            }
        } header: {
            Text("Filament slots")
        } footer: {
            Text("Match each colour in the file to a slot on the printer.")
        }
    }

    private func pickDefaultMachine() {
        guard let info else { return }
        let compatible = info.machines.filter(\.compatible).map(\.id)
        let ready = machines.first { compatible.contains($0.id) && !$0.status.isBusy && !$0.needsClear && $0.status.state != "offline" }
        machineId = ready?.id ?? compatible.first
        autoMap()
    }

    /// Match each filament to the slot with the same material and the closest colour.
    private func autoMap() {
        guard let p = plateInfo, let slots = machine?.status.ams, !slots.isEmpty else { return }
        for f in p.filaments where mapping[f.id] == nil {
            let same = slots.filter { $0.type.caseInsensitiveCompare(f.type) == .orderedSame }
            let pool = same.isEmpty ? slots : same
            let best = pool.min { colourDistance($0.color, f.color) < colourDistance($1.color, f.color) }
            mapping[f.id] = best.map { $0.unit * 4 + $0.slot } ?? -1
        }
    }

    private func loadInfo() async {
        guard let fileId, let client = state.client else { return }
        loading = true
        defer { loading = false }
        do {
            let i = try await client.printInfo(fileId: fileId)
            info = i
            plate = i.plates.first?.index ?? 1
            mapping = [:]
            if machineId == nil || !(i.machines.contains { $0.id == machineId && $0.compatible }) {
                machineId = nil
                pickDefaultMachine()
            } else {
                autoMap()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() {
        guard let fileId, let machineId, let client = state.client else { return }
        sending = true
        // Mapping is indexed by filament id, starting at 1.
        let count = plateInfo?.filaments.map(\.id).max() ?? 0
        let ams = count == 0 || mapping.isEmpty ? [] : (1...count).map { mapping[$0] ?? -1 }
        Task {
            do {
                let job = try await client.print(fileId: fileId, machineId: machineId, plate: plate, amsMapping: ams)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                state.show(willQueue ? "Added to the \(job.machineName) queue" : "Sending to \(job.machineName)")
                dismiss()
            } catch {
                self.error = error.localizedDescription
                sending = false
            }
        }
    }
}

private func colourDistance(_ a: String, _ b: String) -> Double {
    func rgb(_ s: String) -> (Double, Double, Double) {
        let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count >= 6, let v = UInt64(h.prefix(6), radix: 16) else { return (0.5, 0.5, 0.5) }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
    let x = rgb(a), y = rgb(b)
    return pow(x.0 - y.0, 2) + pow(x.1 - y.1, 2) + pow(x.2 - y.2, 2)
}

extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" as used by slicers and printers.
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count >= 6, let v = UInt64(h.prefix(6), radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
