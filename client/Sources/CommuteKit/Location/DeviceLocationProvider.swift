import CoreLocation
import Foundation

/// While-in-use location for departure detection. Asks once; if declined, it simply reports nothing.
@MainActor
public final class DeviceLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    /// Fixes older than this are too stale to tell whether the rider left.
    private static let maxAge: TimeInterval = 5 * 60

    private let manager = CLLocationManager()
    private var latest: CLLocation?
    private var listeners: [UUID: AsyncStream<LocationFix>.Continuation] = [:]

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
    }

    public func start() async {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if Self.isAuthorized(manager.authorizationStatus) {
            manager.startUpdatingLocation()
        }
    }

    public func currentLocation() async -> LocationFix? {
        guard let latest, -latest.timestamp.timeIntervalSinceNow < Self.maxAge else { return nil }
        return Self.fix(latest)
    }

    public func locationUpdates() async -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            let id = UUID()
            listeners[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in self.listeners[id] = nil }
            }
        }
    }

    private static func fix(_ location: CLLocation) -> LocationFix? {
        guard location.horizontalAccuracy >= 0 else { return nil }
        return LocationFix(
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            accuracy: location.horizontalAccuracy
        )
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Fires on creation too; only begin updates once access is actually granted.
        guard Self.isAuthorized(manager.authorizationStatus) else { return }
        Task { @MainActor in
            self.manager.startUpdatingLocation()
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.latest = location
            if let fix = Self.fix(location) {
                for listener in self.listeners.values {
                    listener.yield(fix)
                }
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        status == .authorizedAlways
        #endif
    }
}
