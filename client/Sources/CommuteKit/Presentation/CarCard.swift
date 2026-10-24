import SwiftUI

/// Driving instead: the current car time against free-flow traffic. Tap for directions in
/// Apple Maps; touch and hold to choose Google Maps.
struct CarCard: View {
    let plan: CommutePlan
    let now: Date
    /// Door to door by car; `nil` hides the maps actions.
    var directions: DrivingDirections? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let directions, plan.car != nil {
            Button {
                openURL(directions.appleMapsURL)
            } label: {
                card(showsLink: true)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    openURL(directions.appleMapsURL)
                } label: {
                    Label("Open in Apple Maps", systemImage: "map")
                }
                Button {
                    openURL(directions.googleMapsURL)
                } label: {
                    Label("Open in Google Maps", systemImage: "arrow.up.right.square")
                }
            }
            .accessibilityHint("Opens driving directions in Apple Maps")
        } else {
            card(showsLink: false)
        }
    }

    private func card(showsLink: Bool) -> some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "car.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                if let car = plan.car {
                    // Two rows aligned on their text baselines: drive time and arrival, then the traffic.
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Driving \(Format.minutes(car.eta))")
                                .font(.headline)
                            Text("Arrive \(Format.time(now.addingTimeInterval(car.eta)))")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow(alignment: .firstTextBaseline) {
                            Text(car.isTrafficGood ? "Light traffic" : "Heavy traffic · +\(Format.minutes(car.delay))")
                                .font(.subheadline)
                                .foregroundStyle(car.isTrafficGood ? .green : .orange)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                } else {
                    Text("Driving time unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if showsLink {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
