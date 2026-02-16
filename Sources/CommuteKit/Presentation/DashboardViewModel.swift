import Foundation
import Observation

@MainActor
@Observable
public final class DashboardViewModel {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded(CommutePlan)
        case failed(String)
    }

    public private(set) var loadState: LoadState = .idle
    public var planningMode: PlanningMode
    public var direction: Direction
    public var targetDateTime: Date

    private let planner: Planner
    private let profileStore: CommuteProfileStore
    private let notifications: NotificationScheduler
    private var profile: CommuteProfile?

    public init(
        planner: Planner,
        profileStore: CommuteProfileStore,
        notifications: NotificationScheduler,
        planningMode: PlanningMode = .arriveBy,
        direction: Direction = .homeToWork,
        targetDateTime: Date = Date().addingTimeInterval(60 * 60)
    ) {
        self.planner = planner
        self.profileStore = profileStore
        self.notifications = notifications
        self.planningMode = planningMode
        self.direction = direction
        self.targetDateTime = targetDateTime
    }

    public func bootstrap(defaultProfile: CommuteProfile) async {
        if let saved = await profileStore.loadProfile() {
            profile = saved
            planningMode = saved.defaultPlanningMode
            return
        }

        profile = defaultProfile
        await profileStore.saveProfile(defaultProfile)
        planningMode = defaultProfile.defaultPlanningMode
    }

    public func refreshPlan(now: Date = Date()) async {
        guard let profile else {
            loadState = .failed("Missing commute profile")
            return
        }

        loadState = .loading
        let request = TripRequest(
            direction: direction,
            modePreference: .auto,
            planningMode: planningMode,
            targetDateTime: targetDateTime
        )

        do {
            let plan = try await planner.computePlan(profile: profile, tripRequest: request, now: now)
            loadState = .loaded(plan)
            await notifications.schedule(plan: plan, tripRequest: request)
        } catch {
            loadState = .failed("Failed to compute commute plan")
        }
    }

    public func currentProfile() -> CommuteProfile? {
        profile
    }

    public func updateAddresses(
        homeAddress: String,
        workAddress: String,
        homeLatitude: Double?,
        homeLongitude: Double?,
        workLatitude: Double?,
        workLongitude: Double?
    ) async {
        guard var profile else { return }
        profile.homeAddress = homeAddress
        profile.workAddress = workAddress
        profile.homeLatitude = homeLatitude
        profile.homeLongitude = homeLongitude
        profile.workLatitude = workLatitude
        profile.workLongitude = workLongitude
        self.profile = profile
        await profileStore.saveProfile(profile)
    }
}
