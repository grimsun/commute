#if os(iOS)
import ActivityKit
import Foundation

/// The Lock Screen / Dynamic Island activity. Its content is a `LiveTrip`; countdowns are system
/// timers, so they keep ticking while the app is closed.
public struct CommuteActivityAttributes: ActivityAttributes {
    public typealias ContentState = LiveTrip

    /// One activity per trip direction; a train change updates it rather than starting another.
    public var routeTitle: String

    public init(routeTitle: String) {
        self.routeTitle = routeTitle
    }
}

@MainActor
public final class SystemLiveActivities: LiveActivityUpdating {
    public init() {}

    public func sync(_ trip: LiveTrip?) async {
        await Self.apply(trip)
    }

    /// ActivityKit objects are not Sendable; fetch and change them all in one non-isolated place.
    nonisolated private static func apply(_ trip: LiveTrip?) async {
        let running = Activity<CommuteActivityAttributes>.activities
        guard let trip, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for activity in running {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let routeTitle = "\(trip.originName) → \(trip.destinationName)"
        // Greyed out by the system if the app can't update it before the trip ends.
        let content = ActivityContent(state: trip, staleDate: trip.endsAt)
        if let current = running.first(where: { $0.attributes.routeTitle == routeTitle }) {
            if current.content.state != trip {
                await current.update(content)
            }
            for other in running where other.id != current.id {
                await other.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        for activity in running {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        _ = try? Activity.request(attributes: CommuteActivityAttributes(routeTitle: routeTitle), content: content, pushType: nil)
    }
}
#endif
