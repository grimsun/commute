import Foundation
import MapKit

/// Door-to-station time from Apple Maps. MapKit has no cycling mode, so bike time is the
/// walking route's distance at the rider's speed; walk time is MapKit's own estimate.
@MainActor
public final class MapKitStationAccessProvider: StationAccessProvider {
    private struct Leg {
        let distance: CLLocationDistance
        let walkingTime: TimeInterval
    }

    private var legs: [String: Leg] = [:]

    public init() {}

    public func travelTime(from: Coordinate, to: Coordinate, mode: AccessMode, bikeSpeedKph: Double) async throws -> TimeInterval {
        let leg = try await leg(from: from, to: to)
        switch mode {
        case .walk:
            return leg.walkingTime
        case .bike:
            return StraightLineAccessProvider.estimate(distanceMeters: leg.distance, mode: .bike, bikeSpeedKph: bikeSpeedKph)
        }
    }

    private func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        // Walking routes do not change with time, so they are cached for the app's lifetime.
        let key = "\(from.cacheKey)->\(to.cacheKey)"
        if let cached = legs[key] {
            return cached
        }
        let route = try await MapKitRouting.route(from: from, to: to, transport: .walking)
        let leg = Leg(distance: route.distance, walkingTime: route.expectedTravelTime)
        legs[key] = leg
        return leg
    }
}
