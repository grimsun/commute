import Foundation
import MapKit
import SwiftUI

public struct DashboardView: View {
    private enum PanelState {
        case expanded
        case collapsed
        case hidden
    }

    @State private var viewModel: DashboardViewModel
    @State private var panelState: PanelState = .collapsed
    @State private var isSettingsPresented = false
    @State private var expandedRouteID: String?
    @GestureState private var dragTranslation: CGFloat = 0

    public init(viewModel: DashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let sheetHeight = proxy.size.height * 0.82
                let expandedTop = proxy.size.height * 0.14
                let collapsedCardsHeight = WalletRouteList.collapsedHeight(routeCount: 3)
                let collapsedVisibleHeight = collapsedCardsHeight + 48 + proxy.safeAreaInsets.bottom
                let collapsedTop = max(expandedTop + 56, proxy.size.height - collapsedVisibleHeight + 18)
                let hiddenTop = proxy.size.height + 32
                let anchoredTop = topAnchor(
                    expanded: expandedTop,
                    collapsed: collapsedTop,
                    hidden: hiddenTop
                )
                let liveTop = clampedTop(
                    anchoredTop + dragTranslation,
                    minTop: expandedTop,
                    maxTop: hiddenTop
                )

                ZStack(alignment: .top) {
                    RealMapBackground()
                        .ignoresSafeArea()

                    pinnedTopControls
                        .padding(.top, 4)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .top)

                    panelSheet
                        .frame(maxWidth: .infinity)
                        .frame(height: sheetHeight, alignment: .top)
                        .offset(y: liveTop)
                        .highPriorityGesture(
                            DragGesture()
                                .updating($dragTranslation) { value, state, _ in
                                    state = value.translation.height
                                }
                                .onEnded { value in
                                    let proposed = clampedTop(
                                        anchoredTop + value.predictedEndTranslation.height,
                                        minTop: expandedTop,
                                        maxTop: hiddenTop
                                    )
                                    let targets: [(PanelState, CGFloat)] = [
                                        (.expanded, expandedTop),
                                        (.collapsed, collapsedTop),
                                        (.hidden, hiddenTop)
                                    ]
                                    let nearest = targets.min {
                                        abs($0.1 - proposed) < abs($1.1 - proposed)
                                    }?.0 ?? .collapsed
                                    panelState = nearest
                                }
                        )

                    if panelState == .hidden {
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                panelState = .collapsed
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay {
                                    Circle()
                                        .stroke(.white.opacity(0.35), lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
                        }
                        .padding(.bottom, 28)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .task {
                let profile = CommuteProfile(
                    homeAddress: "Home",
                    workAddress: "Work",
                    homeStation: "Station 1",
                    workStation: "Station 2",
                    trainLine: "Blue"
                )
                await viewModel.bootstrap(defaultProfile: profile)
                await viewModel.refreshPlan()
            }
            .sheet(isPresented: $isSettingsPresented) {
                settingsSheet
                    .presentationDetents([.medium, .large])
            }
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
        }
    }

    private var pinnedTopControls: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    toggleDirection()
                }
                Task {
                    await viewModel.refreshPlan()
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.82)
                    }
                    .overlay {
                        Circle().stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            }

            Text(directionLabel)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.82)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }

            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.82)
                    }
                    .overlay {
                        Circle().stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            }
        }
    }

    private var directionLabel: String {
        switch viewModel.direction {
        case .homeToWork:
            "Home → Work"
        case .workToHome:
            "Work → Home"
        }
    }

    private func toggleDirection() {
        viewModel.direction = viewModel.direction == .homeToWork ? .workToHome : .homeToWork
    }

    private var panelSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                content
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .scrollDisabled(panelState != .expanded)
    }

    private func topAnchor(expanded: CGFloat, collapsed: CGFloat, hidden: CGFloat) -> CGFloat {
        switch panelState {
        case .expanded:
            expanded
        case .collapsed:
            collapsed
        case .hidden:
            hidden
        }
    }

    private func clampedTop(_ value: CGFloat, minTop: CGFloat, maxTop: CGFloat) -> CGFloat {
        min(max(value, minTop), maxTop)
    }

    private var settingsSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                settingsControls
                Spacer()
            }
            .padding()
            .navigationTitle("Settings")
        }
    }

    private var settingsControls: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $viewModel.planningMode) {
                Text("Arrive By").tag(PlanningMode.arriveBy)
                Text("Leave At").tag(PlanningMode.leaveAt)
            }
            .pickerStyle(.segmented)

            DatePicker("Target", selection: $viewModel.targetDateTime)

            Button("Recalculate") {
                Task {
                    await viewModel.refreshPlan()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView("Calculating")
                .frame(maxWidth: .infinity)
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .loaded(plan):
            WalletRouteList(
                routes: routes(from: plan),
                expandedRouteID: $expandedRouteID
            )
        }
    }

    private func routes(from plan: CommutePlan) -> [RouteCardModel] {
        [
            RouteCardModel(
                id: "car",
                title: "Car",
                subtitle: plan.carOption.isTrafficGood ? "Traffic is good" : "Traffic is heavy",
                detail: plan.carOption.reason,
                etaMinutes: Int(plan.carOption.eta / 60),
                accent: Color(red: 0.98, green: 0.46, blue: 0.10)
            ),
            RouteCardModel(
                id: "station1",
                title: "Bike - Train Station 1 - Destination - Bike",
                subtitle: "Train \(plan.multimodalOption.selectedTrain.tripId)",
                detail: "Depart \(plan.multimodalOption.selectedTrain.departureTime.formatted(date: .omitted, time: .shortened))",
                etaMinutes: Int(plan.multimodalOption.selectedTrain.arrivalTime.timeIntervalSince(plan.generatedAt) / 60),
                accent: Color(red: 0.13, green: 0.46, blue: 0.96)
            ),
            RouteCardModel(
                id: "station2",
                title: "Walk - Train Station 2 - Destination - Bike",
                subtitle: plan.multimodalOption.fallbackTrain.map { "Fallback \($0.tripId)" } ?? "Alternative route",
                detail: "Too late at \(plan.multimodalOption.attemptTimes.tooLateAt.formatted(date: .omitted, time: .shortened))",
                etaMinutes: plan.multimodalOption.fallbackTrain.map { Int($0.arrivalTime.timeIntervalSince(plan.generatedAt) / 60) } ?? Int(plan.multimodalOption.selectedTrain.arrivalTime.timeIntervalSince(plan.generatedAt) / 60) + 8,
                accent: Color(red: 0.14, green: 0.72, blue: 0.26)
            )
        ]
    }
}

private struct RealMapBackground: View {
    private static let sfCenter = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    private static let carCoordinates = [
        CLLocationCoordinate2D(latitude: 37.7895, longitude: -122.3969),
        CLLocationCoordinate2D(latitude: 37.7830, longitude: -122.4045),
        CLLocationCoordinate2D(latitude: 37.7764, longitude: -122.4141),
        CLLocationCoordinate2D(latitude: 37.7682, longitude: -122.4295)
    ]

    private static let station1Coordinates = [
        CLLocationCoordinate2D(latitude: 37.7901, longitude: -122.3945),
        CLLocationCoordinate2D(latitude: 37.7829, longitude: -122.4021),
        CLLocationCoordinate2D(latitude: 37.7768, longitude: -122.4108),
        CLLocationCoordinate2D(latitude: 37.7718, longitude: -122.4206),
        CLLocationCoordinate2D(latitude: 37.7662, longitude: -122.4308)
    ]

    private static let station2Coordinates = [
        CLLocationCoordinate2D(latitude: 37.7908, longitude: -122.4010),
        CLLocationCoordinate2D(latitude: 37.7862, longitude: -122.4082),
        CLLocationCoordinate2D(latitude: 37.7792, longitude: -122.4181),
        CLLocationCoordinate2D(latitude: 37.7720, longitude: -122.4270),
        CLLocationCoordinate2D(latitude: 37.7648, longitude: -122.4358)
    ]

    private let mapPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: sfCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
        )
    )

    var body: some View {
        Map(initialPosition: mapPosition) {
            MapPolyline(coordinates: Self.carCoordinates)
                .stroke(.orange, lineWidth: 10)

            MapPolyline(coordinates: Self.station1Coordinates)
                .stroke(.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round, dash: [8, 6]))

            MapPolyline(coordinates: Self.station2Coordinates)
                .stroke(.green, style: StrokeStyle(lineWidth: 10, lineCap: .round, dash: [4, 6]))

            Annotation("Start", coordinate: Self.station1Coordinates.first ?? Self.sfCenter) {
                mapPin(color: .white)
            }
            Annotation("Station 1", coordinate: Self.station1Coordinates[2]) {
                mapPin(color: .blue)
            }
            Annotation("Station 2", coordinate: Self.station2Coordinates[2]) {
                mapPin(color: .green)
            }
            Annotation("Destination", coordinate: Self.station2Coordinates.last ?? Self.sfCenter) {
                mapPin(color: .red)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
    }

    private func mapPin(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay {
                Circle().stroke(.black.opacity(0.35), lineWidth: 1)
            }
    }
}

private struct RouteCardModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let etaMinutes: Int
    let accent: Color
}

private struct WalletRouteList: View {
    let routes: [RouteCardModel]
    @Binding var expandedRouteID: String?

    private static let collapsedSpacing: CGFloat = 62
    private static let collapsedCardHeight: CGFloat = 120

    static func collapsedHeight(routeCount: Int) -> CGFloat {
        (collapsedSpacing * CGFloat(max(routeCount - 1, 0))) + collapsedCardHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                let selectedIndex = routes.firstIndex(where: { $0.id == expandedRouteID })
                let isExpanded = expandedRouteID == route.id

                WalletRouteCard(
                    route: route,
                    expanded: isExpanded
                )
                .offset(y: cardOffset(for: index, selectedIndex: selectedIndex, isExpanded: isExpanded))
                .opacity(cardOpacity(for: index, selectedIndex: selectedIndex))
                .scaleEffect(isExpanded ? 1.0 : 0.98)
                .zIndex(zIndex(for: index, isExpanded: isExpanded))
                .onTapGesture {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        expandedRouteID = expandedRouteID == route.id ? nil : route.id
                    }
                }
            }
        }
        .frame(height: containerHeight)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: expandedRouteID)
    }

    private var containerHeight: CGFloat {
        expandedRouteID == nil ? Self.collapsedHeight(routeCount: routes.count) : 240
    }

    private func cardOffset(for index: Int, selectedIndex: Int?, isExpanded: Bool) -> CGFloat {
        guard let selectedIndex else { return CGFloat(index) * Self.collapsedSpacing }
        if isExpanded { return 8 }
        return index < selectedIndex ? -290 : 310
    }

    private func cardOpacity(for index: Int, selectedIndex: Int?) -> Double {
        guard let selectedIndex else { return 1 }
        return index == selectedIndex ? 1 : 0.04
    }

    private func zIndex(for index: Int, isExpanded: Bool) -> Double {
        if isExpanded { return 999 }
        return Double(routes.count - index)
    }
}

private struct WalletRouteCard: View {
    let route: RouteCardModel
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(expanded ? 3 : 2)
                    Text(route.subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.92))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(route.etaMinutes)")
                        .font(expanded ? .system(size: 34, weight: .bold) : .title.bold())
                        .foregroundStyle(.white)
                    Text("min")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            if expanded {
                Divider().overlay(.white.opacity(0.45))
                Text(route.detail)
                    .font(.callout)
                    .foregroundStyle(.white)
                Text("Tap again to collapse")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: expanded ? 210 : 120, alignment: .top)
        .background(route.accent)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
    }
}

public struct TimelineView: View {
    let attempts: AttemptTimes

    public init(attempts: AttemptTimes) {
        self.attempts = attempts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attempts")
                .font(.headline)
            Text("Get ready: \(attempts.getReadyAt.formatted(date: .omitted, time: .shortened))")
            Text("Leave: \(attempts.leaveAt.formatted(date: .omitted, time: .shortened))")
            Text("Too late: \(attempts.tooLateAt.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
