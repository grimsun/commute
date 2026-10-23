import Foundation

/// Which trip is current. A trip stays current for four hours after its target leave time,
/// so a missed train rolls to later ones; then the app moves on to the next trip.
public enum CommuteWindow {
    public static let rolloverInterval: TimeInterval = 4 * 3600

    /// Today's target leave time, or tomorrow's once today's window has passed.
    public static func targetLeave(for direction: Direction, profile: CommuteProfile, now: Date, calendar: Calendar = .caltrain) -> Date {
        let time = profile.targetLeave(for: direction)
        let today = time.date(on: now, calendar: calendar)
        // A late evening trip keeps its remaining four-hour window across midnight.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) {
            let previous = time.date(on: yesterday, calendar: calendar)
            if now >= previous && now.timeIntervalSince(previous) < rolloverInterval {
                return previous
            }
        }
        guard now.timeIntervalSince(today) >= rolloverInterval,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return today
        }
        return time.date(on: tomorrow, calendar: calendar)
    }

    /// The trip in `direction` that `targetLeave` points at.
    public static func key(for direction: Direction, profile: CommuteProfile, now: Date, calendar: Calendar = .caltrain) -> CommuteKey {
        CommuteKey(date: targetLeave(for: direction, profile: profile, now: now, calendar: calendar), direction: direction, calendar: calendar)
    }

    /// The trip whose target (or rollover window) comes first: morning until four hours after
    /// the morning target, then evening until four hours after the evening target, then tomorrow morning.
    public static func activeDirection(profile: CommuteProfile, now: Date, calendar: Calendar = .caltrain) -> Direction {
        let toWork = targetLeave(for: .homeToWork, profile: profile, now: now, calendar: calendar)
        let toHome = targetLeave(for: .workToHome, profile: profile, now: now, calendar: calendar)
        return toWork <= toHome ? .homeToWork : .workToHome
    }

    /// How long before a target leave time commute mode takes over from schedule mode.
    public static let commuteLead: TimeInterval = 2 * 3600

    /// Commute mode fits from two hours before a target leave time until its four-hour window ends,
    /// on commute days that aren't holidays; any other time the app opens in schedule mode.
    public static func isCommuteTime(profile: CommuteProfile, now: Date, isHoliday: Bool = false, calendar: Calendar = .caltrain) -> Bool {
        guard !isHoliday else { return false }
        return Direction.allCases.contains { direction in
            let target = targetLeave(for: direction, profile: profile, now: now, calendar: calendar)
            let weekday = calendar.component(.weekday, from: target)
            return profile.commuteDays.contains(weekday)
                && now >= target.addingTimeInterval(-commuteLead)
                && now < target.addingTimeInterval(rolloverInterval)
        }
    }
}
