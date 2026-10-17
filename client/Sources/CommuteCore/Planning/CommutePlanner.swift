import Foundation

public protocol CommutePlanning: Sendable {
    func plan(profile: CommuteProfile, direction: Direction, now: Date) async throws -> CommutePlan
}

public enum PlannerError: Error, Equatable {
    case unknownStation(String)
    case sameStation
}

/// Picks the train for a commute and the get-ready / leave / too-late times around it.
///
/// The target train is the first preferred train the rider catches, with the safety buffer,
/// when leaving at the target time. While it is still catchable the plan follows it through
/// get ready → leave now. Once it is not, the plan rolls to the next catchable train.
public struct DefaultPlanner: CommutePlanning {
    private let transit: TransitProvider
    private let access: StationAccessProvider
    private let traffic: TrafficProvider?
    private let calendar: Calendar

    public init(
        transit: TransitProvider,
        access: StationAccessProvider,
        traffic: TrafficProvider?,
        calendar: Calendar = .caltrain
    ) {
        self.transit = transit
        self.access = access
        self.traffic = traffic
        self.calendar = calendar
    }

    public func plan(profile: CommuteProfile, direction: Direction, now: Date) async throws -> CommutePlan {
        let originID = profile.originStationID(for: direction)
        let destinationID = profile.destinationStationID(for: direction)
        guard let originStation = StationCatalog.station(id: originID) else {
            throw PlannerError.unknownStation(originID)
        }
        guard let destinationStation = StationCatalog.station(id: destinationID) else {
            throw PlannerError.unknownStation(destinationID)
        }
        guard originID != destinationID else {
            throw PlannerError.sameStation
        }

        let origin = profile.origin(for: direction)
        let destination = profile.destination(for: direction)
        let targetLeave = profile.targetLeave(for: direction).date(on: now, calendar: calendar)

        async let snapshot = transit.departures(
            fromStation: originID,
            toStation: destinationID,
            after: min(now, targetLeave),
            limit: 24
        )
        async let ride = accessTime(from: origin.coordinate ?? originStation.coordinate, to: originStation, profile: profile)
        async let car = carOption(from: origin.coordinate, to: destination.coordinate, now: now, profile: profile)

        let accessTime = try await ride + TimeInterval(profile.accessOverheadMinutes * 60)
        let safetyBuffer = TimeInterval(profile.stationSafetyBufferMinutes * 60)
        let prepLeadTime = TimeInterval(profile.prepLeadTimeMinutes * 60)
        let transitSnapshot = try await snapshot

        let attempts: (TrainDeparture) -> AttemptTimes = {
            AttemptRules.attempts(for: $0, accessTime: accessTime, safetyBuffer: safetyBuffer, prepLeadTime: prepLeadTime)
        }

        let preferred = transitSnapshot.departures
            .filter { profile.preferredServices.contains($0.service) }
            .sorted { $0.departureTime < $1.departureTime }
        let candidates = preferred.filter { !$0.isCancelled }

        let target = candidates.first { attempts($0).leaveAt >= targetLeave }
        let selected: TrainDeparture?
        let state: CommuteState
        if let target, now <= attempts(target).tooLateAt {
            selected = target
            state = AttemptRules.state(now: now, attempts: attempts(target))
        } else {
            selected = candidates.first { now <= attempts($0).tooLateAt }
            state = .rolledToNextTrain
        }

        let trainOption = selected.map { train in
            TrainOption(
                train: train,
                attempts: attempts(train),
                state: state,
                fallback: candidates.first { $0.departureTime > train.departureTime }
            )
        }

        let visibleFrom = now.addingTimeInterval(-60)
        let upcoming = preferred.filter { $0.departureTime >= visibleFrom }
        let hidden = transitSnapshot.departures.filter {
            !profile.preferredServices.contains($0.service) && $0.departureTime >= visibleFrom
        }

        return CommutePlan(
            generatedAt: now,
            direction: direction,
            originStation: originStation,
            destinationStation: destinationStation,
            targetLeave: targetLeave,
            accessTime: accessTime,
            safetyBuffer: safetyBuffer,
            prepLeadTime: prepLeadTime,
            train: trainOption,
            upcoming: upcoming,
            hiddenTrainCount: hidden.count,
            transitSource: transitSnapshot.source,
            transitFetchedAt: transitSnapshot.fetchedAt,
            car: await car
        )
    }

    private func accessTime(from: Coordinate, to station: Station, profile: CommuteProfile) async throws -> TimeInterval {
        do {
            return try await access.travelTime(from: from, to: station.coordinate, mode: profile.accessMode, bikeSpeedKph: profile.bikeSpeedKph)
        } catch {
            return try await StraightLineAccessProvider().travelTime(
                from: from,
                to: station.coordinate,
                mode: profile.accessMode,
                bikeSpeedKph: profile.bikeSpeedKph
            )
        }
    }

    private func carOption(from: Coordinate?, to: Coordinate?, now: Date, profile: CommuteProfile) async -> CarOption? {
        guard let traffic, let from, let to else { return nil }
        do {
            async let eta = traffic.carETA(from: from, to: to, departure: now)
            async let freeFlow = traffic.freeFlowCarETA(from: from, to: to)
            let current = try await eta
            let baseline = try await freeFlow
            let allowed = baseline + TimeInterval(profile.carGoodDeltaMinutes * 60)
            return CarOption(eta: current, freeFlowETA: baseline, isTrafficGood: current <= allowed)
        } catch {
            return nil
        }
    }
}
