import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.lirriel.dragonlair", category: "notifications")

/// When an import finishes while the app is in the background, iOS can't show its confirmation
/// for deleting the originals. This posts a notification instead: "Delete" opens the app and
/// asks iOS to delete them, "Keep" leaves them in Photos.
@MainActor
final class ImportNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "importDone"
    static let deleteAction = "delete"
    static let keepAction = "keep"
    /// The screenshots to delete go in the notification, so "Delete" still works if iOS closed
    /// the app (and lost the import list) in the meantime.
    nonisolated static let assetIDsKey = "assetIDs"
    private static let requestID = "importDone.delete"

    weak var queue: ImportQueue?

    /// Call from the app's init, before launch finishes, so a tap that launches the app arrives.
    func register(queue: ImportQueue) {
        self.queue = queue
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let delete = UNNotificationAction(identifier: Self.deleteAction, title: "Delete",
                                          options: [.destructive, .foreground])
        let keep = UNNotificationAction(identifier: Self.keepAction, title: "Keep")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [delete, keep], intentIdentifiers: []),
        ])
    }

    /// Asks once for permission. Only shows a prompt while the app is on screen.
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        log.info("Notifications \(granted ? "allowed" : "not allowed", privacy: .public)")
    }

    static func body(count: Int) -> String {
        let noun = count == 1 ? "screenshot is" : "screenshots are"
        return "\(count) \(noun) now in your collection. Delete the originals from Photos?"
    }

    /// Replaces any earlier prompt, so there's only ever one waiting.
    static func postDeletePrompt(assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Import finished"
        content.body = body(count: assetIDs.count)
        content.categoryIdentifier = category
        content.userInfo = [assetIDsKey: assetIDs]
        content.sound = .default
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("Couldn't post the delete prompt: \(error, privacy: .public)") }
        }
    }

    /// Once the originals are dealt with in the app, the prompt is out of date.
    static func removeDeletePrompt() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let ids = response.notification.request.content.userInfo[Self.assetIDsKey] as? [String] ?? []
        await MainActor.run {
            switch action {
            case Self.deleteAction, UNNotificationDefaultActionIdentifier:
                log.info("Delete prompt accepted for \(ids.count) screenshot(s)")
                queue?.requestDeletion(of: ids)
            case Self.keepAction:
                log.info("Delete prompt declined")
                queue?.cancelPendingDeletion()
            default: break
            }
        }
    }

    /// The app is on screen, so iOS's own confirmation is shown instead.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
