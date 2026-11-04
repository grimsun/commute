import XCTest
@testable import CommuteCore

final class WeatherTests: XCTestCase {
    private let calendar = Calendar.caltrain

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Open-Meteo's shape: each value covers the hour before its timestamp.
    private func forecastJSON() -> Data {
        let times = [at(19, 8), at(19, 9), at(19, 10)].map { Int($0.timeIntervalSince1970) }
        return Data("""
        {"latitude":37.79,"longitude":-122.41,"hourly_units":{"time":"unixtime"},
         "hourly":{"time":\(times),"precipitation_probability":[10,70,null],"precipitation":[0.0,0.8,null]}}
        """.utf8)
    }

    func testParsesHourlyRainAsTheHourBefore() throws {
        let forecast = try OpenMeteoWeather.parse(forecastJSON(), fetchedAt: at(19, 6))

        XCTAssertEqual(forecast.hours.map(\.start), [at(19, 7), at(19, 8), at(19, 9)])
        XCTAssertEqual(forecast.hours.map(\.probability), [10, 70, 0])
        XCTAssertEqual(forecast.hours[1].millimeters, 0.8)
        XCTAssertEqual(forecast.hours.map(\.isRainLikely), [false, true, false])
    }

    func testRainOnlyInOverlappingHours() throws {
        let forecast = try OpenMeteoWeather.parse(forecastJSON(), fetchedAt: at(19, 6))

        XCTAssertNil(forecast.rain(from: at(19, 7, 40), to: at(19, 7, 55)))
        XCTAssertEqual(forecast.rain(from: at(19, 7, 55), to: at(19, 8, 5))?.start, at(19, 8))
        XCTAssertNil(forecast.rain(from: at(19, 9), to: at(19, 9, 10)))
    }

    func testWarnsForEachOutdoorLeg() async throws {
        var profile = CommuteProfile.default
        profile.homeStationMinutes = 10
        profile.workStationMinutes = 10
        // 8:20 train, leave at 8:07; arrives 9:00, at work 9:10.
        let train = TrainDeparture(tripID: "103", trainNumber: "103", service: .local, scheduledDeparture: at(19, 8, 20), scheduledArrival: at(19, 9))
        let plan = try await CommutePlanner(transit: FixedTransitProvider(departures: [train]), traffic: nil, calendar: calendar)
            .plan(profile: profile, direction: .homeToWork, now: at(19, 6))
        let wet = try OpenMeteoWeather.parse(forecastJSON(), fetchedAt: at(19, 6)) // rain 8–9
        let dry = RainForecast(hours: [], fetchedAt: at(19, 6))

        let leaving = RainWarning.warnings(for: plan, origin: wet, destination: dry)
        XCTAssertEqual(leaving, [RainWarning(direction: .homeToWork, leg: .toStation, time: at(19, 8, 7), probability: 70)])

        // At work 9:00–9:10, after the rain.
        XCTAssertTrue(RainWarning.warnings(for: plan, origin: dry, destination: wet).isEmpty)
        XCTAssertTrue(RainWarning.warnings(for: plan, origin: nil, destination: nil).isEmpty)
    }

    func testCachesForecastsAndKeepsThemThroughFailures() async {
        nonisolated(unsafe) var requests = 0
        nonisolated(unsafe) var clock = at(19, 6)
        let body = forecastJSON()
        StubURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "api.open-meteo.com")
            return requests == 1 ? (200, body) : (500, Data())
        }
        let weather = OpenMeteoWeather(session: session(), now: { clock })
        let home = Coordinate(latitude: 37.7915, longitude: -122.413)

        let first = await weather.forecast(at: home)
        XCTAssertEqual(first?.hours.count, 3)
        clock = at(19, 6, 20)
        _ = await weather.forecast(at: home)
        XCTAssertEqual(requests, 1, "cached for 30 min")

        clock = at(19, 6, 40)
        let failed = await weather.forecast(at: home)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(failed, first, "the last good forecast stays")
    }
}
