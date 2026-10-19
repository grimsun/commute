import SwiftUI

/// The bottom-sheet content. Collapsed, it shows the header and the next-train card and does not
/// scroll, so any swipe expands the sheet. Expanded, it scrolls through the trains and car card.
struct PlanPanel: View {
    let viewModel: CommuteViewModel
    let isExpanded: Bool
    let onOpenSettings: () -> Void
    /// Reports the height of the collapsed content so the sheet can fit it exactly.
    let onCollapsedHeightChange: (CGFloat) -> Void
    /// Called after the rider sets a train as target, e.g. to collapse the sheet onto it.
    let onPickTrain: () -> Void

    /// While the list scrolls, the clock tick pauses so scrolling stays smooth.
    @State private var isScrolling = false

    private static let topID = "top"
    /// How often the card re-evaluates countdowns, colors and row states between refreshes.
    /// Cheap enough to do every second, so stage changes land on time.
    private static let tick: TimeInterval = 1

    var body: some View {
        // Read observable state here, outside the TimelineView, so changes redraw at once
        // instead of waiting for the next tick.
        let plan = viewModel.plan
        let routeProfile = viewModel.routeProfile
        let departedTrain = viewModel.departedTrain
        let trainPath = viewModel.trainPath
        let elsewhereTrain = viewModel.elsewhereTrain
        let scheduleLabel = viewModel.scheduleDay?.shortLabel
        let scheduleDetail = viewModel.scheduleDay?.label
        let errorMessage = viewModel.errorMessage
        let isDownloading = viewModel.timetableInfo == nil
        let isSchedule = viewModel.mode == .schedule
        return ScrollViewReader { scroller in
            ScrollView {
                SwiftUI.TimelineView(.periodic(from: .now, by: isScrolling ? 3600 : Self.tick)) { _ in
                    let now = viewModel.currentDate()
                    // Travelling until the door-arrival time; evaluated every tick so it ends on time.
                    let tripInProgress = departedTrain.flatMap { train in
                        plan.map { now < $0.doorArrival(for: train) } == true ? train : nil
                    }
                    VStack(spacing: 14) {
                        VStack(spacing: 12) {
                            header
                            if let plan {
                                HeroCard(plan: plan, profile: routeProfile, now: now, tripInProgress: tripInProgress, isSchedule: isSchedule, elsewhereTrain: tripInProgress == nil ? elsewhereTrain : nil, path: trainPath, showsStops: isExpanded, scheduleLabel: scheduleLabel) { train in
                                    Task { await viewModel.pick(train) }
                                }
                            } else {
                                loadingCard(errorMessage: errorMessage, isDownloading: isDownloading)
                            }
                        }
                        .padding(.top, 14)
                        .id(Self.topID)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            onCollapsedHeightChange(height)
                        }

                        if let plan {
                            if let notice = plan.transitNotice {
                                Card {
                                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(.orange)
                                }
                            }
                            UpcomingTrainsCard(
                                plan: plan,
                                now: now,
                                highlightedID: tripInProgress?.id ?? elsewhereTrain?.id ?? plan.train?.train.id,
                                isTripInProgress: tripInProgress != nil,
                                isElsewhere: isSchedule || (tripInProgress == nil && elsewhereTrain != nil),
                                scheduleLabel: scheduleDetail,
                                onPick: { train in
                                    Task { await viewModel.pick(train) }
                                    onPickTrain()
                                },
                                onClearPick: {
                                    Task { await viewModel.clearPick() }
                                },
                                loadPath: { train in await viewModel.path(for: train) }
                            )
                            // Driving is moot once you're on your way, and between two stations.
                            if tripInProgress == nil && !isSchedule {
                                CarCard(plan: plan, now: now)
                            }
                            footer(plan: plan)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    // Stage changes (on track → get ready → leave → next train) and row states animate.
                    .animation(.smooth(duration: 0.35), value: plan.map { PanelPhase(plan: $0, now: now) })
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(!isExpanded)
            .scrollBounceBehavior(.basedOnSize)
            .trackScrolling($isScrolling)
            // The sheet resizing can leave a stale offset; always start from the top.
            .onChange(of: isExpanded) { _, _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scroller.scrollTo(Self.topID, anchor: .top)
                }
            }
        }
    }

    // MARK: Header

    /// A flip button, the stations and settings; not tappable as a whole, since this is where
    /// people grab the sheet. Schedule mode makes each station a menu of all stations.
    private var header: some View {
        HStack(spacing: 10) {
            Button {
                Task { await viewModel.toggleDirection() }
            } label: {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.mode == .schedule ? "Swap stations" : "Switch direction")
            .accessibilityValue(viewModel.mode == .schedule ? "" : viewModel.direction.title)

            Group {
                if viewModel.mode == .schedule {
                    scheduleStations
                } else {
                    // "San Francisco → Palo Alto · To work" on one line; scales down rather than wrapping.
                    (Text(routeTitle).font(.headline)
                        + Text(" · \(viewModel.direction.title)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let notice = viewModel.plan?.transitNotice {
                // Full text is in the expanded sheet; collapsed, a marker keeps the size fixed.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(notice)
            }

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isLoaded)
            .accessibilityLabel("Settings")
        }
    }

    private var routeTitle: String {
        let route = viewModel.route
        let from = StationCatalog.station(id: route.originStationID)?.name ?? "?"
        let to = StationCatalog.station(id: route.destinationStationID)?.name ?? "?"
        return "\(from) → \(to)"
    }

    /// "Palo Alto ⌄ → San Francisco ⌄": each name picks any station.
    private var scheduleStations: some View {
        let route = viewModel.scheduleRoute
        return HStack(spacing: 6) {
            stationMenu(route.originStationID, label: "From") { id in
                // Picking the other end's station swaps the two.
                id == route.destinationStationID ? route.reversed : StationRoute(originStationID: id, destinationStationID: route.destinationStationID)
            }
            Image(systemName: "arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
            stationMenu(route.destinationStationID, label: "To") { id in
                id == route.originStationID ? route.reversed : StationRoute(originStationID: route.originStationID, destinationStationID: id)
            }
        }
    }

    private func stationMenu(_ selectedID: String, label: String, route: @escaping (String) -> StationRoute) -> some View {
        Menu {
            Picker(label, selection: Binding {
                selectedID
            } set: { id in
                Task { await viewModel.setScheduleRoute(route(id)) }
            }) {
                ForEach(StationCatalog.all) { station in
                    Text(station.name).tag(station.id)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(StationCatalog.station(id: selectedID)?.name ?? "?")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(StationCatalog.station(id: selectedID)?.name ?? "")
    }

    // MARK: Cards

    /// Loading and errors keep the exact size of the real card, so the sheet never resizes.
    private func loadingCard(errorMessage: String?, isDownloading: Bool) -> some View {
        HeroCard(
            plan: Placeholder.plan,
            profile: viewModel.profile,
            now: Placeholder.now,
            tripInProgress: nil,
            isSchedule: false,
            reservesMissedLine: true
        )
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .overlay {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(14)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .padding(20)
            } else {
                ProgressView(isDownloading ? "Downloading the Caltrain timetable…" : "Finding trains…")
                    .padding(14)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func footer(plan: CommutePlan) -> some View {
        VStack(spacing: 4) {
            switch plan.transitSource {
            case .sample:
                Label("Sample schedule for previews.", systemImage: "info.circle")
            case .timetable:
                Label("Caltrain timetable. Scheduled times, no live delays.", systemImage: "calendar")
            case .live:
                Label(viewModel.profile.dataSource.mode == .server ? "Live from your server." : "Live delays from Caltrain, updated \(Format.relative(plan.transitFetchedAt, from: viewModel.currentDate())).", systemImage: "dot.radiowaves.left.and.right")
            }
            Text("Updated \(Format.time(plan.generatedAt))")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// What, visually, is happening right now; animations run when it changes.
private struct PanelPhase: Hashable {
    let trainID: String?
    let urgency: Urgency?
    let rows: [String]

    init(plan: CommutePlan, now: Date) {
        trainID = plan.train?.train.id
        urgency = plan.train.map { Urgency(attempts: $0.attempts, now: now) }
        rows = plan.upcoming.map { "\($0.id):\(RowStatus(train: $0, plan: plan, now: now))" }
    }
}

// MARK: - Hero

/// Stand-in data for the loading card: a full-size layout (every line included).
private enum Placeholder {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let plan: CommutePlan = {
        let origin = StationCatalog.all[0]
        let destination = StationCatalog.all[15]
        let train = TrainDeparture(
            tripID: "placeholder",
            trainNumber: "000",
            service: .local,
            scheduledDeparture: now.addingTimeInterval(40 * 60),
            scheduledArrival: now.addingTimeInterval(80 * 60)
        )
        let attempts = AttemptRules.attempts(for: train, accessTime: 600, safetyBuffer: 180, prepLeadTime: 1200)
        return CommutePlan(
            generatedAt: now,
            direction: .homeToWork,
            originStation: origin,
            destinationStation: destination,
            targetLeave: now,
            accessTime: 600,
            egressTime: 600,
            safetyBuffer: 180,
            prepLeadTime: 1200,
            train: TrainOption(train: train, attempts: attempts, state: .onTrack, fallback: nil),
            upcoming: [],
            transitSource: .timetable,
            transitFetchedAt: now,
            car: nil
        )
    }()
}

private struct HeroCard: View {
    let plan: CommutePlan
    let profile: CommuteProfile
    let now: Date
    /// The train the rider left for or is on (from location); replaces the planned train on the card.
    let tripInProgress: TrainDeparture?
    private var hasDeparted: Bool { tripInProgress != nil }
    /// Schedule mode: the next train between two stations, with no leave guidance.
    let isSchedule: Bool
    /// The loading placeholder shows the "too late for…" line so the sheet is sized for it.
    var reservesMissedLine = false
    /// Sets a train as the target, from the "better train" hint.
    /// Away from the starting place and not travelling: show this next train without leave guidance.
    var elsewhereTrain: TrainDeparture? = nil
    private var isElsewhere: Bool { elsewhereTrain != nil }
    /// Just the train: no countdown to leaving, since the rider's starting point is unknown.
    private var isNeutral: Bool { isElsewhere || isSchedule }
    /// Stops and track of the card's train, when loaded.
    var path: TrainPath? = nil
    /// Expanded sheet: the card adds the train's stops.
    var showsStops = false
    /// "Weekday schedule" etc.; shown instead of "Scheduled" when there is no live data.
    var scheduleLabel: String? = nil
    var onPick: (TrainDeparture) -> Void = { _ in }

    var body: some View {
        Card {
            if let riding = tripInProgress {
                content(TrainOption(train: riding, attempts: plan.attempts(for: riding), state: .leaveNow, fallback: nil))
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
            : isNeutral ? (now >= option.train.departureTime ? .missed : .neutral)
            : Urgency(attempts: option.attempts, now: now)
        return VStack(alignment: .leading, spacing: 14) {
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
                // Untracked trains have only timetable times, so the schedule label fits them.
                if (plan.transitSource != .live || train.isTracked != true), !train.isCancelled, let scheduleLabel {
                    Text(scheduleLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    DelayLabel(train: train, isLive: plan.transitSource == .live && train.isTracked == true)
                        .font(.subheadline.weight(.semibold))
                }
            }

            HStack(spacing: 10) {
                stop(time: train.departureTime, scheduled: train.scheduledDeparture, station: plan.originStation.name, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Ride length under the arrow.
                VStack(spacing: 1) {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    Text(Format.minutes(train.arrivalTime.timeIntervalSince(train.departureTime)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                stop(time: train.arrivalTime, scheduled: train.scheduledArrival, station: plan.destinationStation.name, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                // One slot for a one-line notice, so the card keeps its size. On board it shows the
                // next stop; otherwise a missed train takes priority over a better one.
                if let next = nextStopLine(for: train) {
                    Label(next, systemImage: "tram.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
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

                Text(statusTitle(option, urgency: urgency))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(urgency.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("leave-headline")

                leaveLine(option, urgency: urgency)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("leave-countdown")

                // The trip from home or work does not apply when starting from somewhere else.
                if isSchedule {
                    Text(followingLine(after: train))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("following-train")
                } else if !isElsewhere {
                    Text(journeyLine(train))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("journey")
                }
            }

            // Expanded: the ride stop by stop, with where the train is now.
            if showsStops, let path = matchingPath(for: train) {
                Divider()
                StopList(path: path, originID: plan.originStation.id, destinationID: plan.destinationStation.id, delay: TimeInterval(train.delaySeconds), now: now)
                    .transition(.opacity)
            }

        }
    }

    private func trainTitle(_ train: TrainDeparture) -> String {
        let day = Calendar.caltrain.isDate(train.departureTime, inSameDayAs: now) ? "" : Format.day(train.departureTime, relativeTo: now) + " · "
        return day + "Train \(train.trainNumber)"
    }

    /// "You're on track", "Get ready", "Leave soon", "Leave now", or "Missed it" just before re-planning.
    private func statusTitle(_ option: TrainOption, urgency: Urgency) -> String {
        if isSchedule {
            return urgency == .missed ? "Departed" : "Next train"
        }
        if hasDeparted {
            return now < option.train.departureTime ? "You’re on your way" : "You’re on the train"
        }
        if isElsewhere {
            return "Next train"
        }
        switch urgency {
        case .relaxed: return "You’re on track"
        case .soon: return "Get ready"
        case .urgent: return now >= option.attempts.leaveAt ? "Leave now" : "Leave soon"
        case .missed: return "Missed it"
        case .neutral: return "Next train"
        }
    }

    /// "Leave in 22 min · by 8:07 AM"; once leaving, "Too late in 2 min · at 8:10 AM".
    private func leaveLine(_ option: TrainOption, urgency: Urgency) -> Text {
        let attempts = option.attempts
        let colored = { (text: String) in Text(text).foregroundStyle(urgency.color) }
        let detail = { (text: String) in Text(text).foregroundStyle(.secondary) }
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
            return Text("Arrives in ") + colored(Format.countdown(to: train.arrivalTime, from: now)) + detail(" · \(plan.destinationStation.name) \(Format.time(train.arrivalTime))")
        }
        if urgency == .missed {
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
        if hasDeparted && now >= train.departureTime {
            // On board: the line above names the station; only the last leg remains.
            let mode = profile.accessMode == .bike ? "🚲" : "🚶"
            return "Then \(Format.minutes(plan.egressTime)) by \(mode) · \(arrival)"
        }
        let mode = profile.accessMode == .bike ? "🚲" : "🚶"
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
            !$0.isCancelled && profile.preferredServices.contains($0.service) && $0.departureTime > train.departureTime
        }) else {
            return "Last train for now"
        }
        return "Then \(Format.time(next.departureTime)) · \(next.service.displayName) \(next.trainNumber)"
    }

    private var destinationEmoji: String {
        return plan.direction == .homeToWork ? "🏢" : "🏠"
    }

    /// While an earlier preferred train is still at the station but out of reach, say so; it
    /// disappears once that train departs.
    /// The loaded path, if it belongs to the train on the card.
    private func matchingPath(for train: TrainDeparture) -> TrainPath? {
        guard let path, path.trainNumber == train.trainNumber else { return nil }
        return path
    }

    /// On board: "Next stop: San Mateo at 6:12 PM", or "Your stop is next · 6:46 PM".
    private func nextStopLine(for train: TrainDeparture) -> String? {
        guard hasDeparted, now >= train.departureTime, let path = matchingPath(for: train),
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
        guard !isNeutral, !hasDeparted, !reservesMissedLine else { return nil }
        return plan.betterTrain(than: option.train, preferred: profile.preferredServices)
    }

    /// "Express 516 at 8:30 gets you there 14 min earlier"
    private func betterTrainText(_ better: TrainDeparture, than current: TrainDeparture) -> String {
        let saving = current.arrivalTime.timeIntervalSince(better.arrivalTime)
        return "\(better.service.displayName) \(better.trainNumber) at \(Format.time(better.departureTime)) gets you there \(Format.minutes(saving)) earlier"
    }

    private func missedLine(_ option: TrainOption) -> String? {
        if reservesMissedLine {
            return "Too late for the 0:00 AM train"
        }
        guard !isNeutral, !option.isManual, !hasDeparted else { return nil }
        // Only trains that were the target (or a later replacement), never ones before the target time.
        let missed = plan.upcoming.last {
            !$0.isCancelled && profile.preferredServices.contains($0.service)
                && $0.departureTime > now && $0.departureTime < option.train.departureTime
                && plan.attempts(for: $0).leaveAt >= plan.targetLeave
                && plan.attempts(for: $0).tooLateAt < now
        }
        return missed.map { "Too late for the \(Format.time($0.departureTime)) train" }
    }

    private func stop(time: Date, scheduled: Date, station: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(Format.time(time))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
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
}

// MARK: - Upcoming

/// A row's situation right now; also part of what triggers row animations.
private enum RowStatus: Hashable {
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

private struct UpcomingTrainsCard: View {
    let plan: CommutePlan
    let now: Date
    /// The train on the card: the one being taken, else the planned target.
    let highlightedID: String?
    /// The highlighted train is the one the rider is taking (location-confirmed).
    let isTripInProgress: Bool
    /// Away from home or work: rows count down to departure, with no "too late" judgement.
    let isElsewhere: Bool
    /// "Weekday schedule" etc., next to the list title.
    let scheduleLabel: String?
    let onPick: (TrainDeparture) -> Void
    let onClearPick: () -> Void
    /// Stops and times for a train, loaded when its row is opened.
    let loadPath: (TrainDeparture) async -> TrainPath?

    @State private var showsAll = false
    @State private var openRowID: String?
    @State private var openPath: TrainPath?

    /// Upcoming rows shown before "Show more" (departed rows come on top of these).
    private static let collapsedUpcoming = 4

    var body: some View {
        let rows = visibleRows
        let collapsedCount = collapsedRows.count
        let countdownIDs = Set(plan.upcoming.filter { RowStatus(train: $0, plan: plan, now: now, isElsewhere: isElsewhere) == .catchable }.prefix(2).map(\.id))
        Card {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upcoming trains")
                        .font(.headline)
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
                            Text(showsAll ? "Show less" : "Show \(plan.upcoming.count - collapsedRows.count) more")
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
        showsAll ? plan.upcoming : collapsedRows
    }

    /// Departed rows, then the next few; the target train is always included.
    private var collapsedRows: [TrainDeparture] {
        let firstUpcoming = plan.upcoming.firstIndex { $0.departureTime > now } ?? plan.upcoming.count
        let targetIndex = plan.upcoming.firstIndex { $0.id == highlightedID } ?? 0
        let end = max(firstUpcoming + Self.collapsedUpcoming, targetIndex + 1)
        return Array(plan.upcoming.prefix(end))
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
        showsAll ? 0 : plan.upcoming.count - visibleRows.count
    }

    private func row(_ train: TrainDeparture, showsCountdown: Bool) -> some View {
        let status = RowStatus(train: train, plan: plan, now: now, isElsewhere: isElsewhere)
        let isTarget = train.id == highlightedID
        return Button {
            toggleStops(for: train)
        } label: {
            TrainRow(train: train, plan: plan, now: now, status: status, isTarget: isTarget, isTaking: isTarget && isTripInProgress, isElsewhere: isElsewhere, showsCountdown: showsCountdown)
        }
        .buttonStyle(.plain)
            // The long-press preview lifts the row; give it the card's surface and rounded corners.
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .roundedContextMenuPreview()
            .contentShape(Rectangle())
            .contextMenu {
                if status == .catchable && !isTarget {
                    Button {
                        onPick(train)
                    } label: {
                        Label("Pin this train", systemImage: "pin")
                    }
                }
                if isTarget && plan.train?.isManual == true {
                    Button(action: onClearPick) {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("schedule-train-\(train.trainNumber)")
            .accessibilityActions {
                if status == .catchable && !isTarget {
                    Button("Pin this train") { onPick(train) }
                }
                if isTarget && plan.train?.isManual == true {
                    Button("Unpin", action: onClearPick)
                }
            }
    }
}

/// A train's stops from the rider's station to their destination, with where it is now.
private struct StopList: View {
    let path: TrainPath
    let originID: String
    let destinationID: String
    let delay: TimeInterval
    let now: Date

    var body: some View {
        let stops = path.stops(from: originID, to: destinationID)
        let position = path.position(at: now, delay: delay)
        // Highlighted only once the train is moving toward the rider's stops.
        let next = path.position(at: now, delay: delay) == nil ? nil : path.nextStop(at: now, delay: delay)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                let passed = stop.departure.addingTimeInterval(delay) < now && position?.stationID != stop.stationID
                let isEnd = stop.stationID == originID || stop.stationID == destinationID
                let isNext = stop.stationID == next?.stationID
                HStack(spacing: 10) {
                    // The rail: a dot per stop joined by a line; the current stop is a ring.
                    ZStack {
                        if index > 0 {
                            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2).offset(y: -11).frame(height: 22)
                        }
                        Circle()
                            .fill(isNext ? Color.green : position?.stationID == stop.stationID ? Color.accentColor : (passed ? Color.secondary.opacity(0.4) : Color.secondary))
                            .frame(width: isEnd || isNext ? 9 : 7, height: isEnd || isNext ? 9 : 7)
                    }
                    .frame(width: 14, height: 22)

                    Text(StationCatalog.station(id: stop.stationID)?.name ?? stop.stationID)
                        .font(.subheadline.weight(isEnd || isNext ? .semibold : .regular))
                        .foregroundStyle(isNext ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    Spacer()
                    Text(Format.time((stop.stationID == destinationID ? stop.arrival : stop.departure).addingTimeInterval(delay)))
                        .font(.subheadline)
                        .monospacedDigit()
                }
                .foregroundStyle(passed ? .secondary : .primary)
                .opacity(passed ? 0.6 : 1)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct TrainRow: View {
    let train: TrainDeparture
    let plan: CommutePlan
    let now: Date
    let status: RowStatus
    let isTarget: Bool
    /// The rider is on their way to, or already on, this train.
    let isTaking: Bool
    let isElsewhere: Bool
    let showsCountdown: Bool

    var body: some View {
        let urgency: Urgency = isTaking ? .relaxed : isElsewhere ? .neutral : Urgency(attempts: plan.attempts(for: train), now: now)
        let isPast = (status == .departed || status == .tooLate) && !isTaking
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
        case .catchable:
            if showsCountdown {
                let leave = plan.attempts(for: train).leaveAt
                Text(now >= leave ? "Leave now" : "Leave in \(Format.countdown(to: leave, from: now))")
                    .foregroundStyle(isTarget ? urgency.color : .secondary)
            }
        }
    }
}

// MARK: - Car

private struct CarCard: View {
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

private extension View {
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

private extension View {
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
