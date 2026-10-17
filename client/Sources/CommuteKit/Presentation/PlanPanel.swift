import SwiftUI

/// The bottom-sheet content: header, next-train hero card, upcoming trains, car comparison.
struct PlanPanel: View {
    let viewModel: CommuteViewModel
    @Binding var isSettingsPresented: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if let plan = viewModel.plan {
                    if let notice = plan.transitNotice {
                        Card {
                            Label(notice, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                    SwiftUI.TimelineView(.periodic(from: .now, by: 15)) { _ in
                        let now = viewModel.currentDate()
                        VStack(spacing: 14) {
                            HeroCard(plan: plan, profile: viewModel.profile, now: now, departure: departureControl)
                            UpcomingTrainsCard(plan: plan, now: now)
                            CarCard(plan: plan)
                            footer(plan: plan)
                        }
                    }
                } else if let message = viewModel.errorMessage {
                    Card {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Card {
                        ProgressView(viewModel.timetableInfo == nil ? "Downloading the Caltrain timetable…" : "Finding trains…")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.toggleDirection() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(viewModel.direction.title)
                            .font(.title2.weight(.bold))
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    Text(routeSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Switches between going to work and going home")

            if viewModel.isRefreshing {
                ProgressView()
            }

            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Palette.card, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isLoaded)
            .accessibilityLabel("Settings")
        }
    }

    private var routeSubtitle: String {
        let profile = viewModel.profile
        let from = StationCatalog.station(id: profile.originStationID(for: viewModel.direction))?.name ?? "?"
        let to = StationCatalog.station(id: profile.destinationStationID(for: viewModel.direction))?.name ?? "?"
        return "\(from) → \(to)"
    }

    /// "I'm on my way" for the commute on screen, when the app sends its own alerts.
    private var departureControl: DepartureControl? {
        guard viewModel.alertsOnDevice, viewModel.profile.leaveAlertsEnabled else { return nil }
        return DepartureControl(hasDeparted: viewModel.hasDepartedCurrentCommute) {
            Task { await viewModel.markDeparted() }
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
}

// MARK: - Hero

struct DepartureControl {
    let hasDeparted: Bool
    let markDeparted: () -> Void
}

private struct HeroCard: View {
    let plan: CommutePlan
    let profile: CommuteProfile
    let now: Date
    let departure: DepartureControl?

    var body: some View {
        Card {
            if let option = plan.train {
                content(option)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No more trains today", systemImage: "moon.zzz.fill")
                        .font(.headline)
                    Text("Nothing left from \(plan.originStation.name) for the train types you picked. Check Settings → Train types.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func content(_ option: TrainOption) -> some View {
        let state = option.state(at: now)
        let train = option.train
        return VStack(alignment: .leading, spacing: 14) {
            Label(state.title.uppercased(), systemImage: state.symbol)
                .font(.caption.weight(.heavy))
                .foregroundStyle(state.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline(option, state: state))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(detail(option, state: state))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ServiceBadge(service: train.service)
                Text("Train \(train.trainNumber)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                DelayLabel(train: train, isLive: plan.transitSource == .live)
                    .font(.subheadline.weight(.semibold))
            }

            HStack(spacing: 10) {
                stop(time: train.departureTime, scheduled: train.scheduledDeparture, station: plan.originStation.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                stop(time: train.arrivalTime, scheduled: train.scheduledArrival, station: plan.destinationStation.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AttemptStrip(attempts: option.attempts, now: now)

            HStack(spacing: 14) {
                Label("\(Format.minutes(plan.accessTime)) to platform", systemImage: profile.accessMode.symbol)
                Label("At \(destinationName) \(Format.time(plan.doorArrival(for: train)))", systemImage: "flag.checkered")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            if let fallback = option.fallback {
                Label("Missed it? \(fallback.service.displayName) \(fallback.trainNumber) at \(Format.time(fallback.departureTime))", systemImage: "arrow.uturn.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let departure {
                if departure.hasDeparted {
                    Label("On your way. Alerts for this trip are off.", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button(action: departure.markDeparted) {
                        Label("I’m on my way", systemImage: "figure.walk.departure")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.color)
                }
            }
        }
    }

    private var destinationName: String {
        plan.direction == .homeToWork ? "work" : "home"
    }

    private func headline(_ option: TrainOption, state: CommuteState) -> String {
        if now >= option.attempts.leaveAt {
            return now > option.attempts.tooLateAt ? "Missed it" : "Leave now"
        }
        return "Leave \(Format.relative(option.attempts.leaveAt, from: now))"
    }

    private func detail(_ option: TrainOption, state: CommuteState) -> String {
        switch state {
        case .onTrack, .getReady:
            "Leave by \(Format.time(option.attempts.leaveAt)) · target \(Format.time(plan.targetLeave))"
        case .leaveNow:
            "Too late after \(Format.time(option.attempts.tooLateAt))"
        case .rolledToNextTrain:
            // Hours after the target time, "missed" is noise; it is simply the next train.
            if now.timeIntervalSince(plan.targetLeave) < 90 * 60 {
                "Missed the \(Format.time(plan.targetLeave)) target. Leave by \(Format.time(option.attempts.leaveAt)) for this one"
            } else {
                "Next train you can catch. Leave by \(Format.time(option.attempts.leaveAt))"
            }
        }
    }

    private func stop(time: Date, scheduled: Date, station: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
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

/// Get ready → leave → too late, with a marker for the current time.
private struct AttemptStrip: View {
    let attempts: AttemptTimes
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            milestone("Get ready", attempts.getReadyAt, color: .orange)
            milestone("Leave", attempts.leaveAt, color: .red)
            milestone("Too late", attempts.tooLateAt, color: .secondary)
        }
        .padding(.vertical, 10)
        .background(Palette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func milestone(_ title: String, _ date: Date, color: Color) -> some View {
        let isPast = now >= date
        return VStack(spacing: 2) {
            Text(Format.time(date))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .opacity(isPast ? 0.55 : 1)
    }
}

// MARK: - Upcoming

private struct UpcomingTrainsCard: View {
    let plan: CommutePlan
    let now: Date

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upcoming trains")
                    .font(.headline)
                    .padding(.bottom, 6)

                if plan.upcoming.isEmpty {
                    Text("No more trains of your types today.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(plan.upcoming.prefix(8))) { train in
                    TrainRow(train: train, plan: plan, now: now, isSelected: train.id == plan.train?.train.id)
                    if train.id != plan.upcoming.prefix(8).last?.id {
                        Divider()
                    }
                }

                if plan.hiddenTrainCount > 0 {
                    Text("\(plan.hiddenTrainCount) more of other train types hidden. Change in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }
}

private struct TrainRow: View {
    let train: TrainDeparture
    let plan: CommutePlan
    let now: Date
    let isSelected: Bool

    var body: some View {
        let catchable = plan.isCatchable(train, at: now)
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
                }
                Text(Format.minutes(train.arrivalTime.timeIntervalSince(train.departureTime)) + " ride")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                // Rows only flag changes; "Scheduled" on every row would be noise.
                if plan.transitSource == .live || train.isCancelled {
                    DelayLabel(train: train, isLive: plan.transitSource == .live)
                        .font(.caption.weight(.semibold))
                }
                Text(status(catchable: catchable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .opacity(catchable || train.isCancelled ? 1 : 0.45)
    }

    private func status(catchable: Bool) -> String {
        if train.isCancelled {
            return ""
        }
        guard catchable else {
            return "Can’t make it"
        }
        let leave = plan.attempts(for: train).leaveAt
        return now >= leave ? "Leave now" : "Leave \(Format.relative(leave, from: now))"
    }
}

// MARK: - Car

private struct CarCard: View {
    let plan: CommutePlan

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "car.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                if let car = plan.car {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Driving \(Format.minutes(car.eta))")
                            .font(.headline)
                        Text(car.isTrafficGood ? "Traffic is light" : "Heavy traffic, \(Format.minutes(car.delay)) slower than usual")
                            .font(.subheadline)
                            .foregroundStyle(car.isTrafficGood ? .green : .orange)
                    }
                    Spacer()
                    if let train = plan.train?.train {
                        comparison(car: car, train: train)
                    }
                } else {
                    Text("Driving time unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Arrival if leaving by car now vs. by the selected train.
    private func comparison(car: CarOption, train: TrainDeparture) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Arrive \(Format.time(plan.generatedAt.addingTimeInterval(car.eta)))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text("train gets you there \(Format.time(plan.doorArrival(for: train)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
