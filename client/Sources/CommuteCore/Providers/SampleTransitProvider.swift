import Foundation

public enum SampleTransitError: Error, Equatable {
    case unknownStation(String)
}

/// A plausible, deterministic Caltrain-like day used until the homelab server provides live data.
///
/// Weekdays: Locals every 30 minutes, Limited and Express trains at the peaks, South County
/// trains between San Jose and Gilroy. Weekends: hourly Locals. Delays and the odd cancellation
/// are derived from the train number and date, so they stay stable across refreshes.
public struct SampleTransitProvider: TransitProvider {
    private let calendar: Calendar

    public init(calendar: Calendar = .caltrain) {
        self.calendar = calendar
    }

    public func departures(fromStation originID: String, toStation destinationID: String, after: Date, limit: Int) async throws -> TransitSnapshot {
        guard let originIndex = StationCatalog.index(of: originID) else {
            throw SampleTransitError.unknownStation(originID)
        }
        guard let destinationIndex = StationCatalog.index(of: destinationID) else {
            throw SampleTransitError.unknownStation(destinationID)
        }

        let southbound = destinationIndex > originIndex
        let firstDay = calendar.startOfDay(for: after)
        var departures: [TrainDeparture] = []

        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else { continue }
            for run in runs(on: day, southbound: southbound) {
                guard run.stops.contains(originIndex), run.stops.contains(destinationIndex) else { continue }
                let departure = run.time(at: originIndex)
                guard departure >= after.addingTimeInterval(-TimeInterval(run.delaySeconds)) else { continue }
                departures.append(
                    TrainDeparture(
                        tripID: "sample-\(run.dayKey)-\(run.number)",
                        trainNumber: String(run.number),
                        service: run.service,
                        scheduledDeparture: departure,
                        scheduledArrival: run.time(at: destinationIndex),
                        delaySeconds: run.delaySeconds,
                        isCancelled: run.isCancelled
                    )
                )
            }
        }

        let sorted = departures
            .filter { $0.departureTime >= after }
            .sorted { $0.departureTime < $1.departureTime }
        return TransitSnapshot(departures: Array(sorted.prefix(limit)), source: .sample, fetchedAt: Date())
    }

    // MARK: - Schedule generation

    private struct Run {
        let service: TrainService
        let number: Int
        let dayKey: Int
        let terminalDeparture: Date
        let terminalIndex: Int
        let stops: Set<Int>
        let minutesPerStation: Double
        let delaySeconds: Int
        let isCancelled: Bool

        func time(at stationIndex: Int) -> Date {
            let hops = Double(abs(stationIndex - terminalIndex))
            return terminalDeparture.addingTimeInterval((hops * minutesPerStation * 60).rounded())
        }
    }

    private func runs(on day: Date, southbound: Bool) -> [Run] {
        let weekday = calendar.component(.weekday, from: day)
        let isWeekend = weekday == 1 || weekday == 7
        let dayKey = Int(day.timeIntervalSince1970 / 86_400)

        var counters: [TrainService: Int] = [:]
        var result: [Run] = []

        func add(_ service: TrainService, _ minuteOfDay: Int, base: Int) {
            let stops = Self.stops(for: service)
            let index = counters[service, default: 0]
            counters[service] = index + 1
            // Caltrain numbering: odd northbound, even southbound.
            let number = base + index * 2 + (southbound ? 1 : 0)
            let (delay, cancelled) = Self.realtime(number: number, dayKey: dayKey)
            result.append(
                Run(
                    service: service,
                    number: number,
                    dayKey: dayKey,
                    terminalDeparture: day.addingTimeInterval(TimeInterval(minuteOfDay * 60)),
                    terminalIndex: southbound ? stops.min() ?? 0 : stops.max() ?? 0,
                    stops: stops,
                    minutesPerStation: Self.minutesPerStation(service),
                    delaySeconds: delay,
                    isCancelled: cancelled
                )
            )
        }

        if isWeekend {
            for hour in 7...22 {
                add(.local, hour * 60 + 5, base: 201)
            }
            return result
        }

        for hour in 5...22 {
            add(.local, hour * 60, base: 101)
            add(.local, hour * 60 + 30, base: 101)
        }
        for hour in [6, 7, 8, 16, 17, 18] {
            add(.limited, hour * 60 + 15, base: 401)
            add(.express, hour * 60 + 45, base: 501)
        }
        for minute in southbound ? [370, 430, 490, 1000, 1060, 1120] : [330, 390, 450, 960, 1020, 1080] {
            add(.southCounty, minute, base: 801)
        }
        return result
    }

    private static func stops(for service: TrainService) -> Set<Int> {
        let ids: [String]
        switch service {
        case .express:
            ids = expressStops
        case .limited:
            ids = expressStops + ["south_sf", "san_bruno", "burlingame", "san_carlos", "menlo_park", "california_ave", "san_antonio", "lawrence", "santa_clara"]
        case .local:
            let lastLocal = StationCatalog.index(of: "tamien") ?? 0
            let skipped: Set<String> = ["stanford", "broadway"]
            return Set(StationCatalog.all.indices.filter { $0 <= lastLocal && !skipped.contains(StationCatalog.all[$0].id) })
        case .southCounty:
            ids = ["sj_diridon", "tamien", "capitol", "blossom_hill", "morgan_hill", "san_martin", "gilroy"]
        }
        return Set(ids.compactMap { StationCatalog.index(of: $0) })
    }

    private static let expressStops = [
        "san_francisco", "22nd_street", "place_MLBR", "san_mateo", "hillsdale",
        "redwood_city", "palo_alto", "mountain_view", "sunnyvale", "sj_diridon"
    ]

    private static func minutesPerStation(_ service: TrainService) -> Double {
        switch service {
        case .local: 2.6
        case .limited: 2.1
        case .express: 1.7
        case .southCounty: 3.4
        }
    }

    private static func realtime(number: Int, dayKey: Int) -> (delaySeconds: Int, cancelled: Bool) {
        switch (number * 7 + dayKey) % 20 {
        case 14, 15: (120, false)
        case 16: (180, false)
        case 17: (300, false)
        case 18: (480, false)
        case 19: (0, true)
        default: (0, false)
        }
    }
}
