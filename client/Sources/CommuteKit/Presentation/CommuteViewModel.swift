import Foundation
import Observation
import SwiftUI

/// A planned train that just became too late, shown as "Missed it!" before the next one.
public struct MissedTrain: Sendable {
    public var direction: Direction
    public var option: TrainOption
    public var until: Date
}

/// Which plan a card or map shows: a commute direction, or the schedule mode's stations.
enum PlanKey: Hashable {
    case commute(Direction)
    case schedule
}

@MainActor
@Observable
public final class CommuteViewModel {
    public private(set) var profile: CommuteProfile = .default
    /// Commute during the commute window on commute days, schedule otherwise, unless switched by hand.
    public private(set) var mode: AppMode = .commute
    private var schedulePick: String?
    /// Schedule mode on the next day running the other timetable (weekday vs weekend); `nil` is today.
    private var scheduleKindChoice: ScheduleDay.Kind?
    /// Days from today to the day schedule mode shows; 0 for today.
    public private(set) var scheduleDayOffset = 0
    /// The commute direction; schedule mode keeps its own stations in `scheduleRoute`.
    public private(set) var direction: Direction
    /// Plans for both commute directions and the schedule stations, so switching never waits or flashes.
    private var plans: [PlanKey: CommutePlan] = [:]
    public var plan: CommutePlan? { plans[currentKey] }
    /// Track and stop times of the train on each card, for the map.
    private var paths: [PlanKey: TrainPath] = [:]
    public var trainPath: TrainPath? { paths[currentKey] }
    private var currentKey: PlanKey { mode == .schedule ? .schedule : .commute(direction) }
    public private(set) var isRefreshing = false
    /// Set for `missedDisplay` when a refresh moves past a train that just became too late.
    public private(set) var missedTrain: MissedTrain?
    static let missedDisplay: TimeInterval = 10
    public private(set) var errorMessage: String?
    /// False until the saved profile is loaded; settings should not open before then.
    public private(set) var isLoaded = false

    public private(set) var timetableInfo: TimetableInfo?
    /// Which timetable runs on the day of the card's train ("Weekday schedule", holidays).
    public private(set) var scheduleDay: ScheduleDay?
    public private(set) var isUpdatingTimetable = false
    public private(set) var timetableError: String?

    /// Trips under way (and on which train) or ended by hand; saved in `departureLog`.
    private(set) var trips = TripRecord()
    /// Location shows the rider away from the trip's starting place (false when unknown).
    public private(set) var isAwayFromStart = false
    private var isWatchingLocation = false

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
    /// A mode switched by hand, kept while the automatic choice stays the same.
    private var pinnedMode: (mode: AppMode, whileAutomatic: AppMode)?
    /// Trains the rider picked this session, per direction; dropped once they can't be caught.
    private var picks: [Direction: String] = [:]
    private var pickWindows: [Direction: Date] = [:]
    private var refreshGeneration = 0
    private var didLoadProfile = false

    /// Schedule mode's stations: the last ones looked up, else the current commute's.
    public var scheduleRoute: StationRoute {
        profile.scheduleRoute ?? StationRoute(
            originStationID: profile.originStationID(for: direction),
            destinationStationID: profile.destinationStationID(for: direction)
        )
    }

    /// The stations on screen.
    public var route: StationRoute {
        mode == .schedule ? scheduleRoute : StationRoute(
            originStationID: profile.originStationID(for: direction),
            destinationStationID: profile.destinationStationID(for: direction)
        )
    }

    /// The profile behind the card and map: in schedule mode the stations are both ends, with
    /// no travel to them, no buffer, and the next train from now.
    public var routeProfile: CommuteProfile {
        mode == .schedule ? Self.scheduleProfile(profile, route: scheduleRoute, at: now()) : profile
    }

    /// Planned as home → work between the chosen stations.
    private static func scheduleProfile(_ profile: CommuteProfile, route: StationRoute, at date: Date) -> CommuteProfile {
        var result = profile
        for (id, keyPath) in [(route.originStationID, \CommuteProfile.home), (route.destinationStationID, \CommuteProfile.work)] {
            if let station = StationCatalog.station(id: id) {
                result[keyPath: keyPath] = Place(name: station.name, coordinate: station.coordinate)
            }
        }
        result.homeStationID = route.originStationID
        result.workStationID = route.destinationStationID
        result.homeStationMinutes = 0
        result.workStationMinutes = 0
        result.stationSafetyBufferMinutes = 0
        result.prepLeadTimeMinutes = 0
        result.morningTargetLeave = TimeOfDay(date: date)
        result.eveningTargetLeave = TimeOfDay(date: date)
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
            // Settle the mode before anything shows, so the sheet opens at that mode's size.
            await updateMode(at: now())
            isLoaded = true
            timetableInfo = await timetable.info()
            #if DEBUG
            await applyDebugTrip()
            #endif
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

    /// Called when the app returns to the foreground. Back from the background, it starts in the
    /// automatic mode again, like a fresh launch.
    public func becameActive(fromBackground: Bool = false) async {
        guard didLoadProfile else { return }
        if fromBackground {
            pinnedMode = nil
            scheduleKindChoice = nil
        }
        await loadDepartures()
        await refresh()
        await rescheduleAlerts()
    }

    /// `userInitiated` (the refresh button) may fetch live data sooner than the automatic cadence.
    public func refresh(userInitiated: Bool = false) async {
        let previousPicks = picks
        let date = now()
        await updateMode(at: date)
        updateDirection(at: date)
        scheduleDayOffset = await resolveScheduleDayOffset(at: date)
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

        do {
            var newPlans = try await computePlans(at: date)
            // Live delays only around a trip, and only as often as the feed allows; then re-plan with them.
            // Re-planned only when predictions changed since the plans above were made.
            if let feed = services.liveFeed, wantsLiveData(newPlans, at: date) {
                let used = await feed.latest()?.fetchedAt
                await feed.refreshIfDue(manual: userInitiated)
                if await feed.latest()?.fetchedAt != used {
                    newPlans = try await computePlans(at: date)
                }
            }
            guard generation == refreshGeneration else { return }
            noteMissedTrains(replacedBy: newPlans, at: date)
            // Animated so a train change (missed → next) slides in rather than snapping.
            withAnimation(.smooth(duration: 0.35)) {
                plans = newPlans
                errorMessage = nil
                // A trip that just ended hands over to the next one.
                updateDirection(at: date)
            }
            // A pick the planner no longer follows has departed or become uncatchable.
            if newPlans[.schedule]?.train?.isManual != true {
                schedulePick = nil
            }
            for (direction, _) in picks where newPlans[.commute(direction)]?.train?.isManual != true {
                self.picks[direction] = nil
                pickWindows[direction] = nil
            }
        } catch {
            guard generation == refreshGeneration else { return }
            plans = [:]
            errorMessage = Self.message(for: error)
        }
        timetableInfo = await timetable.info()
        scheduleDay = await timetable.scheduleDay(for: plan?.train?.train.departureTime ?? date)
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
        if profile.liveActivityEnabled {
            let active = activeCommute(at: date).direction
            let taken = plans[.commute(active)].flatMap { takenTrain(direction: active, plan: $0) }
            // Away and not travelling: a "leave in" countdown would be wrong, so none.
            let elsewhere = isAwayFromStart && active == direction && taken == nil
            if let plan = plans[.commute(active)], !elsewhere {
                trip = LiveTrip.current(plan: plan, departedTrain: taken, now: date)
            }
        }
        await liveActivity.sync(trip)
    }

    /// Paths for the train each direction's card shows: the one being taken, else the planned one.
    private func loadPaths() async {
        var loaded: [PlanKey: TrainPath] = [:]
        for (key, plan) in plans {
            var train = plan.train?.train
            if case .commute(let direction) = key {
                let elsewhere = direction == self.direction ? commuteElsewhereTrain : nil
                train = takenTrain(direction: direction, plan: plan) ?? elsewhere ?? train
            }
            guard let train else { continue }
            if let existing = paths[key], existing.tripID == train.tripID {
                loaded[key] = existing
            } else if let path = await timetable.path(for: train) {
                loaded[key] = path
            }
        }
        paths = loaded
    }

    /// Stops and times for any listed train, for the inline stop list.
    public func path(for train: TrainDeparture) async -> TrainPath? {
        await timetable.path(for: train)
    }

    /// Both commute directions (they also drive alerts, location and the Lock Screen) and the
    /// schedule stations. The schedule plan has no car or traffic lookups.
    private func computePlans(at date: Date) async throws -> [PlanKey: CommutePlan] {
        let planner = DefaultPlanner(transit: services.transit, traffic: traffic)
        let profile = profile
        let picks = picks
        let scheduleDate = Calendar.caltrain.date(byAdding: .day, value: scheduleDayOffset, to: date) ?? date
        let scheduleProfile = Self.scheduleProfile(profile, route: scheduleRoute, at: scheduleDate)
        async let toWork = planner.plan(profile: profile, direction: .homeToWork, now: date, pickedTripID: picks[.homeToWork])
        async let toHome = planner.plan(profile: profile, direction: .workToHome, now: date, pickedTripID: picks[.workToHome])
        async let schedule = DefaultPlanner(transit: services.transit, traffic: nil)
            .plan(profile: scheduleProfile, direction: .homeToWork, now: scheduleDate, pickedTripID: schedulePick)
        var plans: [PlanKey: CommutePlan] = [:]
        // Each mode shows its own error; the other mode keeps working.
        switch mode {
        case .commute:
            plans[.commute(.homeToWork)] = try await toWork
            plans[.commute(.workToHome)] = try await toHome
            plans[.schedule] = try? await schedule
        case .schedule:
            plans[.schedule] = try await schedule
            plans[.commute(.homeToWork)] = try? await toWork
            plans[.commute(.workToHome)] = try? await toHome
        }
        return plans
    }

    /// How close a departure must be before live delays are worth a request.
    static let liveDataLead: TimeInterval = 90 * 60

    /// Live data matters only when the train on screen leaves soon or is being ridden.
    private func wantsLiveData(_ plans: [PlanKey: CommutePlan], at date: Date) -> Bool {
        guard let plan = plans[currentKey] else { return false }
        let taken = mode == .commute ? takenTrain(direction: direction, plan: plan) : nil
        let train = taken ?? plan.train?.train ?? plan.upcoming.first { $0.departureTime > date }
        guard let train else { return false }
        return train.departureTime.timeIntervalSince(date) <= Self.liveDataLead && date < train.arrivalTime
    }

    /// Seconds until the next refresh: a minute, or just after the next too-late moment.
    private func nextRefreshDelay() -> TimeInterval {
        let date = now()
        let deadlines = plans.values.compactMap { $0.train?.attempts.tooLateAt }.filter { $0 > date }
        guard let next = deadlines.min() else { return 60 }
        return min(60, max(1, next.timeIntervalSince(date) + 1))
    }

    /// A commute's planned train that the new plans dropped because it just became too late
    /// (not one the rider is taking) gets a moment on the card as "Missed it!".
    private func noteMissedTrains(replacedBy newPlans: [PlanKey: CommutePlan], at date: Date) {
        for direction in Direction.allCases {
            guard let oldPlan = plans[.commute(direction)], let old = oldPlan.train,
                  newPlans[.commute(direction)]?.train?.train.id != old.train.id,
                  date > old.attempts.tooLateAt, date.timeIntervalSince(old.attempts.tooLateAt) < 60,
                  takenTrain(direction: direction, plan: oldPlan) == nil else { continue }
            missedTrain = MissedTrain(direction: direction, option: old, until: date.addingTimeInterval(Self.missedDisplay))
        }
    }

    /// The just-missed train for the card on screen, while its moment lasts.
    public func missedOption(at date: Date) -> TrainOption? {
        guard mode == .commute, let missedTrain, missedTrain.direction == direction, date < missedTrain.until else { return nil }
        return missedTrain.option
    }

    /// The view model's clock; views use it so countdowns agree with the plan.
    public func currentDate() -> Date {
        now()
    }

    /// Commute: shows the other direction. Schedule: swaps the two stations.
    public func toggleDirection() async {
        if mode == .schedule {
            await setScheduleRoute(scheduleRoute.reversed)
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
        let active = activeCommute(at: date)
        if let pinned = pinnedDirection, pinned.whileActive == active {
            direction = pinned.direction
        } else {
            pinnedDirection = nil
            direction = active.direction
        }
    }

    /// The trip from `CommuteWindow`, unless it is already done (the rider reached the door):
    /// then the next one, e.g. the evening trip once at work.
    private func activeCommute(at date: Date) -> CommuteKey {
        let active = CommuteWindow.activeDirection(profile: profile, now: date)
        let key = CommuteKey(date: CommuteWindow.targetLeave(for: active, profile: profile, now: date), direction: active)
        guard isFinished(key, at: date) else { return key }
        let next = active.reversed
        return CommuteKey(date: CommuteWindow.targetLeave(for: next, profile: profile, now: date), direction: next)
    }

    private func isFinished(_ key: CommuteKey, at date: Date) -> Bool {
        guard let plan = plans[.commute(key.direction)],
              CommuteKey(date: plan.targetLeave, direction: key.direction) == key else { return false }
        return trips.isComplete(key, in: plan, preferred: profile.preferredServices, now: date)
    }

    // MARK: Mode

    /// Switches between commute and schedule; the choice holds until the automatic one changes
    /// (the commute window opens or closes) or the app comes back from the background.
    public func toggleMode() async {
        let automatic = await automaticMode(at: now())
        let newMode = mode.other
        pinnedMode = newMode == automatic ? nil : (newMode, automatic)
        withAnimation(.smooth(duration: 0.3)) {
            mode = newMode
        }
        await refresh()
    }

    private func automaticMode(at date: Date) async -> AppMode {
        let isHoliday = await timetable.scheduleDay(for: date)?.holidayName != nil
        return CommuteWindow.isCommuteTime(profile: profile, now: date, isHoliday: isHoliday) ? .commute : .schedule
    }

    private func updateMode(at date: Date) async {
        let automatic = await automaticMode(at: date)
        let newMode: AppMode
        if let pinned = pinnedMode, pinned.whileAutomatic == automatic {
            newMode = pinned.mode
        } else {
            pinnedMode = nil
            newMode = automatic
        }
        guard newMode != mode else { return }
        withAnimation(.smooth(duration: 0.3)) {
            mode = newMode
        }
    }

    /// Schedule mode: flips between the weekday and weekend timetables. The other one shows the
    /// next day running it, at the same time; flipping back returns to today.
    public func toggleScheduleKind() async {
        guard mode == .schedule, let shown = scheduleDay?.kind else { return }
        let target: ScheduleDay.Kind = shown == .weekday ? .weekend : .weekday
        let today = await timetable.scheduleDay(for: now())?.kind
        scheduleKindChoice = target == today ? nil : target
        schedulePick = nil
        await refresh()
    }

    /// The first day from today running the chosen timetable (holidays count as weekend days).
    private func resolveScheduleDayOffset(at date: Date) async -> Int {
        guard let choice = scheduleKindChoice else { return 0 }
        for offset in 0..<14 {
            guard let day = Calendar.caltrain.date(byAdding: .day, value: offset, to: date),
                  let schedule = await timetable.scheduleDay(for: day) else { continue }
            if schedule.kind == choice && (choice == .weekend || schedule.holidayName == nil) {
                return offset
            }
        }
        return 0
    }

    /// The moment the card and list are relative to: now, or the same time on the chosen day.
    public func displayDate(for date: Date) -> Date {
        guard mode == .schedule, scheduleDayOffset != 0 else { return date }
        return Calendar.caltrain.date(byAdding: .day, value: scheduleDayOffset, to: date) ?? date
    }

    /// Schedule mode's stations; remembered for next time.
    public func setScheduleRoute(_ route: StationRoute) async {
        guard route.originStationID != route.destinationStationID,
              StationCatalog.station(id: route.originStationID) != nil,
              StationCatalog.station(id: route.destinationStationID) != nil,
              route != profile.scheduleRoute else { return }
        profile.scheduleRoute = route
        schedulePick = nil
        await profileStore.saveProfile(profile)
        await refresh()
    }

    // MARK: Picking a train

    /// Follows `train` for the current trip instead of the target-time train.
    public func pick(_ train: TrainDeparture) async {
        guard let plan, plan.upcoming.contains(where: { $0.id == train.id }),
              plan.isCatchable(train, at: now()), train.id != plan.train?.train.id else { return }
        if mode == .schedule {
            schedulePick = train.tripID
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
        if mode == .schedule {
            schedulePick = nil
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
        if newProfile.usesLocation, !previous.usesLocation {
            await watchLocation()
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
        CommuteKey(date: commutePlan?.targetLeave ?? now(), direction: direction)
    }

    /// The commute direction's plan, in either mode.
    private var commutePlan: CommutePlan? {
        plans[.commute(direction)]
    }

    /// Starts location (asking once) and checks for departure on every new fix; only when the
    /// rider allows it in Settings.
    private func watchLocation() async {
        guard let location, profile.usesLocation, !isWatchingLocation else { return }
        isWatchingLocation = true
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
        guard profile.usesLocation, let plan = commutePlan,
              let origin = profile.origin(for: direction).coordinate,
              let fix = await location?.currentLocation() else {
            if isAwayFromStart {
                withAnimation(.smooth(duration: 0.3)) {
                    isAwayFromStart = false
                }
                await loadPaths()
            }
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
        guard !trips.isUnderWay(currentCommute), !trips.ended.contains(currentCommute),
              profile.commuteDays.contains(weekday) else { return }

        // Well past the station means already on a train (app opened mid-ride);
        // otherwise the rider is heading for the planned train.
        let beyondStation = DepartureDetection.isBeyondStation(origin: origin, station: plan.originStation.coordinate, fix: fix)
        if beyondStation, let riding = await ridingTrain(in: plan, near: fix, now: date),
           DepartureDetection.hasLeft(origin: origin, fix: fix, targetLeave: plan.targetLeave, trainDeparture: riding.arrivalTime, now: date) {
            await markDeparted(on: riding)
        } else if let train = plan.train?.train,
                  DepartureDetection.hasLeft(origin: origin, fix: fix, targetLeave: plan.targetLeave, trainDeparture: train.departureTime, now: date) {
            await markDeparted(on: train)
        }
    }

    /// Of the trains running right now, the one whose timetable position is closest to the rider.
    private func ridingTrain(in plan: CommutePlan, near fix: LocationFix, now date: Date) async -> TrainDeparture? {
        let running = plan.runningTrains(preferred: profile.preferredServices, at: date)
        guard running.count > 1 else { return running.first }
        var best: (train: TrainDeparture, distance: Double)?
        for train in running {
            guard let position = await timetable.path(for: train)?.position(at: date, delay: TimeInterval(train.delaySeconds)) else { continue }
            let distance = position.coordinate.distance(to: fix.coordinate)
            if distance < best?.distance ?? .infinity {
                best = (train, distance)
            }
        }
        return best?.train ?? running.last
    }

    /// Marks the commute on screen as under way on `train`, by hand: "On my way" on the card,
    /// or "I'm taking this train" on a row. Works with or without location.
    public func takeTrain(_ train: TrainDeparture) async {
        guard mode == .commute, let plan = commutePlan,
              plan.upcoming.contains(where: { $0.id == train.id }),
              now() < plan.doorArrival(for: train) else { return }
        withAnimation(.smooth(duration: 0.35)) {
            trips.take(train.trainNumber, for: currentCommute)
        }
        await markDeparted(on: train)
    }

    /// Not taking this trip after all (or location guessed wrong): back to the plan, with its
    /// alerts. Location won't mark it again.
    public func endTrip() async {
        let key = currentCommute
        guard trips.isUnderWay(key) else { return }
        withAnimation(.smooth(duration: 0.35)) {
            trips.end(key)
        }
        await departureLog.markEnded(key)
        await loadPaths()
        await syncLiveActivity()
        await rescheduleAlerts()
    }

    /// Silences the rest of this commute's alerts and remembers which train the rider is taking.
    private func markDeparted(on train: TrainDeparture) async {
        let key = currentCommute
        trips.take(train.trainNumber, for: key)
        await departureLog.markDeparted(key, trainNumber: train.trainNumber)
        await loadPaths()
        await syncLiveActivity()
        await rescheduleAlerts()
    }

    /// The train the rider left for (or is on), when location showed they left. The view
    /// drops it once the door-arrival time passes, so the cutoff follows its own clock tick.
    public var departedTrain: TrainDeparture? {
        guard mode == .commute, let plan = commutePlan else { return nil }
        return takenTrain(direction: direction, plan: plan)
    }

    /// Away from the start but not on the commute: just the next train from the station,
    /// with no leave guidance (that assumes leaving from home or work).
    public var elsewhereTrain: TrainDeparture? {
        mode == .commute ? commuteElsewhereTrain : nil
    }

    private var commuteElsewhereTrain: TrainDeparture? {
        guard isAwayFromStart, let plan = commutePlan, takenTrain(direction: direction, plan: plan) == nil else { return nil }
        let date = now()
        return plan.upcoming.first {
            !$0.isCancelled && profile.preferredServices.contains($0.service) && $0.departureTime > date
        }
    }

    /// The train taken on a departed trip; one rule (`TripRecord`) for the card, map and alerts.
    private func takenTrain(direction: Direction, plan: CommutePlan) -> TrainDeparture? {
        trips.takenTrain(for: CommuteKey(date: plan.targetLeave, direction: direction), in: plan, preferred: profile.preferredServices, now: now())
    }

    #if DEBUG
    /// Launch option for demos: marks the current commute's trip as taken on this train number,
    /// as if "On my way" had been tapped; "none" clears it and "ended" is "End trip".
    public var debugTripNumber: String?

    private func applyDebugTrip() async {
        guard let number = debugTripNumber else { return }
        let date = now()
        let direction = CommuteWindow.activeDirection(profile: profile, now: date)
        let key = CommuteKey(date: CommuteWindow.targetLeave(for: direction, profile: profile, now: date), direction: direction)
        if number == "none" {
            await departureLog.clear(key)
        } else if number == "ended" {
            await departureLog.markEnded(key)
        } else {
            await departureLog.markDeparted(key, trainNumber: number)
        }
    }
    #endif

    private func loadDepartures() async {
        let today = DateKey.key(for: now())
        trips = TripRecord(
            departed: await departureLog.departed(since: today),
            trainNumbers: await departureLog.trainNumbers(since: today),
            ended: await departureLog.ended(since: today)
        )
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
        var alerts = await planner.alerts(profile: profile, now: now(), skipping: trips.departed, picks: commutePicks)
        // On board: a heads-up just before the rider's stop.
        let date = now()
        for key in trips.departed {
            guard let plan = plans[.commute(key.direction)], CommuteKey(date: plan.targetLeave, direction: key.direction) == key,
                  let train = trips.takenTrain(for: key, in: plan, preferred: profile.preferredServices, now: date),
                  let destination = StationCatalog.station(id: profile.destinationStationID(for: key.direction)) else { continue }
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
