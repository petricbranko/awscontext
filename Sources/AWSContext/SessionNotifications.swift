import Foundation
import UserNotifications

/// Posts a notification when the active profile's SSO session expires; clicking it signs in again.
@MainActor
final class SessionNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onSignInRequested: (() -> Void)?

    private var notifiedProfile: String?
    private static let identifier = "session-expired"

    /// Notifications need a real app bundle; `swift run` builds don't have one.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `expiredProfile` is the active profile if it needs signing in, otherwise nil.
    func update(profile expiredProfile: String?) {
        guard expiredProfile != notifiedProfile else { return }
        notifiedProfile = expiredProfile
        guard let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        guard let expiredProfile else { return }

        let content = UNMutableNotificationContent()
        content.title = "AWS session expired"
        content.body = "Your SSO session for “\(expiredProfile)” has ended. Click to sign in again."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.onSignInRequested?()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
