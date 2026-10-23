import SwiftUI

/// A row's situation right now; also part of what triggers row animations.
enum RowStatus: Hashable {
    case departed
    case cancelled
    case tooLate
    case catchable

    init(train: TrainDeparture, plan: CommutePlan, now: Date, isElsewhere: Bool = false) {
        if train.isCancelled {
            self = .cancelled
        } else if train.departureTime <= now {
            self = .departed
        } else if !isElsewhere && !plan.isCatchable(train, at: now) {
            self = .tooLate
        } else {
            self = .catchable
        }
    }
}

/// Departed, then upcoming trains; tap a row for its stops, long-press to pin or take it.
struct UpcomingTrainsCard: View {
    let plan: CommutePlan
    let now: Date
    /// The train on the card: the one being taken, else the planned target.
    let highlightedID: String?
    /// The highlighted train is the one the rider is taking (location-confirmed).
    let isTripInProgress: Bool
    /// Away from home or work: rows count down to departure, with no "too late" judgement.
    let isElsewhere: Bool
    /// Another day's schedule: rows have no countdowns or "departed".
    var isOtherDay = false
    /// "Weekday schedule" etc., next to the list title.
    let scheduleLabel: String?
    /// Commute mode: the train types picked in Settings; the others are marked skipped.
    var preferredServices: Set<TrainService>? = nil
    let onPick: (TrainDeparture) -> Void
    let onClearPick: () -> Void
    /// "I'm taking this train"; `nil` outside commute mode.
    let onTake: ((TrainDeparture) -> Void)?
    let onEndTrip: () -> Void
    /// Stops and times for a train, loaded when its row is opened.
    let loadPath: (TrainDeparture) async -> TrainPath?

    @State private var showsAll = false
    @State private var openRowID: String?
    @State private var openPath: TrainPath?
    @State private var showsSkippedInfo = false

    /// Upcoming rows shown before "Show more" (the departed row comes on top of these).
    private static let collapsedUpcoming = 4

    var body: some View {
        let rows = visibleRows
        let collapsedCount = collapsedRows.count
        let countdownIDs = Set(plan.upcoming.filter { !isSkipped($0) && RowStatus(train: $0, plan: plan, now: now, isElsewhere: isElsewhere) == .catchable }.prefix(2).map(\.id))
        Card {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Upcoming trains")
                            .font(.headline)
                        Spacer()
                        if rows.contains(where: isSkipped) {
                            skippedInfoButton
                        }
                    }
                    if let scheduleLabel {
                        Text(scheduleLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(.bottom, 6)

                if rows.isEmpty {
                    Text("No more trains today.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                let spansDays = Set(rows.map { DateKey.key(for: $0.departureTime) }).count > 1
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, train in
                    VStack(alignment: .leading, spacing: 4) {
                    // Day labels only matter when the list crosses midnight.
                    if spansDays && (index == 0 || !Calendar.caltrain.isDate(rows[index - 1].departureTime, inSameDayAs: train.departureTime)) {
                        Text(Format.day(train.departureTime, relativeTo: now))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 0 : 6)
                    }
                    row(train, showsCountdown: countdownIDs.contains(train.id) || train.id == highlightedID)
                    if openRowID == train.id {
                        Group {
                            if let openPath, openPath.tripID == train.tripID {
                                StopList(path: openPath, originID: plan.originStation.id, destinationID: plan.destinationStation.id, delay: TimeInterval(train.delaySeconds), now: now)
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if train.id != rows.last?.id {
                        Divider()
                    }
                    }
                    // "Show more" unrolls the extra rows one after another; "Show less" folds them quickly.
                    .transition(index < collapsedCount ? .identity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -10))
                            .animation(.smooth(duration: 0.35).delay(Double(min(index - collapsedCount, 15)) * 0.03)),
                        removal: .opacity.animation(.easeOut(duration: 0.15))
                    ))
                }

                if hiddenCount > 0 || showsAll {
                    Button {
                        withAnimation(.smooth(duration: 0.4)) {
                            showsAll.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showsAll ? "Show less" : "Show \(listedTrains.count - collapsedCount) more")
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(showsAll ? 180 : 0))
                        }
                        .contentTransition(.opacity)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
    }

    private var visibleRows: [TrainDeparture] {
        showsAll ? listedTrains : collapsedRows
    }

    /// One departed row, for context: the train being ridden if it has left, else the latest.
    /// Trains that leave between re-plans drop off here, so there's never more than one.
    private var listedTrains: [TrainDeparture] {
        let upcoming = plan.upcoming.filter { $0.departureTime > now }
        let departed = plan.enRoute.first { $0.id == highlightedID && $0.departureTime <= now }
            ?? plan.upcoming.last { $0.departureTime <= now }
        return (departed.map { [$0] } ?? []) + upcoming
    }

    /// The departed row, then the next few; the target train is always included.
    private var collapsedRows: [TrainDeparture] {
        let trains = listedTrains
        let firstUpcoming = trains.firstIndex { $0.departureTime > now } ?? trains.count
        let targetIndex = trains.firstIndex { $0.id == highlightedID } ?? 0
        let end = max(firstUpcoming + Self.collapsedUpcoming, targetIndex + 1)
        return Array(trains.prefix(end))
    }

    /// Tap a row to see its stops; tap again (or another row) to close.
    private func toggleStops(for train: TrainDeparture) {
        withAnimation(.smooth(duration: 0.3)) {
            if openRowID == train.id {
                openRowID = nil
            } else {
                openRowID = train.id
                openPath = nil
            }
        }
        guard openRowID == train.id else { return }
        Task {
            let path = await loadPath(train)
            withAnimation(.smooth(duration: 0.3)) {
                openPath = path
            }
        }
    }

    private var hiddenCount: Int {
        showsAll ? 0 : listedTrains.count - visibleRows.count
    }

    /// A train of a type turned off in Settings, unless it's the one on the card (pinned).
    private func isSkipped(_ train: TrainDeparture) -> Bool {
        guard let preferredServices, train.id != highlightedID else { return false }
        return !preferredServices.contains(train.service)
    }

    private var skippedInfoButton: some View {
        Button {
            showsSkippedInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About skipped trains")
        .popover(isPresented: $showsSkippedInfo) {
            Text("Skipped trains are types you turned off in Settings, so your commute is never planned on them. Touch and hold one to pin it anyway.")
                .font(.subheadline)
                .padding()
                .frame(idealWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// What a long-press on a row offers; the same list backs the VoiceOver actions.
    private struct RowAction: Identifiable {
        let title: String
        let symbol: String
        let perform: () -> Void
        var id: String { title }
    }

    private func actions(for train: TrainDeparture, status: RowStatus, isTarget: Bool) -> [RowAction] {
        // One of pin or take per row: pin while there's still time to leave for the train, take
        // once it's time to go (or away from home and work, where there's no leaving to plan).
        let canPin = status == .catchable && !isTarget
            && (onTake == nil || (!isElsewhere && now < plan.attempts(for: train).leaveAt))
        var actions: [RowAction] = []
        if canPin {
            actions.append(RowAction(title: "Pin this train", symbol: "pin") { onPick(train) })
        }
        if isTarget && plan.train?.isManual == true {
            actions.append(RowAction(title: "Unpin", symbol: "pin.slash", perform: onClearPick))
        }
        if !canPin, let onTake, canTake(train, isTarget: isTarget) {
            actions.append(RowAction(title: "I’m taking this train", symbol: "tram") { onTake(train) })
        }
        if isTarget && isTripInProgress {
            actions.append(RowAction(title: "I’m not on this train", symbol: "xmark", perform: onEndTrip))
        }
        return actions
    }

    private func row(_ train: TrainDeparture, showsCountdown: Bool) -> some View {
        let status = RowStatus(train: train, plan: plan, now: now, isElsewhere: isElsewhere)
        let isTarget = train.id == highlightedID
        let actions = actions(for: train, status: status, isTarget: isTarget)
        return Button {
            toggleStops(for: train)
        } label: {
            TrainRow(train: train, plan: plan, now: now, status: status, isTarget: isTarget, isTaking: isTarget && isTripInProgress, isElsewhere: isElsewhere, isOtherDay: isOtherDay, showsCountdown: showsCountdown && !isOtherDay, isSkipped: isSkipped(train))
        }
        .buttonStyle(.plain)
        // The long-press preview lifts the row; give it the card's surface and rounded corners.
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .roundedContextMenuPreview()
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("schedule-train-\(train.trainNumber)")
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title, action: action.perform)
            }
        }
    }

    /// Any train not cancelled and not yet at the rider's stop, including one already left
    /// (opened the app on board).
    private func canTake(_ train: TrainDeparture, isTarget: Bool) -> Bool {
        !(isTarget && isTripInProgress) && !train.isCancelled && now < train.arrivalTime
    }
}

/// One train in the list: times, type and number, ride length, and its status right now.
struct TrainRow: View {
    let train: TrainDeparture
    let plan: CommutePlan
    let now: Date
    let status: RowStatus
    let isTarget: Bool
    /// The rider is on their way to, or already on, this train.
    let isTaking: Bool
    let isElsewhere: Bool
    var isOtherDay = false
    let showsCountdown: Bool
    /// A type turned off in Settings: never planned, so no countdown.
    var isSkipped = false

    var body: some View {
        let urgency: Urgency = isTaking ? .relaxed : isElsewhere ? .neutral : Urgency(attempts: plan.attempts(for: train), now: now)
        let isPast = (status == .departed || status == .tooLate) && !isTaking && !isOtherDay
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.time(train.departureTime))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(train.isCancelled)
                Text("→ \(Format.time(train.arrivalTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ServiceBadge(service: train.service)
                    Text(train.trainNumber)
                        .font(.subheadline.weight(.medium))
                        .fixedSize()
                    if isTarget && plan.train?.isManual == true {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(Format.minutes(train.arrivalTime.timeIntervalSince(train.departureTime)) + " ride")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                if plan.transitSource == .live && train.isTracked == true && status != .cancelled {
                    DelayLabel(train: train, isLive: true)
                        .font(.caption.weight(.semibold))
                }
                statusText(urgency: urgency)
                    .font(.caption.weight(isTarget ? .semibold : .regular))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            if isTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(urgency.color.opacity(0.13))
            }
        }
        .opacity(isPast ? 0.5 : 1)
    }

    @ViewBuilder
    private func statusText(urgency: Urgency) -> some View {
        switch status {
        case .cancelled:
            Text("Cancelled").foregroundStyle(.red)
        case .departed where isOtherDay:
            EmptyView()
        case .departed:
            if isTaking {
                Text("On board").foregroundStyle(urgency.color)
            } else {
                Text("Departed").foregroundStyle(.secondary)
            }
        case .tooLate where isTaking, .catchable where isTaking:
            // Already on the way, so leave countdowns no longer apply.
            Text("On your way").foregroundStyle(urgency.color)
        case .tooLate:
            Text("Too late").foregroundStyle(.red)
        case .catchable where isElsewhere:
            if showsCountdown {
                Text("in \(Format.countdown(to: train.departureTime, from: now))")
                    .foregroundStyle(isTarget ? urgency.color : .secondary)
            }
        case .catchable where isSkipped:
            Text("Skipped").foregroundStyle(.secondary)
        case .catchable:
            if showsCountdown {
                let leave = plan.attempts(for: train).leaveAt
                Text(now >= leave ? "Leave now" : "Leave in \(Format.countdown(to: leave, from: now))")
                    .foregroundStyle(isTarget ? urgency.color : .secondary)
            }
        }
    }
}

extension View {
    /// Rounded corners for the lifted row in a long-press preview (iOS only).
    @ViewBuilder
    func roundedContextMenuPreview() -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10, style: .continuous))
        #else
        self
        #endif
    }
}
