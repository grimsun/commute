import Foundation

/// What the Lock Screen / Dynamic Island countdown shows for the trip on the card.
public struct LiveTrip: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        /// Not left yet: counts down to the leave time.
        case planned
        /// Left, train not departed: counts down to the train.
        case onTheWay
        /// On board: counts down to arrival.
        case onTrain
    }

    public var phase: Phase
    public var originName: String
    public var destinationName: String
    /// "work" or "home", for "Home at 7:02 PM".
    public var destinationPlace: String
    public var trainNumber: String
    public var serviceName: String
    public var leaveAt: Date
    public var tooLateAt: Date
    public var departure: Date
    public var arrival: Date
    public var doorArrival: Date

    /// When the activity should go away.
    public var endsAt: Date {
        phase == .planned ? tooLateAt : doorArrival
    }

    /// The moment the main countdown runs to.
    public var countdownTarget: Date {
        switch phase {
        case .planned: leaveAt
        case .onTheWay: departure
        case .onTrain: arrival
        }
    }

    public var countdownLabel: String {
        switch phase {
        case .planned: "Leave in"
        case .onTheWay: "Train in"
        case .onTrain: "Arrives in"
        }
    }

    /// Shown from this long before leaving; earlier it would only be clutter.
    public static let leadTime: TimeInterval = 60 * 60

    /// The trip worth showing at `now`, if any: the planned train within the lead time, or the
    /// train being taken until the door.
    public static func current(plan: CommutePlan?, departedTrain: TrainDeparture?, now: Date) -> LiveTrip? {
        guard let plan else { return nil }
        let phase: Phase
        let train: TrainDeparture
        if let departedTrain {
            train = departedTrain
            phase = now < departedTrain.departureTime ? .onTheWay : .onTrain
        } else if let option = plan.train {
            train = option.train
            phase = .planned
        } else {
            return nil
        }
        let attempts = plan.attempts(for: train)
        let trip = LiveTrip(
            phase: phase,
            originName: plan.originStation.name,
            destinationName: plan.destinationStation.name,
            destinationPlace: plan.direction == .homeToWork ? "work" : "home",
            trainNumber: train.trainNumber,
            serviceName: train.service.displayName,
            leaveAt: attempts.leaveAt,
            tooLateAt: attempts.tooLateAt,
            departure: train.departureTime,
            arrival: train.arrivalTime,
            doorArrival: plan.doorArrival(for: train)
        )
        if phase == .planned && now < attempts.leaveAt.addingTimeInterval(-leadTime) {
            return nil
        }
        return now < trip.endsAt ? trip : nil
    }
}

/// Keeps the system's Live Activity in step with the current trip.
@MainActor
public protocol LiveActivityUpdating: AnyObject {
    func sync(_ trip: LiveTrip?) async
}
