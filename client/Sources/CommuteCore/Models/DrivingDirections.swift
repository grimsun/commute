import Foundation

/// Links that open a maps app with driving directions between two places. Both are universal
/// links: they open the app when installed, and the website otherwise.
public struct DrivingDirections: Equatable, Sendable {
    public var from: Coordinate
    public var to: Coordinate

    public init(from: Coordinate, to: Coordinate) {
        self.from = from
        self.to = to
    }

    /// Both places need an address; `nil` otherwise.
    public init?(from: Place, to: Place) {
        guard let start = from.coordinate, let end = to.coordinate else { return nil }
        self.init(from: start, to: end)
    }

    public var appleMapsURL: URL {
        link("https://maps.apple.com/", [
            ("saddr", Self.text(from)),
            ("daddr", Self.text(to)),
            ("dirflg", "d")
        ])
    }

    public var googleMapsURL: URL {
        link("https://www.google.com/maps/dir/", [
            ("api", "1"),
            ("origin", Self.text(from)),
            ("destination", Self.text(to)),
            ("travelmode", "driving")
        ])
    }

    private func link(_ base: String, _ items: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    /// "37.791200,-122.413000": six decimals is about 10 cm.
    private static func text(_ coordinate: Coordinate) -> String {
        String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }
}
