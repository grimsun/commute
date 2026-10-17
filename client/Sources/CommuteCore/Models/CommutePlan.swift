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

    public init(train: TrainDeparture, attempts: AttemptTimes, state: CommuteState, fallback: TrainDeparture?) {
        self.train = train
        self.attempts = attempts
        self.state = state
        self.fallback = fallback
    }

    /// The state as time passes after planning. A train that became too late reads as
    /// rolled over until the next plan picks the following one.
    public func state(at now: Date) -> CommuteState {
        if state == .rolledToNextTrain || now > attempts.tooLateAt {
            return .rolledToNextTrain
        }
        return AttemptRules.state(now: now, attempts: attempts)
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
    /// Door-to-platform time: ride or walk plus overhead.
    public var accessTime: TimeInterval
    public var safetyBuffer: TimeInterval
    public var prepLeadTime: TimeInterval
    /// `nil` when no preferred train is left today.
    public var train: TrainOption?
    /// Upcoming trains of the preferred services, including cancelled ones.
    public var upcoming: [TrainDeparture]
    /// Upcoming trains hidden because their service is not preferred.
    public var hiddenTrainCount: Int
    public var transitSource: TransitDataSource
    public var transitFetchedAt: Date
    /// `nil` when car routing is unavailable.
    public var car: CarOption?

    public init(
        generatedAt: Date,
        direction: Direction,
        originStation: Station,
        destinationStation: Station,
        targetLeave: Date,
        accessTime: TimeInterval,
        safetyBuffer: TimeInterval,
        prepLeadTime: TimeInterval,
        train: TrainOption?,
        upcoming: [TrainDeparture],
        hiddenTrainCount: Int,
        transitSource: TransitDataSource,
        transitFetchedAt: Date,
        car: CarOption?
    ) {
        self.generatedAt = generatedAt
        self.direction = direction
        self.originStation = originStation
        self.destinationStation = destinationStation
        self.targetLeave = targetLeave
        self.accessTime = accessTime
        self.safetyBuffer = safetyBuffer
        self.prepLeadTime = prepLeadTime
        self.train = train
        self.upcoming = upcoming
        self.hiddenTrainCount = hiddenTrainCount
        self.transitSource = transitSource
        self.transitFetchedAt = transitFetchedAt
        self.car = car
    }

    public func attempts(for train: TrainDeparture) -> AttemptTimes {
        AttemptRules.attempts(
            for: train,
            accessTime: accessTime,
            safetyBuffer: safetyBuffer,
            prepLeadTime: prepLeadTime
        )
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
