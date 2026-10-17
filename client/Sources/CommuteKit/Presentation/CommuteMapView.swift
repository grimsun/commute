import MapKit
import SwiftUI

/// Map behind the sheet: home, work, both stations, the access legs and the rail segment.
struct CommuteMapView: View {
    let profile: CommuteProfile
    let isTemporaryRoute: Bool
    /// Height covered by the sheet, so the route is framed in the visible part.
    let bottomInset: CGFloat
    /// Changes when the route should be re-framed, e.g. after the rider panned away and tapped refresh.
    var recenterRequest = 0

    /// A place this close to its station is drawn as one pin, without a ride leg.
    private static let mergeDistance: Double = 200

    @State private var position: MapCameraPosition = .automatic

    private var homeStation: Station? { StationCatalog.station(id: profile.homeStationID) }
    private var workStation: Station? { StationCatalog.station(id: profile.workStationID) }

    private struct Pin: Identifiable {
        let id: String
        let title: String
        let coordinate: Coordinate
        let symbol: String
        let color: Color
    }

    var body: some View {
        Map(position: $position) {
            if let railLine {
                MapPolyline(coordinates: railLine)
                    .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(accessLegs.indices, id: \.self) { index in
                MapPolyline(coordinates: accessLegs[index])
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 6]))
            }
            ForEach(pins) { pin in
                // Centered on the coordinate, same size for every pin: start and end are both
                // part of every trip, so neither is singled out.
                Annotation(pin.title, coordinate: pin.coordinate.clLocationCoordinate, anchor: .center) {
                    marker(pin)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .safeAreaPadding(.bottom, bottomInset)
        // Keep framed pins clear of the settings and refresh buttons.
        .safeAreaPadding(.top, 56)
        .task(id: framingKey) {
            withAnimation {
                position = .rect(boundingRect)
            }
        }
    }

    private var pins: [Pin] {
        var pins: [Pin] = []
        let ends: [(name: String, place: Coordinate?, station: Station?, symbol: String, color: Color)] = [
            ("Home", profile.home.coordinate, homeStation, "house.fill", .blue),
            ("Work", profile.work.coordinate, workStation, "briefcase.fill", .purple)
        ]
        for end in ends {
            guard let station = end.station else { continue }
            if isTemporaryRoute || end.place == nil {
                pins.append(Pin(id: station.id, title: station.name, coordinate: station.coordinate, symbol: "tram.fill", color: .red))
            } else if let place = end.place, place.distance(to: station.coordinate) < Self.mergeDistance {
                pins.append(Pin(id: end.name, title: "\(end.name) · \(station.name)", coordinate: station.coordinate, symbol: end.symbol, color: end.color))
            } else if let place = end.place {
                pins.append(Pin(id: end.name, title: end.name, coordinate: place, symbol: end.symbol, color: end.color))
                pins.append(Pin(id: station.id, title: station.name, coordinate: station.coordinate, symbol: "tram.fill", color: .red))
            }
        }
        return pins
    }

    /// The rail segment following the stations in between, so it traces the real line.
    private var railLine: [CLLocationCoordinate2D]? {
        guard let from = StationCatalog.index(of: profile.homeStationID),
              let to = StationCatalog.index(of: profile.workStationID),
              from != to else { return nil }
        return StationCatalog.all[min(from, to)...max(from, to)].map(\.coordinate.clLocationCoordinate)
    }

    private var accessLegs: [[CLLocationCoordinate2D]] {
        if isTemporaryRoute { return [] }
        return [
            (profile.home.coordinate, homeStation?.coordinate),
            (profile.work.coordinate, workStation?.coordinate)
        ].compactMap { place, station in
            guard let place, let station, place.distance(to: station) >= Self.mergeDistance else { return nil }
            return [place.clLocationCoordinate, station.clLocationCoordinate]
        }
    }

    private var allCoordinates: [Coordinate] {
        [profile.home.coordinate, profile.work.coordinate, homeStation?.coordinate, workStation?.coordinate].compactMap { $0 }
    }

    private var framingKey: String {
        allCoordinates.map(\.cacheKey).joined(separator: "|") + "|\(Int(bottomInset))|\(recenterRequest)"
    }

    private var boundingRect: MKMapRect {
        let rect = allCoordinates
            .map { MKMapPoint($0.clLocationCoordinate) }
            .reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        let padding = max(rect.size.width, rect.size.height) * 0.2 + 2_000
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    private func marker(_ pin: Pin) -> some View {
        Image(systemName: pin.symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(pin.color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}
