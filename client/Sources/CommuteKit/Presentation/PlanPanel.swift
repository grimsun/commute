import SwiftUI

/// The bottom-sheet content. Collapsed, it shows the header and the next-train card and does not
/// scroll, so any swipe expands the sheet. Expanded, it scrolls through the trains and car card.
struct PlanPanel: View {
    let viewModel: CommuteViewModel
    let isExpanded: Bool
    /// Reports the height of the collapsed content so the sheet can fit it exactly.
    let onCollapsedHeightChange: (CGFloat) -> Void
    /// Called after the rider sets a train as target, e.g. to collapse the sheet onto it.
    let onPickTrain: () -> Void

    @State private var isRoutePickerPresented = false
    @State private var draftOriginStationID = ""
    @State private var draftDestinationStationID = ""

    private static let topID = "top"
    /// How often the card re-evaluates countdowns, colors and row states between refreshes.
    private static let tick: TimeInterval = 5

    var body: some View {
        // Read observable state here, outside the TimelineView, so changes redraw at once
        // instead of waiting for the next tick.
        let plan = viewModel.plan
        let routeProfile = viewModel.routeProfile
        let tripInProgress = viewModel.tripInProgress
        let errorMessage = viewModel.errorMessage
        let isDownloading = viewModel.timetableInfo == nil
        let isTemporaryRoute = viewModel.temporaryRoute != nil
        return ScrollViewReader { scroller in
            ScrollView {
                SwiftUI.TimelineView(.periodic(from: .now, by: Self.tick)) { _ in
                    let now = viewModel.currentDate()
                    VStack(spacing: 14) {
                        VStack(spacing: 12) {
                            header
                            if let plan {
                                HeroCard(plan: plan, profile: routeProfile, now: now, tripInProgress: tripInProgress, isTemporaryRoute: isTemporaryRoute)
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
                                highlightedID: tripInProgress?.id ?? plan.train?.train.id,
                                isTripInProgress: tripInProgress != nil,
                                onPick: { train in
                                    Task { await viewModel.pick(train) }
                                    onPickTrain()
                                },
                                onClearPick: {
                                    Task { await viewModel.clearPick() }
                                }
                            )
                            CarCard(plan: plan)
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
            .onChange(of: isExpanded) { _, expanded in
                if !expanded {
                    scroller.scrollTo(Self.topID, anchor: .top)
                }
            }
        }
        .sheet(isPresented: $isRoutePickerPresented) {
            routePicker
        }
    }

    // MARK: Header

    /// A flip button and the stations; expanded adds a context line. Not tappable as a whole,
    /// since this is where people grab the sheet. Long-press for a one-off station pair.
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
            .accessibilityLabel("Switch direction")
            .accessibilityValue(viewModel.direction.title)

            // "San Francisco → Palo Alto · To work" on one line; scales down rather than wrapping.
            (Text(routeTitle).font(.headline)
                + Text(" · \(viewModel.temporaryRoute == nil ? viewModel.direction.title : "One-off")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    openRoutePicker()
                } label: {
                    Label("Other stations…", systemImage: "mappin.and.ellipse")
                }
                if viewModel.temporaryRoute != nil {
                    Button {
                        Task { await viewModel.clearTemporaryRoute() }
                    } label: {
                        Label("Back to my commute", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                Button("Other stations…", action: openRoutePicker)
            }

            if let notice = viewModel.plan?.transitNotice {
                // Full text is in the expanded sheet; collapsed, a marker keeps the size fixed.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(notice)
            }
        }
    }

    private var routeTitle: String {
        let profile = viewModel.routeProfile
        let from = StationCatalog.station(id: profile.originStationID(for: viewModel.direction))?.name ?? "?"
        let to = StationCatalog.station(id: profile.destinationStationID(for: viewModel.direction))?.name ?? "?"
        return "\(from) → \(to)"
    }

    private func openRoutePicker() {
        let profile = viewModel.routeProfile
        draftOriginStationID = profile.originStationID(for: viewModel.direction)
        draftDestinationStationID = profile.destinationStationID(for: viewModel.direction)
        isRoutePickerPresented = true
    }

    // MARK: Cards

    /// Loading and errors keep the exact size of the real card, so the sheet never resizes.
    private func loadingCard(errorMessage: String?, isDownloading: Bool) -> some View {
        HeroCard(
            plan: Placeholder.plan,
            profile: viewModel.profile,
            now: Placeholder.now,
            tripInProgress: nil,
            isTemporaryRoute: false,
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
                Label("Live from your server.", systemImage: "dot.radiowaves.left.and.right")
            }
            Text("Updated \(Format.time(plan.generatedAt))")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: Route picker

    private var routePicker: some View {
        NavigationStack {
            Form {
                Section {
                    stationPicker("From", selection: $draftOriginStationID)
                    stationPicker("To", selection: $draftDestinationStationID)
                    if draftOriginStationID == draftDestinationStationID {
                        Text("Choose two different stations.")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Lasts until you close the app. Times start at the station, without travel to it.")
                }
                if viewModel.temporaryRoute != nil {
                    Section {
                        Button("Back to my commute") {
                            isRoutePickerPresented = false
                            Task { await viewModel.clearTemporaryRoute() }
                        }
                    }
                }
            }
            .navigationTitle("Other stations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isRoutePickerPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show trains") {
                        isRoutePickerPresented = false
                        Task {
                            await viewModel.setTemporaryRoute(
                                originStationID: draftOriginStationID,
                                destinationStationID: draftDestinationStationID
                            )
                        }
                    }
                    .disabled(draftOriginStationID == draftDestinationStationID)
                }
            }
        }
    }

    private func stationPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(StationCatalog.all) { station in
                Text(station.name).tag(station.id)
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
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
    let isTemporaryRoute: Bool
    /// The loading placeholder shows the "too late for…" line so the sheet is sized for it.
    var reservesMissedLine = false

    var body: some View {
        Card {
            if let riding = tripInProgress {
                content(TrainOption(train: riding, attempts: plan.attempts(for: riding), state: .leaveNow, fallback: nil))
            } else if let option = plan.train {
                content(option)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No train to plan for", systemImage: "tram.fill")
                        .font(.headline)
                    Text("Nothing left that matches your target time and train types. Long-press a train in the list to set it as target, or check Settings → Train types.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func content(_ option: TrainOption) -> some View {
        let train = option.train
        // Once on the way, the leave countdown no longer applies; it is calm green until the train.
        let urgency = hasDeparted ? .relaxed : Urgency(attempts: option.attempts, now: now)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ServiceBadge(service: train.service)
                Text(trainTitle(train))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("target-train")
                if option.isManual {
                    Image(systemName: "scope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Set by you")
                }
                Spacer()
                DelayLabel(train: train, isLive: plan.transitSource == .live)
                    .font(.subheadline.weight(.semibold))
            }

            HStack(spacing: 10) {
                stop(time: train.departureTime, scheduled: train.scheduledDeparture, station: plan.originStation.name, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                stop(time: train.arrivalTime, scheduled: train.scheduledArrival, station: plan.destinationStation.name, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let missed = missedLine(option) {
                    Label(missed, systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("missed-train")
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

                Text(journeyLine(train))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier("journey")
            }

        }
    }

    private func trainTitle(_ train: TrainDeparture) -> String {
        let day = Calendar.caltrain.isDate(train.departureTime, inSameDayAs: now) ? "" : Format.day(train.departureTime, relativeTo: now) + " · "
        return day + "Train \(train.trainNumber)"
    }

    /// "You're on track", "Get ready", "Leave soon", "Leave now", or "Missed it" just before re-planning.
    private func statusTitle(_ option: TrainOption, urgency: Urgency) -> String {
        if isTemporaryRoute {
            return urgency == .missed ? "Departed" : "Train in \(Format.countdown(to: option.train.departureTime, from: now))"
        }
        if hasDeparted {
            return now < option.train.departureTime ? "You’re on your way" : "You’re on the train"
        }
        switch urgency {
        case .relaxed: return "You’re on track"
        case .soon: return "Get ready"
        case .urgent: return now >= option.attempts.leaveAt ? "Leave now" : "Leave soon"
        case .missed: return "Missed it"
        }
    }

    /// "Leave in 22 min · by 8:07 AM"; once leaving, "Too late in 2 min · at 8:10 AM".
    private func leaveLine(_ option: TrainOption, urgency: Urgency) -> Text {
        let attempts = option.attempts
        let colored = { (text: String) in Text(text).foregroundStyle(urgency.color) }
        let detail = { (text: String) in Text(text).foregroundStyle(.secondary) }
        if isTemporaryRoute {
            return detail("Departs \(Format.time(option.train.departureTime)) · \(Format.minutes(plan.safetyBuffer)) buffer")
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
        if isTemporaryRoute {
            return "🚆 to \(plan.destinationStation.name) · \(arrival)"
        }
        if hasDeparted && now >= train.departureTime {
            // On board: getting to the station is done, only the last leg remains.
            return "\(Format.minutes(plan.egressTime)) from \(plan.destinationStation.name) · \(arrival)"
        }
        let mode = profile.accessMode == .bike ? "🚲" : "🚶"
        var parts = ["\(Format.minutes(plan.accessTime)) by \(mode) to 🚆"]
        if plan.safetyBuffer >= 60 {
            parts.append("\(Format.minutes(plan.safetyBuffer)) buffer")
        }
        parts.append(arrival)
        return parts.joined(separator: " · ")
    }

    private var destinationEmoji: String {
        if isTemporaryRoute { return "📍" }
        return plan.direction == .homeToWork ? "🏢" : "🏠"
    }

    /// While an earlier preferred train is still at the station but out of reach, say so; it
    /// disappears once that train departs.
    private func missedLine(_ option: TrainOption) -> String? {
        if reservesMissedLine {
            return "Too late for the 0:00 AM train"
        }
        guard !isTemporaryRoute, !option.isManual, !hasDeparted else { return nil }
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

    init(train: TrainDeparture, plan: CommutePlan, now: Date) {
        if train.isCancelled {
            self = .cancelled
        } else if train.departureTime <= now {
            self = .departed
        } else if !plan.isCatchable(train, at: now) {
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
    let onPick: (TrainDeparture) -> Void
    let onClearPick: () -> Void

    @State private var showsAll = false

    /// Upcoming rows shown before "Show more" (departed rows come on top of these).
    private static let collapsedUpcoming = 4

    var body: some View {
        let rows = visibleRows
        let countdownIDs = Set(plan.upcoming.filter { RowStatus(train: $0, plan: plan, now: now) == .catchable }.prefix(2).map(\.id))
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upcoming trains")
                    .font(.headline)
                    .padding(.bottom, 6)

                if rows.isEmpty {
                    Text("No more trains today.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                let spansDays = Set(rows.map { DateKey.key(for: $0.departureTime) }).count > 1
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, train in
                    // Day labels only matter when the list crosses midnight.
                    if spansDays && (index == 0 || !Calendar.caltrain.isDate(rows[index - 1].departureTime, inSameDayAs: train.departureTime)) {
                        Text(Format.day(train.departureTime, relativeTo: now))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 0 : 6)
                    }
                    row(train, showsCountdown: countdownIDs.contains(train.id) || train.id == highlightedID)
                    if train.id != rows.last?.id {
                        Divider()
                    }
                }

                if hiddenCount > 0 || showsAll {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) {
                            showsAll.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showsAll ? "Show less" : "Show \(hiddenCount) more")
                            Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
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

    /// Departed rows, then the next few; the target train is always included.
    private var visibleRows: [TrainDeparture] {
        guard !showsAll else { return plan.upcoming }
        let firstUpcoming = plan.upcoming.firstIndex { $0.departureTime > now } ?? plan.upcoming.count
        let targetIndex = plan.upcoming.firstIndex { $0.id == highlightedID } ?? 0
        let end = max(firstUpcoming + Self.collapsedUpcoming, targetIndex + 1)
        return Array(plan.upcoming.prefix(end))
    }

    private var hiddenCount: Int {
        showsAll ? 0 : plan.upcoming.count - visibleRows.count
    }

    private func row(_ train: TrainDeparture, showsCountdown: Bool) -> some View {
        let status = RowStatus(train: train, plan: plan, now: now)
        let isTarget = train.id == highlightedID
        return TrainRow(train: train, plan: plan, now: now, status: status, isTarget: isTarget, isTaking: isTarget && isTripInProgress, showsCountdown: showsCountdown)
            .contentShape(Rectangle())
            .contextMenu {
                if status == .catchable && !isTarget {
                    Button {
                        onPick(train)
                    } label: {
                        Label("Set as target", systemImage: "scope")
                    }
                }
                if isTarget && plan.train?.isManual == true {
                    Button(action: onClearPick) {
                        Label("Back to automatic target", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("schedule-train-\(train.trainNumber)")
            .accessibilityActions {
                if status == .catchable && !isTarget {
                    Button("Set as target") { onPick(train) }
                }
                if isTarget && plan.train?.isManual == true {
                    Button("Back to automatic target", action: onClearPick)
                }
            }
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
    let showsCountdown: Bool

    var body: some View {
        let urgency = isTaking ? .relaxed : Urgency(attempts: plan.attempts(for: train), now: now)
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
                        Image(systemName: "scope")
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
                if plan.transitSource == .live && status != .cancelled {
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
                            Text("Arrive \(Format.time(plan.generatedAt.addingTimeInterval(car.eta)))")
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
