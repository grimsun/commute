import SwiftUI

extension TrainService {
    var color: Color {
        switch self {
        case .local: Color(red: 0.42, green: 0.47, blue: 0.55)
        case .limited: Color(red: 0.85, green: 0.55, blue: 0.05)
        case .express: Color(red: 0.84, green: 0.18, blue: 0.20)
        case .southCounty: Color(red: 0.13, green: 0.58, blue: 0.42)
        }
    }

    var shortName: String {
        switch self {
        case .local: "LOCAL"
        case .limited: "LIMITED"
        case .express: "EXPRESS"
        case .southCounty: "S. COUNTY"
        }
    }
}

extension CommuteState {
    var title: String {
        switch self {
        case .onTrack: "On track"
        case .getReady: "Get ready"
        case .leaveNow: "Leave now"
        case .rolledToNextTrain: "Next train"
        }
    }

    var color: Color {
        switch self {
        case .onTrack: .green
        case .getReady: .orange
        case .leaveNow: .red
        case .rolledToNextTrain: .indigo
        }
    }

    var symbol: String {
        switch self {
        case .onTrack: "checkmark.circle.fill"
        case .getReady: "figure.walk.motion"
        case .leaveNow: "exclamationmark.circle.fill"
        case .rolledToNextTrain: "arrow.uturn.right.circle.fill"
        }
    }
}

extension AccessMode {
    var symbol: String {
        self == .bike ? "bicycle" : "figure.walk"
    }

    var displayName: String {
        self == .bike ? "Bike" : "Walk"
    }
}

extension Direction {
    var title: String {
        self == .homeToWork ? "To work" : "To home"
    }
}

enum Format {
    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: Calendar.caltrain.timeZone))
    }

    static func minutes(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "in 12 min", "now", "3 min ago". Rounds up so a countdown never shows 0 too early.
    static func relative(_ date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if abs(seconds) < 60 {
            return "now"
        }
        if seconds > 0 {
            return "in \(minutes(ceil(seconds / 60) * 60))"
        }
        return "\(minutes(-seconds)) ago"
    }
}

struct ServiceBadge: View {
    let service: TrainService

    var body: some View {
        Text(service.shortName)
            .font(.caption2.weight(.heavy))
            .tracking(0.4)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(service.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}

struct DelayLabel: View {
    let train: TrainDeparture

    var body: some View {
        if train.isCancelled {
            Text("Cancelled")
                .foregroundStyle(.red)
        } else if train.delayMinutes > 0 {
            Text("+\(train.delayMinutes) min")
                .foregroundStyle(train.delayMinutes >= 5 ? .red : .orange)
        } else {
            Text("On time")
                .foregroundStyle(.green)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Opaque grouped colors so cards stay legible over the map and the glass sheet.
enum Palette {
    #if os(iOS)
    static let panel = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let inset = Color(uiColor: .tertiarySystemGroupedBackground)
    #else
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let inset = Color(nsColor: .underPageBackgroundColor)
    #endif
}
