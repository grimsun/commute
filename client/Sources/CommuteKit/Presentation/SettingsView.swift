import SwiftUI

/// Edits a draft of the profile; changes apply when the sheet closes with Done.
/// Timetable refresh and the server check act immediately.
struct SettingsView: View {
    let viewModel: CommuteViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CommuteProfile
    @State private var serverCheck: (ok: Bool, message: String)?
    @State private var isCheckingServer = false
    @State private var estimating: Set<String> = []

    init(viewModel: CommuteViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                dataSourceSection
                placesSection
                stationsSection
                travelSection
                scheduleSection
                alertsSection
                trainTypesSection
                carSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let profile = draft
                        Task { await viewModel.updateProfile(profile) }
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        draft.homeStationID != draft.workStationID
            && (draft.dataSource.mode == .standalone || draft.dataSource.parsedServerURL != nil)
    }

    // MARK: Data source

    private var dataSourceSection: some View {
        Section {
            Picker("Train data", selection: $draft.dataSource.mode) {
                Text("On this phone").tag(DataMode.standalone)
                Text("Server").tag(DataMode.server)
            }
            .pickerStyle(.segmented)

            if draft.dataSource.mode == .server {
                TextField("https://commute.example.com", text: $draft.dataSource.serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                HStack {
                    Button("Test connection") {
                        Task {
                            isCheckingServer = true
                            serverCheck = await viewModel.testServer(draft.dataSource.serverURL)
                            isCheckingServer = false
                        }
                    }
                    .disabled(draft.dataSource.serverURL.isEmpty || isCheckingServer)
                    Spacer()
                    if isCheckingServer {
                        ProgressView()
                    } else if let serverCheck {
                        Label(serverCheck.message, systemImage: serverCheck.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(serverCheck.ok ? .green : .red)
                            .lineLimit(2)
                    }
                }
            }

            timetableRow
        } header: {
            Text("Data source")
        } footer: {
            Text(draft.dataSource.mode == .standalone
                ? "Uses Caltrain’s published timetable. No live delays; alerts come from the app."
                : "Your server provides live delays and sends push notifications. The timetable is used when it can’t be reached.")
        }
    }

    private var timetableRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Caltrain timetable")
                if let error = viewModel.timetableError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let info = viewModel.timetableInfo {
                    Text(timetableSummary(info))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not downloaded yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if viewModel.isUpdatingTimetable {
                ProgressView()
            } else {
                Button("Refresh") {
                    Task { await viewModel.refreshTimetable() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func timetableSummary(_ info: TimetableInfo) -> String {
        var parts = ["Updated \(info.downloadedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let until = info.validUntil {
            parts.append("valid to \(until.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Places

    private var placesSection: some View {
        Section("Places") {
            placeLink(title: "Home", symbol: "house.fill", place: $draft.home, stationID: $draft.homeStationID)
            placeLink(title: "Work", symbol: "briefcase.fill", place: $draft.work, stationID: $draft.workStationID)
        }
    }

    private func placeLink(title: String, symbol: String, place: Binding<Place>, stationID: Binding<String>) -> some View {
        NavigationLink {
            AddressSearchView(title: "\(title) address", near: place.wrappedValue.coordinate) { name, coordinate in
                place.wrappedValue = Place(name: name, coordinate: coordinate)
                stationID.wrappedValue = StationCatalog.nearest(to: coordinate).id
            }
        } label: {
            LabeledContent {
                Text(place.wrappedValue.name)
                    .lineLimit(1)
            } label: {
                Label(title, systemImage: symbol)
            }
        }
    }

    private var stationsSection: some View {
        Section {
            stationPicker("Home station", selection: $draft.homeStationID)
            stationPicker("Work station", selection: $draft.workStationID)
        } header: {
            Text("Caltrain stations")
        } footer: {
            if draft.homeStationID == draft.workStationID {
                Text("Home and work stations must differ.")
                    .foregroundStyle(.red)
            } else {
                Text("Picking an address selects its nearest station. You can change it here.")
            }
        }
    }

    private func stationPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(StationCatalog.all) { station in
                Text(station.name).tag(station.id)
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
    }

    // MARK: Travel

    private var travelSection: some View {
        Section {
            Picker("Getting there", selection: $draft.accessMode) {
                ForEach(AccessMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            minutesRow("Home ↔ station", minutes: $draft.homeStationMinutes, place: draft.home, stationID: draft.homeStationID)
            minutesRow("Work ↔ station", minutes: $draft.workStationMinutes, place: draft.work, stationID: draft.workStationID)
            Stepper("Safety buffer \(draft.stationSafetyBufferMinutes) min", value: $draft.stationSafetyBufferMinutes, in: 0...15)
            if draft.accessMode == .bike {
                Stepper("Estimate at \(Int(draft.bikeSpeedKph)) km/h", value: $draft.bikeSpeedKph, in: 8...35, step: 1)
            }
        } header: {
            Text("Travel times")
        } footer: {
            Text("Door to platform, including locking up your bike. Estimate asks Apple Maps; adjust to what you actually take.")
        }
    }

    private func minutesRow(_ title: String, minutes: Binding<Int>, place: Place, stationID: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if estimating.contains(title) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Estimate with Maps") {
                        Task {
                            estimating.insert(title)
                            if let estimate = await viewModel.estimateMinutes(from: place, stationID: stationID, mode: draft.accessMode, bikeSpeedKph: draft.bikeSpeedKph) {
                                minutes.wrappedValue = estimate
                            }
                            estimating.remove(title)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .disabled(place.coordinate == nil)
                }
            }
            Spacer()
            Text("\(minutes.wrappedValue) min")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper(title, value: minutes, in: 0...90)
                .labelsHidden()
        }
    }

    // MARK: Schedule

    private var scheduleSection: some View {
        Section {
            DatePicker("Leave home", selection: timeBinding(\.morningTargetLeave), displayedComponents: .hourAndMinute)
            DatePicker("Leave work", selection: timeBinding(\.eveningTargetLeave), displayedComponents: .hourAndMinute)
            Stepper("Get ready \(draft.prepLeadTimeMinutes) min before", value: $draft.prepLeadTimeMinutes, in: 0...60, step: 5)
            WeekdayPicker(selection: $draft.commuteDays)
        } header: {
            Text("Target leave times")
        } footer: {
            Text("The plan follows the first train you can catch when leaving at the target time, then rolls to the next one if you miss it.")
        }
    }

    private var alertsSection: some View {
        Section {
            if draft.dataSource.mode == .standalone {
                Toggle("Get ready & leave now alerts", isOn: $draft.leaveAlertsEnabled)
            } else {
                Label("Sent by your server", systemImage: "bell.badge")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Notifications")
        } footer: {
            if draft.dataSource.mode == .standalone {
                Text("Scheduled a week ahead from the timetable, so they arrive even if the app stays closed. They can’t follow delays. Tap “I’m on my way” to silence the rest of a trip.")
            }
        }
    }

    private var trainTypesSection: some View {
        Section {
            ForEach(TrainService.allCases) { service in
                Toggle(isOn: serviceBinding(service)) {
                    HStack(spacing: 10) {
                        ServiceBadge(service: service)
                        Text(service.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(draft.preferredServices == [service])
            }
        } header: {
            Text("Train types")
        } footer: {
            Text("Only these trains are planned for and listed. At least one type stays on.")
        }
    }

    private var carSection: some View {
        Section {
            Stepper("Good traffic within \(draft.carGoodDeltaMinutes) min", value: $draft.carGoodDeltaMinutes, in: 0...45, step: 5)
        } header: {
            Text("Car comparison")
        } footer: {
            Text("Driving counts as good when it is at most this much slower than with no traffic.")
        }
    }

    // MARK: Bindings

    private func serviceBinding(_ service: TrainService) -> Binding<Bool> {
        Binding {
            draft.preferredServices.contains(service)
        } set: { isOn in
            if isOn {
                draft.preferredServices.insert(service)
            } else if draft.preferredServices.count > 1 {
                draft.preferredServices.remove(service)
            }
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<CommuteProfile, TimeOfDay>) -> Binding<Date> {
        Binding {
            draft[keyPath: keyPath].date(on: Date())
        } set: { date in
            draft[keyPath: keyPath] = TimeOfDay(date: date)
        }
    }
}

/// Monday-first row of day toggles.
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    private static let order = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        HStack(spacing: 6) {
            Text("Days")
            Spacer()
            ForEach(Self.order, id: \.self) { weekday in
                let isOn = selection.contains(weekday)
                Button {
                    if isOn {
                        selection.remove(weekday)
                    } else {
                        selection.insert(weekday)
                    }
                } label: {
                    Text(Calendar.caltrain.veryShortWeekdaySymbols[weekday - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(isOn ? Color.accentColor : Palette.inset, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.caltrain.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
