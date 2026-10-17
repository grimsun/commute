import MapKit
import SwiftUI

/// Map behind the sheet: home, work, both stations, the access legs and the rail segment.
struct CommuteMapView: View {
    let profile: CommuteProfile
    let direction: Direction
    let isTemporaryRoute: Bool
    /// Height covered by the sheet, so the route is framed in the visible part.
    let bottomInset: CGFloat

    @State private var position: MapCameraPosition = .automatic

    private var homeStation: Station? { StationCatalog.station(id: profile.homeStationID) }
    private var workStation: Station? { StationCatalog.station(id: profile.workStationID) }

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

            if !isTemporaryRoute, let home = profile.home.coordinate {
                Annotation("Home", coordinate: home.clLocationCoordinate) {
                    pin("house.fill", color: .blue, isActive: direction == .homeToWork)
                }
            }
            if !isTemporaryRoute, let work = profile.work.coordinate {
                Annotation("Work", coordinate: work.clLocationCoordinate) {
                    pin("briefcase.fill", color: .purple, isActive: direction == .workToHome)
                }
            }
            ForEach([homeStation, workStation].compactMap { $0 }, id: \.id) { station in
                Annotation(station.name, coordinate: station.coordinate.clLocationCoordinate) {
                    pin("tram.fill", color: .red, isActive: false)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .safeAreaPadding(.bottom, bottomInset)
        .task(id: framingKey) {
            withAnimation {
                position = .rect(boundingRect)
            }
        }
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
            guard let place, let station else { return nil }
            return [place.clLocationCoordinate, station.clLocationCoordinate]
        }
    }

    private var allCoordinates: [Coordinate] {
        [profile.home.coordinate, profile.work.coordinate, homeStation?.coordinate, workStation?.coordinate].compactMap { $0 }
    }

    private var framingKey: String {
        allCoordinates.map(\.cacheKey).joined(separator: "|") + "\(Int(bottomInset))"
    }

    private var boundingRect: MKMapRect {
        let rect = allCoordinates
            .map { MKMapPoint($0.clLocationCoordinate) }
            .reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        let padding = max(rect.size.width, rect.size.height) * 0.2 + 2_000
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    private func pin(_ symbol: String, color: Color, isActive: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: isActive ? 15 : 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: isActive ? 34 : 26, height: isActive ? 34 : 26)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}
