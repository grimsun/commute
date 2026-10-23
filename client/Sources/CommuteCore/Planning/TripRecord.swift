import Foundation

/// What the rider has done about each commute: set off on a train (by hand or noticed by
/// location), or ended the trip by hand. The rules for which train that is and when the trip is
/// over live here, so the card, map, alerts and Lock Screen agree.
public struct TripRecord: Equatable, Sendable {
    /// Commutes under way.
    public var departed: Set<CommuteKey>
    /// The train each departed commute is on, when known.
    public var trainNumbers: [CommuteKey: String]
    /// Commutes ended by hand; location doesn't start them again.
    public var ended: Set<CommuteKey>

    public init(departed: Set<CommuteKey> = [], trainNumbers: [CommuteKey: String] = [:], ended: Set<CommuteKey> = []) {
        self.departed = departed
        self.trainNumbers = trainNumbers
        self.ended = ended
    }

    public func isUnderWay(_ key: CommuteKey) -> Bool {
        departed.contains(key)
    }

    public mutating func take(_ trainNumber: String?, for key: CommuteKey) {
        departed.insert(key)
        trainNumbers[key] = trainNumber
        ended.remove(key)
    }

    public mutating func end(_ key: CommuteKey) {
        departed.remove(key)
        trainNumbers[key] = nil
        ended.insert(key)
    }

    /// The train taken on a departed trip, as the plan has it (so with the latest delays). Without
    /// a known number (an older record) it is inferred: the latest running train, else the planned
    /// one. `nil` once a known train has left the plan, which means the trip is over.
    public func takenTrain(for key: CommuteKey, in plan: CommutePlan, preferred: Set<TrainService>, now: Date) -> TrainDeparture? {
        guard departed.contains(key) else { return nil }
        if let number = trainNumbers[key] {
            return plan.train(number: number)
        }
        return plan.runningTrains(preferred: preferred, at: now).last ?? plan.train?.train
    }

    /// Over once the rider could have reached the door, or the known train has left the plan.
    public func isComplete(_ key: CommuteKey, in plan: CommutePlan, preferred: Set<TrainService>, now: Date) -> Bool {
        guard departed.contains(key) else { return false }
        guard let train = takenTrain(for: key, in: plan, preferred: preferred, now: now) else {
            return trainNumbers[key] != nil
        }
        return now >= plan.doorArrival(for: train)
    }
}

extension CommutePlan {
    /// Trains of this trip (preferred, the target or later) that have left but not arrived:
    /// the ones a rider already past the station could be on.
    public func runningTrains(preferred: Set<TrainService>, at date: Date) -> [TrainDeparture] {
        enRoute.filter {
            $0.isUsable(preferred: preferred)
                && attempts(for: $0).leaveAt >= targetLeave
                && $0.departureTime <= date && date < $0.arrivalTime
        }
    }

    /// A listed or still-travelling train by number.
    public func train(number: String) -> TrainDeparture? {
        upcoming.first { $0.trainNumber == number } ?? enRoute.first { $0.trainNumber == number }
    }
}
