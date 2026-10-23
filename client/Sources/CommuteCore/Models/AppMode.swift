import Foundation

/// Commute plans leaving home and work around the target times; schedule shows the next trains
/// between any two stations.
public enum AppMode: String, Codable, CaseIterable, Sendable {
    case commute
    case schedule

    public var title: String {
        switch self {
        case .commute: "Commute"
        case .schedule: "Schedule"
        }
    }

    public var other: AppMode {
        self == .commute ? .schedule : .commute
    }
}

/// A station pair for schedule mode.
public struct StationRoute: Codable, Equatable, Sendable {
    public var originStationID: String
    public var destinationStationID: String

    public init(originStationID: String, destinationStationID: String) {
        self.originStationID = originStationID
        self.destinationStationID = destinationStationID
    }

    public var reversed: StationRoute {
        StationRoute(originStationID: destinationStationID, destinationStationID: originStationID)
    }
}

extension CommuteProfile {
    /// Schedule mode's trip: home → work between the route's stations, leaving at `date`, with
    /// no travel to them, buffer or prep time.
    public func stationToStation(_ route: StationRoute, at date: Date) -> CommuteProfile {
        var result = self
        for (id, keyPath) in [(route.originStationID, \CommuteProfile.home), (route.destinationStationID, \CommuteProfile.work)] {
            if let station = StationCatalog.station(id: id) {
                result[keyPath: keyPath] = Place(name: station.name, coordinate: station.coordinate)
            }
        }
        result.homeStationID = route.originStationID
        result.workStationID = route.destinationStationID
        result.homeStationMinutes = 0
        result.workStationMinutes = 0
        result.stationSafetyBufferMinutes = 0
        result.prepLeadTimeMinutes = 0
        result.morningTargetLeave = TimeOfDay(date: date)
        result.eveningTargetLeave = TimeOfDay(date: date)
        return result
    }
}
