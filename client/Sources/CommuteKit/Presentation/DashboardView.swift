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
    /// Commute was tapped without home and work addresses.
    @State private var isAddressPromptPresented = false
    @State private var panel: PanelSize = .collapsed
    private var isExpanded: Bool { panel == .expanded }
    /// Applied once loaded: the sheet settles at its first detent while it is being presented.
    private let initialPanel: PanelSize
    /// Collapsed height fitted to the card; see `fitCollapsed`. One for both modes, since a sheet
    /// snaps rather than glides to a new height, and remembered across launches, so the sheet
    /// opens at its final size and doesn't jump when the loading card is replaced.
    @State private var fittedHeight: CGFloat? = Self.savedHeight()
    private static let heightKey = "commute.sheetHeight.v2"
    /// From the full-size loading card, until the real card is measured.
    @State private var placeholderHeight: CGFloat = 380
    /// Set while the sheet is moving anyway (launch, settling at collapsed): the next measurement
    /// may shrink the height too, so a card that was briefly taller doesn't leave a gap.
    @State private var refitsOnMeasure = true
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

    private var collapsedHeight: CGFloat {
        fittedHeight ?? placeholderHeight
    }

    private static func savedHeight() -> CGFloat? {
        let saved = UserDefaults.standard.double(forKey: heightKey)
        return saved > 0 ? saved : nil
    }

    private var collapsedDetent: PresentationDetent {
        .height(collapsedHeight)
    }

    private var compactDetent: PresentationDetent {
        // Detents must differ; before measuring, keep compact clearly below collapsed.
        .height(min(compactHeight, collapsedHeight - 40))
    }

    /// Full height, short of the map's top controls, so the mode switch stays in reach.
    private var expandedDetent: PresentationDetent {
        .custom(BelowMapControls.self)
    }

    /// Maps the positions onto detents; heights can change without losing the position.
    private var detentSelection: Binding<PresentationDetent> {
        Binding {
            switch panel {
            case .compact: compactDetent
            case .collapsed: collapsedDetent
            case .expanded: expandedDetent
            }
        } set: { detent in
            panel = detent == expandedDetent ? .expanded : detent == compactDetent ? .compact : .collapsed
        }
    }

    /// Fits the card on launch and whenever the sheet settles at collapsed; in between it only
    /// grows, so the sheet keeps one size as lines come and go and as the mode switches.
    private func fitCollapsed(contentHeight: CGFloat, isPlaceholder: Bool) {
        // Only the collapsed layout counts: expanded adds stops, compact hides the header.
        guard panel == .collapsed else { return }
        // The sheet floats above the home indicator, so the detent can be a little shorter than the
        // content: this leaves a bottom margin about as wide as the card's side margins.
        let fitted = min(max((contentHeight - 16).rounded(), 200), 620)
        if isPlaceholder {
            placeholderHeight = fitted
        } else if refitsOnMeasure ? abs(fitted - (fittedHeight ?? 0)) > 1 : fitted > (fittedHeight ?? 0) + 1 {
            fittedHeight = fitted
            UserDefaults.standard.set(Double(fitted), forKey: Self.heightKey)
        }
    }

    /// Lets the measurements of the next moment refit the sheet, while it is still moving.
    private func allowRefit() {
        refitsOnMeasure = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            refitsOnMeasure = false
        }
    }

    public var body: some View {
        CommuteMapView(
            profile: viewModel.routeProfile,
            isSchedule: viewModel.mode == .schedule,
            // One inset for every sheet position: changing it as the sheet settles would make the
            // map jump. Compact just reveals more of the map.
            bottomInset: collapsedHeight,
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
            MapControls(viewModel: viewModel, onModeChange: {
                recenterRequest += 1
            }, onNeedsAddresses: {
                isAddressPromptPresented = true
            })
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
            .presentationDetents(allowsCompact ? [compactDetent, collapsedDetent, expandedDetent] : [collapsedDetent, expandedDetent], selection: detentSelection)
            .presentationContentInteraction(.resizes)
            // The map's controls stay usable with the sheet open.
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.visible)
            .presentationBackground(Palette.panel)
            .interactiveDismissDisabled()
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView(viewModel: viewModel)
            }
            // On the sheet, since the map can't present while the sheet is up.
            .alert("Add your home and work", isPresented: $isAddressPromptPresented) {
                Button("Open Settings") {
                    isSettingsPresented = true
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Commute mode tells you when to leave and reminds you before your train. It needs your home and work addresses; until then, the app shows the schedule.")
            }
        }
        .task {
            await viewModel.run()
        }
        .onChange(of: viewModel.isLoaded) { _, loaded in
            guard loaded else { return }
            // Wait for the sheet's presentation to settle, or it resets to the first detent.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                allowsCompact = true
                panel = initialPanel
                allowRefit()
            }
            if showsSettingsOnLaunch {
                isSettingsPresented = true
            }
        }
        // The address notice comes or goes, so the card's height changes.
        .onChange(of: viewModel.hasAddresses) { _, _ in
            if panel == .collapsed {
                allowRefit()
            }
        }
        .onChange(of: panel) { previous, current in
            if current == .collapsed && previous != .collapsed {
                allowRefit()
            }
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

/// The large detent less the height of the map's top controls.
private struct BelowMapControls: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        context.maxDetentValue - 56
    }
}

/// The commute / schedule switch (left) and, in schedule mode, which day's trains (right).
private struct MapControls: View {
    let viewModel: CommuteViewModel
    let onModeChange: () -> Void
    let onNeedsAddresses: () -> Void

    var body: some View {
        HStack {
            Button {
                guard viewModel.hasAddresses else {
                    onNeedsAddresses()
                    return
                }
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
