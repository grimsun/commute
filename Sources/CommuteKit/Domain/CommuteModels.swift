import Foundation

public enum Direction: String, Codable, CaseIterable, Sendable {
    case homeToWork
    case workToHome
}

public enum PlanningMode: String, Codable, CaseIterable, Sendable {
    case arriveBy
    case leaveAt
}

public enum ModePreference: String, Codable, CaseIterable, Sendable {
    case car
    case multimodal
    case auto
}

public enum CommuteState: String, Codable, CaseIterable, Sendable {
    case onTrack
    case leaveNow
    case tooLate
    case rolledToNextTrain
}

public enum DepartureTimeReference: Sendable {
    case arriveBy(Date)
    case leaveAt(Date)
}

public struct CommuteProfile: Codable, Equatable, Sendable {
    public var id: UUID
    public var homeAddress: String
    public var workAddress: String
    public var homeStation: String
    public var workStation: String
    public var trainLine: String
    public var bikeBufferMinutes: Int
    public var stationSafetyBufferMinutes: Int
    public var prepLeadTimeMinutes: Int
    public var carGoodDeltaMinutes: Int
    public var defaultPlanningMode: PlanningMode

    public init(
        id: UUID = UUID(),
        homeAddress: String,
        workAddress: String,
        homeStation: String,
        workStation: String,
        trainLine: String,
        bikeBufferMinutes: Int = 5,
        stationSafetyBufferMinutes: Int = 5,
        prepLeadTimeMinutes: Int = 20,
        carGoodDeltaMinutes: Int = 10,
        defaultPlanningMode: PlanningMode = .arriveBy
    ) {
        self.id = id
        self.homeAddress = homeAddress
        self.workAddress = workAddress
        self.homeStation = homeStation
        self.workStation = workStation
        self.trainLine = trainLine
        self.bikeBufferMinutes = bikeBufferMinutes
        self.stationSafetyBufferMinutes = stationSafetyBufferMinutes
        self.prepLeadTimeMinutes = prepLeadTimeMinutes
        self.carGoodDeltaMinutes = carGoodDeltaMinutes
        self.defaultPlanningMode = defaultPlanningMode
    }
}

public struct TripRequest: Equatable, Sendable {
    public var direction: Direction
    public var modePreference: ModePreference
    public var planningMode: PlanningMode
    public var targetDateTime: Date

    public init(
        direction: Direction,
        modePreference: ModePreference,
        planningMode: PlanningMode,
        targetDateTime: Date
    ) {
        self.direction = direction
        self.modePreference = modePreference
        self.planningMode = planningMode
        self.targetDateTime = targetDateTime
    }
}

public struct TrainDeparture: Equatable, Sendable {
    public var tripId: String
    public var departureTime: Date
    public var arrivalTime: Date
    public var delaySeconds: Int
    public var platform: String?

    public init(
        tripId: String,
        departureTime: Date,
        arrivalTime: Date,
        delaySeconds: Int = 0,
        platform: String? = nil
    ) {
        self.tripId = tripId
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.delaySeconds = delaySeconds
        self.platform = platform
    }
}

public struct AttemptTimes: Equatable, Sendable {
    public var getReadyAt: Date
    public var leaveAt: Date
    public var tooLateAt: Date

    public init(getReadyAt: Date, leaveAt: Date, tooLateAt: Date) {
        self.getReadyAt = getReadyAt
        self.leaveAt = leaveAt
        self.tooLateAt = tooLateAt
    }
}

public struct CarOption: Equatable, Sendable {
    public var eta: TimeInterval
    public var baselineETA: TimeInterval
    public var isTrafficGood: Bool
    public var reason: String

    public init(eta: TimeInterval, baselineETA: TimeInterval, isTrafficGood: Bool, reason: String) {
        self.eta = eta
        self.baselineETA = baselineETA
        self.isTrafficGood = isTrafficGood
        self.reason = reason
    }
}

public struct MultimodalOption: Equatable, Sendable {
    public var selectedTrain: TrainDeparture
    public var attemptTimes: AttemptTimes
    public var fallbackTrain: TrainDeparture?

    public init(selectedTrain: TrainDeparture, attemptTimes: AttemptTimes, fallbackTrain: TrainDeparture?) {
        self.selectedTrain = selectedTrain
        self.attemptTimes = attemptTimes
        self.fallbackTrain = fallbackTrain
    }
}

public struct CommutePlan: Equatable, Sendable {
    public var generatedAt: Date
    public var carOption: CarOption
    public var multimodalOption: MultimodalOption
    public var state: CommuteState

    public init(generatedAt: Date, carOption: CarOption, multimodalOption: MultimodalOption, state: CommuteState) {
        self.generatedAt = generatedAt
        self.carOption = carOption
        self.multimodalOption = multimodalOption
        self.state = state
    }
}
