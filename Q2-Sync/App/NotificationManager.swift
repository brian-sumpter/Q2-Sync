//
//  NotificationManager.swift
//  Q2-Sync › App
//
//  PURPOSE
//  Shows macOS notifications ("Q2 connected — sync now?", "Sync complete",
//  "Sync needs your review") and handles their buttons (Sync Now, Eject).
//
//  HOW IT FITS
//  `AutoSyncController` asks this to post notifications, and gets a
//  callback when you click a button. It uses Apple's UserNotifications
//  framework (`UNUserNotificationCenter`).
//
//  SWIFT NOTE
//  The notification center calls its delegate methods on a background
//  thread, so they're marked `nonisolated` and hop to the main actor
//  (`Task { @MainActor in … }`) before touching app state.
//

import Foundation
import UserNotifications

/// Buttons a notification can show.
enum NotificationAction: String {
    case syncNow = "SYNC_NOW"
    case eject = "EJECT"
    case open = "OPEN"
}

/// Posts notifications and reports button clicks.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    /// Called on the main actor when the user clicks a notification or one
    /// of its buttons.
    var onAction: ((NotificationAction) -> Void)?

    private let center = UNUserNotificationCenter.current()

    /// Category identifiers (which set of buttons a notification shows).
    private enum Category {
        static let connected = "Q2_CONNECTED"
        static let finished = "SYNC_FINISHED"
        static let review = "SYNC_REVIEW"
    }

    /// Registers the button sets and becomes the delegate.
    func configure() {
        center.delegate = self
        let sync = UNNotificationAction(identifier: NotificationAction.syncNow.rawValue, title: "Sync Now")
        let eject = UNNotificationAction(identifier: NotificationAction.eject.rawValue, title: "Eject")
        let open = UNNotificationAction(identifier: NotificationAction.open.rawValue, title: "Open Q2 Sync",
                                        options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.connected, actions: [sync], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.finished, actions: [eject], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.review, actions: [open], intentIdentifiers: []),
        ])
    }

    /// Asks macOS for permission to show notifications (once; macOS
    /// remembers the answer).
    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - Posting

    /// "Your Q2 is connected. Sync now?"
    func postConnected(deviceName: String) {
        post(title: "“\(deviceName)” Connected", body: "Sync it with your music now?",
             category: Category.connected, id: "connected")
    }

    /// A finished (or failed) automatic sync.
    func postFinished(title: String, body: String, offerEject: Bool) {
        post(title: title, body: body, category: offerEject ? Category.finished : Category.review, id: "finished")
    }

    /// A new firmware release is available.
    func postFirmware(title: String, body: String) {
        post(title: title, body: body, category: Category.review, id: "firmware")
    }

    /// An automatic sync stopped and is waiting for review.
    func postNeedsReview(reasons: [String]) {
        post(title: "Sync Needs Your Review", body: reasons.joined(separator: " "),
             category: Category.review, id: "review")
    }

    private func post(title: String, body: String, category: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        // Reusing the identifier replaces an older notification of the same kind.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Delegate

    /// Show notifications even while the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A notification or one of its buttons was clicked.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.actionIdentifier
        await MainActor.run {
            if let action = NotificationAction(rawValue: identifier) {
                onAction?(action)
            } else if identifier == UNNotificationDefaultActionIdentifier {
                // Clicking the notification itself just opens the app; only
                // the explicit "Sync Now" button starts a sync.
                onAction?(.open)
            }
        }
    }
}
