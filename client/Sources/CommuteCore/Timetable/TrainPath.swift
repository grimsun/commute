import Foundation

/// Where a train is at a moment: on its track, and which way it is heading.
public struct TrainPosition: Equatable, Sendable {
    public var coordinate: Coordinate
    /// Degrees clockwise from north.
    public var heading: Double
    /// The station it is stopped at, if dwelling.
    public var stationID: String?
}

/// One train's stops and track, able to place it at any time from the timetable.
public struct TrainPath: Equatable, Sendable {
    public struct StopTime: Equatable, Sendable {
        public var stationID: String
        public var arrival: Date
        public var departure: Date
        /// Distance along `line` in meters.
        public var distance: Double
    }

    public let tripID: String
    public let trainNumber: String
    public let service: TrainService
    public let stops: [StopTime]
    /// Track geometry in travel order; station coordinates when the feed has no shape.
    public let line: [Coordinate]
    private let cumulative: [Double]

    init(tripID: String, trainNumber: String, service: TrainService, stops: [(stationID: String, arrival: Date, departure: Date)], line: [Coordinate]) {
        self.tripID = tripID
        self.trainNumber = trainNumber
        self.service = service
        let track = line.count >= 2 ? line : stops.compactMap { StationCatalog.station(id: $0.stationID)?.coordinate }
        self.line = track
        var cumulative = [0.0]
        for index in track.indices.dropFirst() {
            cumulative.append(cumulative[index - 1] + track[index - 1].distance(to: track[index]))
        }
        self.cumulative = cumulative

        // Each station sits at its nearest track point, searching forward so stops stay in order.
        var searchFrom = 0
        self.stops = stops.map { stop in
            var distance = cumulative[searchFrom]
            if let coordinate = StationCatalog.station(id: stop.stationID)?.coordinate {
                let nearest = (searchFrom..<track.count).min { track[$0].distance(to: coordinate) < track[$1].distance(to: coordinate) } ?? searchFrom
                searchFrom = nearest
                distance = cumulative[nearest]
            }
            return StopTime(stationID: stop.stationID, arrival: stop.arrival, departure: stop.departure, distance: distance)
        }
    }

    /// Where the train should be at `date`, shifted by `delay`; `nil` before it starts or after it ends.
    public func position(at date: Date, delay: TimeInterval = 0) -> TrainPosition? {
        let time = date.addingTimeInterval(-delay)
        guard let distance = distance(at: time) else { return nil }
        let dwelling = stops.first { time >= $0.arrival && time <= $0.departure }
        return TrainPosition(coordinate: point(at: distance), heading: heading(at: distance), stationID: dwelling?.stationID)
    }

    /// How far along the track the train is at `time` (already shifted by any delay).
    private func distance(at time: Date) -> Double? {
        guard let first = stops.first, let last = stops.last,
              time >= first.departure, time <= last.arrival else { return nil }

        for index in stops.indices {
            let stop = stops[index]
            if time >= stop.arrival && time <= stop.departure {
                return stop.distance
            }
            if index + 1 < stops.count {
                let next = stops[index + 1]
                if time > stop.departure && time < next.arrival {
                    let fraction = time.timeIntervalSince(stop.departure) / next.arrival.timeIntervalSince(stop.departure)
                    return stop.distance + (next.distance - stop.distance) * fraction
                }
            }
        }
        return nil
    }

    /// The track between two of this train's stations, for drawing the ride.
    public func line(from originID: String, to destinationID: String) -> [Coordinate] {
        guard let from = stops.first(where: { $0.stationID == originID })?.distance,
              let to = stops.last(where: { $0.stationID == destinationID })?.distance else { return [] }
        return section(from: from, to: to)
    }

    private func section(from: Double, to: Double) -> [Coordinate] {
        guard from < to else { return [] }
        let inside = line.indices.filter { cumulative[$0] > from && cumulative[$0] < to }.map { line[$0] }
        return [point(at: from)] + inside + [point(at: to)]
    }

    /// The next stop the train will arrive at after `date`; a stop it is dwelling at counts as left.
    public func nextStop(at date: Date, delay: TimeInterval = 0) -> StopTime? {
        stops.first { $0.arrival.addingTimeInterval(delay) > date }
    }

    /// Stops from `originID` to `destinationID`, inclusive.
    public func stops(from originID: String, to destinationID: String) -> [StopTime] {
        guard let start = stops.firstIndex(where: { $0.stationID == originID }),
              let end = stops.lastIndex(where: { $0.stationID == destinationID }),
              start <= end else { return [] }
        return Array(stops[start...end])
    }

    private func point(at distance: Double) -> Coordinate {
        guard let upper = cumulative.firstIndex(where: { $0 >= distance }), upper > 0 else {
            return distance <= 0 ? line.first ?? Coordinate(latitude: 0, longitude: 0) : line.last ?? Coordinate(latitude: 0, longitude: 0)
        }
        let a = line[upper - 1], b = line[upper]
        let span = cumulative[upper] - cumulative[upper - 1]
        let t = span > 0 ? (distance - cumulative[upper - 1]) / span : 0
        return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Bearing along the track a little ahead of `distance`.
    private func heading(at distance: Double) -> Double {
        let total = cumulative.last ?? 0
        let ahead = min(distance + 50, total)
        let behind = ahead - 100
        let a = point(at: max(behind, 0)), b = point(at: ahead)
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension Timetable {
    /// The path of the trip behind `departure` (from this timetable or the server, matched by
    /// train number and time), on the service day it runs.
    public func path(for departure: TrainDeparture, calendar: Calendar = .caltrain) -> TrainPath? {
        let day = calendar.startOfDay(for: departure.scheduledDeparture)
        for offset in [0, -1] {
            guard let serviceDay = calendar.date(byAdding: .day, value: offset, to: day) else { continue }
            let dateKey = DateKey.key(for: serviceDay, calendar: calendar)
            let weekday = calendar.component(.weekday, from: serviceDay)
            let reference = DateKey.serviceDayReference(for: serviceDay, calendar: calendar)
            for trip in trips where trip.number == departure.trainNumber {
                guard services[trip.serviceID]?.isActive(on: dateKey, weekday: weekday) == true,
                      trip.stops.contains(where: { abs(reference.addingTimeInterval(TimeInterval($0.departure)).timeIntervalSince(departure.scheduledDeparture)) < 90 })
                else { continue }
                return TrainPath(
                    tripID: departure.tripID,
                    trainNumber: trip.number,
                    service: trip.service,
                    stops: trip.stops.map {
                        ($0.station, reference.addingTimeInterval(TimeInterval($0.arrival)), reference.addingTimeInterval(TimeInterval($0.departure)))
                    },
                    line: trip.shapeID.flatMap { shapes[$0] } ?? []
                )
            }
        }
        return nil
    }
}

extension TimetableStore {
    /// The path for `departure` from the cached timetable; never downloads.
    public func path(for departure: TrainDeparture) async -> TrainPath? {
        guard let timetable = try? await current() else { return nil }
        return timetable.path(for: departure)
    }
}
