import Foundation
import MapKit

public enum MapKitTrafficProviderError: Error, Equatable {
    case noRoute
    case noMapItem(String)
}

public actor MapKitTrafficProvider: TrafficProvider {
    private struct RouteKey: Hashable {
        let from: String
        let to: String
        let referenceMinuteBucket: Int
        let kind: Int
    }

    private struct CachedETA {
        let value: TimeInterval
        let cachedAt: Date
    }

    private let etaCacheTTL: TimeInterval
    private var mapItemCache: [String: MKMapItem] = [:]
    private var etaCache: [RouteKey: CachedETA] = [:]
    private var latestCarETA: TimeInterval

    public init(
        normalETA: TimeInterval = 35 * 60,
        etaCacheTTL: TimeInterval = 45
    ) {
        self.latestCarETA = normalETA
        self.etaCacheTTL = etaCacheTTL
    }

    public func carETA(
        from: String,
        to: String,
        departureOrArrival: DepartureTimeReference
    ) async throws -> TimeInterval {
        let now = Date()
        let key = cacheKey(from: from, to: to, reference: departureOrArrival)
        if let cached = etaCache[key], now.timeIntervalSince(cached.cachedAt) <= etaCacheTTL {
            latestCarETA = cached.value
            return cached.value
        }

        do {
            let source = try await resolveMapItem(query: from)
            let destination = try await resolveMapItem(query: to)

            let request = MKDirections.Request()
            request.source = source
            request.destination = destination
            request.transportType = .automobile

            switch departureOrArrival {
            case let .leaveAt(date):
                request.departureDate = date
            case let .arriveBy(date):
                request.arrivalDate = date
            }

            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                throw MapKitTrafficProviderError.noRoute
            }

            let eta = route.expectedTravelTime
            latestCarETA = eta
            etaCache[key] = CachedETA(value: eta, cachedAt: now)
            return eta
        } catch {
            // Keep planner resilient if live traffic is unavailable or addresses are not resolvable.
            let fallback = latestCarETA
            etaCache[key] = CachedETA(value: fallback, cachedAt: now)
            return fallback
        }
    }

    public func baselineCarETA(for direction: Direction, at: Date) async throws -> TimeInterval {
        // v1 policy: treat current conditions as normal baseline.
        latestCarETA
    }

    private func resolveMapItem(query: String) async throws -> MKMapItem {
        let normalized = normalize(query)
        if let cached = mapItemCache[normalized] {
            return cached
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address

        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw MapKitTrafficProviderError.noMapItem(query)
        }
        mapItemCache[normalized] = item
        return item
    }

    private func cacheKey(
        from: String,
        to: String,
        reference: DepartureTimeReference
    ) -> RouteKey {
        let (date, kind): (Date, Int) = {
            switch reference {
            case let .leaveAt(date):
                return (date, 0)
            case let .arriveBy(date):
                return (date, 1)
            }
        }()
        let minuteBucket = Int(date.timeIntervalSince1970 / 60)
        return RouteKey(
            from: normalize(from),
            to: normalize(to),
            referenceMinuteBucket: minuteBucket,
            kind: kind
        )
    }

    private func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
