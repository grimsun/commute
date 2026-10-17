import SwiftUI

/// Edits a draft of the profile; changes apply when the sheet closes with Done.
struct SettingsView: View {
    let viewModel: CommuteViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CommuteProfile

    init(viewModel: CommuteViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                placesSection
                stationsSection
                leaveTimesSection
                accessSection
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
                    .disabled(draft.homeStationID == draft.workStationID)
                }
            }
        }
    }

    // MARK: Sections

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

    private var leaveTimesSection: some View {
        Section {
            DatePicker("Leave home", selection: timeBinding(\.morningTargetLeave), displayedComponents: .hourAndMinute)
            DatePicker("Leave work", selection: timeBinding(\.eveningTargetLeave), displayedComponents: .hourAndMinute)
            Stepper("Get ready \(draft.prepLeadTimeMinutes) min before", value: $draft.prepLeadTimeMinutes, in: 0...60, step: 5)
        } header: {
            Text("Target leave times")
        } footer: {
            Text("The plan follows the first train you can catch when leaving at the target time, then rolls to the next one if you miss it.")
        }
    }

    private var accessSection: some View {
        Section("Getting to the station") {
            Picker("Mode", selection: $draft.accessMode) {
                ForEach(AccessMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if draft.accessMode == .bike {
                Stepper("Bike speed \(Int(draft.bikeSpeedKph)) km/h", value: $draft.bikeSpeedKph, in: 8...35, step: 1)
            }
            Stepper("Platform time \(draft.accessOverheadMinutes) min", value: $draft.accessOverheadMinutes, in: 0...15)
            Stepper("Safety buffer \(draft.stationSafetyBufferMinutes) min", value: $draft.stationSafetyBufferMinutes, in: 0...15)
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
