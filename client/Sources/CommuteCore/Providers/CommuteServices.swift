import Foundation

/// The implementations that differ between standalone and server mode.
/// Everything else (planner, UI, settings) is shared.
public struct CommuteServices: Sendable {
    public var transit: TransitProvider
    public var alerts: LeaveAlertScheduler
    /// Live predictions the app refreshes itself (standalone); `nil` when the server provides them.
    public var liveFeed: CaltrainLiveFeed?

    public init(transit: TransitProvider, alerts: LeaveAlertScheduler, liveFeed: CaltrainLiveFeed? = nil) {
        self.transit = transit
        self.alerts = alerts
        self.liveFeed = liveFeed
    }
}

public protocol CommuteServiceFactory: Sendable {
    func services(for settings: DataSourceSettings) -> CommuteServices
}

/// Standalone: timetable with live delays from Caltrain's public feed + on-device alerts.
/// Server: server trains (timetable when unreachable) + server pushes.
public struct StandardServiceFactory: CommuteServiceFactory {
    private let timetable: TimetableStore
    private let deviceAlerts: LeaveAlertScheduler
    private let liveFeed: CaltrainLiveFeed
    private let session: URLSession

    public init(timetable: TimetableStore, deviceAlerts: LeaveAlertScheduler, liveFeed: CaltrainLiveFeed = CaltrainLiveFeed(), session: URLSession = .shared) {
        self.timetable = timetable
        self.deviceAlerts = deviceAlerts
        self.liveFeed = liveFeed
        self.session = session
    }

    public func services(for settings: DataSourceSettings) -> CommuteServices {
        let scheduled = TimetableTransitProvider(store: timetable)
        switch settings.mode {
        case .standalone:
            return CommuteServices(
                transit: LiveTimetableTransitProvider(store: timetable, feed: liveFeed),
                alerts: deviceAlerts,
                liveFeed: liveFeed
            )
        case .server:
            return CommuteServices(
                transit: FallbackTransitProvider(
                    primary: ServerTransitProvider(baseURL: settings.parsedServerURL, session: session),
                    fallback: scheduled,
                    notice: "Server unreachable. Showing the timetable without live delays."
                ),
                alerts: NoopLeaveAlertScheduler()
            )
        }
    }
}
