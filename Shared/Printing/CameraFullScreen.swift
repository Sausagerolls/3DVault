import SwiftUI
import VaultKit
#if os(macOS)
import AppKit
#endif

/// A printer's camera filling the screen, with its progress in a box along the bottom.
struct CameraFullScreenView: View {
    @Environment(AppState.self) private var state
    let machineId: Int
    let close: () -> Void
    @State private var image: PlatformImage?
    @State private var machine: Machine?

    private var s: PrinterStatus? { machine?.status }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fit).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close camera")
            .padding(20)
        }
        .overlay(alignment: .bottom) {
            if let machine, let s {
                infoBox(machine, s)
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            // Each picture is asked for once the last has arrived, so this can't outrun the printer.
            while !Task.isCancelled {
                if let client = state.client, let data = try? await client.data(from: client.cameraURL(machine: machineId)),
                   let picture = PlatformImage(data: data) {
                    image = picture
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .task {
            while !Task.isCancelled {
                if let m = try? await state.client?.machine(machineId) { machine = m }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        #if os(iOS)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    private func infoBox(_ m: Machine, _ s: PrinterStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(m.name).font(.headline).lineLimit(1)
                StateBadge(state: s.state)
                Spacer(minLength: 8)
                if let t = s.nozzle?.temp { temperature("Nozzle", t, s.nozzle?.target) }
                if let t = s.bed?.temp { temperature("Bed", t, s.bed?.target) }
            }
            if let job = m.activeJob {
                let progress = s.progress ?? job.progress
                HStack {
                    Text(job.modelName).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(Int(progress))%").font(.title3.bold().monospacedDigit())
                }
                ProgressView(value: min(max(progress, 0), 100), total: 100).tint(.orange)
                HStack(spacing: 14) {
                    if let l = s.layer, let t = s.totalLayers { Text("Layer \(l) of \(t)") }
                    Spacer()
                    if s.state == "printing", let r = s.remainingS, r > 0 {
                        if let left = formatDuration(r) { Text("\(left) left") }
                        Text("Done about \(formatFinishTime(.now.addingTimeInterval(TimeInterval(r))))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if let message = s.message, !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func temperature(_ name: String, _ temp: Double, _ target: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(Int(temp))°\(target.map { $0 > 0 ? " / \(Int($0))°" : "" } ?? "")").font(.callout.monospacedDigit())
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
/// A window of its own, since only a whole window can go full screen on the Mac.
@MainActor
enum CameraWindow {
    private static var window: NSWindow?

    static func open(machineId: Int, state: AppState) {
        window?.close()
        let frame = NSApp.mainWindow?.screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.contentView = NSHostingView(rootView: CameraFullScreenView(machineId: machineId) { CameraWindow.close() }.environment(state))
        w.makeKeyAndOrderFront(nil)
        window = w
        #if DEBUG
        // A test leaves the screen where it is.
        if ProcessInfo.processInfo.environment["VAULT_TEST_CAMERA"] != nil {
            w.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 700), display: true)
            return
        }
        #endif
        w.toggleFullScreen(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }
}
#endif
