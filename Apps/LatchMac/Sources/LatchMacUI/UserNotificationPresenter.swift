import AppKit
import UserNotifications

/// Delivers attention alerts as user notifications.
///
/// `UNUserNotificationCenter` needs a bundle identifier, so `make()` returns nil for the
/// SwiftPM preview, which has no bundle. The caller then runs without notifications rather
/// than trapping. Authorization is requested once, on the first alert, so simply launching
/// Latch does not raise a system prompt.
@MainActor
final class UserNotificationPresenter: NSObject, AttentionPresenting, UNUserNotificationCenterDelegate {
    var onAction: ((_ actionID: String, _ userInfo: [String: String]) -> Void)?

    private let center: UNUserNotificationCenter
    private var authorization: Task<Bool, Never>?

    /// Nil when this process cannot post notifications at all.
    static func make() -> UserNotificationPresenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UserNotificationPresenter(center: .current())
    }

    private init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func post(id: String, title: String, body: String, actions: [AttentionAction], userInfo: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        if !actions.isEmpty {
            let category = UNNotificationCategory(
                identifier: id, actions: actions.map {
                    UNNotificationAction(identifier: $0.id, title: $0.title,
                                         options: $0.isDestructive ? [.destructive] : [])
                }, intentIdentifiers: [], options: []
            )
            center.setNotificationCategories([category])
            content.categoryIdentifier = id
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = self.center
        Task { [weak self] in
            guard let self, await self.authorized() else { return }
            try? await center.add(request)
        }
    }

    func withdraw(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func authorized() async -> Bool {
        if let authorization { return await authorization.value }
        let center = self.center
        let task = Task { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
        authorization = task
        return await task.value
    }

    // MARK: Delegate

    /// Latch can be frontmost with the session in question scrolled out of sight or in
    /// another window, so a banner is still shown; the caller has already decided that the
    /// user cannot see it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        await MainActor.run { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.onAction?(action, userInfo)
        }
    }
}
