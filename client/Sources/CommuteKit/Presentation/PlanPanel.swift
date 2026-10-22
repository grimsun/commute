import SwiftUI

/// The bottom-sheet content. Compact, it shows just the train and its times. Collapsed, the header
/// and the next-train card; neither scrolls, so any swipe resizes the sheet. Expanded, it scrolls
/// through the trains and car card.
struct PlanPanel: View {
    let viewModel: CommuteViewModel
    let panel: DashboardView.PanelSize
    private var isExpanded: Bool { panel == .expanded }
    private var isCompact: Bool { panel == .compact }
    let onOpenSettings: () -> Void
    /// Refresh in the header; also recenters the map.
    let onRefresh: () -> Void
    /// Reports the height of the collapsed content (and whether it is the loading card) so the
    /// sheet can fit it exactly.
    let onCollapsedHeightChange: (CGFloat, Bool) -> Void
    /// Reports the height of the compact content: the card's train line and times.
    let onCompactHeightChange: (CGFloat) -> Void
    /// Called after the rider sets a train as target, e.g. to collapse the sheet onto it.
    let onPickTrain: () -> Void

    /// While the list scrolls, the clock tick pauses so scrolling stays smooth.
    @State private var isScrolling = false
    @State private var refreshSpin = 0.0

    private static let topID = "top"
    private static let compactTopPadding: CGFloat = 22
    /// How often the card re-evaluates countdowns, colors and row states between refreshes.
    /// Cheap enough to do every second, so stage changes land on time.
    private static let tick: TimeInterval = 1

    /// Paused while scrolling; compact shows no countdowns, so a minute is enough there.
    private var tickInterval: TimeInterval {
        isScrolling ? 3600 : isCompact ? 60 : Self.tick
    }

    var body: some View {
        // Read observable state here, outside the TimelineView, so changes redraw at once
        // instead of waiting for the next tick.
        let plan = viewModel.plan
        let routeProfile = viewModel.routeProfile
        let departedTrain = viewModel.departedTrain
        let trainPath = viewModel.trainPath
        let elsewhereTrain = viewModel.elsewhereTrain
        let scheduleDetail = viewModel.scheduleDay?.label
        let errorMessage = viewModel.errorMessage
        let isDownloading = viewModel.timetableInfo == nil
        let isSchedule = viewModel.mode == .schedule
        let isOtherDay = isSchedule && viewModel.scheduleDayOffset != 0
        return ScrollViewReader { scroller in
            ScrollView {
                SwiftUI.TimelineView(.periodic(from: .now, by: tickInterval)) { _ in
                    // Another day's schedule reads as if it were that day at this time.
                    let now = viewModel.displayDate(for: viewModel.currentDate())
                    // Travelling until the door-arrival time; evaluated every tick so it ends on time.
                    let tripInProgress = departedTrain.flatMap { train in
                        plan.map { now < $0.doorArrival(for: train) } == true ? train : nil
                    }
                    let missedOption = tripInProgress == nil ? viewModel.missedOption(at: now) : nil
                    VStack(spacing: 14) {
                        VStack(spacing: 12) {
                            // Compact is only the card's top: the train and its times.
                            if !isCompact {
                                header
                            }
                            if let plan {
                                HeroCard(plan: plan, profile: routeProfile, now: now, tripInProgress: tripInProgress, isSchedule: isSchedule, isOtherDay: isOtherDay, elsewhereTrain: tripInProgress == nil ? elsewhereTrain : nil, missedOption: missedOption, path: trainPath, showsStops: isExpanded, isCompact: isCompact,
                                         onTopHeightChange: { height in
                                             // Plus the card's padding and the space above it.
                                             onCompactHeightChange(height + 32 + Self.compactTopPadding)
                                         },
                                         onTakeTrain: isSchedule ? nil : { train in Task { await viewModel.takeTrain(train) } },
                                         onEndTrip: isSchedule ? nil : { Task { await viewModel.endTrip() } },
                                         onToggleDirection: { Task { await viewModel.toggleDirection() } }) { train in
                                    Task { await viewModel.pick(train) }
                                }
                            } else {
                                loadingCard(errorMessage: errorMessage, isDownloading: isDownloading)
                            }
                        }
                        // Compact has no header, so the card keeps clear of the grabber itself.
                        .padding(.top, isCompact ? Self.compactTopPadding : 14)
                        .id(Self.topID)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            onCollapsedHeightChange(height, plan == nil)
                        }

                        // Collapsed, only the header and card show: nothing peeks in under them, and
                        // the list isn't laid out every second while it can't be seen.
                        if let plan, isExpanded {
                            Group {
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
                                isOtherDay: isOtherDay,
                                scheduleLabel: scheduleDetail,
                                preferredServices: isSchedule ? nil : routeProfile.preferredServices,
                                onPick: { train in
                                    Task { await viewModel.pick(train) }
                                    onPickTrain()
                                },
                                onClearPick: {
                                    Task { await viewModel.clearPick() }
                                },
                                onTake: isSchedule ? nil : { train in
                                    Task { await viewModel.takeTrain(train) }
                                    onPickTrain()
                                },
                                onEndTrip: {
                                    Task { await viewModel.endTrip() }
                                },
                                loadPath: { train in await viewModel.path(for: train) }
                            )
                            // Driving is moot once you're on your way, and between two stations.
                            if tripInProgress == nil && !isSchedule {
                                CarCard(plan: plan, now: now)
                            }
                            footer(plan: plan)
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    // Stage changes (on track → get ready → leave → next train) and row states animate.
                    .animation(.smooth(duration: 0.35), value: plan.map { PanelPhase(plan: $0, now: now, includesRows: isExpanded) })
                    .animation(.smooth(duration: 0.25), value: isExpanded)
                }
            }
            .scrollIndicators(.hidden)
            // The sheet floats above the home indicator already; its inset would double the margin.
            .ignoresSafeArea(.container, edges: .bottom)
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

    /// Refresh, the stations and settings; not tappable as a whole, since this is where people
    /// grab the sheet. Schedule mode makes each station a menu of all stations. The direction
    /// flips from the arrow on the card.
    private var header: some View {
        HStack(spacing: 10) {
            Button {
                // One full turn as feedback; refreshes are usually too quick for a spinner.
                withAnimation(.easeInOut(duration: 0.6)) {
                    refreshSpin += 360
                }
                onRefresh()
                Task { await viewModel.refresh(userInitiated: true) }
            } label: {
                // Gray like the settings gear, so the two header buttons match.
                Image(systemName: "arrow.clockwise")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(refreshSpin))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isLoaded)
            .accessibilityLabel("Refresh and recenter")

            Group {
                if viewModel.mode == .schedule {
                    scheduleStations
                } else {
                    // "San Francisco → Palo Alto" on one line (the card says "To work"); scales down rather than wrapping.
                    Text(routeTitle)
                        .font(.headline)
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
struct PanelPhase: Hashable {
    let trainID: String?
    let urgency: Urgency?
    /// Row states, only while the list shows; these are worked out every tick.
    let rows: [String]

    init(plan: CommutePlan, now: Date, includesRows: Bool) {
        trainID = plan.train?.train.id
        urgency = plan.train.map { Urgency(attempts: $0.attempts, now: now) }
        rows = includesRows ? plan.upcoming.map { "\($0.id):\(RowStatus(train: $0, plan: plan, now: now))" } : []
    }
}

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
