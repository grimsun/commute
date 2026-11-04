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
    /// Collapsed height fitted to each mode's card; see `fitCollapsed`. The sheet uses the larger,
    /// since it snaps rather than glides to a new height: switching modes never resizes it, even the
    /// first time. Remembered across launches, so the sheet opens at its final size and doesn't jump
    /// when the loading card is replaced.
    @State private var fittedHeights: [AppMode: CGFloat] = Self.savedHeights()
    private var fittedHeight: CGFloat? { fittedHeights.values.max() }
    private static let heightsKey = "commute.sheetHeights.v3"
    /// The single height saved before heights were kept per mode.
    private static let legacyHeightKey = "commute.sheetHeight.v2"
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

    private static func savedHeights() -> [AppMode: CGFloat] {
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: heightsKey) as? [String: Double] {
            return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in AppMode(rawValue: key).map { ($0, CGFloat(value)) } })
        }
        // The old single height fitted whichever card was taller, so it stands for both.
        let legacy = defaults.double(forKey: legacyHeightKey)
        return legacy > 0 ? [.commute: legacy, .schedule: legacy] : [:]
    }

    private func saveHeights() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: fittedHeights.map { ($0.key.rawValue, Double($0.value)) }), forKey: Self.heightsKey)
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

    /// Fits `mode`'s card on launch and whenever the sheet settles at collapsed; in between it only
    /// grows, so the sheet keeps one size as lines come and go and as the mode switches.
    private func fitCollapsed(contentHeight: CGFloat, isPlaceholder: Bool, mode: AppMode) {
        // Only the collapsed layout counts: expanded adds stops, compact hides the header.
        guard panel == .collapsed else { return }
        // The sheet floats above the home indicator, so the detent can be a little shorter than the
        // content: this leaves a bottom margin about as wide as the card's side margins.
        let fitted = min(max((contentHeight - 16).rounded(), 200), 620)
        if isPlaceholder {
            placeholderHeight = fitted
        } else {
            let current = fittedHeights[mode] ?? 0
            guard refitsOnMeasure ? abs(fitted - current) > 1 : fitted > current + 1 else { return }
            fittedHeights[mode] = fitted
            saveHeights()
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
            }, onCollapsedHeightChange: { contentHeight, isPlaceholder, mode in
                fitCollapsed(contentHeight: contentHeight, isPlaceholder: isPlaceholder, mode: mode)
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
        #if os(iOS)
        .onChange(of: viewModel.profile.appearance, initial: true) { _, appearance in
            appearance.apply()
        }
        #endif
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
