import SwiftUI

/// Full-screen map with the plan in a two-position bottom sheet: collapsed to the next train,
/// or expanded to full height.
public struct DashboardView: View {
    public enum PanelSize: String, Sendable {
        case collapsed, expanded
    }

    @State private var viewModel: CommuteViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false
    @State private var isExpanded = false
    /// Applied once loaded: the sheet settles at its first detent while it is being presented.
    private let startsExpanded: Bool
    /// Fits the header and next-train card; updated as their content changes.
    @State private var collapsedHeight: CGFloat = 380
    @State private var hasMeasuredCollapsedHeight = false
    @State private var recenterRequest = 0
    private let showsSettingsOnLaunch: Bool

    public init(viewModel: CommuteViewModel, panelSize: PanelSize = .collapsed, showsSettings: Bool = false) {
        _viewModel = State(initialValue: viewModel)
        startsExpanded = panelSize == .expanded
        showsSettingsOnLaunch = showsSettings
    }

    private var collapsedDetent: PresentationDetent {
        .height(collapsedHeight)
    }

    /// Maps the two positions onto detents; the collapsed height can change without losing the position.
    private var detentSelection: Binding<PresentationDetent> {
        Binding {
            isExpanded ? .large : collapsedDetent
        } set: { detent in
            isExpanded = detent == .large
        }
    }

    public var body: some View {
        CommuteMapView(
            profile: viewModel.routeProfile,
            isSchedule: viewModel.mode == .schedule,
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
            MapControls(viewModel: viewModel) {
                recenterRequest += 1
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .sheet(isPresented: .constant(true)) {
            PlanPanel(viewModel: viewModel, isExpanded: isExpanded, onOpenSettings: {
                isSettingsPresented = true
            }, onCollapsedHeightChange: { contentHeight in
                // Expanded-only header text must not increase the collapsed detent.
                guard !isExpanded else { return }
                // Content plus the sheet's top grabber area and a little breathing room.
                // The first measurement (the full-size loading card) sets the height; after that it
                // only grows, so the collapsed sheet keeps one size across states and directions.
                let fitted = min(max((contentHeight + 28).rounded(), 200), 620)
                if !hasMeasuredCollapsedHeight {
                    hasMeasuredCollapsedHeight = true
                    collapsedHeight = fitted
                } else if fitted > collapsedHeight + 1 {
                    withAnimation(.snappy(duration: 0.25)) {
                        collapsedHeight = fitted
                    }
                }
            }, onPickTrain: {
                // Show the picked train in the next-train card.
                isExpanded = false
            })
            .presentationDetents([collapsedDetent, .large], selection: detentSelection)
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
            if startsExpanded {
                // Wait for the sheet's presentation to settle, or it resets to the first detent.
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    isExpanded = true
                }
            }
            if showsSettingsOnLaunch {
                isSettingsPresented = true
            }
        }
        .onChange(of: scenePhase) { previous, phase in
            if phase == .active {
                // Reopening the app starts from the next-train view, like a fresh launch.
                if previous == .background {
                    isExpanded = false
                }
                Task { await viewModel.becameActive(fromBackground: previous == .background) }
            }
        }
    }
}

/// The commute / schedule switch (left) and refresh (right) over the map.
private struct MapControls: View {
    let viewModel: CommuteViewModel
    let onRefresh: () -> Void

    @State private var spin = 0.0

    var body: some View {
        HStack {
            Button {
                onRefresh()
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

            Button {
                // One full turn as feedback; refreshes are usually too quick for a spinner.
                withAnimation(.easeInOut(duration: 0.6)) {
                    spin += 360
                }
                onRefresh()
                Task { await viewModel.refresh(userInitiated: true) }
            } label: {
                label(Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spin)))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isLoaded)
            .accessibilityLabel("Refresh and recenter")
        }
    }

    private func label(_ content: some View) -> some View {
        content
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
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
