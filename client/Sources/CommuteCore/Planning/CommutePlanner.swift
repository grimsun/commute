import Foundation

public protocol CommutePlanning: Sendable {
    /// `pickedTripID` is a train the rider chose; it is followed while it can still be caught.
    func plan(profile: CommuteProfile, direction: Direction, now: Date, pickedTripID: String?) async throws -> CommutePlan
}

public enum PlannerError: Error, Equatable {
    case unknownStation(String)
    case sameStation
}

/// Picks the train for a commute and the get-ready / leave / too-late times around it.
///
/// The target train is the first preferred train the rider catches, with the safety buffer,
/// when leaving at the target time. While it is still catchable the plan follows it through
/// get ready → leave now. Once it is not, the plan rolls to the next catchable preferred train,
/// for up to `CommuteWindow.rolloverInterval` after the target; then the target moves to tomorrow.
/// A train the rider picked overrides all of this while it can still be caught.
public struct DefaultPlanner: CommutePlanning {
    /// How many already-departed trains lead the list, for context.
    static let departedShown = 1
    static let departedLookback: TimeInterval = 90 * 60

    private let transit: TransitProvider
    private let traffic: TrafficProvider?
    private let calendar: Calendar

    public init(transit: TransitProvider, traffic: TrafficProvider?, calendar: Calendar = .caltrain) {
        self.transit = transit
        self.traffic = traffic
        self.calendar = calendar
    }

    public func plan(profile: CommuteProfile, direction: Direction, now: Date, pickedTripID: String? = nil) async throws -> CommutePlan {
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

        let targetLeave = CommuteWindow.targetLeave(for: direction, profile: profile, now: now, calendar: calendar)

        async let car = carOption(
            from: profile.origin(for: direction).coordinate,
            to: profile.destination(for: direction).coordinate,
            now: now,
            profile: profile
        )
        // Start a little earlier so the list can show the last trains that already left.
        let snapshot = try await transit.departures(
            fromStation: originID,
            toStation: destinationID,
            after: min(now, targetLeave).addingTimeInterval(-Self.departedLookback),
            limit: 30
        )

        let accessTime = TimeInterval(profile.accessMinutes(for: direction) * 60)
        let safetyBuffer = TimeInterval(profile.stationSafetyBufferMinutes * 60)
        let prepLeadTime = TimeInterval(profile.prepLeadTimeMinutes * 60)
        let attempts: (TrainDeparture) -> AttemptTimes = {
            AttemptRules.attempts(for: $0, accessTime: accessTime, safetyBuffer: safetyBuffer, prepLeadTime: prepLeadTime)
        }

        var departures = snapshot.departures
        // A morning schedule page may end before the evening (or tomorrow's) target.
        // Fetch that part of the timetable explicitly instead of choosing an earlier train.
        if !departures.contains(where: {
            profile.preferredServices.contains($0.service) && !$0.isCancelled && attempts($0).leaveAt >= targetLeave
        }), targetLeave > now {
            let targetSnapshot = try await transit.departures(
                fromStation: originID,
                toStation: destinationID,
                after: targetLeave.addingTimeInterval(accessTime + safetyBuffer),
                limit: 30
            )
            let known = Set(departures.map(\.id))
            departures += targetSnapshot.departures.filter { !known.contains($0.id) }
        }
        let all = departures.sorted { $0.departureTime < $1.departureTime }
        let candidates = all.filter { profile.preferredServices.contains($0.service) && !$0.isCancelled }

        let picked = pickedTripID.flatMap { id in
            all.first { $0.tripID == id && !$0.isCancelled && now <= attempts($0).tooLateAt }
        }
        let target = candidates.first { attempts($0).leaveAt >= targetLeave }
        let selected: TrainDeparture?
        let state: CommuteState
        if let picked {
            selected = picked
            state = AttemptRules.state(now: now, attempts: attempts(picked))
        } else if let target, now <= attempts(target).tooLateAt {
            selected = target
            state = AttemptRules.state(now: now, attempts: attempts(target))
        } else {
            selected = candidates.first { attempts($0).leaveAt >= targetLeave && now <= attempts($0).tooLateAt }
            state = .rolledToNextTrain
        }

        let trainOption = selected.map { train in
            TrainOption(
                train: train,
                attempts: attempts(train),
                state: state,
                fallback: candidates.first { $0.departureTime > train.departureTime },
                isManual: train.tripID == picked?.tripID
            )
        }

        let egressTime = TimeInterval(profile.egressMinutes(for: direction) * 60)
        let departed = all.filter { $0.departureTime < now }.suffix(Self.departedShown)
        let upcoming = Array(departed) + all.filter { $0.departureTime >= now }

        return CommutePlan(
            generatedAt: now,
            direction: direction,
            originStation: originStation,
            destinationStation: destinationStation,
            targetLeave: targetLeave,
            accessTime: accessTime,
            egressTime: egressTime,
            safetyBuffer: safetyBuffer,
            prepLeadTime: prepLeadTime,
            train: trainOption,
            upcoming: upcoming,
            // Until the rider could reach the door, so "almost there" still knows its train.
            enRoute: all.filter {
                $0.departureTime < now && now < $0.arrivalTime.addingTimeInterval(egressTime) && !$0.isCancelled
            },
            transitSource: snapshot.source,
            transitFetchedAt: snapshot.fetchedAt,
            transitNotice: snapshot.notice,
            car: await car
        )
    }

    /// Driving door to door instead, for one direction; `nil` without traffic data.
    public func carOption(profile: CommuteProfile, direction: Direction, now: Date) async -> CarOption? {
        await carOption(from: profile.origin(for: direction).coordinate, to: profile.destination(for: direction).coordinate, now: now, profile: profile)
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
