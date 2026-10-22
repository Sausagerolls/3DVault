import ActivityKit
import Foundation

/// Live Activity for a print job. Shared by the app and the widget extension. The server
/// sends the same field names in its push payloads (see server/app/notify.py).
struct PrintActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// uploading | printing | paused | finished | failed | cancelled
        var state: String
        var progress: Double
        var remainingS: Int?
        var layer: Int?
        var totalLayers: Int?
        var error: String?
        /// Estimated start and end of printing, so the Live Activity can count down by itself.
        var startDate: Date?
        var endDate: Date?
    }

    var jobId: Int
    var modelId: Int
    var modelName: String
    var printerName: String
}
