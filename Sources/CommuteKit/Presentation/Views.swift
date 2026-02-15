import Foundation
import SwiftUI

public struct DashboardView: View {
    @State private var viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                controls
                content
            }
            .padding()
            .navigationTitle("Commute")
            .task {
                let profile = CommuteProfile(
                    homeAddress: "Home",
                    workAddress: "Work",
                    homeStation: "Home Station",
                    workStation: "Work Station",
                    trainLine: "Blue"
                )
                await viewModel.bootstrap(defaultProfile: profile)
                await viewModel.refreshPlan()
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Direction", selection: $viewModel.direction) {
                Text("Home → Work").tag(Direction.homeToWork)
                Text("Work → Home").tag(Direction.workToHome)
            }
            .pickerStyle(.segmented)

            Picker("Mode", selection: $viewModel.planningMode) {
                Text("Arrive By").tag(PlanningMode.arriveBy)
                Text("Leave At").tag(PlanningMode.leaveAt)
            }
            .pickerStyle(.segmented)

            DatePicker("Target", selection: $viewModel.targetDateTime)

            Button("Recalculate") {
                Task {
                    await viewModel.refreshPlan()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView("Calculating")
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
        case let .loaded(plan):
            VStack(spacing: 12) {
                CarCard(option: plan.carOption)
                TrainCard(option: plan.multimodalOption)
                TimelineView(attempts: plan.multimodalOption.attemptTimes)
            }
        }
    }
}

public struct CarCard: View {
    let option: CarOption

    public init(option: CarOption) {
        self.option = option
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Car")
                .font(.headline)
            Text("ETA: \(Int(option.eta / 60)) min")
            Text(option.isTrafficGood ? "Traffic is good" : "Traffic is heavy")
                .foregroundStyle(option.isTrafficGood ? .green : .orange)
            Text(option.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

public struct TrainCard: View {
    let option: MultimodalOption

    public init(option: MultimodalOption) {
        self.option = option
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bike + Train + Bike")
                .font(.headline)
            Text("Train: \(option.selectedTrain.tripId)")
            Text("Departs: \(option.selectedTrain.departureTime.formatted(date: .omitted, time: .shortened))")
            if let fallback = option.fallbackTrain {
                Text("Fallback: \(fallback.tripId) at \(fallback.departureTime.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

public struct TimelineView: View {
    let attempts: AttemptTimes

    public init(attempts: AttemptTimes) {
        self.attempts = attempts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attempts")
                .font(.headline)
            Text("Get ready: \(attempts.getReadyAt.formatted(date: .omitted, time: .shortened))")
            Text("Leave: \(attempts.leaveAt.formatted(date: .omitted, time: .shortened))")
            Text("Too late: \(attempts.tooLateAt.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
