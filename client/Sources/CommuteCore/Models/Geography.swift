import Foundation

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in meters (haversine).
    public func distance(to other: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// A user-chosen location such as home or work.
public struct Place: Codable, Hashable, Sendable {
    public var name: String
    public var coordinate: Coordinate?

    public init(name: String, coordinate: Coordinate?) {
        self.name = name
        self.coordinate = coordinate
    }

    /// No address given yet.
    public static let unset = Place(name: "", coordinate: nil)

    public var isSet: Bool { coordinate != nil }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case homeToWork
    case workToHome

    public var reversed: Direction {
        self == .homeToWork ? .workToHome : .homeToWork
    }
}

/// How the rider gets between a place and its station.
public enum AccessMode: String, Codable, CaseIterable, Sendable {
    case bike
    case walk
}

/// A wall-clock time in the Caltrain time zone, independent of date.
public struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init(date: Date, calendar: Calendar = .caltrain) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    public func date(on day: Date, calendar: Calendar = .caltrain) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start) ?? start
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

extension Calendar {
    /// Caltrain schedules are published in Pacific time regardless of where the phone is.
    public static var caltrain: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }
}
