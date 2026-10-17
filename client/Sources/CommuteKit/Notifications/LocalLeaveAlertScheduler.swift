import Foundation
import UserNotifications

/// Standalone-mode alerts: local notifications scheduled from the timetable.
/// They cannot follow delays; that is what server mode adds.
public struct LocalLeaveAlertScheduler: LeaveAlertScheduler {
    private static let idPrefix = "leave-"

    public init() {}

    public var schedulesOnDevice: Bool { true }

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func replaceAlerts(with alerts: [LeaveAlert]) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        var calendar = Calendar.caltrain
        calendar.locale = Locale(identifier: "en_US_POSIX")
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.threadIdentifier = "\(alert.commute.day)-\(alert.commute.direction.rawValue)"
            content.interruptionLevel = alert.kind == .leaveNow ? .timeSensitive : .active

            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: alert.fireDate)
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
        }
    }
}

/// Shows leave alerts as banners even while the app is open.
public final class LeaveAlertPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = LeaveAlertPresenter()

    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
