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

    private let planner: CommutePlanning
    private let store: CommuteProfileStore
    private let now: () -> Date
    /// Once the rider flips direction by hand, stop following the time of day.
    private var isDirectionPinned = false
    private var refreshGeneration = 0
    private var didLoadProfile = false

    public init(planner: CommutePlanning, store: CommuteProfileStore, now: @escaping () -> Date = Date.init) {
        self.planner = planner
        self.store = store
        self.now = now
        self.direction = .suggested(at: now())
    }

    /// Loads the saved profile, then refreshes every minute until the calling task is cancelled.
    public func run() async {
        if !didLoadProfile {
            profile = await store.loadProfile() ?? .default
            didLoadProfile = true
        }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(60))
        }
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

    public func updateProfile(_ newProfile: CommuteProfile) async {
        guard newProfile != profile else { return }
        profile = newProfile
        await store.saveProfile(newProfile)
        await refresh()
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PlannerError.sameStation:
            "Home and work use the same station. Pick different stations in Settings."
        case PlannerError.unknownStation(let id), SampleTransitError.unknownStation(let id):
            "Unknown station “\(id)”. Pick a station in Settings."
        default:
            "Couldn’t load trains. Pull to retry."
        }
    }
}
