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
    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingSheet = false

    public init(viewModel: DashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let routeCount = 3
                let sheetHeight = proxy.size.height * 0.82
                let maxExpandedTop = proxy.size.height * 0.22
                let expandedListHeight = WalletRouteList.listHeight(routeCount: routeCount)
                let expandedVisibleHeight = expandedListHeight + 28 + proxy.safeAreaInsets.bottom
                let expandedTop = max(maxExpandedTop, proxy.size.height - expandedVisibleHeight)

                let collapsedCardsHeight = WalletRouteList.collapsedStackHeight(routeCount: routeCount)
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

                    LinearGradient(
                        colors: [
                            Color(red: 0.043, green: 0.071, blue: 0.125).opacity(0.16),
                            .clear,
                            Color(red: 0.043, green: 0.071, blue: 0.125).opacity(0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    pinnedTopControls
                        .padding(.top, 4)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .top)

                    panelSheet
                        .frame(maxWidth: .infinity)
                        .frame(height: sheetHeight, alignment: .top)
                        .offset(y: liveTop)
                        .transaction { transaction in
                            if isDraggingSheet {
                                transaction.animation = nil
                            }
                        }
                        .highPriorityGesture(
                            DragGesture()
                                .onChanged { value in
                                    if !isDraggingSheet {
                                        isDraggingSheet = true
                                    }
                                    dragTranslation = value.translation.height
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
                                    withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.14)) {
                                        panelState = nearest
                                        dragTranslation = 0
                                        isDraggingSheet = false
                                    }
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
            .onChange(of: panelState) { _, _ in
                expandedRouteID = nil
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
                    .foregroundStyle(Color(red: 0.059, green: 0.090, blue: 0.165))
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.72))
                    }
                    .overlay {
                        Circle().stroke(.white.opacity(0.28), lineWidth: 1)
                    }
            }

            Text(directionLabel)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(red: 0.059, green: 0.090, blue: 0.165))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                }

            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.059, green: 0.090, blue: 0.165))
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.72))
                    }
                    .overlay {
                        Circle().stroke(.white.opacity(0.28), lineWidth: 1)
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
                expandedRouteID: $expandedRouteID,
                displayMode: panelState == .expanded ? .list : .stack
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
                accent: Color(red: 0.86, green: 0.22, blue: 0.18)
            ),
            RouteCardModel(
                id: "station1",
                title: "Bike - Train Station 1 - Destination - Bike",
                subtitle: "Train \(plan.multimodalOption.selectedTrain.tripId)",
                detail: "Depart \(plan.multimodalOption.selectedTrain.departureTime.formatted(date: .omitted, time: .shortened))",
                etaMinutes: Int(plan.multimodalOption.selectedTrain.arrivalTime.timeIntervalSince(plan.generatedAt) / 60),
                accent: Color(red: 0.12, green: 0.44, blue: 0.92)
            ),
            RouteCardModel(
                id: "station2",
                title: "Walk - Train Station 2 - Destination - Bike",
                subtitle: plan.multimodalOption.fallbackTrain.map { "Fallback \($0.tripId)" } ?? "Alternative route",
                detail: "Too late at \(plan.multimodalOption.attemptTimes.tooLateAt.formatted(date: .omitted, time: .shortened))",
                etaMinutes: plan.multimodalOption.fallbackTrain.map { Int($0.arrivalTime.timeIntervalSince(plan.generatedAt) / 60) } ?? Int(plan.multimodalOption.selectedTrain.arrivalTime.timeIntervalSince(plan.generatedAt) / 60) + 8,
                accent: Color(red: 0.09, green: 0.64, blue: 0.29)
            )
        ]
    }
}

private struct RealMapBackground: View {
    private struct RouteOverlay: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let dashed: Bool
        let lineWidth: CGFloat
    }

    private static let sfCaltrain = CLLocationCoordinate2D(latitude: 37.7764, longitude: -122.3946)
    private static let paloAltoCaltrain = CLLocationCoordinate2D(latitude: 37.4436, longitude: -122.1651)

    @State private var routeOverlays: [RouteOverlay] = []

    private let mapPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (sfCaltrain.latitude + paloAltoCaltrain.latitude) / 2.0,
                longitude: (sfCaltrain.longitude + paloAltoCaltrain.longitude) / 2.0
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.40)
        )
    )

    var body: some View {
        Map(initialPosition: mapPosition) {
            ForEach(routeOverlays) { overlay in
                if overlay.dashed {
                    MapPolyline(coordinates: overlay.coordinates)
                        .stroke(overlay.color, style: StrokeStyle(lineWidth: overlay.lineWidth, lineCap: .round, dash: [6, 5]))
                } else {
                    MapPolyline(coordinates: overlay.coordinates)
                        .stroke(overlay.color, lineWidth: overlay.lineWidth)
                }
            }

            Annotation("San Francisco Caltrain", coordinate: Self.sfCaltrain) {
                mapPin(color: Color(red: 0.12, green: 0.44, blue: 0.92))
            }
            Annotation("Palo Alto Caltrain", coordinate: Self.paloAltoCaltrain) {
                mapPin(color: Color(red: 0.86, green: 0.22, blue: 0.18))
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .task {
            await loadRoutes()
        }
    }

    private func mapPin(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay {
                Circle().stroke(.black.opacity(0.35), lineWidth: 1)
            }
    }

    private func loadRoutes() async {
        let source = MKMapItem(placemark: MKPlacemark(coordinate: Self.sfCaltrain))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: Self.paloAltoCaltrain))

        var overlays: [RouteOverlay] = []

        // Car route
        do {
            let carRequest = MKDirections.Request()
            carRequest.source = source
            carRequest.destination = destination
            carRequest.transportType = .automobile
            let carResponse = try await MKDirections(request: carRequest).calculate()
            if let route = carResponse.routes.first {
                overlays.append(
                    RouteOverlay(
                        id: "car",
                        coordinates: route.polyline.coordinates,
                        color: Color(red: 0.86, green: 0.22, blue: 0.18),
                        dashed: false,
                        lineWidth: 9
                    )
                )
            }
        } catch {
            // Keep going; transit routes may still be available.
        }

        // Transit routes (primary + alternate from same response to guarantee green exists).
        // Transit overlays intentionally disabled for now.

        if overlays.isEmpty {
            overlays = [
                RouteOverlay(
                    id: "fallback",
                    coordinates: [Self.sfCaltrain, Self.paloAltoCaltrain],
                    color: Color(red: 0.86, green: 0.22, blue: 0.18),
                    dashed: false,
                    lineWidth: 9
                )
            ]
        }

        routeOverlays = overlays
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
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
    enum DisplayMode {
        case stack
        case list
    }

    let routes: [RouteCardModel]
    @Binding var expandedRouteID: String?
    let displayMode: DisplayMode
    @Namespace private var cardMorph

    private static let rowSpacing: CGFloat = 10
    private static let stackSpacing: CGFloat = 62
    private static let collapsedCardHeight: CGFloat = 120

    static func collapsedStackHeight(routeCount: Int) -> CGFloat {
        (stackSpacing * CGFloat(max(routeCount - 1, 0))) + collapsedCardHeight
    }

    static func listHeight(routeCount: Int) -> CGFloat {
        let spacing = rowSpacing * CGFloat(max(routeCount - 1, 0))
        return (collapsedCardHeight * CGFloat(routeCount)) + spacing
    }

    var body: some View {
        Group {
            if displayMode == .list {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(routes) { route in
                        routeCard(route)
                            .matchedGeometryEffect(id: route.id, in: cardMorph)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                ZStack(alignment: .top) {
                    ForEach(Array(visibleStackRoutes.enumerated()), id: \.element.id) { index, route in
                        let selectedIndex = visibleStackRoutes.firstIndex(where: { $0.id == expandedRouteID })
                        let isExpanded = expandedRouteID == route.id

                        routeCard(route)
                            .matchedGeometryEffect(id: route.id, in: cardMorph)
                            .offset(y: stackCardOffset(for: index, selectedIndex: selectedIndex, isExpanded: isExpanded))
                            .opacity(stackCardOpacity(for: index, selectedIndex: selectedIndex))
                            .scaleEffect(isExpanded ? 1.0 : 0.98)
                            .zIndex(stackZIndex(for: index, isExpanded: isExpanded))
                    }
                }
                .frame(height: stackContainerHeight)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: displayMode)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: expandedRouteID)
    }

    private var stackContainerHeight: CGFloat {
        expandedRouteID == nil ? Self.collapsedStackHeight(routeCount: visibleStackRoutes.count) : 240
    }

    private var visibleStackRoutes: [RouteCardModel] {
        guard let expandedRouteID else { return routes }
        return routes.filter { $0.id == expandedRouteID }
    }

    @ViewBuilder
    private func routeCard(_ route: RouteCardModel) -> some View {
        let isExpanded = expandedRouteID == route.id
        WalletRouteCard(
            route: route,
            expanded: isExpanded
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                expandedRouteID = expandedRouteID == route.id ? nil : route.id
            }
        }
    }

    private func stackCardOffset(for index: Int, selectedIndex: Int?, isExpanded: Bool) -> CGFloat {
        guard let selectedIndex else { return CGFloat(index) * Self.stackSpacing }
        if isExpanded { return 8 }
        return index < selectedIndex ? -290 : 310
    }

    private func stackCardOpacity(for index: Int, selectedIndex: Int?) -> Double {
        guard let selectedIndex else { return 1 }
        return index == selectedIndex ? 1 : 0.04
    }

    private func stackZIndex(for index: Int, isExpanded: Bool) -> Double {
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
                        .font(expanded ? .headline : .title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(expanded ? 3 : 2)
                    Text(route.subtitle)
                        .font(expanded ? .caption : .subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(route.etaMinutes)")
                        .font(expanded ? .system(size: 34, weight: .bold) : .system(size: 40, weight: .black))
                        .foregroundStyle(.white)
                    Text("min")
                        .font(expanded ? .caption2 : .caption.weight(.semibold))
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
