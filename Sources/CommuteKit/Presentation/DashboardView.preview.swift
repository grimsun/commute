import Foundation
import SwiftUI

#if DEBUG
@MainActor
private func makePreviewViewModel() -> DashboardViewModel {
    let now = Date()
    let planner = DefaultPlanner(
        trafficProvider: MockTrafficProvider(currentETA: 26 * 60, baselineETA: 23 * 60),
        transitProvider: MockTransitProvider(referenceNow: now),
        bikeProvider: MockBikeETAProvider(etaSeconds: 7 * 60)
    )
    let store = InMemoryProfileStore()
    let notifications = NoopNotificationScheduler()
    let vm = DashboardViewModel(
        planner: planner,
        profileStore: store,
        notifications: notifications,
        planningMode: .arriveBy,
        direction: .homeToWork,
        targetDateTime: now.addingTimeInterval(65 * 60)
    )
    return vm
}

#Preview("Commute Dashboard") {
    DashboardView(viewModel: makePreviewViewModel())
}
#endif
