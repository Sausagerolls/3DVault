import AlarmKit
import Foundation
import SwiftUI
import VaultKit

struct PrintAlarmData: AlarmMetadata {}

/// Real alarms for the estimated finish of a print. These ring through silent mode and Focus,
/// unlike the finish notification. The estimate moves during a print, so each check of the
/// server moves the alarm with it.
@MainActor
@Observable
final class PrintAlarms {
    static let shared = PrintAlarms()

    struct Entry: Codable {
        let id: UUID
        let title: String
        /// When it rings. Nil while the print is paused, when the finish time is unknown.
        var date: Date?
    }

    enum AlarmError: LocalizedError {
        case notAllowed
        var errorDescription: String? { "Allow alarms for 3DVault in the Settings app, then try again." }
    }

    private static let key = "printAlarms"
    /// Smaller changes to the estimate than this aren't worth rescheduling for.
    private static let tolerance: TimeInterval = 120

    private(set) var entries: [Int: Entry] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key) }
    }

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key)
        entries = saved.flatMap { try? JSONDecoder().decode([Int: Entry].self, from: $0) } ?? [:]
    }

    func add(jobId: Int, modelName: String, at date: Date) async throws {
        var state = AlarmManager.shared.authorizationState
        if state == .notDetermined { state = try await AlarmManager.shared.requestAuthorization() }
        guard state == .authorized else { throw AlarmError.notAllowed }
        var entry = Entry(id: UUID(), title: "\(modelName) should be done", date: date)
        try await schedule(entry, at: date)
        entry.date = date
        entries[jobId] = entry
    }

    func remove(jobId: Int) {
        guard let entry = entries.removeValue(forKey: jobId) else { return }
        try? AlarmManager.shared.cancel(id: entry.id)
    }

    func removeAll() {
        for id in Array(entries.keys) { remove(jobId: id) }
    }

    /// Bring the alarms in line with how their prints are going.
    func sync(client: APIClient) async {
        for (jobId, var entry) in entries {
            // The alarm has rung. Don't set another one if the print is running late.
            if let date = entry.date, date < .now {
                entries[jobId] = nil
                continue
            }
            guard let job = try? await client.printJob(jobId) else { continue }
            switch job.state {
            case "printing":
                guard let r = job.remainingS, r > 60 else { continue }
                let end = Date.now.addingTimeInterval(TimeInterval(r))
                if let date = entry.date, abs(date.timeIntervalSince(end)) < Self.tolerance { continue }
                try? AlarmManager.shared.cancel(id: entry.id)
                guard (try? await schedule(entry, at: end)) != nil else { continue }
                entry.date = end
                entries[jobId] = entry
            case "paused":
                guard entry.date != nil else { continue }
                try? AlarmManager.shared.cancel(id: entry.id)
                entry.date = nil
                entries[jobId] = entry
            case "finished":
                // Finished early: leave the alarm, since it's there to bring someone to the printer.
                entries[jobId] = nil
            case "failed", "cancelled":
                remove(jobId: jobId)
            default:
                continue
            }
        }
    }

    private func schedule(_ entry: Entry, at date: Date) async throws {
        let title = LocalizedStringResource(stringLiteral: entry.title)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(title: title, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
        }
        let attributes = AlarmAttributes<PrintAlarmData>(presentation: AlarmPresentation(alert: alert), tintColor: .orange)
        _ = try await AlarmManager.shared.schedule(id: entry.id, configuration: .alarm(schedule: .fixed(date), attributes: attributes))
    }
}
