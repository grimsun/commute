//
//  CommuteAppApp.swift
//  CommuteApp
//
//  Created by  on 2/14/26.
//

import SwiftUI
#if canImport(CommuteKit)
import CommuteKit
#endif

@main
struct CommuteAppApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        #if canImport(CommuteKit)
        DashboardView(
            viewModel: DashboardViewModel(
                planner: DefaultPlanner(
                    trafficProvider: MockTrafficProvider(),
                    transitProvider: MockTransitProvider(),
                    bikeProvider: MockBikeETAProvider()
                ),
                profileStore: InMemoryProfileStore(),
                notifications: NoopNotificationScheduler()
            )
        )
        #else
        VStack(spacing: 10) {
            Text("CommuteKit is not linked yet.")
                .font(.headline)
            Text("In Xcode: File > Add Packages... > Add Local..., then choose this repo root.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        #endif
    }
}
