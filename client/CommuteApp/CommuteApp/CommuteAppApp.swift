import CommuteKit
import SwiftUI

@main
struct CommuteAppApp: App {
    @State private var viewModel: CommuteViewModel

    init() {
        LeaveAlertPresenter.shared.install()
        let timetable = TimetableStore(source: GTFSTimetableSource())
        _viewModel = State(initialValue: CommuteViewModel(
            profileStore: UserDefaultsProfileStore(),
            timetable: timetable,
            // Standalone vs server implementations are chosen here, per the saved data source.
            factory: StandardServiceFactory(timetable: timetable, deviceAlerts: LocalLeaveAlertScheduler()),
            traffic: MapKitTrafficProvider(),
            access: MapKitStationAccessProvider(),
            now: DebugLaunch.clock
        ))
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(viewModel: viewModel, panelSize: DebugLaunch.panelSize, showsSettings: DebugLaunch.showsSettings)
        }
    }
}

/// Debug-only launch arguments for screenshots and manual testing, e.g.
/// `-debugNow 2026-10-19T07:45:00-07:00 -debugPanel large -debugSettings YES`.
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
        UserDefaults.standard.string(forKey: "debugPanel").flatMap(DashboardView.PanelSize.init(rawValue:)) ?? .medium
        #else
        .medium
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
