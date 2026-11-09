import Foundation
import UserNotifications

/// Standalone-mode alerts: local notifications scheduled from the timetable, re-planned with
/// live delays by background app refresh.
public struct LocalLeaveAlertScheduler: LeaveAlertScheduler {
    private static let idPrefix = "leave-"

    public init() {}

    public var schedulesOnDevice: Bool { true }

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func authorization() async -> AlertAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
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
            let content = Self.content(for: alert)
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: alert.fireDate)
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
        }
    }

    /// Five seconds: time to lock the phone and see it on the Lock Screen.
    public func showSoon(_ alert: LeaveAlert) async {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-alert", content: Self.content(for: alert), trigger: trigger))
    }

    private static func content(for alert: LeaveAlert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = "\(alert.commute.day)-\(alert.commute.direction.rawValue)"
        content.interruptionLevel = alert.kind == .leaveNow ? .timeSensitive : .active
        if alert.offersOnMyWay, let trainNumber = alert.trainNumber {
            content.categoryIdentifier = OnMyWay.category
            content.userInfo = OnMyWay.userInfo(commute: alert.commute, trainNumber: trainNumber)
        }
        return content
    }
}

/// The "On my way" button on get ready and leave now alerts: it opens the app, which starts that
/// trip like the card's button, so the Lock Screen countdown switches to the train.
enum OnMyWay {
    static let category = "trip"
    static let action = "on-my-way"

    static func userInfo(commute: CommuteKey, trainNumber: String) -> [String: Any] {
        ["commuteDay": commute.day, "direction": commute.direction.rawValue, "trainNumber": trainNumber]
    }

    static func trip(from userInfo: [AnyHashable: Any]) -> (commute: CommuteKey, trainNumber: String)? {
        guard let day = userInfo["commuteDay"] as? Int,
              let direction = (userInfo["direction"] as? String).flatMap(Direction.init(rawValue:)),
              let trainNumber = userInfo["trainNumber"] as? String else { return nil }
        return (CommuteKey(day: day, direction: direction), trainNumber)
    }
}

/// Shows leave alerts as banners even while the app is open, and handles their "On my way".
public final class LeaveAlertPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = LeaveAlertPresenter()

    /// Called on the main actor when "On my way" is tapped; set once at launch.
    @MainActor public var onMyWay: (@MainActor (CommuteKey, String) async -> Void)?

    /// Before the app finishes launching, so a tap that launched it is delivered here.
    public func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Foreground: iOS only lets an open app start the Lock Screen countdown.
        let onMyWay = UNNotificationAction(identifier: OnMyWay.action, title: "On my way", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "figure.walk"))
        center.setNotificationCategories([UNNotificationCategory(identifier: OnMyWay.category, actions: [onMyWay], intentIdentifiers: [])])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == OnMyWay.action,
              let trip = OnMyWay.trip(from: response.notification.request.content.userInfo) else { return }
        await startTrip(trip.commute, trainNumber: trip.trainNumber)
    }

    @MainActor private func startTrip(_ commute: CommuteKey, trainNumber: String) async {
        await onMyWay?(commute, trainNumber)
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
