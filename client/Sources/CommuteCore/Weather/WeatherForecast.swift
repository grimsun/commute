import Foundation

/// The hourly weather at one place: the sky, the temperature, and the chance and amount of rain.
public struct WeatherForecast: Equatable, Sendable {
    public struct Hour: Equatable, Sendable {
        /// The hour runs from `start` to `start` + 1 h.
        public var start: Date
        /// Chance of more than 0.1 mm in the hour, 0–100.
        public var probability: Int
        public var millimeters: Double
        public var condition: WeatherCondition?
        /// Degrees Celsius.
        public var temperature: Double?
        public var isDaylight: Bool

        public init(start: Date, probability: Int, millimeters: Double, condition: WeatherCondition? = nil, temperature: Double? = nil, isDaylight: Bool = true) {
            self.start = start
            self.probability = probability
            self.millimeters = millimeters
            self.condition = condition
            self.temperature = temperature
            self.isDaylight = isDaylight
        }

        /// Wet enough to matter on a bike or on foot.
        public var isRainLikely: Bool {
            probability >= WeatherForecast.likelyProbability || millimeters >= WeatherForecast.likelyMillimeters
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

    /// The hour containing `date`.
    public func hour(at date: Date) -> Hour? {
        hours.first { $0.start <= date && date < $0.start.addingTimeInterval(3600) }
    }

    /// The wettest rainy hour overlapping `start...end`, if any.
    public func rain(from start: Date, to end: Date) -> Hour? {
        hours
            .filter { $0.isRainLikely && $0.start < max(end, start.addingTimeInterval(1)) && $0.start.addingTimeInterval(3600) > start }
            .max { ($0.probability, $0.millimeters) < ($1.probability, $1.millimeters) }
    }
}

/// The sky in broad strokes, from the WMO weather codes forecasts use.
public enum WeatherCondition: Equatable, Sendable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, snow, thunderstorm

    public init?(wmoCode: Int) {
        switch wmoCode {
        case 0: self = .clear
        case 1, 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51...57: self = .drizzle
        case 61, 63, 66, 80, 81: self = .rain
        case 65, 67, 82: self = .heavyRain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .thunderstorm
        default: return nil
        }
    }
}

/// The forecast for one of the day's four moments outside: leaving home, getting to work,
/// leaving work and getting home.
public struct WeatherMoment: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable, CaseIterable {
        case leaveHome, arriveWork, leaveWork, arriveHome
    }

    public var kind: Kind
    public var time: Date
    /// `nil` outside the forecast.
    public var hour: WeatherForecast.Hour?

    public var id: Kind { kind }

    public init(kind: Kind, time: Date, hour: WeatherForecast.Hour?) {
        self.kind = kind
        self.time = time
        self.hour = hour
    }
}

/// The forecasts at both ends of the commute.
public struct CommuteForecasts: Equatable, Sendable {
    public var home: WeatherForecast?
    public var work: WeatherForecast?

    public init(home: WeatherForecast? = nil, work: WeatherForecast? = nil) {
        self.home = home
        self.work = work
    }

    public func origin(for direction: Direction) -> WeatherForecast? {
        direction == .homeToWork ? home : work
    }

    public func destination(for direction: Direction) -> WeatherForecast? {
        direction == .homeToWork ? work : home
    }

    /// The day's four moments from its morning and evening plans: each trip's leave time with the
    /// forecast where it starts, and its door arrival with the forecast where it ends.
    public func moments(toWork: CommutePlan?, toHome: CommutePlan?) -> [WeatherMoment] {
        var moments: [WeatherMoment] = []
        for (plan, leave, arrive) in [(toWork, WeatherMoment.Kind.leaveHome, WeatherMoment.Kind.arriveWork), (toHome, .leaveWork, .arriveHome)] {
            guard let plan, let option = plan.train else { continue }
            let leaving = option.attempts.leaveAt
            let arriving = plan.doorArrival(for: option.train)
            moments.append(WeatherMoment(kind: leave, time: leaving, hour: origin(for: plan.direction)?.hour(at: leaving)))
            moments.append(WeatherMoment(kind: arrive, time: arriving, hour: destination(for: plan.direction)?.hour(at: arriving)))
        }
        return moments
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
    public static func warnings(for plan: CommutePlan, origin: WeatherForecast?, destination: WeatherForecast?) -> [RainWarning] {
        guard let option = plan.train else { return [] }
        let leave = option.attempts.leaveAt
        let legs: [(Leg, WeatherForecast?, Date, Date)] = [
            (.toStation, origin, leave, leave.addingTimeInterval(plan.accessTime)),
            (.fromStation, destination, option.train.arrivalTime, plan.doorArrival(for: option.train))
        ]
        return legs.compactMap { leg, forecast, start, end in
            guard let hour = forecast?.rain(from: start, to: end) else { return nil }
            return RainWarning(direction: plan.direction, leg: leg, time: max(start, hour.start), probability: hour.probability)
        }
    }
}
