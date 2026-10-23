import Foundation

public enum ServerError: Error, Equatable {
    case invalidURL
    case badStatus(Int)
}

/// Realtime trains from a Commute server. The HTTP contract is documented in `server/README.md`.
public struct ServerTransitProvider: TransitProvider {
    struct DeparturesResponse: Codable {
        var fetchedAt: Date
        var departures: [TrainDeparture]
    }

    private let baseURL: URL?
    private let session: URLSession

    public init(baseURL: URL?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func departures(fromStation originID: String, toStation destinationID: String, after: Date, limit: Int) async throws -> TransitSnapshot {
        let response: DeparturesResponse = try await get("v1/departures", query: [
            URLQueryItem(name: "from", value: originID),
            URLQueryItem(name: "to", value: destinationID),
            URLQueryItem(name: "after", value: after.formatted(.iso8601)),
            URLQueryItem(name: "limit", value: String(limit))
        ])
        return TransitSnapshot(
            // Everything the server sends is live unless it says otherwise.
            departures: response.departures
                .map { departure in
                    var departure = departure
                    departure.isTracked = departure.isTracked ?? true
                    return departure
                }
                .sorted { $0.departureTime < $1.departureTime },
            source: .live,
            fetchedAt: response.fetchedAt
        )
    }

    private func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
        guard let baseURL else { throw ServerError.invalidURL }
        var request = URLRequest(url: baseURL.appending(path: path).appending(queryItems: query))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServerError.badStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }
}
