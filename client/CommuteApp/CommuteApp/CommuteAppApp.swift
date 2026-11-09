import BackgroundTasks
import CommuteKit
import SwiftUI

@main
struct CommuteAppApp: App {
    @State private var viewModel: CommuteViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LeaveAlertPresenter.shared.install()
        let timetable = TimetableStore(source: GTFSTimetableSource())
        let model = CommuteViewModel(
            profileStore: UserDefaultsProfileStore(),
            timetable: timetable,
            // Standalone vs server implementations are chosen here, per the saved data source.
            factory: StandardServiceFactory(timetable: timetable, deviceAlerts: LocalLeaveAlertScheduler()),
            traffic: MapKitTrafficProvider(),
            access: MapKitStationAccessProvider(),
            location: DeviceLocationProvider(),
            liveActivity: SystemLiveActivities(),
            weather: OpenMeteoWeather(),
            now: DebugLaunch.clock
        )
        #if DEBUG
        model.debugTripNumber = UserDefaults.standard.string(forKey: "debugTrip")
        #endif
        LeaveAlertPresenter.shared.onMyWay = { commute, trainNumber in
            await model.startTrip(commute, trainNumber: trainNumber)
        }
        _viewModel = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(viewModel: viewModel, panelSize: DebugLaunch.panelSize, showsSettings: DebugLaunch.showsSettings)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                AlertRefresh.schedule(at: viewModel.nextBackgroundRefresh)
            }
        }
        // Re-plans leave alerts with live delays while the app is closed, then asks for the next run.
        .backgroundTask(.appRefresh(AlertRefresh.identifier)) {
            await viewModel.refreshInBackground()
            await AlertRefresh.schedule(at: viewModel.nextBackgroundRefresh)
        }
    }
}

/// Background app refresh for leave alerts. iOS decides when it actually runs; this only says
/// when it would help (see `LeaveAlertPlanner.nextRefresh`).
enum AlertRefresh {
    static let identifier = "lab.CommuteApp.alerts"

    static func schedule(at date: Date) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = date
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Debug-only launch arguments for screenshots and manual testing, e.g.
/// `-debugNow 2026-10-19T07:45:00-07:00 -debugPanel expanded -debugSettings YES -debugTrip 510`.
enum DebugLaunch {
    static var clock: @Sendable () -> Date {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "debugNow"),
           let start = try? Date(text, strategy: .iso8601) {
            let launched = Date()
            return { start.addingTimeInterval(Date().timeIntervalSince(launched)) }
        }
        #endif
        return { Date() }
    }

    static var panelSize: DashboardView.PanelSize {
        #if DEBUG
        UserDefaults.standard.string(forKey: "debugPanel").flatMap(DashboardView.PanelSize.init(rawValue:)) ?? .collapsed
        #else
        .collapsed
        #endif
    }

    static var showsSettings: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "debugSettings")
        #else
        false
        #endif
    }
}
