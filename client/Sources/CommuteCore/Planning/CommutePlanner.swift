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
    private let traffic: TrafficProvider?
    private let calendar: Calendar

    public init(transit: TransitProvider, traffic: TrafficProvider?, calendar: Calendar = .caltrain) {
        self.transit = transit
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

        let targetLeave = profile.targetLeave(for: direction).date(on: now, calendar: calendar)

        async let car = carOption(
            from: profile.origin(for: direction).coordinate,
            to: profile.destination(for: direction).coordinate,
            now: now,
            profile: profile
        )
        let snapshot = try await transit.departures(
            fromStation: originID,
            toStation: destinationID,
            after: min(now, targetLeave),
            limit: 24
        )

        let accessTime = TimeInterval(profile.accessMinutes(for: direction) * 60)
        let safetyBuffer = TimeInterval(profile.stationSafetyBufferMinutes * 60)
        let prepLeadTime = TimeInterval(profile.prepLeadTimeMinutes * 60)
        let attempts: (TrainDeparture) -> AttemptTimes = {
            AttemptRules.attempts(for: $0, accessTime: accessTime, safetyBuffer: safetyBuffer, prepLeadTime: prepLeadTime)
        }

        let preferred = snapshot.departures
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
        let hidden = snapshot.departures.filter {
            !profile.preferredServices.contains($0.service) && $0.departureTime >= visibleFrom
        }

        return CommutePlan(
            generatedAt: now,
            direction: direction,
            originStation: originStation,
            destinationStation: destinationStation,
            targetLeave: targetLeave,
            accessTime: accessTime,
            egressTime: TimeInterval(profile.egressMinutes(for: direction) * 60),
            safetyBuffer: safetyBuffer,
            prepLeadTime: prepLeadTime,
            train: trainOption,
            upcoming: upcoming,
            hiddenTrainCount: hidden.count,
            transitSource: snapshot.source,
            transitFetchedAt: snapshot.fetchedAt,
            transitNotice: snapshot.notice,
            car: await car
        )
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
