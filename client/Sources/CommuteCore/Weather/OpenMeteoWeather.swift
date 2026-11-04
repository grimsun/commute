import Foundation

/// Hourly forecasts from Open-Meteo (free, no key). Each place is fetched at most every
/// `cacheLifetime`, with a backoff after failures; the last good forecast is kept meanwhile.
public actor OpenMeteoWeather: WeatherProviding {
    public static let baseURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
    public static let cacheLifetime: TimeInterval = 30 * 60
    public static let failureBackoff: TimeInterval = 10 * 60

    private struct Entry {
        var forecast: WeatherForecast?
        var attemptedAt: Date
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    public func forecast(at coordinate: Coordinate) async -> WeatherForecast? {
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
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation,weather_code,temperature_2m,is_day"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            // Days start at Caltrain's midnight, so today's morning stays in the forecast all day.
            URLQueryItem(name: "timezone", value: Calendar.caltrain.timeZone.identifier),
            URLQueryItem(name: "forecast_days", value: "3")
        ]
        return components.url!
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            var time: [TimeInterval]
            var precipitation_probability: [Int?]?
            var precipitation: [Double?]?
            var weather_code: [Int?]?
            var temperature_2m: [Double?]?
            var is_day: [Int?]?
        }
        var hourly: Hourly
    }

    /// Open-Meteo's rain values cover the hour before each timestamp; the sky and temperature
    /// are for the timestamp itself, close enough to stand for that hour too.
    static func parse(_ data: Data, fetchedAt: Date) throws -> WeatherForecast {
        let hourly = try JSONDecoder().decode(Response.self, from: data).hourly
        let hours = hourly.time.indices.map { index in
            WeatherForecast.Hour(
                start: Date(timeIntervalSince1970: hourly.time[index] - 3600),
                probability: hourly.precipitation_probability?[safe: index].flatMap { $0 } ?? 0,
                millimeters: hourly.precipitation?[safe: index].flatMap { $0 } ?? 0,
                condition: hourly.weather_code?[safe: index].flatMap { $0 }.flatMap(WeatherCondition.init(wmoCode:)),
                temperature: hourly.temperature_2m?[safe: index].flatMap { $0 },
                isDaylight: (hourly.is_day?[safe: index].flatMap { $0 } ?? 1) == 1
            )
        }
        return WeatherForecast(hours: hours, fetchedAt: fetchedAt)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
