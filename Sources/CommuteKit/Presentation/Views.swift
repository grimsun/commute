import Foundation
import MapKit
import SwiftUI

public struct DashboardView: View {
    private static let mockRouteCount = 3
    private static let defaultHomeCoordinate = CLLocationCoordinate2D(latitude: 37.7764, longitude: -122.3946)
    private static let defaultWorkCoordinate = CLLocationCoordinate2D(latitude: 37.4436, longitude: -122.1651)

    private enum PanelState {
        case expanded
        case collapsed
        case hidden
    }

    enum AddressTarget: String, Identifiable {
        case home
        case work

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home:
                "Home"
            case .work:
                "Work"
            }
        }

        var icon: String {
            switch self {
            case .home:
                "house.fill"
            case .work:
                "briefcase.fill"
            }
        }
    }

    @State private var viewModel: DashboardViewModel
    @State private var panelState: PanelState = .collapsed
    @State private var isSettingsPresented = false
    @State private var expandedRouteID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingSheet = false
    @State private var isSheetDragActive = false
    @State private var isListAtTop = true
    @State private var didEvaluateCurrentDrag = false
    @State private var dragStartedWithListAtTop = false
    @State private var dragStartPanelState: PanelState = .collapsed
    @State private var homeAddressDraft = ""
    @State private var workAddressDraft = ""
    @State private var activeAddressPicker: AddressTarget?
    @State private var isSavingAddresses = false
    @State private var addressSaveMessage: String?
    @State private var addressSaveError: String?
    @State private var mapSourceCoordinate = DashboardView.defaultHomeCoordinate
    @State private var mapDestinationCoordinate = DashboardView.defaultWorkCoordinate
    @State private var transitDebugLines: [String] = []
    @State private var transitDebugLoading = false
    @State private var transitDebugError: String?

    public init(viewModel: DashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let routeCount = Self.mockRouteCount
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
                    RealMapBackground(
                        sourceCoordinate: mapSourceCoordinate,
                        destinationCoordinate: mapDestinationCoordinate
                    )
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
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    if !didEvaluateCurrentDrag {
                                        didEvaluateCurrentDrag = true
                                        dragStartedWithListAtTop = isListAtTop
                                        dragStartPanelState = panelState
                                    }

                                    if !isSheetDragActive {
                                        // In expanded mode, allow:
                                        // 1) explicit top-grab drags, or
                                        // 2) a new downward pull that started while list is already at top.
                                        let startedInGrabZone = value.startLocation.y <= 44
                                        let pullDownFromTop = panelState == .expanded
                                            && dragStartedWithListAtTop
                                            && value.translation.height > 24
                                        isSheetDragActive = panelState != .expanded || startedInGrabZone || pullDownFromTop
                                    }
                                    guard isSheetDragActive else { return }

                                    if !isDraggingSheet {
                                        isDraggingSheet = true
                                    }
                                    dragTranslation = value.translation.height
                                }
                                .onEnded { value in
                                    guard isSheetDragActive else {
                                        isDraggingSheet = false
                                        isSheetDragActive = false
                                        dragTranslation = 0
                                        didEvaluateCurrentDrag = false
                                        dragStartedWithListAtTop = false
                                        return
                                    }
                                    let proposed = clampedTop(
                                        anchoredTop + value.predictedEndTranslation.height,
                                        minTop: expandedTop,
                                        maxTop: hiddenTop
                                    )
                                    let targets: [(PanelState, CGFloat)]
                                    switch dragStartPanelState {
                                    case .expanded:
                                        // Do not allow skipping directly to hidden in one gesture.
                                        targets = [
                                            (.expanded, expandedTop),
                                            (.collapsed, collapsedTop)
                                        ]
                                    case .collapsed:
                                        targets = [
                                            (.expanded, expandedTop),
                                            (.collapsed, collapsedTop),
                                            (.hidden, hiddenTop)
                                        ]
                                    case .hidden:
                                        // Do not allow skipping directly to expanded in one gesture.
                                        targets = [
                                            (.collapsed, collapsedTop),
                                            (.hidden, hiddenTop)
                                        ]
                                    }
                                    let nearest = targets.min {
                                        abs($0.1 - proposed) < abs($1.1 - proposed)
                                    }?.0 ?? .collapsed
                                    withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.14)) {
                                        panelState = nearest
                                        dragTranslation = 0
                                        isDraggingSheet = false
                                        isSheetDragActive = false
                                        didEvaluateCurrentDrag = false
                                        dragStartedWithListAtTop = false
                                        dragStartPanelState = nearest
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
                    homeAddress: "San Francisco Caltrain",
                    workAddress: "Palo Alto Caltrain",
                    homeLatitude: Self.defaultHomeCoordinate.latitude,
                    homeLongitude: Self.defaultHomeCoordinate.longitude,
                    workLatitude: Self.defaultWorkCoordinate.latitude,
                    workLongitude: Self.defaultWorkCoordinate.longitude,
                    homeStation: "Station 1",
                    workStation: "Station 2",
                    trainLine: "Blue"
                )
                await viewModel.bootstrap(defaultProfile: profile)
                applyProfileCoordinatesIfAvailable()
                loadAddressDraftsFromProfile()
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
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: PanelScrollOffsetPreferenceKey.self,
                            value: geo.frame(in: .named("panelScroll")).minY
                        )
                }
                .frame(height: 0)

                content
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .coordinateSpace(name: "panelScroll")
        .onPreferenceChange(PanelScrollOffsetPreferenceKey.self) { offset in
            isListAtTop = offset >= -1
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
            ScrollView {
                VStack(spacing: 14) {
                    addressSettingsSection
                    settingsControls
                    transitDebugSection
                }
                .padding()
            }
            .navigationTitle("Settings")
            .task {
                loadAddressDraftsFromProfile()
                await loadTransitDebugResults()
            }
            .sheet(item: $activeAddressPicker) { target in
                AddressTypeaheadSheet(
                    target: target,
                    regionCenter: target == .home ? mapSourceCoordinate : mapDestinationCoordinate
                ) { mapItem in
                    await selectAddress(mapItem, for: target)
                    activeAddressPicker = nil
                }
            }
        }
    }

    @ViewBuilder
    private var addressSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commute Addresses")
                .font(.headline)

            addressPickerRow(
                target: .home,
                label: homeAddressDraft.isEmpty ? "Set home address" : homeAddressDraft
            )

            addressPickerRow(
                target: .work,
                label: workAddressDraft.isEmpty ? "Set work address" : workAddressDraft
            )

            if let addressSaveError {
                Text(addressSaveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let addressSaveMessage {
                Text(addressSaveMessage)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            if isSavingAddresses {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating route...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func addressPickerRow(target: AddressTarget, label: String) -> some View {
        Button {
            addressSaveError = nil
            addressSaveMessage = nil
            activeAddressPicker = target
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.white.opacity(0.82))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: target.icon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(red: 0.059, green: 0.090, blue: 0.165))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.white.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
    private var transitDebugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transit Results")
                    .font(.headline)
                Spacer()
                if transitDebugLoading {
                    ProgressView()
                        .scaleEffect(0.85)
                }
                Button("Reload") {
                    Task {
                        await loadTransitDebugResults()
                    }
                }
                .buttonStyle(.bordered)
            }

            Text("Ferry Building SF → Stanford University")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let transitDebugError {
                Text(transitDebugError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if transitDebugLines.isEmpty, transitDebugLoading {
                Text("Loading transit routes...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if transitDebugLines.isEmpty {
                Text("No transit routes returned.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(transitDebugLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.white.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadAddressDraftsFromProfile() {
        guard let profile = viewModel.currentProfile() else { return }
        homeAddressDraft = profile.homeAddress
        workAddressDraft = profile.workAddress
        addressSaveError = nil
        addressSaveMessage = nil
    }

    private func applyProfileCoordinatesIfAvailable() {
        guard let profile = viewModel.currentProfile() else { return }
        if let lat = profile.homeLatitude, let lon = profile.homeLongitude {
            mapSourceCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if let lat = profile.workLatitude, let lon = profile.workLongitude {
            mapDestinationCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private func selectAddress(_ mapItem: MKMapItem, for target: AddressTarget) async {
        isSavingAddresses = true
        addressSaveError = nil
        addressSaveMessage = nil

        let coordinate = mapItem.placemark.coordinate
        let line = addressLine(for: mapItem, fallback: target.title)

        if target == .home {
            homeAddressDraft = line
            mapSourceCoordinate = coordinate
        } else {
            workAddressDraft = line
            mapDestinationCoordinate = coordinate
        }

        await persistAddressChanges()
        addressSaveMessage = "\(target.title) updated."
        await viewModel.refreshPlan()
        isSavingAddresses = false
    }

    private func persistAddressChanges() async {
        let trimmedHome = homeAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWork = workAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty, !trimmedWork.isEmpty else { return }

        await viewModel.updateAddresses(
            homeAddress: trimmedHome,
            workAddress: trimmedWork,
            homeLatitude: mapSourceCoordinate.latitude,
            homeLongitude: mapSourceCoordinate.longitude,
            workLatitude: mapDestinationCoordinate.latitude,
            workLongitude: mapDestinationCoordinate.longitude
        )
    }

    private func loadTransitDebugResults() async {
        if transitDebugLoading { return }
        transitDebugLoading = true
        transitDebugError = nil
        transitDebugLines = []

        do {
            let sourceItem = try await resolveMapItem(
                query: "Ferry Building, San Francisco",
                regionCenter: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
            )
            let destinationItem = try await resolveMapItem(
                query: "Stanford University",
                regionCenter: CLLocationCoordinate2D(latitude: 37.4275, longitude: -122.1697)
            )

            let response = try await queryTransitRoutes(
                source: sourceItem,
                destination: destinationItem
            )
            let lines = response.routes.enumerated().map { idx, route in
                let etaMin = Int(route.expectedTravelTime / 60)
                let distanceKm = route.distance / 1000
                let firstSteps = route.steps
                    .prefix(3)
                    .map { $0.instructions.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " | ")

                return "\(idx + 1). ETA \(etaMin)m, \(String(format: "%.1f", distanceKm))km, \(route.name.isEmpty ? "Transit route" : route.name)\(firstSteps.isEmpty ? "" : " — \(firstSteps)")"
            }

            transitDebugLines = lines
            if lines.isEmpty {
                transitDebugError = "No transit itineraries were returned for this query."
            }
        } catch {
            let nsError = error as NSError
            transitDebugError = "Transit query failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription)"
        }

        transitDebugLoading = false
    }

    private func queryTransitRoutes(
        source: MKMapItem,
        destination: MKMapItem
    ) async throws -> MKDirections.Response {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let now = Date()
        let nextWeekday8am = nextWeekdayMorning8am(from: now, calendar: calendar)
        let departureCandidates = [nextWeekday8am, now]

        for departureDate in departureCandidates {
            // First attempt with alternates, then retry simple transit request.
            for wantsAlternates in [true, false] {
                let request = MKDirections.Request()
                request.source = source
                request.destination = destination
                request.transportType = .transit
                request.requestsAlternateRoutes = wantsAlternates
                request.departureDate = departureDate

                do {
                    let response = try await MKDirections(request: request).calculate()
                    if !response.routes.isEmpty {
                        return response
                    }
                } catch {
                    if wantsAlternates {
                        continue
                    }
                }
            }
        }

        throw NSError(
            domain: "TransitQuery",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No transit routes returned by MapKit for next weekday 8:00 AM or current time (America/Los_Angeles)."]
        )
    }

    private func nextWeekdayMorning8am(from date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let isWeekend = weekday == 1 || weekday == 7 // Sunday/Saturday
        let baseDate = isWeekend
            ? calendar.date(byAdding: .day, value: weekday == 7 ? 2 : 1, to: date) ?? date
            : date

        return calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: baseDate
        ) ?? date
    }

    private func resolveMapItem(
        query: String,
        regionCenter: CLLocationCoordinate2D
    ) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: regionCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
        )
        let response = try await MKLocalSearch(request: request).start()
        if let first = response.mapItems.first {
            return first
        }
        throw NSError(
            domain: "TransitQuery",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "No map item found for '\(query)'"]
        )
    }

    private func addressLine(for item: MKMapItem, fallback: String) -> String {
        let placemark = item.placemark
        if let name = item.name, !name.isEmpty {
            if let locality = placemark.locality, !locality.isEmpty {
                return "\(name), \(locality)"
            }
            return name
        }
        return fallback
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
                subtitle: "Train 508",
                detail: "Depart 8:17 AM",
                etaMinutes: 34,
                accent: Color(red: 0.12, green: 0.44, blue: 0.92)
            ),
            RouteCardModel(
                id: "station2",
                title: "Walk - Train Station 2 - Destination - Bike",
                subtitle: "Fallback train 512",
                detail: "Too late at 8:12 AM",
                etaMinutes: 42,
                accent: Color(red: 0.09, green: 0.64, blue: 0.29)
            )
        ]
    }
}

private struct AddressTypeaheadSheet: View {
    let target: DashboardView.AddressTarget
    let regionCenter: CLLocationCoordinate2D
    let onSelect: (MKMapItem) async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var autocomplete = AddressAutocompleteModel()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if autocomplete.completions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Start typing an address")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(autocomplete.completions.indices, id: \.self) { index in
                        let completion = autocomplete.completions[index]
                        Button {
                            Task {
                                await onSelect(completion)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(completion.name ?? "Address")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                let subtitle = completion.placemark.title ?? ""
                                if !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("\(target.title) Address")
            .searchable(text: $query, prompt: "Search address")
            .onChange(of: query) { _, newValue in
                autocomplete.update(query: newValue, around: regionCenter)
            }
        }
    }
}

@MainActor
private final class AddressAutocompleteModel: ObservableObject {
    @Published var completions: [MKMapItem] = []

    private var inFlightTask: Task<Void, Never>?

    func update(query: String, around center: CLLocationCoordinate2D) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlightTask?.cancel()
        guard !trimmed.isEmpty else {
            completions = []
            return
        }

        inFlightTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.resultTypes = .address
            request.region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.45)
            )

            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                completions = Array(response.mapItems.prefix(8))
            } catch {
                guard !Task.isCancelled else { return }
                completions = []
            }
        }
    }
}

private struct PanelScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

    let sourceCoordinate: CLLocationCoordinate2D
    let destinationCoordinate: CLLocationCoordinate2D

    @State private var routeOverlays: [RouteOverlay] = []
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $mapPosition) {
            ForEach(routeOverlays) { overlay in
                if overlay.dashed {
                    MapPolyline(coordinates: overlay.coordinates)
                        .stroke(overlay.color, style: StrokeStyle(lineWidth: overlay.lineWidth, lineCap: .round, dash: [6, 5]))
                } else {
                    MapPolyline(coordinates: overlay.coordinates)
                        .stroke(overlay.color, lineWidth: overlay.lineWidth)
                }
            }

            Annotation("Home", coordinate: sourceCoordinate) {
                mapPin(color: Color(red: 0.12, green: 0.44, blue: 0.92))
            }
            Annotation("Work", coordinate: destinationCoordinate) {
                mapPin(color: Color(red: 0.86, green: 0.22, blue: 0.18))
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .task {
            await loadRoutes()
        }
        .onChange(of: sourceCoordinate.latitude) { _, _ in
            Task { await loadRoutes() }
        }
        .onChange(of: sourceCoordinate.longitude) { _, _ in
            Task { await loadRoutes() }
        }
        .onChange(of: destinationCoordinate.latitude) { _, _ in
            Task { await loadRoutes() }
        }
        .onChange(of: destinationCoordinate.longitude) { _, _ in
            Task { await loadRoutes() }
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
        let source = MKMapItem(placemark: MKPlacemark(coordinate: sourceCoordinate))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: destinationCoordinate))

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
                    coordinates: [sourceCoordinate, destinationCoordinate],
                    color: Color(red: 0.86, green: 0.22, blue: 0.18),
                    dashed: false,
                    lineWidth: 9
                )
            ]
        }

        routeOverlays = overlays
        mapPosition = .region(regionFitting(source: sourceCoordinate, destination: destinationCoordinate))
    }

    private func regionFitting(
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> MKCoordinateRegion {
        let minLat = min(source.latitude, destination.latitude)
        let maxLat = max(source.latitude, destination.latitude)
        let minLon = min(source.longitude, destination.longitude)
        let maxLon = max(source.longitude, destination.longitude)
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = max((maxLat - minLat) * 1.9, 0.06)
        let spanLon = max((maxLon - minLon) * 1.9, 0.06)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
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
