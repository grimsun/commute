import SwiftUI

/// Full-screen map with the plan in a persistent bottom sheet.
public struct DashboardView: View {
    public enum PanelSize: String, Sendable {
        case peek, medium, large
    }

    @State private var viewModel: CommuteViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false
    private let showsSettingsOnLaunch: Bool
    @State private var detent: PresentationDetent

    private static let peekDetent = PresentationDetent.height(220)

    public init(viewModel: CommuteViewModel, panelSize: PanelSize = .medium, showsSettings: Bool = false) {
        _viewModel = State(initialValue: viewModel)
        showsSettingsOnLaunch = showsSettings
        let detent: PresentationDetent = switch panelSize {
        case .peek: Self.peekDetent
        case .medium: .medium
        case .large: .large
        }
        _detent = State(initialValue: detent)
    }

    public var body: some View {
        GeometryReader { proxy in
            CommuteMapView(
                profile: viewModel.profile,
                direction: viewModel.direction,
                bottomInset: mapInset(screenHeight: proxy.size.height)
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: .constant(true)) {
            PlanPanel(viewModel: viewModel, isSettingsPresented: $isSettingsPresented)
                .presentationDetents([Self.peekDetent, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
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
            if loaded, showsSettingsOnLaunch {
                isSettingsPresented = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.becameActive() }
            }
        }
    }

    private func mapInset(screenHeight: CGFloat) -> CGFloat {
        switch detent {
        case Self.peekDetent: 250
        case .large: screenHeight * 0.9
        default: screenHeight * 0.56
        }
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
