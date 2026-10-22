import SwiftUI
import VaultKit

private let slicedExts: Set<String> = ["gcode", "bgcode"]
private let sliceableExts: Set<String> = ["stl", "obj", "3mf", "step", "stp", "amf"]

/// Files on a model that can be printed: sliced files first, then files the server can slice.
func printableFiles(_ m: ModelDetail) -> [VaultFile] {
    let sliced = m.files.filter { slicedExts.contains($0.ext) || ($0.ext == "3mf" && $0.meta["sliced"] != nil) }
    let rest = m.files.filter { f in sliceableExts.contains(f.ext) && f.kind != "photo" && !sliced.contains { $0.id == f.id } }
    return sliced + rest
}

/// Choose what to print and where, slice it on the server if needed, preview the layers,
/// map filament slots, then send or queue the print.
struct PrintSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let model: ModelDetail
    var initialFile: VaultFile?

    /// "f<id>" for one file, "all" for every mesh part together.
    @State private var source = ""
    @State private var info: PrintInfo?
    @State private var machines: [Machine] = []
    @State private var machineId: Int?
    @State private var plate = 1
    /// Filament id in the sliced file -> AMS tray index (unit * 4 + slot), or -1 for the external spool.
    @State private var mapping: [Int: Int] = [:]
    @State private var loading = false
    @State private var sending = false
    @State private var error: String?

    // Slicing
    @State private var options: SlicerOptions?
    @State private var optionsError: String?
    @State private var settings = SliceSettings()
    @State private var slicing: SliceTask?
    @State private var slicedFileId: Int?
    @State private var showPreview = false

    private var files: [VaultFile] { printableFiles(model) }
    private var meshParts: [VaultFile] { files.filter { ["stl", "obj", "step", "stp", "amf"].contains($0.ext) } }
    private var selectedFile: VaultFile? {
        source.hasPrefix("f") ? model.files.first { "f\($0.id)" == source } : nil
    }
    private var machine: Machine? { machines.first { $0.id == machineId } }
    private var plateInfo: SlicedPlate? { info?.plates.first { $0.index == plate } }
    /// The selection still has to be sliced before it can be printed.
    private var needsSlice: Bool {
        slicedFileId == nil && (source == "all" || (info != nil && info?.format == nil))
    }
    private var printFileId: Int? { slicedFileId ?? (info?.format != nil ? info?.fileId : nil) }
    private var willQueue: Bool {
        guard let m = machine else { return false }
        return m.status.isBusy || m.needsClear || m.queued > 0 || m.activeJob != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                printerSection
                if slicing != nil {
                    slicingSection
                } else if needsSlice {
                    sliceSettingsSection
                } else if let info, info.format != nil {
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
                if loading {
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
                    if needsSlice {
                        Button("Slice") { startSlice() }
                            .disabled(options == nil || machineId == nil || slicing != nil)
                    } else {
                        Button(willQueue ? "Queue" : "Print") { send() }
                            .disabled(!canSend || sending)
                    }
                }
            }
            .navigationDestination(isPresented: $showPreview) {
                if let fid = printFileId { LayerPreview(fileId: fid, plate: plate, bed: machine?.bed) }
            }
            .task(id: source) { await loadInfo() }
            .task(id: machineId) {
                await loadOptions()
                #if DEBUG
                // Simulator testing: VAULT_TEST_PRINT=slice slices straight away, =preview also opens the layer preview.
                let mode = ProcessInfo.processInfo.environment["VAULT_TEST_PRINT"]
                if (mode == "slice" || mode == "preview"), needsSlice, options != nil { startSlice() }
                #endif
            }
            .task {
                if source.isEmpty { source = initialFile.map { "f\($0.id)" } ?? files.first.map { "f\($0.id)" } ?? "" }
                while !Task.isCancelled {
                    if let m = try? await state.client?.machines() { machines = m }
                    if machineId == nil { pickDefaultMachine() }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private var canSend: Bool {
        guard printFileId != nil, let id = machineId, let info else { return false }
        return info.machines.first { $0.id == id }?.compatible == true
    }

    // MARK: sections

    @ViewBuilder
    private var sourceSection: some View {
        if files.count > 1 {
            Section("What to print") {
                Picker("File", selection: $source) {
                    ForEach(files) { f in
                        VStack(alignment: .leading) {
                            Text(f.name).lineLimit(1)
                            Text(slicedExts.contains(f.ext) || f.meta["sliced"] != nil ? "Sliced, ready to print" : "Needs slicing")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag("f\(f.id)")
                    }
                    if meshParts.count > 1 {
                        Text("All \(meshParts.count) parts together").tag("all")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(slicing != nil)
            }
        }
    }

    private var printerSection: some View {
        Section("Printer") {
            let choices = machines.filter(\.enabled)
            if choices.isEmpty {
                Text("No printers are set up yet. An admin can add one in the web app under Settings › Printers.")
                    .foregroundStyle(.secondary)
            }
            Picker("Printer", selection: $machineId) {
                ForEach(choices) { m in
                    let compatible = info.map { i in i.format == nil || i.machines.contains { $0.id == m.id && $0.compatible } } ?? true
                    HStack {
                        Text(m.name)
                        Spacer()
                        if !compatible {
                            Text("Can't print this file").foregroundStyle(.secondary)
                        } else {
                            StateBadge(state: m.needsClear && !m.status.isBusy ? "needs_clear" : m.status.state)
                        }
                    }
                    .tag(Optional(m.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(slicing != nil)
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

    @ViewBuilder
    private var sliceSettingsSection: some View {
        if let optionsError {
            Section { Label(optionsError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } else if let o = options {
            Section {
                Picker("Quality", selection: $settings.process) {
                    ForEach(o.processes) { Text($0.name.components(separatedBy: " @").first ?? $0.name).tag($0.name) }
                }
                if let slots = machine?.status.ams, !slots.isEmpty {
                    Picker("Filament slot", selection: $settings.slot) {
                        Text("External spool").tag(-1)
                        ForEach(slots, id: \.self) { s in
                            HStack {
                                Circle().fill(Color(hex: s.color) ?? .gray).frame(width: 12, height: 12)
                                Text("Slot \(s.slot + 1) · \(s.type)")
                            }
                            .tag(s.unit * 4 + s.slot)
                        }
                    }
                    .onChange(of: settings.slot) { matchFilamentToSlot(o) }
                }
                NavigationLink {
                    FilamentPicker(filaments: o.filaments, selection: $settings.filament)
                } label: {
                    LabeledContent("Filament", value: settings.filament.components(separatedBy: " @").first ?? settings.filament)
                }
                Picker("Build plate", selection: $settings.bedType) {
                    ForEach(o.bedTypes, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Slice settings")
            } footer: {
                Text("Sliced on the server with OrcaSlicer using \(o.printer).")
            }
            Section("Adjust") {
                Stepper(value: $settings.layerHeight, in: 0.08...0.32, step: 0.04) {
                    LabeledContent("Layer height", value: String(format: "%.2f mm", settings.layerHeight))
                }
                Stepper(value: $settings.infill, in: 0...100, step: 5) {
                    LabeledContent("Infill", value: "\(Int(settings.infill))%")
                }
                Stepper(value: $settings.walls, in: 1...8) {
                    LabeledContent("Walls", value: "\(settings.walls)")
                }
                Toggle("Supports", isOn: $settings.supports)
                if settings.supports {
                    Picker("Support type", selection: $settings.supportType) {
                        Text("Tree").tag("tree(auto)")
                        Text("Normal").tag("normal(auto)")
                    }
                }
                Picker("Brim", selection: $settings.brim) {
                    Text("Auto").tag("auto_brim")
                    Text("Outer only").tag("outer_only")
                    Text("None").tag("no_brim")
                }
                Stepper(value: $settings.scale, in: 10...400, step: 5) {
                    LabeledContent("Scale", value: "\(Int(settings.scale))%")
                }
            }
        } else if machineId != nil {
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        }
    }

    private var slicingSection: some View {
        Section {
            if let t = slicing {
                if t.state == "failed" {
                    Label(t.error.isEmpty ? "Slicing failed" : t.error, systemImage: "xmark.octagon").foregroundStyle(.red)
                    Button("Change Settings") { slicing = nil }
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text(t.state == "queued" ? "Waiting to slice" : "Slicing…")
                            if let ahead = t.ahead, ahead > 0 {
                                Text("\(ahead) ahead in the queue").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Big models can take a few minutes.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
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
            if let fid = printFileId {
                NavigationLink {
                    LayerPreview(fileId: fid, plate: plate, bed: machine?.bed)
                } label: {
                    Label("Layer preview", systemImage: "square.stack.3d.up")
                }
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

    // MARK: loading

    private func pickDefaultMachine() {
        let enabled = machines.filter(\.enabled)
        let ready = enabled.first { !$0.status.isBusy && !$0.needsClear && $0.status.state != "offline" }
        machineId = ready?.id ?? enabled.first?.id
    }

    private func loadInfo() async {
        slicedFileId = nil
        slicing = nil
        mapping = [:]
        guard let f = selectedFile, let client = state.client else {
            info = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            let i = try await client.printInfo(fileId: f.id)
            info = i
            plate = i.plates.first?.index ?? 1
            if i.format == nil && i.sliceable == false {
                error = "This server can't slice files. Slice it in your slicer and add the G-code or sliced 3MF to the model."
            } else {
                error = nil
            }
            autoMap()
            #if DEBUG
            if ProcessInfo.processInfo.environment["VAULT_TEST_PRINT"] == "preview", i.format != nil { showPreview = true }
            #endif
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadOptions() async {
        options = nil
        optionsError = nil
        guard let machineId, let client = state.client else { return }
        do {
            let o = try await client.slicerOptions(machineId: machineId)
            options = o
            settings = SliceSettings(options: o, keeping: settings)
            if let m = machine, let slot = m.status.ams?.first {
                settings.slot = slot.unit * 4 + slot.slot
                matchFilamentToSlot(o)
            }
        } catch {
            optionsError = error.localizedDescription
        }
    }

    /// Pick a filament profile of the slot's material when the current one is a different material.
    private func matchFilamentToSlot(_ o: SlicerOptions) {
        guard settings.slot >= 0, let slot = machine?.status.ams?.first(where: { $0.unit * 4 + $0.slot == settings.slot }) else { return }
        let current = o.filaments.first { $0.name == settings.filament }
        if current?.type?.caseInsensitiveCompare(slot.type) == .orderedSame { return }
        let same = o.filaments.filter { $0.type?.caseInsensitiveCompare(slot.type) == .orderedSame }
        if let best = same.first(where: { $0.name.hasPrefix("Bambu \(slot.type) Basic") }) ?? same.first(where: { $0.name.hasPrefix("Generic") }) ?? same.first {
            settings.filament = best.name
        }
    }

    /// Match each filament to the slot with the same material and the closest colour.
    private func autoMap() {
        guard let p = plateInfo, let slots = machine?.status.ams, !slots.isEmpty else { return }
        for f in p.filaments where mapping[f.id] == nil {
            if slicedFileId != nil, settings.slot >= 0, p.filaments.count == 1 {
                mapping[f.id] = settings.slot
                continue
            }
            let same = slots.filter { $0.type.caseInsensitiveCompare(f.type) == .orderedSame }
            let pool = same.isEmpty ? slots : same
            let best = pool.min { colourDistance($0.color, f.color) < colourDistance($1.color, f.color) }
            mapping[f.id] = best.map { $0.unit * 4 + $0.slot } ?? -1
        }
    }

    // MARK: actions

    private func startSlice() {
        guard let machineId, let client = state.client else { return }
        let ids = source == "all" ? meshParts.map(\.id) : selectedFile.map { [$0.id] } ?? []
        var overrides = settings.overrides
        if settings.slot >= 0, let slot = machine?.status.ams?.first(where: { $0.unit * 4 + $0.slot == settings.slot }) {
            overrides["filament_colours"] = .array([.string(slot.color)])
        }
        error = nil
        Task {
            do {
                var t = try await client.slice(fileIds: ids, machineId: machineId, process: settings.process,
                                               filaments: [settings.filament], overrides: overrides)
                slicing = t
                while t.state == "queued" || t.state == "slicing" {
                    try await Task.sleep(for: .seconds(2))
                    t = try await client.sliceTask(t.id)
                    slicing = t
                }
                if t.state == "done", let out = t.outputFileId {
                    let i = try await client.printInfo(fileId: out)
                    info = i
                    plate = i.plates.first?.index ?? 1
                    mapping = [:]
                    slicedFileId = out
                    slicing = nil
                    autoMap()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    state.changed()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["VAULT_TEST_PRINT"] == "preview" { showPreview = true }
                    #endif
                }
            } catch {
                self.error = error.localizedDescription
                slicing = nil
            }
        }
    }

    private func send() {
        guard let fileId = printFileId, let machineId, let client = state.client else { return }
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

/// Per-print slicer settings, starting from the printer's default process.
struct SliceSettings: Equatable {
    var process = ""
    var filament = ""
    var bedType = ""
    var slot = -1
    var layerHeight = 0.2
    var infill = 15.0
    var walls = 2
    var supports = false
    var supportType = "tree(auto)"
    var brim = "auto_brim"
    var scale = 100.0

    init() {}

    init(options o: SlicerOptions, keeping old: SliceSettings) {
        self = old
        if !o.processes.contains(where: { $0.name == process }) { process = o.defaultProcess.isEmpty ? o.processes.first?.name ?? "" : o.defaultProcess }
        if !o.filaments.contains(where: { $0.name == filament }) { filament = o.defaultFilament.isEmpty ? o.filaments.first?.name ?? "" : o.defaultFilament }
        if !o.bedTypes.contains(bedType) { bedType = o.defaultBedType.isEmpty ? o.bedTypes.first ?? "" : o.defaultBedType }
        let d = o.defaults
        layerHeight = d.layerHeight ?? layerHeight
        infill = d.sparseInfillDensity ?? infill
        walls = Int(d.wallLoops ?? Double(walls))
        supports = d.enableSupport ?? supports
        supportType = d.supportType ?? supportType
        brim = d.brimType ?? brim
    }

    var overrides: [String: JSONValue] {
        [
            "layer_height": .number(layerHeight),
            "sparse_infill_density": .number(infill),
            "wall_loops": .number(Double(walls)),
            "enable_support": .bool(supports),
            "support_type": .string(supportType),
            "brim_type": .string(brim),
            "bed_type": .string(bedType),
            "scale": .number(scale / 100),
        ]
    }
}

/// Searchable list of filament profiles; there are well over a hundred per printer.
private struct FilamentPicker: View {
    @Environment(\.dismiss) private var dismiss
    let filaments: [SlicerProfile]
    @Binding var selection: String
    @State private var search = ""

    var body: some View {
        List {
            let shown = search.isEmpty ? filaments : filaments.filter { $0.name.localizedCaseInsensitiveContains(search) }
            ForEach(shown) { f in
                Button {
                    selection = f.name
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(f.name.components(separatedBy: " @").first ?? f.name)
                            Text([f.type, f.user ? "Imported" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if f.name == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $search, prompt: "PLA, PETG, Bambu…")
        .navigationTitle("Filament")
    }
}

/// Top-down view of one layer of the sliced toolpaths, with a slider through the layers.
struct LayerPreview: View {
    @Environment(AppState.self) private var state
    let fileId: Int
    let plate: Int
    let bed: BedSize?
    @State private var summary: ToolpathSummary?
    @State private var index = 0.0
    @State private var layers: [Int: ToolpathLayer] = [:]
    @State private var error: String?

    private static let colours: [Color] = [.orange, .yellow, .red, .purple, .pink, .indigo, .green, .blue, .gray]

    var body: some View {
        VStack(spacing: 12) {
            if let s = summary, s.layers > 0 {
                let i = Int(index)
                Canvas { ctx, size in draw(ctx, size, s, i) }
                    .aspectRatio(1, contentMode: .fit)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Text("Layer \(i + 1) of \(s.layers)")
                    Spacer()
                    Text(String(format: "%.2f mm", s.z[safe: i] ?? 0)).monospacedDigit()
                }
                .font(.callout)
                Slider(value: $index, in: 0...Double(max(s.layers - 1, 1)), step: 1)
                legend
            } else if let error {
                ContentUnavailableView("No Preview", systemImage: "square.stack.3d.up.slash", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .padding()
        .navigationTitle("Layer preview")
        .task {
            do {
                guard let client = state.client else { return }
                let s = try await client.toolpaths(fileId: fileId, plate: plate)
                summary = s
                index = Double(max(0, s.layers / 2))
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: Int(index)) { await fetch(around: Int(index)) }
    }

    private var legend: some View {
        let names = [("Outer wall", 0), ("Inner wall", 1), ("Infill", 2), ("Solid infill", 3), ("Top", 4), ("Support", 6)]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: 4) {
            ForEach(names, id: \.1) { name, f in
                HStack(spacing: 6) {
                    Circle().fill(Self.colours[f]).frame(width: 8, height: 8)
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fetch(around i: Int) async {
        guard let client = state.client, let s = summary else { return }
        for j in [i, i - 1] where j >= 0 && j < s.layers && layers[j] == nil {
            if let l = try? await client.toolpathLayer(fileId: fileId, plate: plate, index: j) { layers[j] = l }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ s: ToolpathSummary, _ i: Int) {
        // Fit the bed if known, otherwise the print's own bounds with a margin.
        let b = s.bounds ?? [0, 0, 1, 1]
        let (minX, minY, maxX, maxY): (Double, Double, Double, Double) = bed.map { (0, 0, $0.x, $0.y) }
            ?? (b[0] - 5, b[1] - 5, b[2] + 5, b[3] + 5)
        let span = max(maxX - minX, maxY - minY, 1)
        let k = min(size.width, size.height) / span
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - minX) * k, y: size.height - (y - minY) * k) }
        if bed != nil {
            ctx.stroke(Path(CGRect(origin: pt(minX, maxY), size: CGSize(width: (maxX - minX) * k, height: (maxY - minY) * k))),
                       with: .color(.secondary.opacity(0.4)), lineWidth: 1)
        }
        let width = max(0.4 * k, 0.5)
        if let prev = layers[i - 1] {
            ctx.stroke(path(prev.paths, pt), with: .color(.secondary.opacity(0.25)), lineWidth: width)
        }
        guard let layer = layers[i] else { return }
        for f in Set(layer.paths.map(\.f)) {
            let p = path(layer.paths.filter { $0.f == f }, pt)
            ctx.stroke(p, with: .color(Self.colours[min(f, Self.colours.count - 1)]), lineWidth: width)
        }
    }

    private func path(_ paths: [ToolpathLayer.Path], _ pt: (Double, Double) -> CGPoint) -> Path {
        var p = Path()
        for seg in paths where seg.p.count >= 4 {
            p.move(to: pt(seg.p[0], seg.p[1]))
            var j = 2
            while j + 1 < seg.p.count {
                p.addLine(to: pt(seg.p[j], seg.p[j + 1]))
                j += 2
            }
        }
        return p
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
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
