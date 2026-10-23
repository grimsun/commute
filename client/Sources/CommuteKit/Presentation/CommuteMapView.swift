import MapKit
import SwiftUI

/// Map behind the sheet: both stations, home and work when given as addresses, the access legs and the rail segment.
struct CommuteMapView: View {
    let profile: CommuteProfile
    /// Station to station: no home, work or legs to them.
    let isSchedule: Bool
    /// Height covered by the sheet, so the route is framed in the visible part.
    let bottomInset: CGFloat
    /// Changes when the route should be re-framed, e.g. after the rider panned away and tapped refresh.
    var recenterRequest = 0
    /// The train on the card: its track draws the ride, and it moves along it.
    var trainPath: TrainPath? = nil
    /// Realtime delay of that train; 0 with the timetable.
    var trainDelay: TimeInterval = 0
    /// Without live data the marker shows where the timetable says the train is.
    var isLive = false
    var now: () -> Date = Date.init
    /// False while the sheet covers the map, so the train stops animating unseen.
    var isVisible = true

    /// A place this close to its station counts as no address: only the station is drawn.
    private static let mergeDistance: Double = 200

    @State private var position: MapCameraPosition = .automatic
    @State private var trainPosition: TrainPosition?

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
            if let trainPosition, let trainPath {
                // Arrow only: the train is already named on the card.
                Annotation("Train \(trainPath.trainNumber)", coordinate: trainPosition.coordinate.clLocationCoordinate, anchor: .center) {
                    trainMarker(heading: trainPosition.heading)
                }
                .annotationTitles(.hidden)
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
        // Moves the train once a second; small steps read as gliding at map scale.
        .task(id: "\(trainPath?.tripID ?? "")|\(isVisible)") {
            while isVisible && !Task.isCancelled {
                let next = trainPath?.position(at: now(), delay: trainDelay)
                withAnimation(.linear(duration: 1)) {
                    trainPosition = next
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The ride's ends in the train's direction of travel.
    private var originStationID: String {
        guard let trainPath,
              let home = trainPath.stops.firstIndex(where: { $0.stationID == profile.homeStationID }),
              let work = trainPath.stops.firstIndex(where: { $0.stationID == profile.workStationID }) else { return profile.homeStationID }
        return home < work ? profile.homeStationID : profile.workStationID
    }

    private var destinationStationID: String {
        originStationID == profile.homeStationID ? profile.workStationID : profile.homeStationID
    }

    /// Home or work, when the rider gave an address away from its station; else just the station.
    private func address(_ place: Place, near station: Station?) -> Coordinate? {
        guard !isSchedule, let coordinate = place.coordinate, let station,
              coordinate.distance(to: station.coordinate) >= Self.mergeDistance else { return nil }
        return coordinate
    }

    private var pins: [Pin] {
        var pins: [Pin] = []
        let ends: [(name: String, place: Place, station: Station?, symbol: String, color: Color)] = [
            ("Home", profile.home, homeStation, "house.fill", .blue),
            ("Work", profile.work, workStation, "briefcase.fill", .purple)
        ]
        for end in ends {
            guard let station = end.station else { continue }
            if let address = address(end.place, near: station) {
                pins.append(Pin(id: end.name, title: end.name, coordinate: address, symbol: end.symbol, color: end.color))
            }
            pins.append(Pin(id: station.id, title: station.name, coordinate: station.coordinate, symbol: "tram.fill", color: .red))
        }
        return pins
    }

    /// The ride along the real track when the train's path is known, else through the stations.
    private var railLine: [CLLocationCoordinate2D]? {
        if let trainPath {
            let track = trainPath.line(from: originStationID, to: destinationStationID)
            if track.count >= 2 {
                return track.map(\.clLocationCoordinate)
            }
        }
        guard let from = StationCatalog.index(of: profile.homeStationID),
              let to = StationCatalog.index(of: profile.workStationID),
              from != to else { return nil }
        return StationCatalog.all[min(from, to)...max(from, to)].map(\.coordinate.clLocationCoordinate)
    }

    private var accessLegs: [[CLLocationCoordinate2D]] {
        [(profile.home, homeStation), (profile.work, workStation)].compactMap { place, station in
            guard let station, let address = address(place, near: station) else { return nil }
            return [address.clLocationCoordinate, station.coordinate.clLocationCoordinate]
        }
    }

    private var allCoordinates: [Coordinate] {
        [address(profile.home, near: homeStation), address(profile.work, near: workStation),
         homeStation?.coordinate, workStation?.coordinate].compactMap { $0 }
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

    private func trainMarker(heading: Double) -> some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(heading))
            .frame(width: 30, height: 30)
            .background(Color.black.opacity(0.8), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
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
