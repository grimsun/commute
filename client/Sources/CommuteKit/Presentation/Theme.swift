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

extension AccessMode {
    var symbol: String {
        self == .bike ? "bicycle" : "figure.walk"
    }

    var displayName: String {
        self == .bike ? "Bike" : "Walk"
    }
}

extension Appearance {
    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    #if os(iOS)
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Applies to every window, so the map, the sheet and anything presented on it follow at once.
    @MainActor
    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
    #endif
}

extension Direction {
    var title: String {
        self == .homeToWork ? "To work" : "To home"
    }
}

enum Format {
    static func time(_ date: Date) -> String {
        date.caltrainTime
    }

    static func day(_ date: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.caltrain
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
        }
    }

    /// "Saturday".
    static func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: Calendar.caltrain.timeZone).weekday(.wide))
    }

    /// "Oct 24".
    static func shortDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: Calendar.caltrain.timeZone).month(.abbreviated).day())
    }

    /// "8 min", "1h 52 min", "2h".
    static func minutes(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60) min"
    }

    /// Time left until `date`, rounded up so a countdown never reaches 0 early: "22 min", "1h 52 min",
    /// and "1 min" through the last minute.
    static func countdown(to date: Date, from now: Date) -> String {
        minutes(max(1, ceil(date.timeIntervalSince(now) / 60)) * 60)
    }

    /// "in 12 min", "now", "3 min ago".
    static func relative(_ date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if abs(seconds) < 60 {
            return "now"
        }
        if seconds > 0 {
            return "in \(countdown(to: date, from: now))"
        }
        return "\(minutes(-seconds)) ago"
    }
}

/// How pressing the leave time is: drives the green → yellow → red of the card and list.
enum Urgency: Hashable {
    /// Before get-ready time.
    case relaxed
    /// Getting ready.
    case soon
    /// The last few minutes before leaving, and leave-now itself.
    case urgent
    /// Past too-late; a new plan is on its way.
    case missed
    /// No leave guidance applies (the rider is elsewhere): informational only.
    case neutral

    /// Minutes before the leave time when the countdown turns red.
    static let urgentLead: TimeInterval = 3 * 60

    init(attempts: AttemptTimes, now: Date) {
        if now > attempts.tooLateAt {
            self = .missed
        } else if now >= attempts.leaveAt.addingTimeInterval(-Self.urgentLead) {
            self = .urgent
        } else if now >= attempts.getReadyAt {
            self = .soon
        } else {
            self = .relaxed
        }
    }

    var color: Color {
        switch self {
        case .relaxed: .green
        // A deep amber reads as yellow but stays legible on white; on dark, a brighter yellow.
        case .soon: Color(light: Color(red: 0.85, green: 0.62, blue: 0.0), dark: Color(red: 1.0, green: 0.8, blue: 0.04))
        case .urgent, .missed: .red
        case .neutral: .blue
        }
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
    /// Without realtime data a train is only "scheduled", never confirmed on time.
    let isLive: Bool

    var body: some View {
        if train.isCancelled {
            Text("Cancelled")
                .foregroundStyle(.red)
        } else if train.delayMinutes > 0 {
            Text("+\(train.delayMinutes) min")
                .foregroundStyle(train.delayMinutes >= 5 ? .red : .orange)
        } else if isLive {
            Text("On time")
                .foregroundStyle(.green)
        } else {
            Text("Scheduled")
                .foregroundStyle(.secondary)
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

extension Color {
    /// One color in light mode and another in dark mode.
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light) })
        #endif
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
