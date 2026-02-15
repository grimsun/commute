import Foundation

public actor DefaultPlanner: Planner {
    private let trafficProvider: TrafficProvider
    private let transitProvider: TransitProvider
    private let bikeProvider: BikeETAProvider

    public init(trafficProvider: TrafficProvider, transitProvider: TransitProvider, bikeProvider: BikeETAProvider) {
        self.trafficProvider = trafficProvider
        self.transitProvider = transitProvider
        self.bikeProvider = bikeProvider
    }

    public func computePlan(profile: CommuteProfile, tripRequest: TripRequest, now: Date) async throws -> CommutePlan {
        let fromAddress = tripRequest.direction == .homeToWork ? profile.homeAddress : profile.workAddress
        let toAddress = tripRequest.direction == .homeToWork ? profile.workAddress : profile.homeAddress
        let station = tripRequest.direction == .homeToWork ? profile.homeStation : profile.workStation

        let reference: DepartureTimeReference = tripRequest.planningMode == .arriveBy
            ? .arriveBy(tripRequest.targetDateTime)
            : .leaveAt(tripRequest.targetDateTime)

        async let carETA = trafficProvider.carETA(from: fromAddress, to: toAddress, departureOrArrival: reference)
        async let baselineETA = trafficProvider.baselineCarETA(for: tripRequest.direction, at: now)
        async let bikeToStation = bikeProvider.bikeETA(from: fromAddress, to: station, at: now)
        async let trains = transitProvider.nextTrains(station: station, line: profile.trainLine, after: now, limit: 8)

        let computedCarETA = try await carETA
        let computedBaseline = try await baselineETA
        let bikeETASeconds = try await bikeToStation + TimeInterval(profile.bikeBufferMinutes * 60)
        let nextTrains = try await trains.sorted { $0.departureTime < $1.departureTime }

        guard !nextTrains.isEmpty else {
            throw PlannerError.noTrainData
        }

        let selectedTrain: TrainDeparture
        let fallbackTrain: TrainDeparture?

        switch tripRequest.planningMode {
        case .arriveBy:
            let trainsBeforeTarget = nextTrains.filter { $0.arrivalTime <= tripRequest.targetDateTime }
            let feasible = firstFeasibleTrain(
                in: trainsBeforeTarget.isEmpty ? nextTrains : trainsBeforeTarget,
                now: now,
                bikeETASeconds: bikeETASeconds
            )
            selectedTrain = feasible.selected
            fallbackTrain = feasible.fallback
        case .leaveAt:
            let candidate = firstFeasibleTrain(
                in: nextTrains.filter { $0.departureTime >= tripRequest.targetDateTime },
                now: tripRequest.targetDateTime,
                bikeETASeconds: bikeETASeconds
            )
            selectedTrain = candidate.selected
            fallbackTrain = candidate.fallback
        }

        let leaveAt = selectedTrain.departureTime.addingTimeInterval(-bikeETASeconds)
        let tooLateAt = selectedTrain.departureTime.addingTimeInterval(-60) // Explicit 1-minute feasibility rule.
        let getReadyAt = leaveAt.addingTimeInterval(-TimeInterval(profile.prepLeadTimeMinutes * 60))

        let attempts = AttemptTimes(getReadyAt: getReadyAt, leaveAt: leaveAt, tooLateAt: tooLateAt)
        let state = commuteState(now: now, attempts: attempts, selectedTrain: selectedTrain)

        let allowedETA = computedBaseline + TimeInterval(profile.carGoodDeltaMinutes * 60)
        let isGood = computedCarETA <= allowedETA

        let car = CarOption(
            eta: computedCarETA,
            baselineETA: computedBaseline,
            isTrafficGood: isGood,
            reason: isGood ? "Traffic is within threshold" : "Traffic exceeds baseline threshold"
        )

        let multimodal = MultimodalOption(selectedTrain: selectedTrain, attemptTimes: attempts, fallbackTrain: fallbackTrain)
        return CommutePlan(generatedAt: now, carOption: car, multimodalOption: multimodal, state: state)
    }

    private func firstFeasibleTrain(in trains: [TrainDeparture], now: Date, bikeETASeconds: TimeInterval) -> (selected: TrainDeparture, fallback: TrainDeparture?) {
        guard let first = trains.first else {
            fatalError("Expected at least one train candidate")
        }

        let estimatedArrivalAtStation = now.addingTimeInterval(bikeETASeconds)
        if let idx = trains.firstIndex(where: {
            estimatedArrivalAtStation <= $0.departureTime.addingTimeInterval(-60)
        }) {
            let selected = trains[idx]
            let fallback = trains.dropFirst(idx + 1).first
            return (selected, fallback)
        }

        return (first, trains.dropFirst().first)
    }

    private func commuteState(now: Date, attempts: AttemptTimes, selectedTrain: TrainDeparture) -> CommuteState {
        if now > attempts.tooLateAt {
            return .rolledToNextTrain
        }
        if now >= attempts.leaveAt {
            return .leaveNow
        }
        if now >= attempts.getReadyAt {
            return .onTrack
        }
        if now >= selectedTrain.departureTime {
            return .tooLate
        }
        return .onTrack
    }
}

public enum PlannerError: Error, Equatable {
    case noTrainData
}
