import Foundation

/// Source of train departures: the downloaded timetable, the server, or a sample for previews.
public protocol TransitProvider: Sendable {
    /// Trains that stop at `originID` and later at `destinationID`, departing at or after `after`,
    /// sorted by predicted departure. Cancelled trains are included and flagged.
    func departures(fromStation originID: String, toStation destinationID: String, after: Date, limit: Int) async throws -> TransitSnapshot
}

/// Door-to-station travel time; used to suggest the minutes the rider configures.
public protocol StationAccessProvider: Sendable {
    func travelTime(from: Coordinate, to: Coordinate, mode: AccessMode, bikeSpeedKph: Double) async throws -> TimeInterval
}

public protocol TrafficProvider: Sendable {
    func carETA(from: Coordinate, to: Coordinate, departure: Date) async throws -> TimeInterval
    /// Travel time without traffic, used as the "good traffic" baseline.
    func freeFlowCarETA(from: Coordinate, to: Coordinate) async throws -> TimeInterval
}

/// Delivers get ready / leave now alerts. Standalone: local notifications. Server mode: the
/// server pushes, so the app schedules nothing.
public protocol LeaveAlertScheduler: Sendable {
    /// Whether this scheduler shows alerts on the phone itself.
    var schedulesOnDevice: Bool { get }
    func requestAuthorization() async -> Bool
    /// Replaces every previously scheduled alert with `alerts`.
    func replaceAlerts(with alerts: [LeaveAlert]) async
}

public struct NoopLeaveAlertScheduler: LeaveAlertScheduler {
    public init() {}

    public var schedulesOnDevice: Bool { false }
    public func requestAuthorization() async -> Bool { true }
    public func replaceAlerts(with alerts: [LeaveAlert]) async {}
}

/// Estimates access time from straight-line distance; the fallback when routing is unavailable.
public struct StraightLineAccessProvider: StationAccessProvider {
    /// Street routes are rarely straight; this inflates crow-flies distance to a typical route.
    public static let detourFactor = 1.3
    public static let walkingSpeedKph = 4.8

    public init() {}

    public func travelTime(from: Coordinate, to: Coordinate, mode: AccessMode, bikeSpeedKph: Double) async throws -> TimeInterval {
        Self.estimate(distanceMeters: from.distance(to: to) * Self.detourFactor, mode: mode, bikeSpeedKph: bikeSpeedKph)
    }

    public static func estimate(distanceMeters: Double, mode: AccessMode, bikeSpeedKph: Double) -> TimeInterval {
        let kph = mode == .bike ? max(bikeSpeedKph, 1) : walkingSpeedKph
        return distanceMeters / (kph * 1000 / 3600)
    }
}
