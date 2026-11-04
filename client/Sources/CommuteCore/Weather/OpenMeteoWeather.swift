import Foundation

/// Rain forecasts from Open-Meteo (free, no key). Each place is fetched at most every
/// `cacheLifetime`, with a backoff after failures; the last good forecast is kept meanwhile.
public actor OpenMeteoWeather: WeatherProviding {
    public static let baseURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
    public static let cacheLifetime: TimeInterval = 30 * 60
    public static let failureBackoff: TimeInterval = 10 * 60

    private struct Entry {
        var forecast: RainForecast?
        var attemptedAt: Date
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    public func forecast(at coordinate: Coordinate) async -> RainForecast? {
        // About 1 km: close enough for the same forecast.
        let key = String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
        let date = now()
        if let entry = cache[key] {
            let wait = entry.forecast == nil ? Self.failureBackoff : Self.cacheLifetime
            if date.timeIntervalSince(entry.attemptedAt) < wait {
                return entry.forecast
            }
        }
        let previous = cache[key]?.forecast
        cache[key] = Entry(forecast: previous, attemptedAt: date)
        do {
            var request = URLRequest(url: Self.url(for: coordinate))
            request.timeoutInterval = 10
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let forecast = try Self.parse(data, fetchedAt: date)
            cache[key] = Entry(forecast: forecast, attemptedAt: date)
            return forecast
        } catch {
            return previous
        }
    }

    static func url(for coordinate: Coordinate) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "3")
        ]
        return components.url!
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            var time: [TimeInterval]
            var precipitation_probability: [Int?]?
            var precipitation: [Double?]?
        }
        var hourly: Hourly
    }

    /// Open-Meteo's hourly values cover the hour before each timestamp.
    static func parse(_ data: Data, fetchedAt: Date) throws -> RainForecast {
        let hourly = try JSONDecoder().decode(Response.self, from: data).hourly
        let hours = hourly.time.indices.map { index in
            RainForecast.Hour(
                start: Date(timeIntervalSince1970: hourly.time[index] - 3600),
                probability: hourly.precipitation_probability?[safe: index].flatMap { $0 } ?? 0,
                millimeters: hourly.precipitation?[safe: index].flatMap { $0 } ?? 0
            )
        }
        return RainForecast(hours: hours, fetchedAt: fetchedAt)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
