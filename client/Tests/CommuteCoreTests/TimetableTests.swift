import XCTest
@testable import CommuteCore

/// Uses `Fixtures/mini-gtfs.zip`: Locals 102 (SF 8:00 → PA 8:50) and 198 (SF 24:30 → PA 25:10),
/// Express 502 (SF 8:30 → PA 9:00), northbound 101, weekend Local 202 (SF 9:00 → PA 9:45),
/// a bus-bridge trip that is ignored, and Thanksgiving running the weekend service.
final class TimetableTests: XCTestCase {
    private let calendar = Calendar.caltrain

    static func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mini-gtfs", withExtension: "zip", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func fixtureTimetable() throws -> Timetable {
        try GTFSParser.parse(archive: ZipArchive(data: fixtureData()), downloadedAt: Date(timeIntervalSince1970: 0))
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func numbers(_ departures: [TrainDeparture]) -> [String] {
        departures.map(\.trainNumber)
    }

    /// Queries also return the next day's trains; most tests look at one day.
    private func numbers(_ departures: [TrainDeparture], on day: Date) -> [String] {
        departures.filter { calendar.isDate($0.scheduledDeparture, inSameDayAs: day) }.map(\.trainNumber)
    }

    // MARK: ZIP

    func testZipReadsDeflatedAndStoredEntries() throws {
        let archive = try ZipArchive(data: Self.fixtureData())

        XCTAssertEqual(String(decoding: try archive.contents(of: "readme.txt"), as: UTF8.self), "stored entry")
        XCTAssertTrue(String(decoding: try archive.contents(of: "routes.txt"), as: UTF8.self).contains("Local Weekday"))
        XCTAssertThrowsError(try archive.contents(of: "shapes.txt")) { error in
            XCTAssertEqual(error as? ZipError, .missingEntry("shapes.txt"))
        }
    }

    func testZipRejectsNonZipData() {
        XCTAssertThrowsError(try ZipArchive(data: Data("hello, not a zip file at all".utf8))) { error in
            XCTAssertEqual(error as? ZipError, .notAZip)
        }
    }

    // MARK: Parsing

    func testCSVHandlesQuotesBOMAndCRLF() {
        let table = CSVTable(data: Data("\u{FEFF}id,name\r\n1,\"A, \"\"quoted\"\" name\"\r\n2,plain\r\n".utf8))
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.value(table.rows[0], "name"), "A, \"quoted\" name")
        XCTAssertEqual(table.value(table.rows[1], "id"), "2")
    }

    func testParsesTripsWithParentStationsAndServices() throws {
        let timetable = try Self.fixtureTimetable()

        XCTAssertEqual(timetable.trips.count, 5, "bus bridge is skipped")
        XCTAssertEqual(timetable.feedVersion, "test-1")
        let local = try XCTUnwrap(timetable.trips.first { $0.number == "102" })
        XCTAssertEqual(local.service, .local)
        XCTAssertEqual(local.stops.map(\.station), ["san_francisco", "place_MLBR", "palo_alto"])
        XCTAssertEqual(timetable.trips.first { $0.number == "502" }?.stops.map(\.station), ["san_francisco", "palo_alto"], "sorted by stop_sequence")
        XCTAssertEqual(timetable.validRange, 20261001...20261231)
    }

    func testGTFSTimesBeyondMidnight() {
        XCTAssertEqual(GTFSParser.seconds("25:10:00"), 25 * 3600 + 600)
        XCTAssertNil(GTFSParser.seconds("8:00"))
    }

    // MARK: Queries

    func testWeekdayDeparturesInOrderWithArrival() throws {
        let departures = try Self.fixtureTimetable().departures(from: "san_francisco", to: "palo_alto", after: at(19, 7), limit: 2, calendar: calendar)

        XCTAssertEqual(numbers(departures), ["102", "502"])
        XCTAssertEqual(departures.first?.scheduledDeparture, at(19, 8))
        XCTAssertEqual(departures.first?.scheduledArrival, at(19, 8, 50))
        XCTAssertEqual(departures.last?.service, .express)
    }

    func testDirectionMatters() throws {
        let northbound = try Self.fixtureTimetable().departures(from: "palo_alto", to: "san_francisco", after: at(19, 6), limit: 10, calendar: calendar)
        XCTAssertEqual(Set(numbers(northbound)), ["101"])
    }

    func testIntermediateStation() throws {
        let departures = try Self.fixtureTimetable().departures(from: "place_MLBR", to: "palo_alto", after: at(19, 7), limit: 1, calendar: calendar)
        XCTAssertEqual(departures.first?.scheduledDeparture, at(19, 8, 21), "departure, not arrival, at the origin")
    }

    func testWeekendAndHolidayUseWeekendService() throws {
        let timetable = try Self.fixtureTimetable()
        let saturday = timetable.departures(from: "san_francisco", to: "palo_alto", after: at(24, 6), limit: 10, calendar: calendar)
        let thanksgiving = timetable.departures(from: "san_francisco", to: "palo_alto", after: at(26, 6, month: 11), limit: 10, calendar: calendar)

        XCTAssertEqual(numbers(saturday, on: at(24, 6)), ["202"])
        XCTAssertEqual(numbers(thanksgiving, on: at(26, 6, month: 11)), ["202"])
        XCTAssertEqual(numbers(thanksgiving, on: at(27, 6, month: 11)), ["102", "502"], "weekday service resumes on Friday")
    }

    func testTripsPastMidnightBelongToPreviousServiceDay() throws {
        let timetable = try Self.fixtureTimetable()
        let lateMonday = timetable.departures(from: "san_francisco", to: "palo_alto", after: at(19, 23), limit: 1, calendar: calendar)
        let earlyTuesday = timetable.departures(from: "san_francisco", to: "palo_alto", after: at(20, 0), limit: 1, calendar: calendar)

        XCTAssertEqual(numbers(lateMonday), ["198"])
        XCTAssertEqual(lateMonday.first?.scheduledDeparture, at(20, 0, 30))
        XCTAssertEqual(earlyTuesday.first?.tripID, lateMonday.first?.tripID)
    }

    // MARK: Store

    func testStoreDownloadsOnceThenUsesMemoryAndDisk() async throws {
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: "timetable-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let source = CountingSource(timetable: try Self.fixtureTimetable())

        let store = TimetableStore(source: source, cacheURL: cacheURL)
        let noInfoYet = await store.info()
        XCTAssertNil(noInfoYet)
        _ = try await store.current()
        _ = try await store.current()
        var downloads = await source.count
        XCTAssertEqual(downloads, 1)

        let relaunched = TimetableStore(source: source, cacheURL: cacheURL)
        let cachedInfo = await relaunched.info()
        XCTAssertEqual(cachedInfo?.tripCount, 5)
        _ = try await relaunched.current()
        downloads = await source.count
        XCTAssertEqual(downloads, 1, "read from disk")

        try await relaunched.refresh()
        downloads = await source.count
        XCTAssertEqual(downloads, 2)
    }

    func testStoreSharesConcurrentDownloads() async throws {
        let source = CountingSource(timetable: try Self.fixtureTimetable(), delay: .milliseconds(50))
        let store = TimetableStore(source: source, cacheURL: nil)

        async let first = store.current()
        async let second = store.current()
        _ = try await (first, second)
        let downloads = await source.count
        XCTAssertEqual(downloads, 1)
    }

    func testTimetableProviderFlagsExpiredTimetable() async throws {
        let store = TimetableStore(source: CountingSource(timetable: try Self.fixtureTimetable()), cacheURL: nil)
        let provider = TimetableTransitProvider(store: store, calendar: calendar)

        let current = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: at(19, 7), limit: 5)
        XCTAssertEqual(current.source, .timetable)
        XCTAssertNil(current.notice)

        let expired = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: at(5, 7, month: 1).addingTimeInterval(366 * 86_400), limit: 5)
        XCTAssertNotNil(expired.notice)
    }
}

actor CountingSource: TimetableSource {
    private let timetable: Timetable
    private let delay: Duration
    private(set) var count = 0

    init(timetable: Timetable, delay: Duration = .zero) {
        self.timetable = timetable
        self.delay = delay
    }

    func fetchTimetable() async throws -> Timetable {
        count += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return timetable
    }
}

/// Runs against a real Caltrain feed when `CALTRAIN_GTFS` points to a downloaded zip.
final class RealFeedTests: XCTestCase {
    func testParsesRealCaltrainFeed() throws {
        guard let path = ProcessInfo.processInfo.environment["CALTRAIN_GTFS"] else {
            throw XCTSkip("Set CALTRAIN_GTFS to a Caltrain GTFS zip to run")
        }
        let calendar = Calendar.caltrain
        let start = Date()
        let timetable = try GTFSParser.parse(archive: ZipArchive(data: Data(contentsOf: URL(filePath: path))), downloadedAt: Date())
        let parseTime = Date().timeIntervalSince(start)

        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 7))!
        let trains = timetable.departures(from: "san_francisco", to: "palo_alto", after: monday, limit: 8, calendar: calendar)
        print("trips \(timetable.trips.count), parse \(String(format: "%.2f", parseTime))s, valid \(String(describing: timetable.validRange))")
        for train in trains {
            print(train.trainNumber, train.service, train.scheduledDeparture.formatted(date: .omitted, time: .shortened), "→", train.scheduledArrival.formatted(date: .omitted, time: .shortened))
        }
        XCTAssertGreaterThan(timetable.trips.count, 100)
        XCTAssertFalse(trains.isEmpty)
        XCTAssertTrue(Set(trains.map(\.service)).isSubset(of: Set(TrainService.allCases)))
        let unknown = Set(timetable.trips.flatMap { $0.stops.map(\.station) }).subtracting(StationCatalog.all.map(\.id))
        XCTAssertTrue(unknown.isEmpty, "stations missing from StationCatalog: \(unknown)")
    }
}
