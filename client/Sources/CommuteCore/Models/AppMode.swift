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
