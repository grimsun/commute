import Foundation
import Observation
import SwiftUI

/// A station-to-station route used only while this app session is open.
public struct TemporaryRoute: Equatable, Sendable {
    public var originStationID: String
    public var destinationStationID: String

    public init(originStationID: String, destinationStationID: String) {
        self.originStationID = originStationID
        self.destinationStationID = destinationStationID
    }
}

@MainActor
@Observable
public final class CommuteViewModel {
    public private(set) var profile: CommuteProfile = .default
    public private(set) var temporaryRoute: TemporaryRoute?
    private var temporaryPick: String?
    public private(set) var direction: Direction
    /// Plans for both directions, so switching direction never waits or flashes.
    private var plans: [Direction: CommutePlan] = [:]
    public var plan: CommutePlan? { plans[direction] }
    /// Track and stop times of the train on the card, per direction, for the map.
    private var paths: [Direction: TrainPath] = [:]
    public var trainPath: TrainPath? { paths[direction] }
    public private(set) var isRefreshing = false
    public private(set) var errorMessage: String?
    /// False until the saved profile is loaded; settings should not open before then.
    public private(set) var isLoaded = false

    public private(set) var timetableInfo: TimetableInfo?
    public private(set) var isUpdatingTimetable = false
    public private(set) var timetableError: String?

    private(set) var departedCommutes: Set<CommuteKey> = []
    /// Location shows the rider away from the trip's starting place (false when unknown).
    public private(set) var isAwayFromStart = false
    /// The train each departed commute is on, for "on your way" / "on the train".
    private var departedTrains: [CommuteKey: TrainDeparture] = [:]

    private let profileStore: CommuteProfileStore
    private let timetable: TimetableStore
    private let factory: CommuteServiceFactory
    private let traffic: TrafficProvider?
    private let access: StationAccessProvider
    private let departureLog: DepartureLog
    private let location: LocationProviding?
    private let liveActivity: LiveActivityUpdating?
    private let now: () -> Date
    /// The mode-specific implementations; rebuilt when the data source changes.
    private var services: CommuteServices
    /// A direction flipped by hand, kept until the current trip changes (see `CommuteWindow`).
    private var pinnedDirection: (direction: Direction, whileActive: CommuteKey)?
    /// Trains the rider picked this session, per direction; dropped once they can't be caught.
    private var picks: [Direction: String] = [:]
    private var pickWindows: [Direction: Date] = [:]
    private var refreshGeneration = 0
    private var didLoadProfile = false

    /// Uses the chosen stations as both endpoints; no home/work access time applies.
    public var routeProfile: CommuteProfile {
        guard let route = temporaryRoute,
              let origin = StationCatalog.station(id: route.originStationID),
              let destination = StationCatalog.station(id: route.destinationStationID) else { return profile }
        var result = profile
        let from = Place(name: origin.name, coordinate: origin.coordinate)
        let to = Place(name: destination.name, coordinate: destination.coordinate)
        if direction == .homeToWork {
            result.home = from
            result.work = to
            result.homeStationID = origin.id
            result.workStationID = destination.id
        } else {
            result.work = from
            result.home = to
            result.workStationID = origin.id
            result.homeStationID = destination.id
        }
        result.homeStationMinutes = 0
        result.workStationMinutes = 0
        result.morningTargetLeave = TimeOfDay(date: now())
        result.eveningTargetLeave = TimeOfDay(date: now())
        return result
    }

    public init(
        profileStore: CommuteProfileStore,
        timetable: TimetableStore,
        factory: CommuteServiceFactory,
        traffic: TrafficProvider?,
        access: StationAccessProvider,
        departureLog: DepartureLog = DepartureLog(),
        location: LocationProviding? = nil,
        liveActivity: LiveActivityUpdating? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.profileStore = profileStore
        self.timetable = timetable
        self.factory = factory
        self.traffic = traffic
        self.access = access
        self.departureLog = departureLog
        self.location = location
        self.liveActivity = liveActivity
        self.now = now
        self.direction = CommuteWindow.activeDirection(profile: .default, now: now())
        self.services = factory.services(for: CommuteProfile.default.dataSource)
    }

    // MARK: Lifecycle

    /// Loads saved state, then refreshes every minute, and also the moment a planned train becomes
    /// too late so the card moves to the next one without waiting. Runs until the task is cancelled.
    public func run() async {
        if !didLoadProfile {
            didLoadProfile = true
            profile = await profileStore.loadProfile() ?? .default
            services = factory.services(for: profile.dataSource)
            isLoaded = true
            timetableInfo = await timetable.info()
            await loadDepartures()
            await refresh()
            await rescheduleAlerts()
            await watchLocation()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(nextRefreshDelay()))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Called when the app returns to the foreground.
    public func becameActive() async {
        guard didLoadProfile else { return }
        await loadDepartures()
        await refresh()
        await rescheduleAlerts()
    }

    public func refresh() async {
        let previousPicks = picks
        let date = now()
        updateDirection(at: date)
        for (direction, target) in pickWindows {
            if target != CommuteWindow.targetLeave(for: direction, profile: profile, now: date) {
                picks[direction] = nil
                pickWindows[direction] = nil
            }
        }

        // Later requests win; an older response that lands late is dropped.
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
            }
        }

        let planner = DefaultPlanner(transit: services.transit, traffic: traffic)
        let profile = profile
        let picks = picks
        do {
            let newPlans: [Direction: CommutePlan]
            if temporaryRoute != nil {
                var routeProfile = routeProfile
                let currentTime = TimeOfDay(date: date)
                routeProfile.morningTargetLeave = currentTime
                routeProfile.eveningTargetLeave = currentTime
                let current = try await planner.plan(profile: routeProfile, direction: direction, now: date, pickedTripID: temporaryPick)
                newPlans = [direction: current]
            } else {
                async let toWork = planner.plan(profile: profile, direction: .homeToWork, now: date, pickedTripID: picks[.homeToWork])
                async let toHome = planner.plan(profile: profile, direction: .workToHome, now: date, pickedTripID: picks[.workToHome])
                newPlans = try await [Direction.homeToWork: toWork, .workToHome: toHome]
            }
            guard generation == refreshGeneration else { return }
            // Animated so a train change (missed → next) slides in rather than snapping.
            withAnimation(.smooth(duration: 0.35)) {
                plans = newPlans
                errorMessage = nil
            }
            if temporaryRoute != nil {
                if newPlans[direction]?.train?.isManual != true { temporaryPick = nil }
            } else {
            // A pick the planner no longer follows has departed or become uncatchable.
                for (direction, _) in picks where newPlans[direction]?.train?.isManual != true {
                    self.picks[direction] = nil
                    pickWindows[direction] = nil
                }
            }
        } catch {
            guard generation == refreshGeneration else { return }
            plans = [:]
            errorMessage = Self.message(for: error)
        }
        timetableInfo = await timetable.info()
        await loadPaths()
        await syncLiveActivity()
        if generation == refreshGeneration, previousPicks != self.picks {
            await rescheduleAlerts()
        }
        await detectDeparture(at: date)
    }

    /// The Lock Screen countdown follows the current trip, not a direction flipped by hand.
    private func syncLiveActivity() async {
        guard let liveActivity else { return }
        let date = now()
        var trip: LiveTrip?
        if profile.liveActivityEnabled, temporaryRoute == nil {
            let active = activeCommute(at: date).direction
            let taken = plans[active].flatMap { takenTrain(direction: active, plan: $0) }
            // Away and not travelling: a "leave in" countdown would be wrong, so none.
            let elsewhere = isAwayFromStart && active == direction && taken == nil
            if let plan = plans[active], !elsewhere {
                trip = LiveTrip.current(plan: plan, departedTrain: taken, now: date)
            }
        }
        await liveActivity.sync(trip)
    }

    /// Paths for the train each direction's card shows: the one being taken, else the planned one.
    private func loadPaths() async {
        var loaded: [Direction: TrainPath] = [:]
        for (direction, plan) in plans {
            let elsewhere = direction == self.direction ? elsewhereTrain : nil
            guard let train = takenTrain(direction: direction, plan: plan) ?? elsewhere ?? plan.train?.train else { continue }
            if let existing = paths[direction], existing.tripID == train.tripID {
                loaded[direction] = existing
            } else if let path = await timetable.path(for: train) {
                loaded[direction] = path
            }
        }
        paths = loaded
    }

    /// Stops and times for any listed train, for the inline stop list.
    public func path(for train: TrainDeparture) async -> TrainPath? {
        await timetable.path(for: train)
    }

    /// Seconds until the next refresh: a minute, or just after the next too-late moment.
    private func nextRefreshDelay() -> TimeInterval {
        let date = now()
        let deadlines = plans.values.compactMap { $0.train?.attempts.tooLateAt }.filter { $0 > date }
        guard let next = deadlines.min() else { return 60 }
        return min(60, max(1, next.timeIntervalSince(date) + 1))
    }

    /// The view model's clock; views use it so countdowns agree with the plan.
    public func currentDate() -> Date {
        now()
    }

    public func toggleDirection() async {
        if var route = temporaryRoute {
            swap(&route.originStationID, &route.destinationStationID)
            temporaryRoute = route
            temporaryPick = nil
            plans[direction] = nil
            await refresh()
            return
        }
        // Both directions are already planned; just show the other one, crossfading.
        withAnimation(.smooth(duration: 0.3)) {
            direction = direction.reversed
        }
        pinnedDirection = (direction, activeCommute(at: now()))
        // "Away" is relative to this direction's starting place.
        await detectDeparture(at: now())
    }

    private func updateDirection(at date: Date) {
        if temporaryRoute != nil { return }
        let active = activeCommute(at: date)
        if let pinned = pinnedDirection, pinned.whileActive == active {
            direction = pinned.direction
        } else {
            pinnedDirection = nil
            direction = active.direction
        }
    }

    private func activeCommute(at date: Date) -> CommuteKey {
        let active = CommuteWindow.activeDirection(profile: profile, now: date)
        return CommuteKey(date: CommuteWindow.targetLeave(for: active, profile: profile, now: date), direction: active)
    }

    // MARK: Picking a train

    public func setTemporaryRoute(originStationID: String, destinationStationID: String) async {
        guard originStationID != destinationStationID,
              StationCatalog.station(id: originStationID) != nil,
              StationCatalog.station(id: destinationStationID) != nil else { return }
        let route = TemporaryRoute(originStationID: originStationID, destinationStationID: destinationStationID)
        guard route != temporaryRoute else { return }
        temporaryRoute = route
        temporaryPick = nil
        plans[direction] = nil
        await refresh()
    }

    public func clearTemporaryRoute() async {
        guard temporaryRoute != nil else { return }
        temporaryRoute = nil
        temporaryPick = nil
        pinnedDirection = nil
        plans[direction] = nil
        await refresh()
    }

    /// Follows `train` for the current trip instead of the target-time train.
    public func pick(_ train: TrainDeparture) async {
        guard let plan, plan.upcoming.contains(where: { $0.id == train.id }),
              plan.isCatchable(train, at: now()), train.id != plan.train?.train.id else { return }
        if temporaryRoute != nil {
            temporaryPick = train.tripID
            await refresh()
            return
        }
        picks[direction] = train.tripID
        pickWindows[direction] = plan.targetLeave
        await refresh()
        await rescheduleAlerts()
    }

    /// Back to the train chosen from the target time.
    public func clearPick() async {
        if temporaryRoute != nil {
            temporaryPick = nil
            await refresh()
            return
        }
        picks[direction] = nil
        pickWindows[direction] = nil
        await refresh()
        await rescheduleAlerts()
    }

    // MARK: Settings

    public func updateProfile(_ newProfile: CommuteProfile) async {
        guard newProfile != profile else { return }
        let previous = profile
        profile = newProfile

        if newProfile.dataSource != previous.dataSource {
            // Clear alerts the old implementation scheduled before switching.
            await services.alerts.replaceAlerts(with: [])
            services = factory.services(for: newProfile.dataSource)
        }
        if newProfile.leaveAlertsEnabled, !previous.leaveAlertsEnabled, services.alerts.schedulesOnDevice {
            if !(await services.alerts.requestAuthorization()) {
                profile.leaveAlertsEnabled = false
            }
        }

        await profileStore.saveProfile(profile)
        await refresh()
        await rescheduleAlerts()
    }

    public func refreshTimetable() async {
        isUpdatingTimetable = true
        timetableError = nil
        defer { isUpdatingTimetable = false }
        do {
            timetableInfo = try await timetable.refresh()
        } catch {
            timetableError = "Couldn’t download the Caltrain timetable. Check your connection and try again."
            return
        }
        await refresh()
        await rescheduleAlerts()
    }

    /// Checks a server URL; returns a short status line for Settings.
    public func testServer(_ urlText: String) async -> (ok: Bool, message: String) {
        guard let url = DataSourceSettings(mode: .server, serverURL: urlText).parsedServerURL else {
            return (false, "Enter a full http:// or https:// address.")
        }
        do {
            let health = try await ServerTransitProvider(baseURL: url).checkHealth()
            return (true, "Connected" + (health.version.map { " · server \($0)" } ?? ""))
        } catch ServerError.badStatus(let code) {
            return (false, "The server answered with HTTP \(code).")
        } catch is DecodingError {
            return (false, "Reached something, but it isn’t a Commute server.")
        } catch {
            return (false, "Can’t reach the server.")
        }
    }

    /// Door-to-platform minutes suggested by routing, rounded up.
    public func estimateMinutes(from place: Place, stationID: String, mode: AccessMode, bikeSpeedKph: Double) async -> Int? {
        guard let from = place.coordinate, let station = StationCatalog.station(id: stationID) else { return nil }
        let seconds: TimeInterval
        do {
            seconds = try await access.travelTime(from: from, to: station.coordinate, mode: mode, bikeSpeedKph: bikeSpeedKph)
        } catch {
            guard let fallback = try? await StraightLineAccessProvider().travelTime(from: from, to: station.coordinate, mode: mode, bikeSpeedKph: bikeSpeedKph) else { return nil }
            seconds = fallback
        }
        // Plus a couple of minutes to lock up or reach the platform.
        return Int((seconds / 60).rounded(.up)) + 2
    }

    // MARK: Alerts

    /// Whether the app itself shows leave alerts in the current mode.
    public var alertsOnDevice: Bool {
        services.alerts.schedulesOnDevice
    }

    /// The trip on screen; late at night that is tomorrow morning's.
    private var currentCommute: CommuteKey {
        CommuteKey(date: plan?.targetLeave ?? now(), direction: direction)
    }

    public var hasDepartedCurrentCommute: Bool {
        departedCommutes.contains(currentCommute)
    }

    /// Starts location (asking once) and checks for departure on every new fix.
    private func watchLocation() async {
        guard let location else { return }
        await location.start()
        let updates = await location.locationUpdates()
        Task { [weak self] in
            for await _ in updates {
                guard let self else { return }
                await self.detectDeparture(at: self.now())
            }
        }
    }

    /// With location access, notices the rider has left the starting place for the trip on
    /// screen and silences that trip's remaining alerts. Without it, nothing changes.
    private func detectDeparture(at date: Date) async {
        guard temporaryRoute == nil, let plan,
              let origin = profile.origin(for: direction).coordinate,
              let fix = await location?.currentLocation() else {
            isAwayFromStart = false
            return
        }
        let away = DepartureDetection.isAway(from: origin, fix: fix)
        if away != isAwayFromStart {
            withAnimation(.smooth(duration: 0.3)) {
                isAwayFromStart = away
            }
            await loadPaths()
        }
        // Only a commute day's trip counts as leaving for it; any other time it's just elsewhere.
        let weekday = Calendar.caltrain.component(.weekday, from: plan.targetLeave)
        guard !hasDepartedCurrentCommute, profile.commuteDays.contains(weekday) else { return }

        // Well past the station means already on a train (app opened mid-ride);
        // otherwise the rider is heading for the planned train.
        let beyondStation = DepartureDetection.isBeyondStation(origin: origin, station: plan.originStation.coordinate, fix: fix)
        if beyondStation, let riding = Self.likelyRidingTrain(in: plan, profile: profile, now: date),
           DepartureDetection.hasLeft(origin: origin, fix: fix, targetLeave: plan.targetLeave, trainDeparture: riding.arrivalTime, now: date) {
            await markDeparted(on: riding)
        } else if let train = plan.train?.train,
                  DepartureDetection.hasLeft(origin: origin, fix: fix, targetLeave: plan.targetLeave, trainDeparture: train.departureTime, now: date) {
            await markDeparted(on: train)
        }
    }

    /// The most recent preferred train for this trip (the target or later) that has left but not yet arrived.
    private static func likelyRidingTrain(in plan: CommutePlan, profile: CommuteProfile, now: Date) -> TrainDeparture? {
        plan.upcoming.last {
            !$0.isCancelled && profile.preferredServices.contains($0.service)
                && plan.attempts(for: $0).leaveAt >= plan.targetLeave
                && $0.departureTime <= now && now < $0.arrivalTime
        }
    }

    /// Silences the rest of this commute's alerts and remembers which train the rider is taking.
    private func markDeparted(on train: TrainDeparture) async {
        let key = currentCommute
        departedTrains[key] = train
        await departureLog.markDeparted(key)
        departedCommutes.insert(key)
        await loadPaths()
        await syncLiveActivity()
        await rescheduleAlerts()
    }

    /// The train the rider left for (or is on), when location showed they left. The view
    /// drops it once the door-arrival time passes, so the cutoff follows its own clock tick.
    public var departedTrain: TrainDeparture? {
        guard let plan else { return nil }
        return takenTrain(direction: direction, plan: plan)
    }

    /// Away from the start but not on the commute: just the next train from the station,
    /// with no leave guidance (that assumes leaving from home or work).
    public var elsewhereTrain: TrainDeparture? {
        guard isAwayFromStart, temporaryRoute == nil, let plan, departedTrain == nil else { return nil }
        let date = now()
        return plan.upcoming.first {
            !$0.isCancelled && profile.preferredServices.contains($0.service) && $0.departureTime > date
        }
    }

    /// The train taken on a departed trip. After a relaunch only the departure is remembered,
    /// so it is inferred from the timetable. One rule for the card, the map and alerts.
    private func takenTrain(direction: Direction, plan: CommutePlan) -> TrainDeparture? {
        let key = CommuteKey(date: plan.targetLeave, direction: direction)
        guard temporaryRoute == nil, departedCommutes.contains(key) else { return nil }
        return departedTrains[key]
            ?? Self.likelyRidingTrain(in: plan, profile: profile, now: now())
            ?? plan.train?.train
    }

    private func loadDepartures() async {
        departedCommutes = await departureLog.departed(since: DateKey.key(for: now()))
    }

    private func rescheduleAlerts() async {
        let scheduler = services.alerts
        guard scheduler.schedulesOnDevice else { return }
        guard profile.leaveAlertsEnabled else {
            await scheduler.replaceAlerts(with: [])
            return
        }
        let planner = LeaveAlertPlanner(planner: DefaultPlanner(transit: services.transit, traffic: nil))
        var commutePicks: [CommuteKey: String] = [:]
        for (direction, tripID) in picks {
            if let target = pickWindows[direction] {
                commutePicks[CommuteKey(date: target, direction: direction)] = tripID
            }
        }
        var alerts = await planner.alerts(profile: profile, now: now(), skipping: departedCommutes, picks: commutePicks)
        // On board: a heads-up just before the rider's stop.
        let date = now()
        for (key, train) in departedTrains {
            guard let destination = StationCatalog.station(id: profile.destinationStationID(for: key.direction)) else { continue }
            let alert = LeaveAlertPlanner.arrivingAlert(for: train, destination: destination, key: key)
            if alert.fireDate > date {
                alerts.append(alert)
            }
        }
        await scheduler.replaceAlerts(with: alerts)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PlannerError.sameStation:
            "Home and work use the same station. Pick different stations in Settings."
        case PlannerError.unknownStation(let id), SampleTransitError.unknownStation(let id):
            "Unknown station “\(id)”. Pick a station in Settings."
        case is URLError, is TimetableSourceError, is ZipError, is GTFSError:
            "Couldn’t download the Caltrain timetable. Check your connection and tap Refresh to retry."
        default:
            "Couldn’t load trains. Tap Refresh to retry."
        }
    }
}
