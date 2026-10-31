import AppIntents
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VaultKit
import WidgetKit

// A Home Screen and Lock Screen widget with a printer's latest camera picture and progress.
// Widgets can't play video, so the picture is a snapshot taken whenever the widget refreshes:
// every few minutes while printing (iOS decides exactly when), and straight away whenever
// the app checks the printers.

struct PrinterEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Printer"
    static let defaultQuery = PrinterQuery()
    let id: Int
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PrinterQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [PrinterEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PrinterEntity] {
        guard let client = SharedConfig.client() else { return [] }
        return try await client.machines().map { PrinterEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectPrinterIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Printer"
    static let description = IntentDescription("Shows a printer's camera and print progress.")

    @Parameter(title: "Printer")
    var printer: PrinterEntity?
}

struct PrinterEntry: TimelineEntry {
    let date: Date
    var name = "Printer"
    var state = "offline"
    var progress: Double = 0
    var layer: Int?
    var totalLayers: Int?
    var endDate: Date?
    var title: String?
    var message: String?
    var image: UIImage?
    var signedOut = false

    var isBusy: Bool { ["preparing", "printing", "paused"].contains(state) }

    static let placeholder = PrinterEntry(date: .now, name: "A1 mini", state: "printing", progress: 42, layer: 63,
                                          totalLayers: 150, endDate: .now.addingTimeInterval(1980), title: "3DBenchy")
}

struct PrinterProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PrinterEntry { .placeholder }

    func snapshot(for configuration: SelectPrinterIntent, in context: Context) async -> PrinterEntry {
        context.isPreview ? .placeholder : await entry(for: configuration, in: context)
    }

    func timeline(for configuration: SelectPrinterIntent, in context: Context) async -> Timeline<PrinterEntry> {
        let e = await entry(for: configuration, in: context)
        // Ask for frequent refreshes only while something is printing; iOS limits them anyway.
        let next = Date.now.addingTimeInterval(e.isBusy ? 5 * 60 : 30 * 60)
        return Timeline(entries: [e], policy: .after(next))
    }

    private func entry(for configuration: SelectPrinterIntent, in context: Context) async -> PrinterEntry {
        guard let client = SharedConfig.client() else { return PrinterEntry(date: .now, signedOut: true) }
        guard let machines = try? await client.machines(), !machines.isEmpty else {
            return PrinterEntry(date: .now, message: "Can't reach the server")
        }
        // The chosen printer, or else the first one that's busy, or else the first.
        let m = machines.first { $0.id == configuration.printer?.id }
            ?? machines.first { $0.status.isBusy } ?? machines[0]
        let s = m.status
        var e = PrinterEntry(date: .now, name: m.name, state: s.state, progress: s.progress ?? m.activeJob?.progress ?? 0,
                             layer: s.layer, totalLayers: s.totalLayers, title: m.activeJob?.modelName, message: s.message)
        if s.state == "printing", let r = s.remainingS, r > 0 { e.endDate = .now.addingTimeInterval(TimeInterval(r)) }
        let wantsImage = context.family != .accessoryCircular && context.family != .accessoryRectangular
        if wantsImage, m.hasCamera, s.state != "offline", let data = try? await client.data(from: client.cameraURL(machine: m.id)) {
            // Widgets have a small memory budget, so decode straight to a thumbnail.
            e.image = thumbnail(data, maxPixels: context.family == .systemSmall ? 500 : 900)
        }
        return e
    }

    private func thumbnail(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map(UIImage.init(cgImage:))
    }
}

struct PrinterWidget: Widget {
    static let kind = "PrinterWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectPrinterIntent.self, provider: PrinterProvider()) { entry in
            PrinterWidgetView(entry: entry)
                .widgetURL(URL(string: "threedvault://printers"))
        }
        .configurationDisplayName("Printer")
        .description("Camera and progress of a printer.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct PrinterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PrinterEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: entry.progress, in: 0...100) {
                Image(systemName: "printer.fill")
            } currentValueLabel: {
                Text(entry.isBusy ? "\(Int(entry.progress))" : "–")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.name).font(.headline).lineLimit(1)
                if entry.isBusy {
                    ProgressView(value: entry.progress, total: 100)
                    timeText.font(.caption)
                } else {
                    Text(stateLabel).font(.caption)
                }
            }
            .containerBackground(.clear, for: .widget)
        case .systemSmall:
            camera
                .overlay(alignment: .bottomLeading) { details(compact: true).padding(10) }
                .containerBackground(.black, for: .widget)
        case .systemMedium:
            HStack(spacing: 0) {
                camera.frame(maxWidth: .infinity)
                details(compact: false).padding(12).frame(width: 150, alignment: .leading)
            }
            .containerBackground(.black, for: .widget)
        default:
            VStack(spacing: 0) {
                camera.frame(maxHeight: .infinity)
                details(compact: false).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .containerBackground(.black, for: .widget)
        }
    }

    @ViewBuilder private var camera: some View {
        if let image = entry.image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .overlay(alignment: .topTrailing) {
                    // The picture is a snapshot, so say how old it is.
                    Text(entry.date, style: .time)
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(8)
                }
        } else {
            ZStack {
                Color(white: 0.12)
                Image(systemName: entry.signedOut ? "person.crop.circle.badge.questionmark" : "video.slash")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
    }

    private func details(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            if entry.signedOut {
                Text("Sign in to 3DVault").font(.caption.weight(.semibold))
            } else {
                Text(compact ? (entry.title ?? entry.name) : entry.name)
                    .font(compact ? .caption.weight(.semibold) : .headline).lineLimit(1)
                if !compact, let title = entry.title, entry.isBusy {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if entry.isBusy {
                    HStack {
                        Text("\(Int(entry.progress))%").font((compact ? Font.caption : .title3).weight(.bold).monospacedDigit())
                        if !compact, let l = entry.layer, let t = entry.totalLayers {
                            Spacer(minLength: 4)
                            Text("\(l)/\(t)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: entry.progress, total: 100).tint(.orange)
                    timeText.font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(stateLabel).font(.caption).foregroundStyle(entry.state == "failed" ? .red : .secondary)
                    if !compact, let m = entry.message, !m.isEmpty {
                        Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(compact ? 6 : 0)
        .background {
            if compact { RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.55)) }
        }
    }

    @ViewBuilder private var timeText: some View {
        if entry.state == "paused" {
            Text("Paused")
        } else if let end = entry.endDate, end > .now {
            // Counts down by itself between refreshes.
            Text("Done in \(end, style: .relative)")
        } else {
            Text(stateLabel)
        }
    }

    private var stateLabel: String {
        switch entry.state {
        case "printing": "Printing"
        case "preparing": "Preparing"
        case "paused": "Paused"
        case "finished": "Finished"
        case "failed": "Failed"
        case "idle": "Ready"
        default: "Offline"
        }
    }
}
