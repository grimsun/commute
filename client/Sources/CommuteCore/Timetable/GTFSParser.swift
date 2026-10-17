import Foundation

public enum GTFSError: Error, Equatable {
    case missingFile(String)
    case noTrips
}

/// Turns the GTFS text files of a Caltrain feed into a `Timetable`.
public enum GTFSParser {
    public static let requiredFiles = ["stops.txt", "routes.txt", "trips.txt", "stop_times.txt"]
    public static let optionalFiles = ["calendar.txt", "calendar_dates.txt", "feed_info.txt", "shapes.txt"]

    public static func parse(archive: ZipArchive, downloadedAt: Date) throws -> Timetable {
        var files: [String: Data] = [:]
        for name in requiredFiles {
            files[name] = try archive.contents(of: name)
        }
        for name in optionalFiles {
            files[name] = try? archive.contents(of: name)
        }
        return try parse(files: files, downloadedAt: downloadedAt)
    }

    public static func parse(files: [String: Data], downloadedAt: Date) throws -> Timetable {
        func table(_ name: String) throws -> CSVTable {
            guard let data = files[name] else { throw GTFSError.missingFile(name) }
            return CSVTable(data: data)
        }

        // Platforms (e.g. "70011") map to parent stations (e.g. "san_francisco").
        let stops = try table("stops.txt")
        var parentStation: [String: String] = [:]
        for row in stops.rows {
            let id = stops.value(row, "stop_id")
            let parent = stops.value(row, "parent_station")
            parentStation[id] = parent.isEmpty ? id : parent
        }

        let routes = try table("routes.txt")
        var routeService: [String: TrainService] = [:]
        for row in routes.rows {
            let name = routes.value(row, "route_short_name")
            let longName = routes.value(row, "route_long_name")
            if let service = TrainService(gtfsRouteName: name) ?? TrainService(gtfsRouteName: longName) {
                routeService[routes.value(row, "route_id")] = service
            }
        }

        let tripsTable = try table("trips.txt")
        var tripInfo: [String: (number: String, service: TrainService, serviceID: String, shapeID: String?)] = [:]
        for row in tripsTable.rows {
            guard let service = routeService[tripsTable.value(row, "route_id")] else { continue }
            let id = tripsTable.value(row, "trip_id")
            let shortName = tripsTable.value(row, "trip_short_name")
            let shapeID = tripsTable.value(row, "shape_id")
            tripInfo[id] = (shortName.isEmpty ? id : shortName, service, tripsTable.value(row, "service_id"), shapeID.isEmpty ? nil : shapeID)
        }

        let stopTimes = try table("stop_times.txt")
        var stopsByTrip: [String: [(sequence: Int, stop: Timetable.Stop)]] = [:]
        for row in stopTimes.rows {
            let tripID = stopTimes.value(row, "trip_id")
            guard tripInfo[tripID] != nil,
                  let station = parentStation[stopTimes.value(row, "stop_id")],
                  let arrival = seconds(stopTimes.value(row, "arrival_time")) ?? seconds(stopTimes.value(row, "departure_time")),
                  let departure = seconds(stopTimes.value(row, "departure_time")) ?? seconds(stopTimes.value(row, "arrival_time"))
            else { continue }
            let stop = Timetable.Stop(
                station: station,
                arrival: arrival,
                departure: departure,
                pickup: stopTimes.value(row, "pickup_type") != "1",
                dropOff: stopTimes.value(row, "drop_off_type") != "1"
            )
            stopsByTrip[tripID, default: []].append((Int(stopTimes.value(row, "stop_sequence")) ?? 0, stop))
        }

        let trips = stopsByTrip.compactMap { tripID, stops -> Timetable.Trip? in
            guard let info = tripInfo[tripID], stops.count >= 2 else { return nil }
            return Timetable.Trip(
                id: tripID,
                number: info.number,
                service: info.service,
                serviceID: info.serviceID,
                stops: stops.sorted { $0.sequence < $1.sequence }.map(\.stop),
                shapeID: info.shapeID
            )
        }
        .sorted { $0.id < $1.id }
        guard !trips.isEmpty else { throw GTFSError.noTrips }

        var services: [String: Timetable.ServiceCalendar] = [:]
        if files["calendar.txt"] != nil {
            let calendar = try table("calendar.txt")
            let days = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
            for row in calendar.rows {
                let weekdays = Set(days.compactMap { name, weekday in calendar.value(row, name) == "1" ? weekday : nil })
                services[calendar.value(row, "service_id")] = Timetable.ServiceCalendar(
                    weekdays: weekdays,
                    startDate: Int(calendar.value(row, "start_date")) ?? 0,
                    endDate: Int(calendar.value(row, "end_date")) ?? 0
                )
            }
        }
        if files["calendar_dates.txt"] != nil {
            let exceptions = try table("calendar_dates.txt")
            for row in exceptions.rows {
                guard let date = Int(exceptions.value(row, "date")) else { continue }
                let id = exceptions.value(row, "service_id")
                var service = services[id] ?? Timetable.ServiceCalendar(weekdays: [], startDate: 0, endDate: 0)
                if exceptions.value(row, "exception_type") == "2" {
                    service.removedDates.insert(date)
                } else {
                    service.addedDates.insert(date)
                }
                services[id] = service
            }
        }
        guard !services.isEmpty else { throw GTFSError.missingFile("calendar.txt") }

        var feedVersion: String?
        if files["feed_info.txt"] != nil {
            let info = try table("feed_info.txt")
            feedVersion = info.rows.first.map { info.value($0, "feed_version") }.flatMap { $0.isEmpty ? nil : $0 }
        }

        var shapes: [String: [Coordinate]] = [:]
        if files["shapes.txt"] != nil {
            let table = try table("shapes.txt")
            var points: [String: [(sequence: Int, coordinate: Coordinate)]] = [:]
            for row in table.rows {
                guard let lat = Double(table.value(row, "shape_pt_lat")),
                      let lon = Double(table.value(row, "shape_pt_lon")) else { continue }
                points[table.value(row, "shape_id"), default: []].append(
                    (Int(table.value(row, "shape_pt_sequence")) ?? 0, Coordinate(latitude: lat, longitude: lon))
                )
            }
            shapes = points.mapValues { $0.sorted { $0.sequence < $1.sequence }.map(\.coordinate) }
        }

        return Timetable(downloadedAt: downloadedAt, feedVersion: feedVersion, services: services, trips: trips, shapes: shapes)
    }

    /// "HH:MM:SS" to seconds; hours may exceed 23 for trips past midnight.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
