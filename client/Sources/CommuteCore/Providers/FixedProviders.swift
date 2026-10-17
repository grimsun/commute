import Foundation

/// Returns a fixed list of departures; for tests and previews.
public struct FixedTransitProvider: TransitProvider {
    public var departures: [TrainDeparture]
    public var source: TransitDataSource

    public init(departures: [TrainDeparture], source: TransitDataSource = .sample) {
        self.departures = departures
        self.source = source
    }

    public func departures(fromStation originID: String, toStation destinationID: String, after: Date, limit: Int) async throws -> TransitSnapshot {
        let filtered = departures
            .filter { $0.departureTime >= after }
            .sorted { $0.departureTime < $1.departureTime }
        return TransitSnapshot(departures: Array(filtered.prefix(limit)), source: source, fetchedAt: after)
    }
}

public struct FixedAccessProvider: StationAccessProvider {
    public var seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    public func travelTime(from: Coordinate, to: Coordinate, mode: AccessMode, bikeSpeedKph: Double) async throws -> TimeInterval {
        seconds
    }
}

public struct FixedTrafficProvider: TrafficProvider {
    public var eta: TimeInterval
    public var freeFlowETA: TimeInterval

    public init(eta: TimeInterval, freeFlowETA: TimeInterval) {
        self.eta = eta
        self.freeFlowETA = freeFlowETA
    }

    public func carETA(from: Coordinate, to: Coordinate, departure: Date) async throws -> TimeInterval {
        eta
    }

    public func freeFlowCarETA(from: Coordinate, to: Coordinate) async throws -> TimeInterval {
        freeFlowETA
    }
}
