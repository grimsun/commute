import Foundation

/// The hourly chance and amount of rain at one place.
public struct RainForecast: Equatable, Sendable {
    public struct Hour: Equatable, Sendable {
        /// The hour runs from `start` to `start` + 1 h.
        public var start: Date
        /// Chance of more than 0.1 mm in the hour, 0–100.
        public var probability: Int
        public var millimeters: Double

        public init(start: Date, probability: Int, millimeters: Double) {
            self.start = start
            self.probability = probability
            self.millimeters = millimeters
        }

        /// Wet enough to matter on a bike or on foot.
        public var isRainLikely: Bool {
            probability >= RainForecast.likelyProbability || millimeters >= RainForecast.likelyMillimeters
        }
    }

    public static let likelyProbability = 50
    public static let likelyMillimeters = 0.3

    public var hours: [Hour]
    public var fetchedAt: Date

    public init(hours: [Hour], fetchedAt: Date) {
        self.hours = hours
        self.fetchedAt = fetchedAt
    }

    /// The wettest rainy hour overlapping `start...end`, if any.
    public func rain(from start: Date, to end: Date) -> Hour? {
        hours
            .filter { $0.isRainLikely && $0.start < max(end, start.addingTimeInterval(1)) && $0.start.addingTimeInterval(3600) > start }
            .max { ($0.probability, $0.millimeters) < ($1.probability, $1.millimeters) }
    }
}

/// The forecasts at both ends of the commute.
public struct CommuteForecasts: Equatable, Sendable {
    public var home: RainForecast?
    public var work: RainForecast?

    public init(home: RainForecast? = nil, work: RainForecast? = nil) {
        self.home = home
        self.work = work
    }

    public func origin(for direction: Direction) -> RainForecast? {
        direction == .homeToWork ? home : work
    }

    public func destination(for direction: Direction) -> RainForecast? {
        direction == .homeToWork ? work : home
    }

    /// Rain on `plan`'s ways to and from its stations.
    public func warnings(for plan: CommutePlan) -> [RainWarning] {
        RainWarning.warnings(for: plan, origin: origin(for: plan.direction), destination: destination(for: plan.direction))
    }
}

/// Rain expected on one of a trip's outdoor legs: from the door to the station, or from the
/// station to the door.
public struct RainWarning: Equatable, Sendable {
    public enum Leg: Sendable {
        case toStation
        case fromStation
    }

    public var direction: Direction
    public var leg: Leg
    /// When the rider is out in it: the leg's start, or the rainy hour's if later.
    public var time: Date
    public var probability: Int

    public init(direction: Direction, leg: Leg, time: Date, probability: Int) {
        self.direction = direction
        self.leg = leg
        self.time = time
        self.probability = probability
    }

    /// Checks the plan's train: the ride to the station with the origin's forecast, the ride
    /// home or to work with the destination's. At most one warning per leg.
    public static func warnings(for plan: CommutePlan, origin: RainForecast?, destination: RainForecast?) -> [RainWarning] {
        guard let option = plan.train else { return [] }
        let leave = option.attempts.leaveAt
        let legs: [(Leg, RainForecast?, Date, Date)] = [
            (.toStation, origin, leave, leave.addingTimeInterval(plan.accessTime)),
            (.fromStation, destination, option.train.arrivalTime, plan.doorArrival(for: option.train))
        ]
        return legs.compactMap { leg, forecast, start, end in
            guard let hour = forecast?.rain(from: start, to: end) else { return nil }
            return RainWarning(direction: plan.direction, leg: leg, time: max(start, hour.start), probability: hour.probability)
        }
    }
}
