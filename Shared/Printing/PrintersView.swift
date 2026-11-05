import SwiftUI
import VaultKit

/// Live status of every printer, with camera, controls and the print queue.
struct PrintersView: View {
    @Environment(AppState.self) private var state
    let open: (Int) -> Void
    @State private var machines: [Machine] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(machines) { m in
                    PrinterCard(machine: m, open: open) { await refresh() }
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if loaded && machines.isEmpty {
                ContentUnavailableView("No Printers", systemImage: "printer",
                                       description: Text(error ?? "An admin can add printers in the web app under Settings › Printers."))
            } else if !loaded {
                ProgressView()
            }
        }
        .navigationTitle("Printers")
        .refreshable { await refresh() }
        .task {
            // Poll while visible; the server keeps the live connections.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // The first fetch can be cancelled as the screen slides in on iPhone, leaving it empty
        // until a pull to refresh. An unstructured task isn't tied to that transition.
        .onAppear { Task { await refresh() } }
    }

    private func refresh() async {
        guard let client = state.client else { return }
        do {
            machines = try await client.machines()
            error = nil
            loaded = true
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            if !loaded { self.error = error.localizedDescription }
            loaded = true
        }
    }
}

private struct PrinterCard: View {
    @Environment(AppState.self) private var state
    let machine: Machine
    let open: (Int) -> Void
    let refresh: () async -> Void
    @State private var confirmCancel = false
    @State private var busy = false
    @State private var alarmError: String?
    @State private var showQueue = false

    private var s: PrinterStatus { machine.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name).font(.headline)
                    StateBadge(state: s.state)
                }
                Spacer()
                if let n = s.nozzle?.temp {
                    tempLabel("Nozzle", n, s.nozzle?.target)
                }
                if let b = s.bed?.temp {
                    tempLabel("Bed", b, s.bed?.target)
                }
            }

            if machine.hasCamera && s.state != "offline" {
                CameraView(machineId: machine.id)
            }

            if let job = machine.activeJob {
                Button { if let id = job.modelId { open(id) } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.modelName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text("\(Int(s.progress ?? job.progress))%").font(.subheadline.monospacedDigit())
                        }
                        ProgressView(value: (s.progress ?? job.progress) / 100)
                        HStack {
                            if let l = s.layer, let t = s.totalLayers { Text("Layer \(l) of \(t)") }
                            Spacer()
                            if let r = formatDuration(s.remainingS), s.isBusy { Text("\(r) left") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if s.state == "printing", let r = s.remainingS, r > 0 {
                            Text("Done about \(formatFinishTime(.now.addingTimeInterval(TimeInterval(r))))")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .buttonStyle(.plain)
                HStack {
                    if s.state == "paused" {
                        Button { control("resume") } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button { control("pause") } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.bordered)
                            .disabled(s.state != "printing")
                    }
                    Button(role: .destructive) { confirmCancel = true } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                    #if os(iOS)
                    Spacer()
                    alarmButton(job)
                    #endif
                }
                .disabled(busy)
            } else if let msg = s.message, !msg.isEmpty {
                Text(msg).font(.callout).foregroundStyle(s.state == "failed" ? .red : .secondary)
            }

            if machine.needsClear {
                HStack {
                    Label("Clear the bed before the next print starts.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Bed Cleared") { clearBed() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || s.isBusy)
                }
            }

            #if os(macOS)
            // In a three-column window a NavigationLink opens in the detail column, covering the
            // model details, with no way back. A sheet opens and closes cleanly.
            Button { showQueue = true } label: { queueLabel }
                .buttonStyle(.plain)
                .sheet(isPresented: $showQueue) {
                    NavigationStack {
                        PrintQueueView(machine: machine) { id in
                            showQueue = false
                            open(id)
                        }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showQueue = false }
                            }
                        }
                    }
                    .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
                }
            #else
            NavigationLink {
                PrintQueueView(machine: machine, open: open)
            } label: {
                queueLabel
            }
            .buttonStyle(.plain)
            #endif
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .confirmationDialog("Stop this print?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop Print", role: .destructive) { control("cancel") }
        } message: {
            Text("The printer stops and the job can't be resumed.")
        }
    }

    private var queueLabel: some View {
        HStack {
            Label(machine.queued == 0 ? "Queue and history" : "\(machine.queued) waiting in queue", systemImage: "list.bullet")
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    #if os(iOS)
    /// Sets an alarm for the estimated finish, or shows the one already set and removes it.
    @ViewBuilder private func alarmButton(_ job: PrintJob) -> some View {
        let alarms = PrintAlarms.shared
        if let entry = alarms.entries[job.id] {
            Button { alarms.remove(jobId: job.id) } label: {
                Label(entry.date.map { formatFinishTime($0) } ?? "Alarm", systemImage: "alarm.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Removes the alarm")
        } else if s.state == "printing", let r = s.remainingS, r > 60 {
            Button {
                Task {
                    do {
                        try await alarms.add(jobId: job.id, modelName: job.modelName, at: .now.addingTimeInterval(TimeInterval(r)))
                    } catch {
                        alarmError = error.localizedDescription
                    }
                }
            } label: {
                Label("Alarm", systemImage: "alarm")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Sets an alarm for the estimated finish time")
            .alert("Couldn't Set Alarm", isPresented: Binding(get: { alarmError != nil }, set: { if !$0 { alarmError = nil } })) {
                Button("OK") {}
            } message: {
                Text(alarmError ?? "")
            }
        }
    }
    #endif

    private func tempLabel(_ name: String, _ temp: Double, _ target: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(Int(temp))°\(target.map { $0 > 0 ? " / \(Int($0))°" : "" } ?? "")").font(.callout.monospacedDigit())
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }

    private func control(_ action: String) {
        run { try await $0.control(machine: machine.id, action) }
    }

    private func clearBed() {
        run { try await $0.bedCleared(machine: machine.id) }
    }

    private func run(_ op: @escaping (APIClient) async throws -> Void) {
        guard let client = state.client else { return }
        busy = true
        Task {
            do {
                try await op(client)
                successHaptic()
            } catch {
                state.report(error)
            }
            await refresh()
            busy = false
        }
    }
}

struct StateBadge: View {
    let state: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case "idle": "Ready"
        case "preparing": "Preparing"
        case "printing": "Printing"
        case "paused": "Paused"
        case "finished": "Finished"
        case "failed": "Failed"
        case "queued": "Queued"
        case "uploading": "Sending"
        case "cancelled": "Cancelled"
        case "needs_clear": "Clear bed"
        default: "Offline"
        }
    }

    private var color: Color {
        switch state {
        case "idle", "finished": .green
        case "printing", "preparing", "uploading": .blue
        case "paused", "queued", "needs_clear": .orange
        case "failed": .red
        default: .gray
        }
    }
}

/// Camera snapshot refreshed every few seconds while on screen.
private struct CameraView: View {
    @Environment(AppState.self) private var state
    let machineId: Int
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.black.opacity(0.08).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            while !Task.isCancelled {
                if let client = state.client, let data = try? await client.data(from: client.cameraURL(machine: machineId)),
                   let img = PlatformImage(data: data) {
                    image = img
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// Waiting jobs and recent history for one printer.
struct PrintQueueView: View {
    @Environment(AppState.self) private var state
    let machine: Machine
    let open: (Int) -> Void
    @State private var jobs: [PrintJob] = []

    var body: some View {
        List {
            let waiting = jobs.filter { $0.state == "queued" }.sorted { $0.id < $1.id }
            if !waiting.isEmpty {
                Section("Waiting") {
                    ForEach(waiting) { j in
                        JobRow(job: j, open: open)
                            .swipeActions {
                                Button("Remove", role: .destructive) { cancel(j) }
                            }
                    }
                }
            }
            Section("History") {
                ForEach(jobs.filter { $0.state != "queued" }) { j in JobRow(job: j, open: open) }
            }
        }
        .navigationTitle(machine.name)
        .overlay {
            if jobs.isEmpty { ContentUnavailableView("No Prints Yet", systemImage: "printer") }
        }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func load() async {
        guard let client = state.client else { return }
        if let j = try? await client.printJobs(machineId: machine.id) { jobs = j }
    }

    private func cancel(_ j: PrintJob) {
        Task {
            do {
                try await state.client?.cancelJob(j.id)
            } catch {
                state.report(error)
            }
            await load()
        }
    }
}

struct JobRow: View {
    let job: PrintJob
    var showMachine = false
    let open: (Int) -> Void

    var body: some View {
        Button { if let id = job.modelId { open(id) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.modelName).lineLimit(1)
                    Text([showMachine ? job.machineName : nil, job.external == true ? "Started outside 3DVault" : job.user, (job.finishedAt ?? job.createdAt).formatted(date: .abbreviated, time: .shortened)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if !job.error.isEmpty {
                        Text(job.error).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                StateBadge(state: job.state)
            }
        }
        .buttonStyle(.plain)
    }
}
