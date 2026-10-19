import SwiftUI

/// Full-screen map with the plan in a three-position bottom sheet: compact (just the train and
/// its times), collapsed to the next-train card, or expanded to full height.
public struct DashboardView: View {
    public enum PanelSize: String, Sendable {
        case compact, collapsed, expanded
    }

    @State private var viewModel: CommuteViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false
    @State private var panel: PanelSize = .collapsed
    private var isExpanded: Bool { panel == .expanded }
    /// Applied once loaded: the sheet settles at its first detent while it is being presented.
    private let initialPanel: PanelSize
    /// Collapsed heights fitted to each mode's card (schedule's is shorter); see `fitCollapsed`.
    /// Remembered across launches, so the sheet opens at its final size and doesn't jump when
    /// the loading card is replaced.
    @State private var collapsedHeights: [AppMode: CGFloat] = Self.savedHeights()
    private static let heightsKey = "commute.sheetHeights.v1"
    /// From the full-size loading card, until a mode's real card is measured.
    @State private var placeholderHeight: CGFloat = 380
    /// Fits the train line and times.
    @State private var compactHeight: CGFloat = 150
    /// The sheet settles at its smallest detent while presenting, so compact joins afterwards.
    @State private var allowsCompact = false
    @State private var recenterRequest = 0
    private let showsSettingsOnLaunch: Bool

    public init(viewModel: CommuteViewModel, panelSize: PanelSize = .collapsed, showsSettings: Bool = false) {
        _viewModel = State(initialValue: viewModel)
        initialPanel = panelSize
        showsSettingsOnLaunch = showsSettings
    }

    /// The current mode's collapsed height, changed with an animation so switching modes glides.
    @State private var collapsedHeight: CGFloat = Self.savedHeights()[.commute] ?? 380

    private func updateCollapsedHeight(animated: Bool = true) {
        let target = collapsedHeights[viewModel.mode] ?? placeholderHeight
        guard abs(target - collapsedHeight) > 0.5 else { return }
        var transaction = Transaction(animation: .smooth(duration: 0.3))
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            collapsedHeight = target
        }
    }

    private static func savedHeights() -> [AppMode: CGFloat] {
        let saved = UserDefaults.standard.dictionary(forKey: heightsKey) as? [String: Double] ?? [:]
        var heights: [AppMode: CGFloat] = [:]
        for (key, value) in saved {
            if let mode = AppMode(rawValue: key) { heights[mode] = value }
        }
        return heights
    }

    private func saveHeights() {
        let saved = Dictionary(uniqueKeysWithValues: collapsedHeights.map { ($0.key.rawValue, Double($0.value)) })
        UserDefaults.standard.set(saved, forKey: Self.heightsKey)
    }

    /// The taller mode's collapsed height, so neither card covers the route.
    private var mapBottomInset: CGFloat {
        collapsedHeights.values.max() ?? placeholderHeight
    }

    private var collapsedDetent: PresentationDetent {
        .height(collapsedHeight)
    }

    private var compactDetent: PresentationDetent {
        // Detents must differ; before measuring, keep compact clearly below collapsed.
        .height(min(compactHeight, collapsedHeight - 40))
    }

    /// Maps the positions onto detents; heights can change without losing the position.
    private var detentSelection: Binding<PresentationDetent> {
        Binding {
            switch panel {
            case .compact: compactDetent
            case .collapsed: collapsedDetent
            case .expanded: .large
            }
        } set: { detent in
            panel = detent == .large ? .expanded : detent == compactDetent ? .compact : .collapsed
        }
    }

    /// The first real measurement for a mode sets its height (the loading card is a guess); after
    /// that it only grows, so the card keeps one size as its lines come and go.
    private func fitCollapsed(contentHeight: CGFloat, isPlaceholder: Bool) {
        // Only the collapsed layout counts: expanded adds stops, compact hides the header.
        guard panel == .collapsed else { return }
        // The sheet floats above the home indicator, so the detent can be a little shorter than the
        // content: this leaves a bottom margin about as wide as the card's side margins.
        let fitted = min(max((contentHeight - 16).rounded(), 200), 620)
        let mode = viewModel.mode
        if isPlaceholder {
            if collapsedHeights[mode] == nil {
                placeholderHeight = fitted
            }
        } else if let current = collapsedHeights[mode] {
            if fitted > current + 1 {
                collapsedHeights[mode] = fitted
                saveHeights()
            }
        } else {
            collapsedHeights[mode] = fitted
            saveHeights()
        }
        updateCollapsedHeight()
    }

    public var body: some View {
        CommuteMapView(
            profile: viewModel.routeProfile,
            isSchedule: viewModel.mode == .schedule,
            // One inset for every sheet position and mode: changing it as the sheet settles or the
            // mode switches would make the map jump. Compact just reveals more of the map.
            bottomInset: mapBottomInset,
            recenterRequest: recenterRequest,
            trainPath: viewModel.trainPath,
            trainDelay: TimeInterval(viewModel.plan?.train?.train.delaySeconds ?? 0),
            isLive: viewModel.plan?.transitSource == .live,
            now: viewModel.currentDate,
            isVisible: !isExpanded
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            // A separate view, so refresh progress redraws only the buttons, not the map.
            MapControls(viewModel: viewModel) {
                recenterRequest += 1
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .sheet(isPresented: .constant(true)) {
            PlanPanel(viewModel: viewModel, panel: panel, onOpenSettings: {
                isSettingsPresented = true
            }, onRefresh: {
                recenterRequest += 1
            }, onCollapsedHeightChange: { contentHeight, isPlaceholder in
                fitCollapsed(contentHeight: contentHeight, isPlaceholder: isPlaceholder)
            }, onCompactHeightChange: { contentHeight in
                compactHeight = (contentHeight - 16).rounded()
            }, onPickTrain: {
                // Show the picked train in the next-train card.
                panel = .collapsed
            })
            .presentationDetents(allowsCompact ? [compactDetent, collapsedDetent, .large] : [collapsedDetent, .large], selection: detentSelection)
            .presentationContentInteraction(.resizes)
            .presentationBackgroundInteraction(.enabled(upThrough: collapsedDetent))
            .presentationDragIndicator(.visible)
            .presentationBackground(Palette.panel)
            .interactiveDismissDisabled()
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView(viewModel: viewModel)
            }
        }
        .task {
            await viewModel.run()
        }
        .onChange(of: viewModel.isLoaded) { _, loaded in
            guard loaded else { return }
            // The mode is known now; start at its remembered size without animating.
            updateCollapsedHeight(animated: false)
            // Wait for the sheet's presentation to settle, or it resets to the first detent.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                allowsCompact = true
                panel = initialPanel
            }
            if showsSettingsOnLaunch {
                isSettingsPresented = true
            }
        }
        .onChange(of: viewModel.mode) { _, _ in
            updateCollapsedHeight()
        }
        .onChange(of: scenePhase) { previous, phase in
            if phase == .active {
                // Reopening the app starts from the next-train view, like a fresh launch;
                // compact stays compact, since that was a deliberate choice.
                if previous == .background && panel == .expanded {
                    panel = .collapsed
                }
                Task { await viewModel.becameActive(fromBackground: previous == .background) }
            }
        }
    }
}

/// The commute / schedule switch (left) and, in schedule mode, which day's trains (right).
private struct MapControls: View {
    let viewModel: CommuteViewModel
    let onModeChange: () -> Void

    var body: some View {
        HStack {
            Button {
                onModeChange()
                Task { await viewModel.toggleMode() }
            } label: {
                ModeSwitch(mode: viewModel.mode)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isLoaded)
            .accessibilityLabel("Mode")
            .accessibilityValue(viewModel.mode.title)
            .accessibilityHint("Switches to \(viewModel.mode.other.title.lowercased())")
            .accessibilityIdentifier("mode-switch")

            Spacer()

            if let day = viewModel.scheduleDay {
                ScheduleKindPill(day: day, isSchedule: viewModel.mode == .schedule) {
                    Task { await viewModel.toggleScheduleKind() }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: viewModel.mode)
    }
}

/// Which timetable the trains on screen run on: "Weekday", "Weekend" or "Holiday". In schedule
/// mode a tap flips between weekday and weekend; in commute mode it's only a label.
private struct ScheduleKindPill: View {
    let day: ScheduleDay
    let isSchedule: Bool
    let onToggle: () -> Void

    var body: some View {
        if isSchedule {
            Button(action: onToggle) {
                label(showsToggle: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Timetable")
            .accessibilityValue(title)
            .accessibilityHint("Switches between weekday and weekend trains")
            .accessibilityIdentifier("schedule-kind")
        } else {
            label(showsToggle: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title) timetable")
        }
    }

    private var title: String {
        day.holidayName == nil ? day.kind.rawValue.capitalized : "Holiday"
    }

    private func label(showsToggle: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .contentTransition(.opacity)
            if showsToggle {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(showsToggle ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .animation(.smooth(duration: 0.25), value: title)
    }
}

/// Both modes side by side, the current one highlighted, so it reads as a switch.
private struct ModeSwitch: View {
    let mode: AppMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.commute, symbol: "briefcase.fill")
            segment(.schedule, symbol: "calendar")
        }
        .padding(3)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func segment(_ segment: AppMode, symbol: String) -> some View {
        let isSelected = segment == mode
        return HStack(spacing: 5) {
            Image(systemName: symbol)
            if isSelected {
                Text(segment.title)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, isSelected ? 12 : 10)
        .frame(maxHeight: .infinity)
        .background {
            if isSelected {
                Capsule().fill(.tint)
            }
        }
        .contentShape(Capsule())
    }
}

#if DEBUG
/// Sample trains and no alerts, so previews work offline.
private struct PreviewServiceFactory: CommuteServiceFactory {
    func services(for settings: DataSourceSettings) -> CommuteServices {
        CommuteServices(transit: SampleTransitProvider(), alerts: NoopLeaveAlertScheduler())
    }
}

@MainActor
private func previewViewModel() -> CommuteViewModel {
    CommuteViewModel(
        profileStore: InMemoryProfileStore(),
        timetable: TimetableStore(source: GTFSTimetableSource(), cacheURL: nil),
        factory: PreviewServiceFactory(),
        traffic: FixedTrafficProvider(eta: 52 * 60, freeFlowETA: 38 * 60),
        access: FixedAccessProvider(seconds: 7 * 60)
    )
}

#Preview("Dashboard") {
    DashboardView(viewModel: previewViewModel())
}

#Preview("Settings") {
    SettingsView(viewModel: previewViewModel())
}
#endif
