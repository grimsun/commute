import SwiftUI

/// The next-train card: the train, its times and what to do now (leave, on the way, on board…).
struct HeroCard: View {
    let plan: CommutePlan
    let profile: CommuteProfile
    let now: Date
    /// The train the rider left for or is on (from location); replaces the planned train on the card.
    let tripInProgress: TrainDeparture?
    private var hasDeparted: Bool { tripInProgress != nil }
    /// Schedule mode: the next train between two stations, with no leave guidance.
    let isSchedule: Bool
    /// Schedule mode showing another day: no countdowns, the day instead.
    var isOtherDay = false
    /// The loading placeholder shows the "too late for…" line so the sheet is sized for it.
    var reservesMissedLine = false
    /// Away from the starting place and not travelling: show this next train without leave guidance.
    var elsewhereTrain: TrainDeparture? = nil
    private var isElsewhere: Bool { elsewhereTrain != nil }
    /// A train that just became too late: "Missed it!" for a few seconds before the next one.
    var missedOption: TrainOption? = nil
    /// Just the train: no countdown to leaving, since the rider's starting point is unknown.
    private var isNeutral: Bool { isElsewhere || isSchedule }
    /// Stops and track of the card's train, when loaded.
    var path: TrainPath? = nil
    /// Expanded sheet: the card adds the train's stops.
    var showsStops = false
    /// Compact sheet: only the train line and its times.
    var isCompact = false
    /// Height of the train line and times, for sizing the compact sheet.
    var onTopHeightChange: (CGFloat) -> Void = { _ in }
    /// "On my way": the rider marks this train as the one they're taking. `nil` hides it.
    var onTakeTrain: ((TrainDeparture) -> Void)? = nil
    /// "End trip": not travelling after all.
    var onEndTrip: (() -> Void)? = nil
    /// The arrow between the times flips the direction (or swaps the stations).
    var onToggleDirection: (() -> Void)? = nil
    /// Sets a train as the target, from the "better train" hint.
    var onPick: (TrainDeparture) -> Void = { _ in }

    /// "On my way" appears this close to the train, when it is useful and not clutter.
    private static let takeTrainLead: TimeInterval = 90 * 60

    var body: some View {
        Card {
            if let riding = tripInProgress {
                content(TrainOption(train: riding, attempts: plan.attempts(for: riding), state: .leaveNow, fallback: nil))
            } else if let missedOption {
                content(missedOption)
            } else if let next = elsewhereTrain {
                content(TrainOption(train: next, attempts: plan.attempts(for: next), state: .onTrack, fallback: nil))
            } else if let option = plan.train {
                content(option)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No train to plan for", systemImage: "tram.fill")
                        .font(.headline)
                    Text(isSchedule
                         ? "No more trains between these stations for now. Check Settings → Train types."
                         : "Nothing left that matches your target time and train types. Long-press a train in the list to pin it, or check Settings → Train types.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func content(_ option: TrainOption) -> some View {
        let train = option.train
        // Once on the way, the leave countdown no longer applies; it is calm green until the train.
        let urgency: Urgency = hasDeparted ? .relaxed
            : isOtherDay ? .neutral
            : isNeutral ? (now >= option.train.departureTime ? .missed : .neutral)
            : Urgency(attempts: option.attempts, now: now)
        return VStack(alignment: .leading, spacing: 14) {
            // The train and its times: all the compact sheet shows.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ServiceBadge(service: train.service)
                    Text(trainTitle(train))
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("target-train")
                    if option.isManual {
                        Image(systemName: "pin.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer()
                    // Live trains show their delay; others which way they run (the schedule type is on the list).
                    if (plan.transitSource != .live || train.isTracked != true), !train.isCancelled {
                        Text(boundLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        DelayLabel(train: train, isLive: plan.transitSource == .live && train.isTracked == true)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                // Two rows, so the arrow sits on the times' line and the ride length on the stations'.
                Grid(horizontalSpacing: 10, verticalSpacing: 1) {
                    GridRow {
                        timeText(train.departureTime)
                            .gridColumnAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        directionArrow
                        timeText(train.arrivalTime)
                            .gridColumnAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        stationText(plan.originStation.name, time: train.departureTime, scheduled: train.scheduledDeparture)
                        Text(Format.minutes(train.arrivalTime.timeIntervalSince(train.departureTime)))
                            .monospacedDigit()
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        stationText(plan.destinationStation.name, time: train.arrivalTime, scheduled: train.scheduledArrival)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                onTopHeightChange(height)
            }

            if !isCompact {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    // One slot for a one-line notice, so the card keeps its size. On board it shows the
                    // next stop; otherwise a missed train takes priority over a better one.
                    if let next = nextStopLine(for: train) {
                        Label(next, systemImage: "tram.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                            .accessibilityIdentifier("next-stop")
                    } else if let missed = missedLine(option) {
                        Label(missed, systemImage: "xmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .accessibilityIdentifier("missed-train")
                    } else if let better = betterTrain(than: option) {
                        Button {
                            onPick(better)
                        } label: {
                            Label(betterTrainText(better, than: option.train), systemImage: "bolt.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityHint("Pins this train")
                        .accessibilityIdentifier("better-train")
                    }

                    HStack(spacing: 8) {
                        Text(statusTitle(option, urgency: urgency))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(urgency.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .accessibilityIdentifier("leave-headline")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        tripButton(for: option.train, urgency: urgency)
                    }

                    leaveLine(option, urgency: urgency)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("leave-countdown")

                    // The trip from home or work does not apply when starting from somewhere else; the
                    // train after this one does.
                    if isNeutral {
                        Text(followingLine(after: train))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityIdentifier("following-train")
                    } else {
                        Text(journeyLine(train))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityIdentifier("journey")
                    }
                }
            }

            // Expanded: the ride stop by stop, with where the train is now.
            if showsStops, let path = matchingPath(for: train) {
                Divider()
                StopList(path: path, originID: plan.originStation.id, destinationID: plan.destinationStation.id, delay: TimeInterval(train.delaySeconds), now: now, isCondensed: true)
                    .transition(.opacity)
            }

        }
    }

    /// "Southbound" / "Northbound".
    private var boundLabel: String {
        let from = StationCatalog.index(of: plan.originStation.id) ?? 0
        let to = StationCatalog.index(of: plan.destinationStation.id) ?? 0
        return to > from ? "Southbound" : "Northbound"
    }

    @ViewBuilder
    private var directionArrow: some View {
        if let onToggleDirection {
            Button(action: onToggleDirection) {
                // Filled and round, like "On my way", so it reads as a button.
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSchedule ? "Swap stations" : "Switch direction")
            .accessibilityValue(isSchedule ? "" : plan.direction.title)
            .accessibilityIdentifier("switch-direction")
        } else {
            Image(systemName: "arrow.right")
                .frame(width: 28, height: 28)
                .foregroundStyle(.tertiary)
        }
    }

    /// "On my way" before leaving; "End trip" once under way.
    @ViewBuilder
    private func tripButton(for train: TrainDeparture, urgency: Urgency) -> some View {
        if hasDeparted, let onEndTrip {
            Button(action: onEndTrip) {
                tripButtonLabel("End trip")
                    .foregroundStyle(.secondary)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityHint("You’re not taking this trip; brings back its plan and alerts")
            .accessibilityIdentifier("end-trip")
        } else if !hasDeparted, let onTakeTrain, urgency != .missed,
                  train.departureTime > now, train.departureTime.timeIntervalSince(now) <= Self.takeTrainLead {
            Button {
                onTakeTrain(train)
            } label: {
                // Away from home or work, the rider is likely at or near the station already.
                tripButtonLabel(isElsewhere ? "On this train" : "On my way")
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityHint("Marks this train as the one you’re taking")
            .accessibilityIdentifier("on-my-way")
        }
    }

    /// Sized to the longest of the trip buttons' titles, so they swap without changing size.
    private func tripButtonLabel(_ title: String) -> some View {
        ZStack {
            ForEach(["On my way", "On this train", "End trip"], id: \.self) { text in
                Text(text).hidden()
            }
            Text(title)
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func trainTitle(_ train: TrainDeparture) -> String {
        let day = Calendar.caltrain.isDate(train.departureTime, inSameDayAs: now) ? "" : Format.day(train.departureTime, relativeTo: now) + " · "
        return day + "Train \(train.trainNumber)"
    }

    /// "You're on track", "Get ready", "Leave soon", "Leave now", or "Missed it" just before re-planning.
    private func statusTitle(_ option: TrainOption, urgency: Urgency) -> String {
        if isOtherDay {
            return Format.weekday(option.train.departureTime)
        }
        if isSchedule {
            return urgency == .missed ? "Departed" : "Next train"
        }
        if hasDeparted {
            if now < option.train.departureTime { return "You’re on your way" }
            // Off the train, on the last leg to the door.
            return now < option.train.arrivalTime ? "You’re on the train" : "Almost there"
        }
        if isElsewhere {
            return "Next train"
        }
        switch urgency {
        case .relaxed: return "You’re on track"
        case .soon: return "Get ready"
        case .urgent: return now >= option.attempts.leaveAt ? "Leave now" : "Leave soon"
        case .missed: return "Missed it!"
        case .neutral: return "Next train"
        }
    }

    /// "Leave in 22 min · by 8:07 AM"; once leaving, "Too late in 2 min · at 8:10 AM".
    private func leaveLine(_ option: TrainOption, urgency: Urgency) -> Text {
        let attempts = option.attempts
        let colored = { (text: String) in Text(text).foregroundStyle(urgency.color) }
        let detail = { (text: String) in Text(text).foregroundStyle(.secondary) }
        if isOtherDay {
            return Text("Departs ") + colored(Format.time(option.train.departureTime)) + detail(" · \(Format.shortDate(option.train.departureTime))")
        }
        if isSchedule && urgency == .missed {
            return detail("Finding the next train…")
        }
        if isNeutral {
            return Text("Departs in ") + colored(Format.countdown(to: option.train.departureTime, from: now)) + detail(" · \(Format.time(option.train.departureTime))")
        }
        if hasDeparted {
            let train = option.train
            if now < train.departureTime {
                return Text("Train in ") + colored(Format.countdown(to: train.departureTime, from: now)) + detail(" · departs \(Format.time(train.departureTime))")
            }
            if now < train.arrivalTime {
                return Text("Arrives in ") + colored(Format.countdown(to: train.arrivalTime, from: now)) + detail(" · \(plan.destinationStation.name) \(Format.time(train.arrivalTime))")
            }
            let door = plan.doorArrival(for: train)
            return Text(plan.direction == .homeToWork ? "At work in " : "Home in ") + colored(Format.countdown(to: door, from: now)) + detail(" · \(Format.time(door))")
        }
        if urgency == .missed {
            // The plan already moved on; name the train it moved to.
            if let next = plan.train?.train, next.id != option.train.id {
                return Text("Next: ") + detail("\(next.service.displayName) \(next.trainNumber) at \(Format.time(next.departureTime))")
            }
            return detail("Finding the next train…")
        }
        if now < attempts.leaveAt {
            return Text("Leave in ") + colored(Format.countdown(to: attempts.leaveAt, from: now)) + detail(" · by \(Format.time(attempts.leaveAt))")
        }
        return Text("Too late in ") + colored(Format.countdown(to: attempts.tooLateAt, from: now)) + detail(" · at \(Format.time(attempts.tooLateAt))")
    }

    /// "10 min by 🚲 to 🚆 · 3 min buffer · 🏢 at 9:26 AM"
    private func journeyLine(_ train: TrainDeparture) -> String {
        let arrival = "\(destinationEmoji) at \(Format.time(plan.doorArrival(for: train)))"
        let mode = profile.accessMode == .bike ? "🚲" : "🚶"
        if hasDeparted && now >= train.departureTime {
            // Off the train, the line above already gives the door time.
            if now >= train.arrivalTime {
                return "\(Format.minutes(plan.egressTime)) by \(mode) from \(plan.destinationStation.name)"
            }
            // On board: the line above names the station; only the last leg remains.
            return "Then \(Format.minutes(plan.egressTime)) by \(mode) · \(arrival)"
        }
        var parts = ["\(Format.minutes(plan.accessTime)) by \(mode) to 🚆"]
        if plan.safetyBuffer >= 60 {
            parts.append("\(Format.minutes(plan.safetyBuffer)) buffer")
        }
        parts.append(arrival)
        return parts.joined(separator: " · ")
    }

    /// Schedule mode: "Then 5:42 PM · Local 147", the train after this one.
    private func followingLine(after train: TrainDeparture) -> String {
        guard let next = plan.upcoming.first(where: {
            $0.isUsable(preferred: profile.preferredServices) && $0.departureTime > train.departureTime
        }) else {
            return "Last train for now"
        }
        return "Then \(Format.time(next.departureTime)) · \(next.service.displayName) \(next.trainNumber)"
    }

    private var destinationEmoji: String {
        plan.direction == .homeToWork ? "🏢" : "🏠"
    }

    /// The loaded path, if it belongs to the train on the card.
    private func matchingPath(for train: TrainDeparture) -> TrainPath? {
        guard let path, path.trainNumber == train.trainNumber else { return nil }
        return path
    }

    /// On board: "Next stop: San Mateo at 6:12 PM", or "Your stop is next · 6:46 PM".
    private func nextStopLine(for train: TrainDeparture) -> String? {
        guard hasDeparted, now >= train.departureTime, now < train.arrivalTime, let path = matchingPath(for: train),
              let next = path.nextStop(at: now, delay: TimeInterval(train.delaySeconds)) else { return nil }
        let time = Format.time(next.arrival.addingTimeInterval(TimeInterval(train.delaySeconds)))
        if next.stationID == plan.destinationStation.id {
            return "Your stop is next · \(time)"
        }
        let name = StationCatalog.station(id: next.stationID)?.name ?? next.stationID
        return "Next stop: \(name) at \(time)"
    }

    /// An express overtaking the planned train, say; never while travelling or on the placeholder.
    private func betterTrain(than option: TrainOption) -> TrainDeparture? {
        guard !isNeutral, !hasDeparted, !reservesMissedLine, missedOption == nil else { return nil }
        return plan.betterTrain(than: option.train, preferred: profile.preferredServices)
    }

    /// "Express 516 at 8:30 gets you there 14 min earlier"
    private func betterTrainText(_ better: TrainDeparture, than current: TrainDeparture) -> String {
        let saving = current.arrivalTime.timeIntervalSince(better.arrivalTime)
        return "\(better.service.displayName) \(better.trainNumber) at \(Format.time(better.departureTime)) gets you there \(Format.minutes(saving)) earlier"
    }

    /// While an earlier preferred train is still at the station but out of reach, say so; it
    /// disappears once that train departs.
    private func missedLine(_ option: TrainOption) -> String? {
        if reservesMissedLine {
            return "Too late for the 0:00 AM train"
        }
        guard !isNeutral, !option.isManual, !hasDeparted else { return nil }
        // Only trains that were the target (or a later replacement), never ones before the target time.
        let missed = plan.upcoming.last {
            $0.isUsable(preferred: profile.preferredServices)
                && $0.departureTime > now && $0.departureTime < option.train.departureTime
                && plan.attempts(for: $0).leaveAt >= plan.targetLeave
                && plan.attempts(for: $0).tooLateAt < now
        }
        return missed.map { "Too late for the \(Format.time($0.departureTime)) train" }
    }

    private func timeText(_ time: Date) -> some View {
        Text(Format.time(time))
            .font(.title.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The station, after the struck-through timetable time when the train runs late.
    private func stationText(_ station: String, time: Date, scheduled: Date) -> some View {
        HStack(spacing: 4) {
            if abs(time.timeIntervalSince(scheduled)) >= 60 {
                Text(Format.time(scheduled))
                    .strikethrough()
            }
            Text(station)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
