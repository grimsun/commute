import Foundation

/// Caltrain service patterns. Raw values are the wire format shared with the server.
public enum TrainService: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case limited
    case express
    case southCounty

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .limited: "Limited"
        case .express: "Express"
        case .southCounty: "South County"
        }
    }

    public var summary: String {
        switch self {
        case .local: "Stops at every station"
        case .limited: "Skips some stations"
        case .express: "Fewest stops, fastest"
        case .southCounty: "San Jose to Gilroy"
        }
    }

    /// Maps GTFS `route_short_name` values ("Local Weekday", "Local Weekend", ...) to a service.
    public init?(gtfsRouteName: String) {
        let name = gtfsRouteName.lowercased()
        if name.hasPrefix("local") {
            self = .local
        } else if name.hasPrefix("limited") {
            self = .limited
        } else if name.hasPrefix("express") || name.hasPrefix("baby bullet") {
            self = .express
        } else if name.hasPrefix("south county") {
            self = .southCounty
        } else {
            return nil
        }
    }
}

public struct TrainDeparture: Codable, Equatable, Identifiable, Sendable {
    public var tripID: String
    public var trainNumber: String
    public var service: TrainService
    /// Timetable departure from the origin station.
    public var scheduledDeparture: Date
    /// Timetable arrival at the destination station.
    public var scheduledArrival: Date
    public var delaySeconds: Int
    public var isCancelled: Bool
    public var platform: String?
    /// The live feed reported on this train; otherwise its times are just the timetable's.
    /// Optional so server JSON without the field still decodes.
    public var isTracked: Bool?

    public var id: String { tripID }

    /// Predicted departure including realtime delay.
    public var departureTime: Date { scheduledDeparture.addingTimeInterval(TimeInterval(delaySeconds)) }
    /// Predicted arrival including realtime delay.
    public var arrivalTime: Date { scheduledArrival.addingTimeInterval(TimeInterval(delaySeconds)) }
    public var delayMinutes: Int { Int((Double(delaySeconds) / 60).rounded()) }

    /// Running, and of a type the rider takes: a train the plan may use.
    public func isUsable(preferred: Set<TrainService>) -> Bool {
        !isCancelled && preferred.contains(service)
    }

    public init(
        tripID: String,
        trainNumber: String,
        service: TrainService,
        scheduledDeparture: Date,
        scheduledArrival: Date,
        delaySeconds: Int = 0,
        isCancelled: Bool = false,
        platform: String? = nil,
        isTracked: Bool? = nil
    ) {
        self.tripID = tripID
        self.trainNumber = trainNumber
        self.service = service
        self.scheduledDeparture = scheduledDeparture
        self.scheduledArrival = scheduledArrival
        self.delaySeconds = delaySeconds
        self.isCancelled = isCancelled
        self.platform = platform
        self.isTracked = isTracked
    }
}

public enum TransitDataSource: String, Codable, Sendable {
    /// Generated locally; for previews and tests.
    case sample
    /// The published Caltrain timetable, without realtime changes.
    case timetable
    /// Timetable plus realtime predictions from the server.
    case live
}

public struct TransitSnapshot: Equatable, Sendable {
    public var departures: [TrainDeparture]
    public var source: TransitDataSource
    public var fetchedAt: Date
    /// Something the rider should know about the data, such as a server fallback.
    public var notice: String?

    public init(departures: [TrainDeparture], source: TransitDataSource, fetchedAt: Date, notice: String? = nil) {
        self.departures = departures
        self.source = source
        self.fetchedAt = fetchedAt
        self.notice = notice
    }
}
