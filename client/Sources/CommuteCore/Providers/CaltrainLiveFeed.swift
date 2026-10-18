import Foundation

/// Predicted stop times for running trains, from Caltrain's public JSON trip-updates feed
/// (the one caltrain.com uses; no key). Kept deliberately sparse: it only fetches when asked,
/// never more often than `minimumInterval`, and backs off after failures.
public actor CaltrainLiveFeed {
    public static let tripUpdatesURL = URL(string: "https://www.caltrain.com/files/rt/tripupdates/CT.json")!

    /// Predictions older than this are ignored.
    public static let maximumAge: TimeInterval = 6 * 60
    /// Normal spacing between requests.
    public static let minimumInterval: TimeInterval = 3 * 60
    /// Spacing when the rider explicitly refreshes.
    public static let manualInterval: TimeInterval = 30
    /// Wait after a failed request.
    public static let failureBackoff: TimeInterval = 5 * 60

    public struct StopUpdate: Equatable, Sendable {
        public var stopID: String
        public var arrival: Date?
        public var departure: Date?
    }

    public struct Snapshot: Equatable, Sendable {
        public var fetchedAt: Date
        /// By train number (Caltrain's trip ids are train numbers).
        public var trips: [String: [StopUpdate]]
        public var cancelled: Set<String>
    }

    private let url: URL
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var snapshot: Snapshot?
    private var lastAttempt: Date?
    private var lastFailure: Date?
    private var inFlight: Task<Bool, Never>?

    public init(url: URL = CaltrainLiveFeed.tripUpdatesURL, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.session = session
        self.now = now
    }

    /// The latest predictions if still fresh.
    public func latest() -> Snapshot? {
        guard let snapshot, now().timeIntervalSince(snapshot.fetchedAt) <= Self.maximumAge else { return nil }
        return snapshot
    }

    /// Whether a request would be allowed now.
    public func isDue(manual: Bool = false) -> Bool {
        let date = now()
        if let lastFailure, date.timeIntervalSince(lastFailure) < Self.failureBackoff {
            return false
        }
        guard let lastAttempt else { return true }
        return date.timeIntervalSince(lastAttempt) >= (manual ? Self.manualInterval : Self.minimumInterval)
    }

    /// Fetches if due; returns whether new predictions arrived.
    /// A caller arriving while a request is running waits for it instead of skipping.
    @discardableResult
    public func refreshIfDue(manual: Bool = false) async -> Bool {
        if let inFlight {
            return await inFlight.value
        }
        guard isDue(manual: manual) else { return false }
        lastAttempt = now()
        let task = Task { await fetch() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func fetch() async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            snapshot = try Self.parse(data, fetchedAt: now())
            lastFailure = nil
            return true
        } catch {
            lastFailure = now()
            return false
        }
    }

    // MARK: Parsing

    private struct Feed: Decodable {
        var Entities: [Entity]?
    }

    private struct Entity: Decodable {
        var TripUpdate: TripUpdate?
    }

    private struct TripUpdate: Decodable {
        var Trip: Trip?
        var StopTimeUpdate: [StopTime]?
    }

    private struct Trip: Decodable {
        var TripId: String?
        var ScheduleRelationship: Relationship?
    }

    /// GTFS-realtime enums arrive as numbers or names depending on the encoder.
    private enum Relationship: Decodable {
        case cancelled, other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = number == 3 ? .cancelled : .other
            } else if let name = try? container.decode(String.self) {
                self = name.uppercased().hasPrefix("CANCEL") ? .cancelled : .other
            } else {
                self = .other
            }
        }
    }

    private struct StopTime: Decodable {
        var StopId: String?
        var Arrival: Event?
        var Departure: Event?
    }

    private struct Event: Decodable {
        var Time: Double?
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> Snapshot {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        var trips: [String: [StopUpdate]] = [:]
        var cancelled: Set<String> = []
        for entity in feed.Entities ?? [] {
            guard let update = entity.TripUpdate, let tripID = update.Trip?.TripId else { continue }
            if update.Trip?.ScheduleRelationship == .cancelled {
                cancelled.insert(tripID)
            }
            trips[tripID] = (update.StopTimeUpdate ?? []).compactMap { stop in
                guard let stopID = stop.StopId else { return nil }
                return StopUpdate(
                    stopID: stopID,
                    arrival: stop.Arrival?.Time.map(Date.init(timeIntervalSince1970:)),
                    departure: stop.Departure?.Time.map(Date.init(timeIntervalSince1970:))
                )
            }
        }
        return Snapshot(fetchedAt: fetchedAt, trips: trips, cancelled: cancelled)
    }
}

/// Timetable trains with live delays from `CaltrainLiveFeed` applied. Never fetches by itself;
/// the view model decides when the feed refreshes.
public struct LiveTimetableTransitProvider: TransitProvider {
    private let base: TimetableTransitProvider
    private let store: TimetableStore
    private let feed: CaltrainLiveFeed

    public init(store: TimetableStore, feed: CaltrainLiveFeed, calendar: Calendar = .caltrain) {
        self.base = TimetableTransitProvider(store: store, calendar: calendar)
        self.store = store
        self.feed = feed
    }

    public func departures(fromStation originID: String, toStation destinationID: String, after: Date, limit: Int) async throws -> TransitSnapshot {
        var snapshot = try await base.departures(fromStation: originID, toStation: destinationID, after: after, limit: limit)
        guard let live = await feed.latest(), let timetable = try? await store.current() else { return snapshot }

        snapshot.departures = snapshot.departures.map { departure in
            var updated = departure
            if live.cancelled.contains(departure.trainNumber) {
                updated.isCancelled = true
                updated.isTracked = true
            } else if let updates = live.trips[departure.trainNumber],
                      let delay = Self.delay(of: departure, originID: originID, updates: updates, timetable: timetable) {
                updated.delaySeconds = delay
                updated.isTracked = true
            }
            return updated
        }
        snapshot.source = .live
        snapshot.fetchedAt = live.fetchedAt
        return snapshot
    }

    /// Delay at the rider's station, or at the next predicted stop when the station has passed.
    static func delay(of departure: TrainDeparture, originID: String, updates: [CaltrainLiveFeed.StopUpdate], timetable: Timetable) -> Int? {
        func station(_ update: CaltrainLiveFeed.StopUpdate) -> String {
            timetable.platformStations[update.stopID] ?? update.stopID
        }
        if let atOrigin = updates.first(where: { station($0) == originID }),
           let predicted = atOrigin.departure ?? atOrigin.arrival {
            return max(0, Int(predicted.timeIntervalSince(departure.scheduledDeparture).rounded()))
        }
        guard let path = timetable.path(for: departure) else { return nil }
        for update in updates {
            guard let stop = path.stops.first(where: { $0.stationID == station(update) }) else { continue }
            if let predicted = update.departure {
                return max(0, Int(predicted.timeIntervalSince(stop.departure).rounded()))
            }
            if let predicted = update.arrival {
                return max(0, Int(predicted.timeIntervalSince(stop.arrival).rounded()))
            }
        }
        return nil
    }
}
