import Foundation

/// The implementations that differ between standalone and server mode.
/// Everything else (planner, UI, settings) is shared.
public struct CommuteServices: Sendable {
    public var transit: TransitProvider
    public var alerts: LeaveAlertScheduler

    public init(transit: TransitProvider, alerts: LeaveAlertScheduler) {
        self.transit = transit
        self.alerts = alerts
    }
}

public protocol CommuteServiceFactory: Sendable {
    func services(for settings: DataSourceSettings) -> CommuteServices
}

/// Standalone: timetable + on-device alerts.
/// Server: server trains (timetable when unreachable) + server pushes.
public struct StandardServiceFactory: CommuteServiceFactory {
    private let timetable: TimetableStore
    private let deviceAlerts: LeaveAlertScheduler
    private let session: URLSession

    public init(timetable: TimetableStore, deviceAlerts: LeaveAlertScheduler, session: URLSession = .shared) {
        self.timetable = timetable
        self.deviceAlerts = deviceAlerts
        self.session = session
    }

    public func services(for settings: DataSourceSettings) -> CommuteServices {
        let scheduled = TimetableTransitProvider(store: timetable)
        switch settings.mode {
        case .standalone:
            return CommuteServices(transit: scheduled, alerts: deviceAlerts)
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
