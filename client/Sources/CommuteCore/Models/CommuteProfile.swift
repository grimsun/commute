import Foundation

public struct CommuteProfile: Codable, Equatable, Sendable {
    public var home: Place
    public var work: Place
    public var homeStationID: String
    public var workStationID: String

    /// How the rider gets to and from stations; drives icons and the Maps estimate.
    public var accessMode: AccessMode
    /// Riding speed used when estimating bike time from a route distance.
    public var bikeSpeedKph: Double
    /// Door-to-platform minutes between home and its station, either direction.
    public var homeStationMinutes: Int
    /// Door-to-platform minutes between work and its station, either direction.
    public var workStationMinutes: Int
    /// Slack between the planned arrival at the station and the departure.
    public var stationSafetyBufferMinutes: Int
    /// How long before "leave now" the "get ready" heads-up comes.
    public var prepLeadTimeMinutes: Int

    /// When the rider wants to leave home in the morning.
    public var morningTargetLeave: TimeOfDay
    /// When the rider wants to leave work in the evening.
    public var eveningTargetLeave: TimeOfDay
    /// Days with a commute, as `Calendar` weekday numbers (1 = Sunday).
    public var commuteDays: Set<Int>

    /// Train services the rider is willing to take.
    public var preferredServices: Set<TrainService>

    /// Car traffic counts as good while it is at most this much slower than free flow.
    public var carGoodDeltaMinutes: Int

    /// Whether the app schedules its own get ready / leave now notifications.
    public var leaveAlertsEnabled: Bool

    /// Where train data comes from.
    public var dataSource: DataSourceSettings

    /// Show the trip countdown on the Lock Screen and in the Dynamic Island.
    public var liveActivityEnabled: Bool

    /// Use location while the app is open to notice leaving home or work, or riding a train.
    /// Off, trips are only marked by hand.
    public var usesLocation: Bool

    /// The last stations looked up in schedule mode; `nil` starts from the commute stations.
    public var scheduleRoute: StationRoute?

    public init(
        home: Place,
        work: Place,
        homeStationID: String,
        workStationID: String,
        accessMode: AccessMode = .bike,
        bikeSpeedKph: Double = 16,
        homeStationMinutes: Int = 10,
        workStationMinutes: Int = 10,
        stationSafetyBufferMinutes: Int = 3,
        prepLeadTimeMinutes: Int = 20,
        morningTargetLeave: TimeOfDay = TimeOfDay(hour: 8, minute: 0),
        eveningTargetLeave: TimeOfDay = TimeOfDay(hour: 17, minute: 30),
        commuteDays: Set<Int> = [2, 3, 4, 5, 6],
        preferredServices: Set<TrainService> = Set(TrainService.allCases),
        carGoodDeltaMinutes: Int = 10,
        leaveAlertsEnabled: Bool = false,
        dataSource: DataSourceSettings = DataSourceSettings(),
        liveActivityEnabled: Bool = true,
        usesLocation: Bool = true,
        scheduleRoute: StationRoute? = nil
    ) {
        self.home = home
        self.work = work
        self.homeStationID = homeStationID
        self.workStationID = workStationID
        self.accessMode = accessMode
        self.bikeSpeedKph = bikeSpeedKph
        self.homeStationMinutes = homeStationMinutes
        self.workStationMinutes = workStationMinutes
        self.stationSafetyBufferMinutes = stationSafetyBufferMinutes
        self.prepLeadTimeMinutes = prepLeadTimeMinutes
        self.morningTargetLeave = morningTargetLeave
        self.eveningTargetLeave = eveningTargetLeave
        self.commuteDays = commuteDays
        self.preferredServices = preferredServices
        self.carGoodDeltaMinutes = carGoodDeltaMinutes
        self.leaveAlertsEnabled = leaveAlertsEnabled
        self.dataSource = dataSource
        self.liveActivityEnabled = liveActivityEnabled
        self.usesLocation = usesLocation
        self.scheduleRoute = scheduleRoute
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

    /// Door to origin platform.
    public func accessMinutes(for direction: Direction) -> Int {
        direction == .homeToWork ? homeStationMinutes : workStationMinutes
    }

    /// Destination platform to door.
    public func egressMinutes(for direction: Direction) -> Int {
        direction == .homeToWork ? workStationMinutes : homeStationMinutes
    }

    // Decoding tolerates missing keys so saved profiles survive new fields.
    private enum CodingKeys: String, CodingKey {
        case home, work, homeStationID, workStationID, accessMode, bikeSpeedKph, homeStationMinutes, workStationMinutes
        case stationSafetyBufferMinutes, prepLeadTimeMinutes, morningTargetLeave, eveningTargetLeave, commuteDays
        case preferredServices, carGoodDeltaMinutes, leaveAlertsEnabled, dataSource, liveActivityEnabled, usesLocation, scheduleRoute
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
        homeStationMinutes = try c.decodeIfPresent(Int.self, forKey: .homeStationMinutes) ?? d.homeStationMinutes
        workStationMinutes = try c.decodeIfPresent(Int.self, forKey: .workStationMinutes) ?? d.workStationMinutes
        stationSafetyBufferMinutes = try c.decodeIfPresent(Int.self, forKey: .stationSafetyBufferMinutes) ?? d.stationSafetyBufferMinutes
        prepLeadTimeMinutes = try c.decodeIfPresent(Int.self, forKey: .prepLeadTimeMinutes) ?? d.prepLeadTimeMinutes
        morningTargetLeave = try c.decodeIfPresent(TimeOfDay.self, forKey: .morningTargetLeave) ?? d.morningTargetLeave
        eveningTargetLeave = try c.decodeIfPresent(TimeOfDay.self, forKey: .eveningTargetLeave) ?? d.eveningTargetLeave
        commuteDays = try c.decodeIfPresent(Set<Int>.self, forKey: .commuteDays) ?? d.commuteDays
        preferredServices = try c.decodeIfPresent(Set<TrainService>.self, forKey: .preferredServices) ?? d.preferredServices
        carGoodDeltaMinutes = try c.decodeIfPresent(Int.self, forKey: .carGoodDeltaMinutes) ?? d.carGoodDeltaMinutes
        leaveAlertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .leaveAlertsEnabled) ?? d.leaveAlertsEnabled
        dataSource = try c.decodeIfPresent(DataSourceSettings.self, forKey: .dataSource) ?? d.dataSource
        liveActivityEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveActivityEnabled) ?? d.liveActivityEnabled
        usesLocation = try c.decodeIfPresent(Bool.self, forKey: .usesLocation) ?? d.usesLocation
        scheduleRoute = try c.decodeIfPresent(StationRoute.self, forKey: .scheduleRoute)
    }
}
