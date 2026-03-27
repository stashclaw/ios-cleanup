import UserNotifications

/// Manages local push notifications for PhotoDuck.
/// Caseless enum — all methods are static, no instance state.
enum NotificationManager {

    private static let notificationIdentifier = "photoduck.newPhotos"
    private static let permissionRequestedKey = "photoduck.notificationPermissionRequested"

    // MARK: - Permission

    /// Requests notification permission if not already requested.
    /// Safe to call multiple times — no-ops after first prompt.
    @discardableResult
    static func requestPermissionIfNeeded() async -> Bool {
        guard !UserDefaults.standard.bool(forKey: permissionRequestedKey) else {
            return (try? await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized) ?? false
        }
        UserDefaults.standard.set(true, forKey: permissionRequestedKey)
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    // MARK: - Notification

    /// Posts a local notification telling the user about new photos to review.
    /// Called from BackgroundScanCacheWriter after a background scan finds new groups.
    static func scheduleNewPhotosNotification(newPhotoCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "PhotoDuck"
        content.body = "\(newPhotoCount) new photo\(newPhotoCount == 1 ? "" : "s") ready to review"
        content.sound = .default
        content.badge = NSNumber(value: newPhotoCount)

        // 1-second delay (minimum for UNTimeIntervalNotificationTrigger)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Cleanup

    /// Clears the app icon badge. Call on foreground open.
    static func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }

    /// Removes any pending "new photos" notification that hasn't fired yet.
    static func clearPendingNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [notificationIdentifier]
        )
    }
}
