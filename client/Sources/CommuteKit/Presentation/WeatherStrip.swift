import SwiftUI

/// The day's weather at a glance: leaving home and getting to work, then leaving work and getting
/// home, each with its time. Moments already past are dimmed. A tap switches between the sky and
/// the temperature, remembered for next time.
struct WeatherStrip: View {
    let moments: [WeatherMoment]
    let now: Date

    @AppStorage("commute.weatherShowsTemperature") private var showsTemperature = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) {
                showsTemperature.toggle()
            }
        } label: {
            strip
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: showsTemperature)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weather")
        .accessibilityValue(moments.map(Self.spoken).joined(separator: "; "))
        .accessibilityHint(showsTemperature ? "Shows the sky" : "Shows temperatures")
        .accessibilityIdentifier("weather")
    }

    private var strip: some View {
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
        .contentShape(Capsule())
    }

    private func item(_ moment: WeatherMoment) -> some View {
        let symbol = Self.symbol(for: moment.hour)
        let colors = Self.colors(for: symbol)
        let isPast = moment.time < now
        return VStack(spacing: 1) {
            Group {
                if showsTemperature {
                    Text(moment.hour?.temperature.map(Self.degrees) ?? "–")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(colors[0], colors[colors.count > 1 ? 1 : 0], colors.last!)
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .frame(height: 19)
            .transition(.opacity)
            Text(Format.shortTime(moment.time))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 36)
        .opacity(isPast ? 0.7 : 1)
    }

    /// Gray clouds with colored sun, moon, rain and snow: the multicolor symbols' white clouds
    /// vanish on the light glass.
    static func colors(for symbol: String) -> [Color] {
        let cloud = Color(white: 0.55)
        switch symbol {
        case "sun.max.fill": return [.orange]
        case "moon.stars.fill": return [.indigo, .yellow]
        case "cloud.sun.fill": return [cloud, .orange]
        case "cloud.moon.fill": return [cloud, .indigo]
        case "cloud.drizzle.fill", "cloud.rain.fill", "cloud.heavyrain.fill": return [cloud, .blue]
        case "cloud.snow.fill": return [cloud, .cyan]
        case "cloud.bolt.rain.fill": return [cloud, .yellow, .blue]
        case "minus": return [.secondary]
        default: return [cloud]
        }
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

    /// "54°" in the phone's unit (Fahrenheit in the US).
    static func degrees(_ celsius: Double) -> String {
        let local = Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: UnitTemperature(forLocale: .current, usage: .weather))
        return "\(Int(local.value.rounded()))°"
    }

    /// "Leave home 7:12 AM, rain, 70%, 54°".
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
                parts.append(degrees(temperature))
            }
        } else {
            parts.append("no forecast")
        }
        return parts.joined(separator: ", ")
    }
}
