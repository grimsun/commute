import SwiftUI

/// The day's weather at a glance: leaving home and getting to work, then leaving work and getting
/// home, each with its time. Moments already past are dimmed.
struct WeatherStrip: View {
    let moments: [WeatherMoment]
    let now: Date

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                if index > 0 && moment.kind == .leaveWork {
                    // Morning trip | evening trip.
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: 1, height: 22)
                        .padding(.horizontal, 3)
                }
                item(moment)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weather")
        .accessibilityValue(moments.map(Self.spoken).joined(separator: "; "))
        .accessibilityIdentifier("weather")
    }

    private func item(_ moment: WeatherMoment) -> some View {
        VStack(spacing: 1) {
            Image(systemName: Self.symbol(for: moment.hour))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 15, weight: .medium))
                .frame(height: 18)
            Text(Format.shortTime(moment.time))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 36)
        .opacity(moment.time < now ? 0.45 : 1)
    }

    static func symbol(for hour: WeatherForecast.Hour?) -> String {
        guard let hour else { return "minus" }
        let day = hour.isDaylight
        switch hour.condition {
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        // A dry-looking sky with rain likely anyway (showers): show the rain, like the card does.
        case _ where hour.isRainLikely: return "cloud.rain.fill"
        case .clear: return day ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case nil: return "cloud.fill"
        }
    }

    /// "Leave home 7:12 AM, rain, 70%, 11°".
    static func spoken(_ moment: WeatherMoment) -> String {
        let title = switch moment.kind {
        case .leaveHome: "Leave home"
        case .arriveWork: "Get to work"
        case .leaveWork: "Leave work"
        case .arriveHome: "Get home"
        }
        var parts = ["\(title) \(Format.time(moment.time))"]
        if let hour = moment.hour {
            if hour.isRainLikely {
                parts.append("rain likely, \(hour.probability)%")
            }
            if let temperature = hour.temperature {
                parts.append(Measurement(value: temperature, unit: UnitTemperature.celsius).formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0)))))
            }
        } else {
            parts.append("no forecast")
        }
        return parts.joined(separator: ", ")
    }
}
