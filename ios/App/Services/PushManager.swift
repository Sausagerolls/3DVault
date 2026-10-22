import ActivityKit
import UIKit
import UserNotifications
import VaultKit

/// Registers this device for print notifications and keeps the server told about
/// Live Activity tokens, so it can start, update and end the print Live Activity.
@MainActor
final class PushManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushManager()

    #if DEBUG
    static let environment = "sandbox"
    #else
    static let environment = "production"
    #endif

    private weak var state: AppState?
    private var deviceToken: String?
    private var startToken: String?
    private var watching = false

    /// Call once signed in.
    func start(state: AppState) {
        self.state = state
        UNUserNotificationCenter.current().delegate = self
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
        guard !watching else { return }
        watching = true
        Task {
            for await data in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                startToken = data.hex
                await upload()
            }
        }
        Task {
            // Activities started by a push or by this app: send their update tokens to the server.
            for await activity in Activity<PrintActivityAttributes>.activityUpdates {
                watch(activity)
            }
        }
        for activity in Activity<PrintActivityAttributes>.activities { watch(activity) }
    }

    func signedOut() async {
        if let token = deviceToken { try? await state?.client?.unregisterPushDevice(token: token) }
        for activity in Activity<PrintActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func didRegister(_ token: Data) {
        deviceToken = token.hex
        Task { await upload() }
    }

    private func upload() async {
        guard let token = deviceToken, let client = state?.client else { return }
        try? await client.registerPushDevice(token: token, environment: Self.environment, startToken: startToken)
    }

    private func watch(_ activity: Activity<PrintActivityAttributes>) {
        let jobId = activity.attributes.jobId
        Task {
            for await data in activity.pushTokenUpdates {
                try? await state?.client?.registerLiveActivity(jobId: jobId, token: data.hex, environment: Self.environment)
            }
        }
    }

    /// Start the Live Activity straight away when this device sends a print that starts now.
    func printStarted(_ job: PrintJob) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              !Activity<PrintActivityAttributes>.activities.contains(where: { $0.attributes.jobId == job.id }) else { return }
        let attributes = PrintActivityAttributes(jobId: job.id, modelId: job.modelId ?? 0, modelName: job.modelName, printerName: job.machineName)
        let content = PrintActivityAttributes.ContentState(state: "uploading", progress: 0)
        _ = try? Activity.request(attributes: attributes, content: .init(state: content, staleDate: nil), pushType: .token)
    }

    #if DEBUG
    /// Simulator testing: VAULT_TEST_ACTIVITY=1 shows a pretend print in the Dynamic Island.
    func testActivity() {
        guard ProcessInfo.processInfo.environment["VAULT_TEST_ACTIVITY"] == "1" else { return }
        let attributes = PrintActivityAttributes(jobId: -1, modelId: 0, modelName: "3DBenchy", printerName: "A1 mini")
        let content = PrintActivityAttributes.ContentState(state: "printing", progress: 42, remainingS: 1980, layer: 63, totalLayers: 150)
        do {
            _ = try Activity.request(attributes: attributes, content: .init(state: content, staleDate: nil))
        } catch {
            print("test activity failed: \(error)")
        }
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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push registration failed: \(error.localizedDescription)")
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
