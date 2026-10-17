import Foundation

/// One commute on one day, e.g. Monday's morning trip.
public struct CommuteKey: Codable, Hashable, Sendable {
    /// yyyymmdd.
    public var day: Int
    public var direction: Direction

    public init(day: Int, direction: Direction) {
        self.day = day
        self.direction = direction
    }

    public init(date: Date, direction: Direction, calendar: Calendar = .caltrain) {
        self.init(day: DateKey.key(for: date, calendar: calendar), direction: direction)
    }

    var identifier: String { "\(day)-\(direction.rawValue)" }
}

public struct LeaveAlert: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case getReady, leaveNow, tooLate
    }

    public var id: String
    public var commute: CommuteKey
    public var kind: Kind
    public var fireDate: Date
    public var title: String
    public var body: String

    public init(commute: CommuteKey, kind: Kind, fireDate: Date, title: String, body: String) {
        self.id = "leave-\(commute.identifier)-\(kind.rawValue)"
        self.commute = commute
        self.kind = kind
        self.fireDate = fireDate
        self.title = title
        self.body = body
    }
}

/// Builds get ready / leave now / too late alerts for the coming commutes from the timetable,
/// so they fire even if the app is not opened.
public struct LeaveAlertPlanner: Sendable {
    /// iOS keeps at most 64 pending notifications per app.
    public static let maxAlerts = 60

    private let planner: CommutePlanning
    private let calendar: Calendar

    /// `planner` should not use a traffic provider; car ETAs are irrelevant here.
    public init(planner: CommutePlanning, calendar: Calendar = .caltrain) {
        self.planner = planner
        self.calendar = calendar
    }

    /// `picks` are trains the rider chose for specific commutes; their alerts follow those trains.
    public func alerts(profile: CommuteProfile, now: Date, days: Int = 7, skipping departed: Set<CommuteKey> = [], picks: [CommuteKey: String] = [:]) async -> [LeaveAlert] {
        var alerts: [LeaveAlert] = []
        let today = calendar.startOfDay(for: now)

        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  profile.commuteDays.contains(calendar.component(.weekday, from: day)) else { continue }

            for direction in Direction.allCases {
                let key = CommuteKey(date: day, direction: direction, calendar: calendar)
                guard !departed.contains(key) else { continue }
                let target = profile.targetLeave(for: direction).date(on: day, calendar: calendar)
                // Plan from well before the target so the target train is chosen, or from now if later.
                let planningTime = max(now, target.addingTimeInterval(-3 * 3600))
                guard let plan = try? await planner.plan(profile: profile, direction: direction, now: planningTime, pickedTripID: picks[key]),
                      let option = plan.train,
                      calendar.isDate(option.train.departureTime, inSameDayAs: day) else { continue }

                alerts += Self.alerts(for: option, plan: plan, key: key, includeGetReady: profile.prepLeadTimeMinutes > 0)
                    .filter { $0.fireDate > now }
            }
        }

        return Array(alerts.sorted { $0.fireDate < $1.fireDate }.prefix(Self.maxAlerts))
    }

    static func alerts(for option: TrainOption, plan: CommutePlan, key: CommuteKey, includeGetReady: Bool) -> [LeaveAlert] {
        let train = option.train
        let attempts = option.attempts
        let trainName = "\(train.service.displayName) \(train.trainNumber)"
        var alerts: [LeaveAlert] = []

        if includeGetReady {
            alerts.append(LeaveAlert(
                commute: key,
                kind: .getReady,
                fireDate: attempts.getReadyAt,
                title: "Get ready: \(trainName) at \(time(train.departureTime))",
                body: "Leave at \(time(attempts.leaveAt)) to reach \(plan.originStation.name) on time."
            ))
        }
        alerts.append(LeaveAlert(
            commute: key,
            kind: .leaveNow,
            fireDate: attempts.leaveAt,
            title: "Leave now for \(trainName)",
            body: "Departs \(plan.originStation.name) \(time(train.departureTime)), arrives \(plan.destinationStation.name) \(time(train.arrivalTime))."
        ))
        if let next = option.fallback {
            let nextLeave = plan.attempts(for: next).leaveAt
            alerts.append(LeaveAlert(
                commute: key,
                kind: .tooLate,
                fireDate: attempts.tooLateAt.addingTimeInterval(60),
                title: "Missed \(trainName)?",
                body: "Next: \(next.service.displayName) \(next.trainNumber) at \(time(next.departureTime)). Leave by \(time(nextLeave))."
            ))
        }
        return alerts
    }

    private static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: Calendar.caltrain.timeZone))
    }
}
