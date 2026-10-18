import Foundation

/// The parts of a Caltrain GTFS feed needed to answer "which trains go from A to B after T".
public struct Timetable: Codable, Equatable, Sendable {
    /// Bump when the cached format changes; older caches are discarded.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var downloadedAt: Date
    public var feedVersion: String?
    public var services: [String: ServiceCalendar]
    public var trips: [Trip]
    /// Track geometry by GTFS shape id, in travel order.
    public var shapes: [String: [Coordinate]]
    /// Holiday or special-day names by yyyymmdd ("Thanksgiving", "6/16 World Cup").
    public var holidays: [Int: String]
    /// Platform stop ids ("70011") to their station ("san_francisco"), for realtime feeds.
    public var platformStations: [String: String]

    public init(
        downloadedAt: Date,
        feedVersion: String?,
        services: [String: ServiceCalendar],
        trips: [Trip],
        shapes: [String: [Coordinate]] = [:],
        holidays: [Int: String] = [:],
        platformStations: [String: String] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.downloadedAt = downloadedAt
        self.feedVersion = feedVersion
        self.services = services
        self.trips = trips
        self.shapes = shapes
        self.holidays = holidays
        self.platformStations = platformStations
    }

    public struct ServiceCalendar: Codable, Equatable, Sendable {
        /// `Calendar` weekday numbers, 1 = Sunday.
        public var weekdays: Set<Int>
        /// yyyymmdd; 0 when the service is defined only by calendar_dates.
        public var startDate: Int
        public var endDate: Int
        public var addedDates: Set<Int>
        public var removedDates: Set<Int>
        /// The feed's service name, e.g. "Year Round starting 1/31/2026 (Weekday)".
        public var name: String?

        public init(weekdays: Set<Int>, startDate: Int, endDate: Int, addedDates: Set<Int> = [], removedDates: Set<Int> = [], name: String? = nil) {
            self.weekdays = weekdays
            self.startDate = startDate
            self.endDate = endDate
            self.addedDates = addedDates
            self.removedDates = removedDates
            self.name = name
        }

        public func isActive(on dateKey: Int, weekday: Int) -> Bool {
            if removedDates.contains(dateKey) {
                return false
            }
            if addedDates.contains(dateKey) {
                return true
            }
            return startDate <= dateKey && dateKey <= endDate && weekdays.contains(weekday)
        }
    }

    public struct Trip: Codable, Equatable, Sendable {
        public var id: String
        public var number: String
        public var service: TrainService
        public var serviceID: String
        /// In travel order.
        public var stops: [Stop]
        public var shapeID: String?

        public init(id: String, number: String, service: TrainService, serviceID: String, stops: [Stop], shapeID: String? = nil) {
            self.id = id
            self.number = number
            self.service = service
            self.serviceID = serviceID
            self.stops = stops
            self.shapeID = shapeID
        }
    }

    public struct Stop: Codable, Equatable, Sendable {
        /// Parent station id, matching `StationCatalog`.
        public var station: String
        /// Seconds after the service day's reference time (noon minus 12 hours); may exceed 24 h.
        public var arrival: Int
        public var departure: Int
        public var pickup: Bool
        public var dropOff: Bool

        public init(station: String, arrival: Int, departure: Int, pickup: Bool = true, dropOff: Bool = true) {
            self.station = station
            self.arrival = arrival
            self.departure = departure
            self.pickup = pickup
            self.dropOff = dropOff
        }
    }

    /// First and last service dates covered by the feed.
    public var validRange: ClosedRange<Int>? {
        let keys = services.values.flatMap { calendar -> [Int] in
            var keys = Array(calendar.addedDates)
            if calendar.startDate > 0 {
                keys += [calendar.startDate, calendar.endDate]
            }
            return keys
        }
        guard let first = keys.min(), let last = keys.max() else { return nil }
        return first...last
    }

    /// Scheduled trains stopping at `originID` and later at `destinationID`, departing at or after `after`.
    public func departures(from originID: String, to destinationID: String, after: Date, limit: Int, calendar: Calendar = .caltrain) -> [TrainDeparture] {
        var result: [TrainDeparture] = []
        let today = calendar.startOfDay(for: after)

        // Yesterday's service day can run past midnight; tomorrow's covers late queries.
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let dateKey = DateKey.key(for: day, calendar: calendar)
            let weekday = calendar.component(.weekday, from: day)
            let reference = DateKey.serviceDayReference(for: day, calendar: calendar)

            for trip in trips {
                guard services[trip.serviceID]?.isActive(on: dateKey, weekday: weekday) == true,
                      let originIndex = trip.stops.firstIndex(where: { $0.station == originID && $0.pickup }),
                      let destination = trip.stops[(originIndex + 1)...].first(where: { $0.station == destinationID && $0.dropOff })
                else { continue }

                let departure = reference.addingTimeInterval(TimeInterval(trip.stops[originIndex].departure))
                guard departure >= after else { continue }
                result.append(
                    TrainDeparture(
                        tripID: "\(dateKey)-\(trip.id)",
                        trainNumber: trip.number,
                        service: trip.service,
                        scheduledDeparture: departure,
                        scheduledArrival: reference.addingTimeInterval(TimeInterval(destination.arrival))
                    )
                )
            }
        }

        return Array(result.sorted { $0.scheduledDeparture < $1.scheduledDeparture }.prefix(limit))
    }
}

/// Which timetable runs on a day, for the "Weekday schedule" label.
public struct ScheduleDay: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case weekday, weekend
    }

    public var kind: Kind
    /// Set on holidays and special-service days.
    public var holidayName: String?

    public init(kind: Kind, holidayName: String?) {
        self.kind = kind
        self.holidayName = holidayName
    }

    /// Fits a tight spot: "Weekday schedule", "Weekend schedule", or "Holiday schedule".
    public var shortLabel: String {
        holidayName == nil ? "\(kind.rawValue.capitalized) schedule" : "Holiday schedule"
    }

    /// "Weekday schedule", "Weekend schedule", or "Thanksgiving · weekend schedule".
    public var label: String {
        guard let holidayName else { return "\(kind.rawValue.capitalized) schedule" }
        return "\(holidayName) · \(kind.rawValue) schedule"
    }
}

extension Timetable {
    /// The schedule running on the service day of `date`; `nil` when nothing runs.
    public func scheduleDay(for date: Date, calendar: Calendar = .caltrain) -> ScheduleDay? {
        let key = DateKey.key(for: date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: date)
        let active = services.values.filter { $0.isActive(on: key, weekday: weekday) }
        guard !active.isEmpty else { return nil }

        // Prefer the feed's own naming; else infer from which days the services run.
        let names = active.compactMap { $0.name?.lowercased() }
        let kind: ScheduleDay.Kind
        if names.contains(where: { $0.contains("weekend") }) {
            kind = .weekend
        } else if names.contains(where: { $0.contains("weekday") }) {
            kind = .weekday
        } else {
            let weekend: Set<Int> = [1, 7]
            let regular = active.flatMap(\.weekdays)
            kind = !regular.isEmpty && Set(regular).isSubset(of: weekend) || (regular.isEmpty && weekend.contains(weekday)) ? .weekend : .weekday
        }
        return ScheduleDay(kind: kind, holidayName: holidays[key])
    }
}

/// yyyymmdd integers, the GTFS date format.
public enum DateKey {
    public static func key(for date: Date, calendar: Calendar = .caltrain) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    public static func date(for key: Int, calendar: Calendar = .caltrain) -> Date? {
        calendar.date(from: DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100))
    }

    /// GTFS times count from noon minus 12 hours, which differs from midnight on DST change days.
    static func serviceDayReference(for day: Date, calendar: Calendar) -> Date {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        return noon.addingTimeInterval(-12 * 3600)
    }
}
