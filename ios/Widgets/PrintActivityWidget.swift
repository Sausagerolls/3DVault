import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VaultWidgets: WidgetBundle {
    var body: some Widget {
        PrintActivityWidget()
        PrinterWidget()
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
                    Remaining(state: context.state).font(.title3.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.modelName).font(.headline).lineLimit(1)
                        PrintProgress(state: context.state)
                        Text(stateDetail(context.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: stateIcon(context.state)).foregroundStyle(stateTint(context.state))
            } compactTrailing: {
                Remaining(state: context.state).monospacedDigit().frame(maxWidth: 64)
            } minimal: {
                PrintProgress(state: context.state, circular: true)
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
                Remaining(state: context.state).font(.title2.monospacedDigit().bold())
            }
            PrintProgress(state: context.state)
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

/// Counts down to the estimated finish by itself while printing; otherwise shows the last percentage.
private struct Remaining: View {
    let state: PrintActivityAttributes.ContentState

    var body: some View {
        if state.state == "printing", let end = state.endDate, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(statePercent(state))
        }
    }
}

/// A progress bar the system advances on its own between the app's checks.
private struct PrintProgress: View {
    let state: PrintActivityAttributes.ContentState
    var circular = false

    var body: some View {
        Group {
            if state.state == "printing", let start = state.startDate, let end = state.endDate, start < end {
                if circular {
                    ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.circular)
                } else {
                    ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                }
            } else if circular {
                ProgressView(value: state.progress, total: 100).progressViewStyle(.circular)
            } else {
                ProgressView(value: state.progress, total: 100)
            }
        }
        .tint(stateTint(state))
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
        parts.append(s.endDate.map { "Done about \($0.formatted(date: .omitted, time: .shortened))" } ?? "Printing")
        return parts.joined(separator: " · ")
    }
}
