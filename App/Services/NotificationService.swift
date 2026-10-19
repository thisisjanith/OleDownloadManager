import Foundation
import UserNotifications

/// Posts completion/failure notifications. Permission is requested lazily, the first time there
/// is something to report, and a denial is respected silently.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let enabled: Bool
    private var authorizationRequested = false
    var onActivate: ((UUID) -> Void)?

    init(enabled: Bool) {
        self.enabled = enabled
        super.init()
        if enabled { UNUserNotificationCenter.current().delegate = self }
    }

    func post(title: String, body: String, id: UUID) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            var status = settings.authorizationStatus
            if status == .notDetermined, !authorizationRequested {
                authorizationRequested = true
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                status = granted ? .authorized : .denied
            }
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["downloadID": id.uuidString]
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let idString = response.notification.request.content.userInfo["downloadID"] as? String
        await MainActor.run {
            if let idString, let id = UUID(uuidString: idString) { self.onActivate?(id) }
        }
    }
}
