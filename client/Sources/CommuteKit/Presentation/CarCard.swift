import SwiftUI

/// Driving instead: the current car time against free-flow traffic.
struct CarCard: View {
    let plan: CommutePlan
    let now: Date

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "car.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                if let car = plan.car {
                    // Two rows, each aligned on its text baseline: drive time / arrival, traffic / train arrival.
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
                            if let train = plan.train?.train {
                                Text("By train \(Format.time(plan.doorArrival(for: train)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                } else {
                    Text("Driving time unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
