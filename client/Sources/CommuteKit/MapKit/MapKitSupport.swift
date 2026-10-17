import CoreLocation
import MapKit

extension Coordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Rounded to roughly 10 m so nearby requests share cache entries.
    var cacheKey: String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}

extension MKMapItem {
    static func at(_ coordinate: Coordinate) -> MKMapItem {
        if #available(iOS 26, macOS 26, *) {
            return MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate.clLocationCoordinate))
    }

    var coordinate: Coordinate {
        if #available(iOS 26, macOS 26, *) {
            return Coordinate(location.coordinate)
        }
        return Coordinate(placemark.coordinate)
    }

    var addressSubtitle: String {
        if #available(iOS 26, macOS 26, *) {
            return address?.shortAddress ?? address?.fullAddress ?? ""
        }
        return placemark.title ?? ""
    }
}

enum MapKitRouting {
    @MainActor
    static func route(from: Coordinate, to: Coordinate, transport: MKDirectionsTransportType, departure: Date? = nil) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = .at(from)
        request.destination = .at(to)
        request.transportType = transport
        request.departureDate = departure
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw MKError(.directionsNotFound)
        }
        return route
    }
}
