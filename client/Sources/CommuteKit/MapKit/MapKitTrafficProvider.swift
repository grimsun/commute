import Foundation
import MapKit

/// Car ETAs from Apple Maps, with a free-flow baseline taken from a 3 AM departure.
@MainActor
public final class MapKitTrafficProvider: TrafficProvider {
    private struct Cached {
        let value: TimeInterval
        let cachedAt: Date
    }

    private let etaTTL: TimeInterval
    private let calendar: Calendar
    private var etaCache: [String: Cached] = [:]
    private var freeFlowCache: [String: TimeInterval] = [:]

    public init(etaTTL: TimeInterval = 120, calendar: Calendar = .caltrain) {
        self.etaTTL = etaTTL
        self.calendar = calendar
    }

    public func carETA(from: Coordinate, to: Coordinate, departure: Date) async throws -> TimeInterval {
        let key = "\(from.cacheKey)->\(to.cacheKey)"
        if let cached = etaCache[key], departure.timeIntervalSince(cached.cachedAt) < etaTTL {
            return cached.value
        }
        let eta = try await MapKitRouting.route(from: from, to: to, transport: .automobile, departure: departure).expectedTravelTime
        etaCache[key] = Cached(value: eta, cachedAt: departure)
        return eta
    }

    public func freeFlowCarETA(from: Coordinate, to: Coordinate) async throws -> TimeInterval {
        let key = "\(from.cacheKey)->\(to.cacheKey)"
        if let cached = freeFlowCache[key] {
            return cached
        }
        let eta = try await MapKitRouting.route(from: from, to: to, transport: .automobile, departure: nextQuietHour()).expectedTravelTime
        freeFlowCache[key] = eta
        return eta
    }

    private func nextQuietHour() -> Date {
        let now = Date()
        let today = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}
