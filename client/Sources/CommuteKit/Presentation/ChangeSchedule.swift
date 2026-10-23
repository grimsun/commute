import SwiftUI

extension View {
    /// Reports whether the user is scrolling (iOS 18+; earlier systems never pause).
    @ViewBuilder
    func trackScrolling(_ isScrolling: Binding<Bool>) -> some View {
        if #available(iOS 18, macOS 15, *) {
            onScrollPhaseChange { _, phase in
                isScrolling.wrappedValue = phase.isScrolling
            }
        } else {
            self
        }
    }
}

/// Fires at the seconds of each minute when something shown can change, and every 15 s besides.
/// Countdowns are in whole minutes, so a deadline changes what's shown at the same second of
/// every minute before it: a few redraws a minute instead of sixty.
struct ChangeSchedule: TimelineSchedule, Equatable {
    /// Seconds past the minute, sorted.
    let offsets: [Double]
    var isPaused = false

    private static let backstop: [Double] = [0, 15, 30, 45]

    init(offsets: [Double], isPaused: Bool = false) {
        self.offsets = offsets.sorted()
        self.isPaused = isPaused
    }

    init(instants: [Date]) {
        // A moment after each deadline, so the new value has taken effect; tenths are plenty.
        let seconds = instants.map { (($0.timeIntervalSinceReferenceDate + 0.05).truncatingRemainder(dividingBy: 60) * 10).rounded(.up) / 10 }
        self.init(offsets: Array(Set(seconds + Self.backstop)))
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var emittedStart = false
        var minute = (startDate.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        var index = 0
        let offsets = offsets
        let isPaused = isPaused
        return AnyIterator {
            if !emittedStart {
                emittedStart = true
                return startDate
            }
            guard !isPaused, !offsets.isEmpty else { return nil }
            while true {
                if index == offsets.count {
                    index = 0
                    minute += 60
                }
                let date = Date(timeIntervalSinceReferenceDate: minute + offsets[index])
                index += 1
                if date > startDate {
                    return date
                }
            }
        }
    }
}
