import Foundation
import Observation

@MainActor
@Observable
public final class CommuteViewModel {
    public private(set) var profile: CommuteProfile = .default
    public private(set) var direction: Direction
    public private(set) var plan: CommutePlan?
    public private(set) var isRefreshing = false
    public private(set) var errorMessage: String?
    /// False until the saved profile is loaded; settings should not open before then.
    public private(set) var isLoaded = false

    public private(set) var timetableInfo: TimetableInfo?
    public private(set) var isUpdatingTimetable = false
    public private(set) var timetableError: String?

    private(set) var departedCommutes: Set<CommuteKey> = []

    private let profileStore: CommuteProfileStore
    private let timetable: TimetableStore
    private let factory: CommuteServiceFactory
    private let traffic: TrafficProvider?
    private let access: StationAccessProvider
    private let departureLog: DepartureLog
    private let now: () -> Date
    /// The mode-specific implementations; rebuilt when the data source changes.
    private var services: CommuteServices
    /// Once the rider flips direction by hand, stop following the time of day.
    private var isDirectionPinned = false
    private var refreshGeneration = 0
    private var didLoadProfile = false

    public init(
        profileStore: CommuteProfileStore,
        timetable: TimetableStore,
        factory: CommuteServiceFactory,
        traffic: TrafficProvider?,
        access: StationAccessProvider,
        departureLog: DepartureLog = DepartureLog(),
        now: @escaping () -> Date = Date.init
    ) {
        self.profileStore = profileStore
        self.timetable = timetable
        self.factory = factory
        self.traffic = traffic
        self.access = access
        self.departureLog = departureLog
        self.now = now
        self.direction = .suggested(at: now())
        self.services = factory.services(for: CommuteProfile.default.dataSource)
    }

    // MARK: Lifecycle

    /// Loads saved state, then refreshes every minute until the calling task is cancelled.
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
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
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
        let date = now()
        if !isDirectionPinned {
            direction = .suggested(at: date)
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
        do {
            let newPlan = try await planner.plan(profile: profile, direction: direction, now: date)
            guard generation == refreshGeneration else { return }
            plan = newPlan
            errorMessage = nil
        } catch {
            guard generation == refreshGeneration else { return }
            plan = nil
            errorMessage = Self.message(for: error)
        }
        timetableInfo = await timetable.info()
    }

    /// The view model's clock; views use it so countdowns agree with the plan.
    public func currentDate() -> Date {
        now()
    }

    public func toggleDirection() async {
        direction = direction.reversed
        isDirectionPinned = true
        plan = nil
        await refresh()
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

    public var hasDepartedCurrentCommute: Bool {
        departedCommutes.contains(CommuteKey(date: now(), direction: direction))
    }

    /// "I'm on my way": silences the rest of this commute's alerts.
    public func markDeparted() async {
        let key = CommuteKey(date: now(), direction: direction)
        await departureLog.markDeparted(key)
        departedCommutes.insert(key)
        await rescheduleAlerts()
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
        let alerts = await planner.alerts(profile: profile, now: now(), skipping: departedCommutes)
        await scheduler.replaceAlerts(with: alerts)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PlannerError.sameStation:
            "Home and work use the same station. Pick different stations in Settings."
        case PlannerError.unknownStation(let id), SampleTransitError.unknownStation(let id):
            "Unknown station “\(id)”. Pick a station in Settings."
        case is URLError, is TimetableSourceError, is ZipError, is GTFSError:
            "Couldn’t download the Caltrain timetable. Check your connection and pull to retry."
        default:
            "Couldn’t load trains. Pull to retry."
        }
    }
}
