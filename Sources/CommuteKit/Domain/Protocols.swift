import Foundation

public protocol TrafficProvider: Sendable {
    func carETA(from: String, to: String, departureOrArrival: DepartureTimeReference) async throws -> TimeInterval
    func baselineCarETA(for direction: Direction, at: Date) async throws -> TimeInterval
}

public protocol TransitProvider: Sendable {
    func nextTrains(station: String, line: String, after: Date, limit: Int) async throws -> [TrainDeparture]
}

public protocol BikeETAProvider: Sendable {
    func bikeETA(from: String, to: String, at: Date) async throws -> TimeInterval
}

public protocol NotificationScheduler: Sendable {
    func schedule(plan: CommutePlan, tripRequest: TripRequest) async
    func cancel(for tripRequest: TripRequest) async
}

public protocol Planner: Sendable {
    func computePlan(profile: CommuteProfile, tripRequest: TripRequest, now: Date) async throws -> CommutePlan
}

public protocol CommuteProfileStore: Sendable {
    func loadProfile() async -> CommuteProfile?
    func saveProfile(_ profile: CommuteProfile) async
}
