import ActivityKit
import BackgroundTasks
import UIKit
import UserNotifications
import VaultKit

/// Follows this person's prints on the device itself, with no push service:
/// - a Live Activity that counts down to the estimated finish on its own, corrected
///   whenever the app gets to check the server;
/// - a local notification scheduled for the estimated finish time;
/// - a notification as soon as the app sees a print has finished or failed;
/// - background refresh, so iOS can let the app check now and then while closed.
@MainActor
final class PrintTracker: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PrintTracker()
    static let refreshTask = "com.3dvault.mac.refresh"

    private weak var state: AppState?
    private let notifiedKey = "printTracker.notified"

    func start(state: AppState) {
        self.state = state
        UNUserNotificationCenter.current().delegate = self
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func signedOut() async {
        for activity in Activity<PrintActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    private var client: APIClient? { state?.client ?? SharedConfig.client() }

    /// A print was just sent from this device.
    func track(_ job: PrintJob) {
        update(job)
        Task { await sync() }
    }

    /// Check the server for this person's prints and bring activities and notifications up to date.
    func sync() async {
        guard let client else { return }
        guard let active = try? await client.printJobs(active: true, mine: true) else { return }
        let running = active.filter { $0.state != "queued" }
        for job in running { update(job) }
        // Activities for jobs that are no longer running: find out how they ended.
        for activity in Activity<PrintActivityAttributes>.activities where !running.contains(where: { $0.id == activity.attributes.jobId }) {
            if let job = try? await client.printJob(activity.attributes.jobId) {
                await finish(job, activity: activity)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        scheduleRefresh()
    }

    private func content(_ job: PrintJob) -> PrintActivityAttributes.ContentState {
        let now = Date()
        var end: Date?
        var start: Date?
        if job.state == "printing", let r = job.remainingS, r > 0 {
            end = now.addingTimeInterval(TimeInterval(r))
            // Back-date the start so a timer-driven progress bar begins at the real progress.
            let p = max(min(job.progress / 100, 0.99), 0)
            start = now.addingTimeInterval(-TimeInterval(r) * p / max(1 - p, 0.01))
        }
        return .init(state: job.state, progress: job.progress, remainingS: job.remainingS, layer: job.layer,
                     totalLayers: job.totalLayers, error: job.error, startDate: start, endDate: end)
    }

    private func update(_ job: PrintJob) {
        let c = content(job)
        if let activity = Activity<PrintActivityAttributes>.activities.first(where: { $0.attributes.jobId == job.id }) {
            Task { await activity.update(.init(state: c, staleDate: c.endDate?.addingTimeInterval(600))) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            let attributes = PrintActivityAttributes(jobId: job.id, modelId: job.modelId ?? 0, modelName: job.modelName, printerName: job.machineName)
            _ = try? Activity.request(attributes: attributes, content: .init(state: c, staleDate: c.endDate?.addingTimeInterval(600)))
        }
        scheduleETA(job, at: c.endDate)
    }

    private func finish(_ job: PrintJob, activity: Activity<PrintActivityAttributes>) async {
        let c = content(job)
        await activity.end(.init(state: c, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(3 * 3600)))
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["job-\(job.id)-eta"])
        guard ["finished", "failed"].contains(job.state), !alreadyNotified(job.id) else { return }
        let n = UNMutableNotificationContent()
        n.title = job.state == "finished" ? "Print finished" : "Print failed"
        n.body = job.state == "finished"
            ? "\(job.modelName) is done on \(job.machineName). Clear the bed for the next print."
            : "\(job.modelName) stopped on \(job.machineName). \(job.error)"
        n.sound = .default
        n.userInfo = ["modelId": job.modelId ?? 0]
        n.threadIdentifier = "printer-\(job.machineId)"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "job-\(job.id)-end", content: n, trigger: nil))
        markNotified(job.id)
    }

    /// "Should be finished about now", replaced each time the estimate changes.
    private func scheduleETA(_ job: PrintJob, at date: Date?) {
        let id = "job-\(job.id)-eta"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let date, date.timeIntervalSinceNow > 60 else { return }
        let n = UNMutableNotificationContent()
        n.title = "Print should be finished"
        n.body = "\(job.modelName) on \(job.machineName) should be done about now. Open 3DVault to check."
        n.sound = .default
        n.userInfo = ["modelId": job.modelId ?? 0]
        n.threadIdentifier = "printer-\(job.machineId)"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: n, trigger: trigger))
    }

    private func alreadyNotified(_ id: Int) -> Bool {
        (UserDefaults.standard.array(forKey: notifiedKey) as? [Int] ?? []).contains(id)
    }

    private func markNotified(_ id: Int) {
        var ids = UserDefaults.standard.array(forKey: notifiedKey) as? [Int] ?? []
        ids.append(id)
        UserDefaults.standard.set(Array(ids.suffix(200)), forKey: notifiedKey)
    }

    /// Ask iOS to wake the app to check again while prints are running. iOS decides when.
    func scheduleRefresh() {
        guard !Activity<PrintActivityAttributes>.activities.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    #if DEBUG
    /// Simulator testing: VAULT_TEST_ACTIVITY=1 shows a pretend print in the Dynamic Island.
    func testActivity() {
        guard ProcessInfo.processInfo.environment["VAULT_TEST_ACTIVITY"] == "1" else { return }
        let attributes = PrintActivityAttributes(jobId: -1, modelId: 0, modelName: "3DBenchy", printerName: "A1 mini")
        let content = PrintActivityAttributes.ContentState(state: "printing", progress: 42, remainingS: 1980, layer: 63, totalLayers: 150,
                                                           startDate: .now.addingTimeInterval(-1430), endDate: .now.addingTimeInterval(1980))
        _ = try? Activity.request(attributes: attributes, content: .init(state: content, staleDate: nil))
    }
    #endif

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let modelId = response.notification.request.content.userInfo["modelId"] as? Int
        await MainActor.run {
            if let modelId, modelId > 0 { state?.openModel = modelId }
        }
    }
}
