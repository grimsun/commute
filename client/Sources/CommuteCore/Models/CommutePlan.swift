import Foundation

/// Where the rider stands relative to the selected train.
/// Mirrors the push-notification sequence: get ready → leave now → too late → next train.
public enum CommuteState: String, Codable, CaseIterable, Sendable {
    /// Before the get-ready time for the target train.
    case onTrack
    /// Between get-ready and leave-now.
    case getReady
    /// Past leave-now, still catchable.
    case leaveNow
    /// The target train can no longer be caught; showing the next one.
    case rolledToNextTrain
}

public struct AttemptTimes: Equatable, Sendable {
    public var getReadyAt: Date
    /// Leaving now still arrives at the station with the safety buffer.
    public var leaveAt: Date
    /// Leaving after this misses the train even with no buffer.
    public var tooLateAt: Date

    public init(getReadyAt: Date, leaveAt: Date, tooLateAt: Date) {
        self.getReadyAt = getReadyAt
        self.leaveAt = leaveAt
        self.tooLateAt = tooLateAt
    }
}

public struct TrainOption: Equatable, Sendable {
    public var train: TrainDeparture
    public var attempts: AttemptTimes
    public var state: CommuteState
    /// The train after this one, in case this one is missed.
    public var fallback: TrainDeparture?
    /// Picked by the rider rather than chosen from the target time.
    public var isManual: Bool

    public init(train: TrainDeparture, attempts: AttemptTimes, state: CommuteState, fallback: TrainDeparture?, isManual: Bool = false) {
        self.train = train
        self.attempts = attempts
        self.state = state
        self.fallback = fallback
        self.isManual = isManual
    }

    /// The state as time passes after planning. A train that became too late reads as
    /// rolled over until the next plan picks the following one.
    public func state(at now: Date) -> CommuteState {
        if now > attempts.tooLateAt {
            return .rolledToNextTrain
        }
        let current = AttemptRules.state(now: now, attempts: attempts)
        // A replacement train still progresses to get ready and leave now.
        return state == .rolledToNextTrain && current == .onTrack ? .rolledToNextTrain : current
    }
}

public struct CarOption: Equatable, Sendable {
    public var eta: TimeInterval
    public var freeFlowETA: TimeInterval
    public var isTrafficGood: Bool

    public init(eta: TimeInterval, freeFlowETA: TimeInterval, isTrafficGood: Bool) {
        self.eta = eta
        self.freeFlowETA = freeFlowETA
        self.isTrafficGood = isTrafficGood
    }

    public var delay: TimeInterval { max(0, eta - freeFlowETA) }
}

public struct CommutePlan: Equatable, Sendable {
    public var generatedAt: Date
    public var direction: Direction
    public var originStation: Station
    public var destinationStation: Station
    public var targetLeave: Date
    /// Door to origin platform.
    public var accessTime: TimeInterval
    /// Destination platform to door.
    public var egressTime: TimeInterval
    public var safetyBuffer: TimeInterval
    public var prepLeadTime: TimeInterval
    /// `nil` when no preferred train is left today.
    public var train: TrainOption?
    /// The last couple of departed trains, then every upcoming train of all services,
    /// including cancelled ones.
    public var upcoming: [TrainDeparture]
    /// Departed trains the rider could still be travelling with (until the door arrival after
    /// them), including ones too old for `upcoming`.
    public var enRoute: [TrainDeparture]
    public var transitSource: TransitDataSource
    public var transitFetchedAt: Date
    public var transitNotice: String?
    /// `nil` when car routing is unavailable.
    public var car: CarOption?

    public init(
        generatedAt: Date,
        direction: Direction,
        originStation: Station,
        destinationStation: Station,
        targetLeave: Date,
        accessTime: TimeInterval,
        egressTime: TimeInterval,
        safetyBuffer: TimeInterval,
        prepLeadTime: TimeInterval,
        train: TrainOption?,
        upcoming: [TrainDeparture],
        enRoute: [TrainDeparture] = [],
        transitSource: TransitDataSource,
        transitFetchedAt: Date,
        transitNotice: String? = nil,
        car: CarOption?
    ) {
        self.generatedAt = generatedAt
        self.direction = direction
        self.originStation = originStation
        self.destinationStation = destinationStation
        self.targetLeave = targetLeave
        self.accessTime = accessTime
        self.egressTime = egressTime
        self.safetyBuffer = safetyBuffer
        self.prepLeadTime = prepLeadTime
        self.train = train
        self.upcoming = upcoming
        self.enRoute = enRoute
        self.transitSource = transitSource
        self.transitFetchedAt = transitFetchedAt
        self.transitNotice = transitNotice
        self.car = car
    }

    /// The commute this plan is for.
    public var key: CommuteKey {
        CommuteKey(date: targetLeave, direction: direction)
    }

    public func attempts(for train: TrainDeparture) -> AttemptTimes {
        AttemptRules.attempts(
            for: train,
            accessTime: accessTime,
            safetyBuffer: safetyBuffer,
            prepLeadTime: prepLeadTime
        )
    }

    /// When the rider reaches the destination door on this train.
    public func doorArrival(for train: TrainDeparture) -> Date {
        train.arrivalTime.addingTimeInterval(egressTime)
    }

    /// Minimum arrival gain for suggesting another train.
    public static let betterTrainMinimumGain: TimeInterval = 5 * 60

    /// A preferred train that lets the rider leave no earlier than for `current` yet arrives at least
    /// `betterTrainMinimumGain` sooner, e.g. an express overtaking a local. The soonest arrival wins.
    public func betterTrain(than current: TrainDeparture, preferred: Set<TrainService>) -> TrainDeparture? {
        let currentLeave = attempts(for: current).leaveAt
        return upcoming
            .filter {
                $0.id != current.id && $0.isUsable(preferred: preferred)
                    && attempts(for: $0).leaveAt >= currentLeave
                    && $0.arrivalTime <= current.arrivalTime.addingTimeInterval(-Self.betterTrainMinimumGain)
            }
            .min { $0.arrivalTime < $1.arrivalTime }
    }

    public func isCatchable(_ train: TrainDeparture, at now: Date) -> Bool {
        !train.isCancelled && now <= attempts(for: train).tooLateAt
    }
}

public enum AttemptRules {
    public static func attempts(
        for train: TrainDeparture,
        accessTime: TimeInterval,
        safetyBuffer: TimeInterval,
        prepLeadTime: TimeInterval
    ) -> AttemptTimes {
        let tooLate = train.departureTime.addingTimeInterval(-accessTime)
        let leave = tooLate.addingTimeInterval(-safetyBuffer)
        return AttemptTimes(
            getReadyAt: leave.addingTimeInterval(-prepLeadTime),
            leaveAt: leave,
            tooLateAt: tooLate
        )
    }

    /// Get ready → leave now progression for a train that is still catchable.
    public static func state(now: Date, attempts: AttemptTimes) -> CommuteState {
        if now < attempts.getReadyAt {
            return .onTrack
        }
        if now < attempts.leaveAt {
            return .getReady
        }
        return .leaveNow
    }
}
