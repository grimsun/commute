import SwiftUI

/// Full-screen map with the plan in a persistent bottom sheet.
public struct DashboardView: View {
    public enum PanelSize: String, Sendable {
        case peek, medium, large
    }

    @State private var viewModel: CommuteViewModel
    @State private var isSettingsPresented: Bool
    @State private var detent: PresentationDetent

    private static let peekDetent = PresentationDetent.height(220)

    public init(viewModel: CommuteViewModel, panelSize: PanelSize = .medium, showsSettings: Bool = false) {
        _viewModel = State(initialValue: viewModel)
        _isSettingsPresented = State(initialValue: showsSettings)
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
@MainActor
private func previewViewModel() -> CommuteViewModel {
    CommuteViewModel(
        planner: DefaultPlanner(
            transit: SampleTransitProvider(),
            access: FixedAccessProvider(seconds: 7 * 60),
            traffic: FixedTrafficProvider(eta: 52 * 60, freeFlowETA: 38 * 60)
        ),
        store: InMemoryProfileStore()
    )
}

#Preview("Dashboard") {
    DashboardView(viewModel: previewViewModel())
}

#Preview("Settings") {
    SettingsView(viewModel: previewViewModel())
}
#endif
