import ActivityKit
import CommuteKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island countdown for the current trip. Every countdown is a system
/// timer, so it stays right while the app is closed.
struct CommuteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteActivityAttributes.self) { context in
            LockScreenTrip(trip: context.state)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
        } dynamicIsland: { context in
            let trip = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trip.countdownLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Countdown(trip: trip)
                            .font(.title2.weight(.bold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(trip.serviceName) \(trip.trainNumber)")
                            .font(.caption.weight(.semibold))
                        Text(trip.departure, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RouteLine(trip: trip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: trip.phase == .onTrain ? "tram.fill" : "figure.walk")
                    .foregroundStyle(PhaseColor.of(trip))
            } compactTrailing: {
                Countdown(trip: trip)
                    .frame(maxWidth: 52)
                    .foregroundStyle(PhaseColor.of(trip))
            } minimal: {
                Image(systemName: "tram.fill")
                    .foregroundStyle(PhaseColor.of(trip))
            }
        }
    }
}

private struct LockScreenTrip: View {
    let trip: LiveTrip

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.countdownLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Countdown(trip: trip)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(PhaseColor.of(trip))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(trip.serviceName) \(trip.trainNumber)")
                    .font(.headline)
                RouteLine(trip: trip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(trip.phase == .planned ? "Leave by \(trip.leaveAt.formatted(date: .omitted, time: .shortened))" : "\(trip.destinationPlace.capitalized) at \(trip.doorArrival.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

/// "San Francisco 8:20 → Palo Alto 8:59"
private struct RouteLine: View {
    let trip: LiveTrip

    var body: some View {
        Text("\(trip.originName) \(trip.departure.formatted(date: .omitted, time: .shortened)) → \(trip.destinationName) \(trip.arrival.formatted(date: .omitted, time: .shortened))")
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Counts down to the trip's current target; never runs backwards past zero.
private struct Countdown: View {
    let trip: LiveTrip

    var body: some View {
        let target = max(trip.countdownTarget, .now)
        Text(timerInterval: Date.now...target, countsDown: true)
            .monospacedDigit()
            .multilineTextAlignment(.leading)
    }
}

private enum PhaseColor {
    static func of(_ trip: LiveTrip) -> Color {
        trip.phase == .planned ? .orange : .green
    }
}
