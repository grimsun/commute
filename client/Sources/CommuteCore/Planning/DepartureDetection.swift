import Foundation

/// A device location with its accuracy radius in meters.
public struct LocationFix: Equatable, Sendable {
    public var coordinate: Coordinate
    public var accuracy: Double

    public init(coordinate: Coordinate, accuracy: Double) {
        self.coordinate = coordinate
        self.accuracy = accuracy
    }
}

/// Where the phone is, when the rider allows it. `nil` means unknown, never "at home".
public protocol LocationProviding: Sendable {
    /// Asks for permission if it has not been asked yet; starts updates if granted.
    func start() async
    func currentLocation() async -> LocationFix?
    /// New fixes as they arrive, so departure is noticed without waiting for a refresh.
    func locationUpdates() async -> AsyncStream<LocationFix>
}

/// Decides whether the rider has left for the trip on screen.
public enum DepartureDetection {
    /// Farther than this from the starting place counts as gone; covers a block or a big building.
    public static let leaveRadius: Double = 250
    /// Being away earlier than this before the target (e.g. a morning errand) is not "leaving".
    public static let window: TimeInterval = 2 * 3600

    /// Margin past the station that can only be explained by riding a train.
    public static let beyondStationMargin: Double = 1500

    /// How close the phone must be to where the timetable puts a train to count as riding it.
    public static let onTrainRadius: Double = 1500

    /// Near enough to a running train's position to be on it.
    public static func isOnTrain(at position: Coordinate, fix: LocationFix) -> Bool {
        position.distance(to: fix.coordinate) <= onTrainRadius + max(0, fix.accuracy)
    }

    /// Farther from the starting place than its station is, by a clear margin: on a train, not on the way.
    public static func isBeyondStation(origin: Coordinate, station: Coordinate, fix: LocationFix) -> Bool {
        origin.distance(to: fix.coordinate) > origin.distance(to: station) + beyondStationMargin + max(0, fix.accuracy)
    }

    /// Clearly away from `origin`: a vague fix must clear the radius by its own uncertainty.
    public static func isAway(from origin: Coordinate, fix: LocationFix) -> Bool {
        origin.distance(to: fix.coordinate) > leaveRadius + max(0, fix.accuracy)
    }

    /// Away from the starting place during the trip window, so the rider has set off.
    public static func hasLeft(origin: Coordinate, fix: LocationFix, targetLeave: Date, trainDeparture: Date, now: Date) -> Bool {
        guard now >= targetLeave.addingTimeInterval(-window), now <= trainDeparture else { return false }
        return isAway(from: origin, fix: fix)
    }
}
