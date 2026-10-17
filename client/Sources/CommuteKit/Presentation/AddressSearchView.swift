import MapKit
import SwiftUI

struct AddressSearchView: View {
    let title: String
    let near: Coordinate?
    let onSelect: (String, Coordinate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = AddressSearchModel()
    @State private var query = ""

    var body: some View {
        List(search.results) { result in
            Button {
                onSelect(result.title, result.coordinate)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .foregroundStyle(.primary)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if search.results.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Search for an address" : "No matches",
                    systemImage: "magnifyingglass"
                )
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Address or place")
        .task(id: query) {
            // Debounce typing; a new keystroke cancels this task.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await search.search(query, near: near)
        }
    }
}

struct AddressResult: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: Coordinate
}

@MainActor
@Observable
final class AddressSearchModel {
    private(set) var results: [AddressResult] = []

    /// Searches around the Peninsula unless a nearer reference point is known.
    private static let peninsula = Coordinate(latitude: 37.55, longitude: -122.25)

    func search(_ query: String, near: Coordinate?) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        let center = near ?? Self.peninsula
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(
            center: center.clLocationCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.8, longitudeDelta: 0.8)
        )

        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems.prefix(10).map { item in
                AddressResult(title: item.name ?? "Address", subtitle: item.addressSubtitle, coordinate: item.coordinate)
            }
        } catch {
            results = []
        }
    }
}
