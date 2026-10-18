import XCTest
@testable import CommuteCore

final class LiveFeedTests: XCTestCase {
    private let calendar = Calendar.caltrain

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Caltrain's JSON shape: train 102 leaves SF (platform 70012) 4 min late; 502 is cancelled.
    private func feedJSON() -> Data {
        let late = Int(at(19, 8, 4).timeIntervalSince1970)
        let millbrae = Int(at(19, 8, 25).timeIntervalSince1970)
        return Data("""
        {"Header":{"GtfsRealtimeVersion":"1.0","Timestamp":1},"Entities":[
          {"Id":"102","TripUpdate":{"Trip":{"TripId":"102","RouteId":"Local Weekday","DirectionId":1},
            "StopTimeUpdate":[{"StopId":"70012","Arrival":{"Time":\(late)},"Departure":{"Time":\(late)}},
                              {"StopId":"70062","Arrival":{"Time":\(millbrae)},"Departure":{"Time":\(millbrae + 60)}}]}},
          {"Id":"502","TripUpdate":{"Trip":{"TripId":"502","ScheduleRelationship":3}}}
        ]}
        """.utf8)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testParsesTripUpdatesAndCancellations() throws {
        let snapshot = try CaltrainLiveFeed.parse(feedJSON(), fetchedAt: Date())
        XCTAssertEqual(snapshot.trips["102"]?.first?.stopID, "70012")
        XCTAssertEqual(snapshot.trips["102"]?.first?.departure, at(19, 8, 4))
        XCTAssertEqual(snapshot.cancelled, ["502"])
    }

    func testAppliesDelayAtOriginAndFromLaterStops() async throws {
        let timetable = try TimetableTests.fixtureTimetable()
        let snapshot = try CaltrainLiveFeed.parse(feedJSON(), fetchedAt: Date())
        let departure = try XCTUnwrap(timetable.departures(from: "san_francisco", to: "palo_alto", after: at(19, 7), limit: 1, calendar: calendar).first)

        XCTAssertEqual(LiveTimetableTransitProvider.delay(of: departure, originID: "san_francisco", updates: snapshot.trips["102"]!, timetable: timetable), 240)

        // Already past SF: the Millbrae prediction (8:26 vs 8:21 scheduled departure) gives the delay.
        let afterSF = Array(snapshot.trips["102"]!.dropFirst())
        XCTAssertEqual(LiveTimetableTransitProvider.delay(of: departure, originID: "san_francisco", updates: afterSF, timetable: timetable), 300)
    }

    func testProviderMarksTrackedTrainsAndCancellations() async throws {
        StubURLProtocol.handler = { [feedJSON = feedJSON()] _ in (200, feedJSON) }
        let store = TimetableStore(source: CountingSource(timetable: try TimetableTests.fixtureTimetable()), cacheURL: nil)
        let now = at(19, 7, 30)
        let feed = CaltrainLiveFeed(session: session(), now: { now })
        let provider = LiveTimetableTransitProvider(store: store, feed: feed, calendar: calendar)

        let before = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: at(19, 7), limit: 2)
        XCTAssertEqual(before.source, .timetable, "nothing fetched yet")

        let fetched = await feed.refreshIfDue()
        XCTAssertTrue(fetched)
        let live = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: at(19, 7), limit: 2)
        XCTAssertEqual(live.source, .live)
        XCTAssertEqual(live.departures.first { $0.trainNumber == "102" }?.delaySeconds, 240)
        XCTAssertEqual(live.departures.first { $0.trainNumber == "102" }?.isTracked, true)
        XCTAssertEqual(live.departures.first { $0.trainNumber == "502" }?.isCancelled, true)
    }

    func testFeedIsThrottled() async throws {
        var requests = 0
        let counter = LockedCounter()
        StubURLProtocol.handler = { [feedJSON = feedJSON()] _ in counter.increment(); return (200, feedJSON) }
        let clock = MutableClock(at(19, 7))
        let feed = CaltrainLiveFeed(session: session(), now: { clock.now })

        _ = await feed.refreshIfDue()
        _ = await feed.refreshIfDue()
        requests = counter.value
        XCTAssertEqual(requests, 1, "second call within the interval does nothing")

        clock.advance(by: 60)
        let manualTooSoon = await feed.isDue(manual: false)
        let manualOK = await feed.isDue(manual: true)
        XCTAssertFalse(manualTooSoon)
        XCTAssertTrue(manualOK, "a manual refresh may come sooner")

        clock.advance(by: CaltrainLiveFeed.minimumInterval)
        _ = await feed.refreshIfDue()
        XCTAssertEqual(counter.value, 2)

        clock.advance(by: CaltrainLiveFeed.maximumAge + 1)
        let stale = await feed.latest()
        XCTAssertNil(stale, "old predictions are dropped")
    }

    func testConcurrentCallersShareOneRequest() async throws {
        let counter = LockedCounter()
        StubURLProtocol.handler = { [feedJSON = feedJSON()] _ in counter.increment(); return (200, feedJSON) }
        let feed = CaltrainLiveFeed(session: session())

        async let first = feed.refreshIfDue()
        async let second = feed.refreshIfDue()
        let results = await [first, second]
        XCTAssertEqual(results, [true, true], "the second caller gets the first one's result")
        XCTAssertEqual(counter.value, 1)
    }

    func testFailureBacksOff() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let clock = MutableClock(at(19, 7))
        let feed = CaltrainLiveFeed(session: session(), now: { clock.now })

        let first = await feed.refreshIfDue(manual: true)
        XCTAssertFalse(first)
        clock.advance(by: 60)
        let retry = await feed.isDue(manual: true)
        XCTAssertFalse(retry, "even manual refreshes wait after a failure")
        clock.advance(by: CaltrainLiveFeed.failureBackoff)
        let later = await feed.isDue(manual: true)
        XCTAssertTrue(later)
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
