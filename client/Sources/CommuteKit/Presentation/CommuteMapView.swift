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
    /// The map's size inside its safe area (above `padding`), for fitting the route.
    @State private var viewport: CGSize = .zero
    /// The bottom safe area actually applied, which also places the Maps logo. It follows
    /// `bottomInset` only once the camera has zoomed to the new framing: changing it first would
    /// make the map jump.
    @State private var appliedInset: CGFloat?
    private var padding: CGFloat { appliedInset ?? bottomInset }

    /// The lines and pins, built once per set of inputs rather than on every body pass: the train
    /// marker redraws the map once a second, and the track runs to thousands of points.
    private struct Geometry {
        var fullLine: [CLLocationCoordinate2D] = []
        var railLine: [CLLocationCoordinate2D]?
        var accessLegs: [[CLLocationCoordinate2D]] = []
        var pins: [Pin] = []
    }

    private var geometry = Geometry()

    init(profile: CommuteProfile, isSchedule: Bool, bottomInset: CGFloat, recenterRequest: Int = 0, trainPath: TrainPath? = nil,
         trainDelay: TimeInterval = 0, isLive: Bool = false, now: @escaping () -> Date = Date.init, isVisible: Bool = true) {
        self.profile = profile
        self.isSchedule = isSchedule
        self.bottomInset = bottomInset
        self.recenterRequest = recenterRequest
        self.trainPath = trainPath
        self.trainDelay = trainDelay
        self.isLive = isLive
        self.now = now
        self.isVisible = isVisible
        geometry = Geometry(fullLine: fullLine, railLine: railLine, accessLegs: accessLegs, pins: pins)
    }

    private var homeStation: Station? { StationCatalog.station(id: profile.homeStationID) }
    private var workStation: Station? { StationCatalog.station(id: profile.workStationID) }

    private struct Pin: Identifiable {
        let id: String
        let title: String
        let coordinate: Coordinate
        let symbol: String
        let color: Color
        var isStation: Bool { symbol == "tram.fill" }
    }

    var body: some View {
        Map(position: $position) {
            // The train's whole run, faint, so it is on a line before and after the ride.
            MapPolyline(coordinates: geometry.fullLine)
                .stroke(Color.red.opacity(0.3), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let railLine = geometry.railLine {
                MapPolyline(coordinates: railLine)
                    .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(geometry.accessLegs.indices, id: \.self) { index in
                MapPolyline(coordinates: geometry.accessLegs[index])
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 6]))
            }
            ForEach(geometry.pins) { pin in
                // Centered on the coordinate. Stations are small stops on the line; home and work
                // keep their icons, so the ends of the trip read first.
                Annotation(pin.title, coordinate: pin.coordinate.clLocationCoordinate, anchor: .center) {
                    marker(pin)
                }
            }
            if let trainPosition, let trainPath {
                // Last, so it moves over the pins. Arrow only: the train is already named on the card.
                Annotation("Train \(trainPath.trainNumber)", coordinate: trainPosition.coordinate.clLocationCoordinate, anchor: .center) {
                    trainMarker(heading: trainPosition.heading)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // Inside the safe area padding below, so this is the part the route is fitted to.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewport = size
        }
        .safeAreaPadding(.bottom, padding)
        // Keep framed pins clear of the settings and refresh buttons.
        .safeAreaPadding(.top, 56)
        .task(id: framingKey) {
            // Zoom to fit above the sheet's new height, then move the inset (and the logo) there;
            // the same route in the same space, so that step doesn't move the map.
            let target = bottomInset
            withAnimation(.smooth(duration: 0.45)) {
                position = .rect(framedRect(fittingAbove: target))
            }
            guard padding != target else { return }
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                appliedInset = target
                position = .rect(boundingRect)
            }
        }
        // Moves the train once a second; small steps read as gliding at map scale. Only a real
        // move redraws, so a train waiting at a station (or none at all) costs nothing.
        .task(id: "\(trainPath?.tripID ?? "")|\(isVisible)|\(Int(trainDelay))") {
            guard let trainPath else {
                trainPosition = nil
                return
            }
            while isVisible && !Task.isCancelled {
                let next = trainPath.position(at: now(), delay: trainDelay)
                if next != trainPosition {
                    withAnimation(.linear(duration: 1)) {
                        trainPosition = next
                    }
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

    /// The card's train from end to end, else the whole line through every station.
    private var fullLine: [CLLocationCoordinate2D] {
        let track = trainPath?.line ?? []
        return (track.count >= 2 ? track : StationCatalog.all.map(\.coordinate)).map(\.clLocationCoordinate)
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
        allCoordinates.map(\.cacheKey).joined(separator: "|") + "|\(Int(bottomInset))|\(Int(padding))|\(Int(viewport.width))x\(Int(viewport.height))|\(recenterRequest)"
    }

    /// The rect handed to the map, which fits it to the viewport: the route's rect, grown or
    /// shrunk so the route fits above `target` rather than above the applied inset, top-aligned.
    /// With the inset already there, it's the route's rect.
    private func framedRect(fittingAbove target: CGFloat) -> MKMapRect {
        let route = boundingRect
        let visibleHeight = viewport.height + padding - target
        guard viewport.width > 0, viewport.height > 0, visibleHeight > 0, padding != target else { return route }
        // Map points per screen point.
        let scale = max(route.size.width / viewport.width, route.size.height / visibleHeight)
        let size = MKMapSize(width: viewport.width * scale, height: viewport.height * scale)
        let origin = MKMapPoint(x: route.midX - size.width / 2, y: route.midY - visibleHeight * scale / 2)
        return MKMapRect(origin: origin, size: size)
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
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(heading))
            .frame(width: 26, height: 26)
            .background(Color.black.opacity(0.8), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }

    @ViewBuilder
    private func marker(_ pin: Pin) -> some View {
        if pin.isStation {
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.red, lineWidth: 4))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        } else {
            placeMarker(pin)
        }
    }

    private func placeMarker(_ pin: Pin) -> some View {
        Image(systemName: pin.symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(pin.color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}
