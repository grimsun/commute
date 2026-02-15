import Foundation

public actor MockTrafficProvider: TrafficProvider {
    public var currentETA: TimeInterval
    public var baselineETA: TimeInterval

    public init(currentETA: TimeInterval = 34 * 60, baselineETA: TimeInterval = 28 * 60) {
        self.currentETA = currentETA
        self.baselineETA = baselineETA
    }

    public func carETA(from: String, to: String, departureOrArrival: DepartureTimeReference) async throws -> TimeInterval {
        currentETA
    }

    public func baselineCarETA(for direction: Direction, at: Date) async throws -> TimeInterval {
        baselineETA
    }
}

public actor MockTransitProvider: TransitProvider {
    public var departures: [TrainDeparture]

    public init(referenceNow: Date = Date()) {
        departures = [
            TrainDeparture(
                tripId: "T-001",
                departureTime: referenceNow.addingTimeInterval(12 * 60),
                arrivalTime: referenceNow.addingTimeInterval(36 * 60),
                platform: "1"
            ),
            TrainDeparture(
                tripId: "T-002",
                departureTime: referenceNow.addingTimeInterval(27 * 60),
                arrivalTime: referenceNow.addingTimeInterval(51 * 60),
                platform: "2"
            ),
            TrainDeparture(
                tripId: "T-003",
                departureTime: referenceNow.addingTimeInterval(42 * 60),
                arrivalTime: referenceNow.addingTimeInterval(66 * 60),
                platform: "2"
            )
        ]
    }

    public init(departures: [TrainDeparture]) {
        self.departures = departures
    }

    public func nextTrains(station: String, line: String, after: Date, limit: Int) async throws -> [TrainDeparture] {
        Array(
            departures
                .filter { $0.departureTime >= after }
                .sorted { $0.departureTime < $1.departureTime }
                .prefix(limit)
        )
    }
}

public actor MockBikeETAProvider: BikeETAProvider {
    public var etaSeconds: TimeInterval

    public init(etaSeconds: TimeInterval = 8 * 60) {
        self.etaSeconds = etaSeconds
    }

    public func bikeETA(from: String, to: String, at: Date) async throws -> TimeInterval {
        etaSeconds
    }
}

public actor InMemoryProfileStore: CommuteProfileStore {
    private var profile: CommuteProfile?

    public init(profile: CommuteProfile? = nil) {
        self.profile = profile
    }

    public func loadProfile() async -> CommuteProfile? {
        profile
    }

    public func saveProfile(_ profile: CommuteProfile) async {
        self.profile = profile
    }
}

public actor NoopNotificationScheduler: NotificationScheduler {
    public init() {}

    public func schedule(plan: CommutePlan, tripRequest: TripRequest) async {}
    public func cancel(for tripRequest: TripRequest) async {}
}
