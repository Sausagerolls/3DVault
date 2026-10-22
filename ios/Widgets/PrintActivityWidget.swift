import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VaultWidgets: WidgetBundle {
    var body: some Widget {
        PrintActivityWidget()
    }
}

/// Lock Screen and Dynamic Island view of a running print.
struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(url(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.printerName, systemImage: "printer.fill")
                        .font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(statePercent(context.state)).font(.title3.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.modelName).font(.headline).lineLimit(1)
                        ProgressView(value: context.state.progress, total: 100).tint(stateTint(context.state))
                        Text(stateDetail(context.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: stateIcon(context.state)).foregroundStyle(stateTint(context.state))
            } compactTrailing: {
                Text(statePercent(context.state)).monospacedDigit()
            } minimal: {
                ProgressView(value: context.state.progress, total: 100)
                    .progressViewStyle(.circular)
                    .tint(stateTint(context.state))
            }
            .widgetURL(url(context))
        }
    }

    private func url(_ context: ActivityViewContext<PrintActivityAttributes>) -> URL? {
        URL(string: "threedvault://model/\(context.attributes.modelId)")
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<PrintActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: stateIcon(context.state)).foregroundStyle(stateTint(context.state))
                Text(context.attributes.modelName).font(.headline).lineLimit(1)
                Spacer()
                Text(statePercent(context.state)).font(.title2.monospacedDigit().bold())
            }
            ProgressView(value: context.state.progress, total: 100).tint(stateTint(context.state))
            HStack {
                Text(context.attributes.printerName)
                Spacer()
                Text(stateDetail(context.state))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private func statePercent(_ s: PrintActivityAttributes.ContentState) -> String { "\(Int(s.progress))%" }

private func stateIcon(_ s: PrintActivityAttributes.ContentState) -> String {
    switch s.state {
    case "finished": "checkmark.circle.fill"
    case "failed": "xmark.octagon.fill"
    case "paused": "pause.circle.fill"
    case "cancelled": "stop.circle.fill"
    default: "printer.fill"
    }
}

private func stateTint(_ s: PrintActivityAttributes.ContentState) -> Color {
    switch s.state {
    case "finished": .green
    case "failed", "cancelled": .red
    case "paused": .orange
    default: .orange
    }
}

private func stateDetail(_ s: PrintActivityAttributes.ContentState) -> String {
    switch s.state {
    case "finished": return "Finished. Clear the bed."
    case "failed": return s.error?.isEmpty == false ? s.error! : "Failed"
    case "cancelled": return "Stopped"
    case "paused": return "Paused"
    case "uploading": return "Sending to printer…"
    default:
        var parts: [String] = []
        if let l = s.layer, let t = s.totalLayers { parts.append("Layer \(l)/\(t)") }
        if let r = s.remainingS {
            let h = r / 3600, m = r % 3600 / 60
            parts.append(h > 0 ? "\(h)h \(m)m left" : "\(m)m left")
        }
        return parts.isEmpty ? "Printing" : parts.joined(separator: " · ")
    }
}
