import Foundation

public struct CommuteProfile: Codable, Equatable, Sendable {
    public var home: Place
    public var work: Place
    public var homeStationID: String
    public var workStationID: String

    /// How the rider gets to and from stations.
    public var accessMode: AccessMode
    /// Riding speed used to turn route distance into bike time.
    public var bikeSpeedKph: Double
    /// Fixed time on top of the ride or walk: locking up, reaching the platform.
    public var accessOverheadMinutes: Int
    /// Slack between the planned arrival at the station and the departure.
    public var stationSafetyBufferMinutes: Int
    /// How long before "leave now" the "get ready" heads-up comes.
    public var prepLeadTimeMinutes: Int

    /// When the rider wants to leave home in the morning.
    public var morningTargetLeave: TimeOfDay
    /// When the rider wants to leave work in the evening.
    public var eveningTargetLeave: TimeOfDay

    /// Train services the rider is willing to take.
    public var preferredServices: Set<TrainService>

    /// Car traffic counts as good while it is at most this much slower than free flow.
    public var carGoodDeltaMinutes: Int

    public init(
        home: Place,
        work: Place,
        homeStationID: String,
        workStationID: String,
        accessMode: AccessMode = .bike,
        bikeSpeedKph: Double = 16,
        accessOverheadMinutes: Int = 2,
        stationSafetyBufferMinutes: Int = 3,
        prepLeadTimeMinutes: Int = 20,
        morningTargetLeave: TimeOfDay = TimeOfDay(hour: 8, minute: 0),
        eveningTargetLeave: TimeOfDay = TimeOfDay(hour: 17, minute: 30),
        preferredServices: Set<TrainService> = Set(TrainService.allCases),
        carGoodDeltaMinutes: Int = 10
    ) {
        self.home = home
        self.work = work
        self.homeStationID = homeStationID
        self.workStationID = workStationID
        self.accessMode = accessMode
        self.bikeSpeedKph = bikeSpeedKph
        self.accessOverheadMinutes = accessOverheadMinutes
        self.stationSafetyBufferMinutes = stationSafetyBufferMinutes
        self.prepLeadTimeMinutes = prepLeadTimeMinutes
        self.morningTargetLeave = morningTargetLeave
        self.eveningTargetLeave = eveningTargetLeave
        self.preferredServices = preferredServices
        self.carGoodDeltaMinutes = carGoodDeltaMinutes
    }

    public static let `default` = CommuteProfile(
        home: Place(name: "San Francisco Caltrain", coordinate: Coordinate(latitude: 37.7764, longitude: -122.3946)),
        work: Place(name: "Palo Alto Caltrain", coordinate: Coordinate(latitude: 37.4436, longitude: -122.1651)),
        homeStationID: "san_francisco",
        workStationID: "palo_alto"
    )

    public func origin(for direction: Direction) -> Place {
        direction == .homeToWork ? home : work
    }

    public func destination(for direction: Direction) -> Place {
        direction == .homeToWork ? work : home
    }

    public func originStationID(for direction: Direction) -> String {
        direction == .homeToWork ? homeStationID : workStationID
    }

    public func destinationStationID(for direction: Direction) -> String {
        direction == .homeToWork ? workStationID : homeStationID
    }

    public func targetLeave(for direction: Direction) -> TimeOfDay {
        direction == .homeToWork ? morningTargetLeave : eveningTargetLeave
    }

    // Decoding tolerates missing keys so saved profiles survive new fields.
    private enum CodingKeys: String, CodingKey {
        case home, work, homeStationID, workStationID, accessMode, bikeSpeedKph, accessOverheadMinutes
        case stationSafetyBufferMinutes, prepLeadTimeMinutes, morningTargetLeave, eveningTargetLeave
        case preferredServices, carGoodDeltaMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CommuteProfile.default
        home = try c.decodeIfPresent(Place.self, forKey: .home) ?? d.home
        work = try c.decodeIfPresent(Place.self, forKey: .work) ?? d.work
        homeStationID = try c.decodeIfPresent(String.self, forKey: .homeStationID) ?? d.homeStationID
        workStationID = try c.decodeIfPresent(String.self, forKey: .workStationID) ?? d.workStationID
        accessMode = try c.decodeIfPresent(AccessMode.self, forKey: .accessMode) ?? d.accessMode
        bikeSpeedKph = try c.decodeIfPresent(Double.self, forKey: .bikeSpeedKph) ?? d.bikeSpeedKph
        accessOverheadMinutes = try c.decodeIfPresent(Int.self, forKey: .accessOverheadMinutes) ?? d.accessOverheadMinutes
        stationSafetyBufferMinutes = try c.decodeIfPresent(Int.self, forKey: .stationSafetyBufferMinutes) ?? d.stationSafetyBufferMinutes
        prepLeadTimeMinutes = try c.decodeIfPresent(Int.self, forKey: .prepLeadTimeMinutes) ?? d.prepLeadTimeMinutes
        morningTargetLeave = try c.decodeIfPresent(TimeOfDay.self, forKey: .morningTargetLeave) ?? d.morningTargetLeave
        eveningTargetLeave = try c.decodeIfPresent(TimeOfDay.self, forKey: .eveningTargetLeave) ?? d.eveningTargetLeave
        preferredServices = try c.decodeIfPresent(Set<TrainService>.self, forKey: .preferredServices) ?? d.preferredServices
        carGoodDeltaMinutes = try c.decodeIfPresent(Int.self, forKey: .carGoodDeltaMinutes) ?? d.carGoodDeltaMinutes
    }
}
