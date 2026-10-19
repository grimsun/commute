import XCTest
@testable import CommuteCore

final class ServerTransitProviderTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testDecodesDeparturesAndSendsQuery() async throws {
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path(), "/api/v1/departures")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "from" }?.value, "san_francisco")
            XCTAssertEqual(query.first { $0.name == "to" }?.value, "palo_alto")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "5")
            let body = """
            {"fetchedAt":"2026-10-19T14:40:00Z","departures":[
              {"tripID":"t1","trainNumber":"406","service":"limited","scheduledDeparture":"2026-10-19T15:15:00Z",
               "scheduledArrival":"2026-10-19T15:46:00Z","delaySeconds":180,"isCancelled":false}
            ]}
            """
            return (200, Data(body.utf8))
        }
        let provider = ServerTransitProvider(baseURL: URL(string: "http://commute.local/api")!, session: session())

        let snapshot = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: Date(), limit: 5)

        XCTAssertEqual(snapshot.source, .live)
        XCTAssertEqual(snapshot.departures.first?.trainNumber, "406")
        XCTAssertEqual(snapshot.departures.first?.service, .limited)
        XCTAssertEqual(snapshot.departures.first?.delayMinutes, 3)
    }

    func testBadStatusThrows() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        let provider = ServerTransitProvider(baseURL: URL(string: "http://commute.local")!, session: session())

        do {
            _ = try await provider.checkHealth()
            XCTFail("expected badStatus")
        } catch {
            XCTAssertEqual(error as? ServerError, .badStatus(503))
        }
    }

    func testMissingURLThrows() async {
        do {
            _ = try await ServerTransitProvider(baseURL: nil).checkHealth()
            XCTFail("expected invalidURL")
        } catch {
            XCTAssertEqual(error as? ServerError, .invalidURL)
        }
    }
}

final class ServiceFactoryTests: XCTestCase {
    private let train = TrainDeparture(
        tripID: "t", trainNumber: "102", service: .local,
        scheduledDeparture: Date(timeIntervalSince1970: 2_000_000_000),
        scheduledArrival: Date(timeIntervalSince1970: 2_000_003_000)
    )

    func testFallbackUsesSecondaryWithNotice() async throws {
        let provider = FallbackTransitProvider(
            primary: ServerTransitProvider(baseURL: nil),
            fallback: FixedTransitProvider(departures: [train], source: .timetable),
            notice: "offline"
        )
        let snapshot = try await provider.departures(fromStation: "a", toStation: "b", after: Date(timeIntervalSince1970: 0), limit: 5)

        XCTAssertEqual(snapshot.departures, [train])
        XCTAssertEqual(snapshot.source, .timetable)
        XCTAssertEqual(snapshot.notice, "offline")
    }

    func testFactorySwapsImplementationsByMode() {
        let factory = StandardServiceFactory(
            timetable: TimetableStore(source: CountingSource(timetable: Timetable(downloadedAt: .now, feedVersion: nil, services: [:], trips: [])), cacheURL: nil),
            deviceAlerts: RecordingAlertScheduler()
        )

        let standalone = factory.services(for: DataSourceSettings(mode: .standalone))
        XCTAssertTrue(standalone.transit is LiveTimetableTransitProvider)
        XCTAssertNotNil(standalone.liveFeed)
        XCTAssertTrue(standalone.alerts.schedulesOnDevice)

        let server = factory.services(for: DataSourceSettings(mode: .server, serverURL: "http://commute.local"))
        XCTAssertTrue(server.transit is FallbackTransitProvider)
        XCTAssertFalse(server.alerts.schedulesOnDevice, "the server sends pushes")
    }
}

final class LeaveAlertPlannerTests: XCTestCase {
    private let calendar = Calendar.caltrain

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func train(_ number: String, departs: Date) -> TrainDeparture {
        TrainDeparture(tripID: number, trainNumber: number, service: .local, scheduledDeparture: departs, scheduledArrival: departs.addingTimeInterval(2400))
    }

    /// Monday-only commuter, 8:00 target, 10 min to the station, 3 min buffer, 20 min prep.
    private func alertPlanner() -> (LeaveAlertPlanner, CommuteProfile) {
        var profile = CommuteProfile.default
        profile.commuteDays = [2]
        profile.homeStationMinutes = 10
        profile.stationSafetyBufferMinutes = 3
        profile.prepLeadTimeMinutes = 20
        let planner = DefaultPlanner(
            transit: FixedTransitProvider(departures: [train("103", departs: at(19, 8, 20)), train("105", departs: at(19, 8, 40))]),
            traffic: nil,
            calendar: calendar
        )
        return (LeaveAlertPlanner(planner: planner, calendar: calendar), profile)
    }

    func testSchedulesGetReadyLeaveAndTooLateForTargetTrain() async {
        let (planner, profile) = alertPlanner()
        let alerts = await planner.alerts(profile: profile, now: at(19, 6))

        XCTAssertEqual(alerts.map(\.kind), [.getReady, .leaveNow, .tooLate])
        XCTAssertEqual(alerts.map(\.fireDate), [at(19, 7, 47), at(19, 8, 7), at(19, 8, 11)])
        XCTAssertTrue(alerts[1].title.contains("103"))
        XCTAssertTrue(alerts[2].body.contains("105"), "too-late alert names the next train")
        XCTAssertEqual(Set(alerts.map(\.id)).count, 3)
    }

    func testSkipsPastAlertsAndDepartedCommutes() async {
        let (planner, profile) = alertPlanner()

        let later = await planner.alerts(profile: profile, now: at(19, 7, 50))
        XCTAssertEqual(later.map(\.kind), [.leaveNow, .tooLate])

        let departed = await planner.alerts(profile: profile, now: at(19, 6), skipping: [CommuteKey(date: at(19, 6), direction: .homeToWork, calendar: calendar)])
        XCTAssertTrue(departed.isEmpty)
    }

    func testArrivingAlertFiresBeforeTheStop() {
        let arrival = at(19, 9, 14)
        let train = TrainDeparture(tripID: "114", trainNumber: "114", service: .local, scheduledDeparture: at(19, 8, 25), scheduledArrival: arrival)
        let alert = LeaveAlertPlanner.arrivingAlert(for: train, destination: StationCatalog.station(id: "palo_alto")!, key: CommuteKey(day: 20261019, direction: .homeToWork))

        XCTAssertEqual(alert.kind, .arriving)
        XCTAssertEqual(alert.fireDate, at(19, 9, 11))
        XCTAssertEqual(alert.title, "Next stop: Palo Alto")
    }

    func testNoAlertsOnNonCommuteDays() async {
        let (planner, profile) = alertPlanner()
        let alerts = await planner.alerts(profile: profile, now: at(20, 6), days: 6) // Tue through Sun
        XCTAssertTrue(alerts.isEmpty)
    }
}

final class DepartureLogTests: XCTestCase {
    func testRemembersDepartedCommutes() async {
        let suite = "commute.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let log = DepartureLog(suiteName: suite)
        let morning = CommuteKey(day: 20261019, direction: .homeToWork)

        await log.markDeparted(morning)
        let today = await log.departed(since: 20261019)
        let tomorrow = await log.departed(since: 20261020)

        XCTAssertEqual(today, [morning])
        XCTAssertTrue(tomorrow.isEmpty)
    }

    func testRemembersTheTrainAndCanUndo() async {
        let suite = "commute.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let log = DepartureLog(suiteName: suite)
        let morning = CommuteKey(day: 20261019, direction: .homeToWork)
        let evening = CommuteKey(day: 20261019, direction: .workToHome)

        await log.markDeparted(morning, trainNumber: "510")
        await log.markDeparted(evening)
        var trains = await log.trainNumbers(since: 20261019)
        XCTAssertEqual(trains, [morning: "510"])

        await log.clear(morning)
        let departed = await log.departed(since: 20261019)
        trains = await log.trainNumbers(since: 20261019)
        XCTAssertEqual(departed, [evening])
        XCTAssertTrue(trains.isEmpty)
    }

    func testEndedTripsAreRememberedUntilTakenAgain() async {
        let suite = "commute.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let log = DepartureLog(suiteName: suite)
        let morning = CommuteKey(day: 20261019, direction: .homeToWork)

        await log.markDeparted(morning, trainNumber: "510")
        await log.markEnded(morning)
        var departed = await log.departed(since: 20261019)
        var ended = await log.ended(since: 20261019)
        XCTAssertTrue(departed.isEmpty)
        XCTAssertEqual(ended, [morning])

        // Taking a train again starts the trip again.
        await log.markDeparted(morning, trainNumber: "114")
        departed = await log.departed(since: 20261019)
        ended = await log.ended(since: 20261019)
        XCTAssertEqual(departed, [morning])
        XCTAssertTrue(ended.isEmpty)
    }
}

struct RecordingAlertScheduler: LeaveAlertScheduler {
    var schedulesOnDevice: Bool { true }
    func requestAuthorization() async -> Bool { true }
    func replaceAlerts(with alerts: [LeaveAlert]) async {}
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
