import SwiftUI

/// "Rain likely as you leave home · 70%", and for the trip back later that day "Rain likely on the
/// way home around 6 PM".
struct RainNotice: View {
    let warnings: [RainWarning]
    /// The trip on the card; warnings for the other one name it.
    let direction: Direction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.lines(for: warnings, direction: direction), id: \.self) { line in
                Label(line, systemImage: "cloud.rain.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.blue)
        .accessibilityIdentifier("rain")
    }

    static func lines(for warnings: [RainWarning], direction: Direction) -> [String] {
        var lines: [String] = []
        let current = warnings.filter { $0.direction == direction }
        if !current.isEmpty {
            let legs = Set(current.map(\.leg))
            let toWork = direction == .homeToWork
            let when = legs.count == 2 ? "as you leave and arrive"
                : legs.contains(.toStation) ? (toWork ? "as you leave home" : "as you leave work")
                : (toWork ? "as you get to work" : "as you get home")
            lines.append("Rain likely \(when)" + chance(current))
        }
        let back = warnings.filter { $0.direction != direction }
        if let first = back.min(by: { $0.time < $1.time }) {
            let way = first.direction == .homeToWork ? "to work" : "home"
            lines.append("Rain likely on the way \(way) around \(Format.time(first.time))")
        }
        return lines
    }

    /// " · 70%", left out when rain is expected from the amount alone.
    private static func chance(_ warnings: [RainWarning]) -> String {
        let probability = warnings.map(\.probability).max() ?? 0
        return probability >= WeatherForecast.likelyProbability ? " · \(probability)%" : ""
    }
}
