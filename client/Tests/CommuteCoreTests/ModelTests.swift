import XCTest
@testable import CommuteCore

final class ModelTests: XCTestCase {
    func testProfileDecodingFillsMissingFieldsWithDefaults() throws {
        let json = #"{"homeStationID":"mountain_view","preferredServices":["express"]}"#
        let profile = try JSONDecoder().decode(CommuteProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.homeStationID, "mountain_view")
        XCTAssertEqual(profile.preferredServices, [.express])
        XCTAssertEqual(profile.workStationID, CommuteProfile.default.workStationID)
        XCTAssertEqual(profile.morningTargetLeave, CommuteProfile.default.morningTargetLeave)
    }

    func testProfileRoundTrips() throws {
        var profile = CommuteProfile.default
        profile.accessMode = .walk
        profile.eveningTargetLeave = TimeOfDay(hour: 18, minute: 5)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(CommuteProfile.self, from: data), profile)
    }

    func testTimeOfDayUsesPacificTime() {
        let calendar = Calendar.caltrain
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 3))!
        let date = TimeOfDay(hour: 8, minute: 15).date(on: day, calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.hour, .minute, .day], from: date), DateComponents(day: 19, hour: 8, minute: 15))
    }

    func testSuggestedDirection() {
        let calendar = Calendar.caltrain
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15))!

        XCTAssertEqual(Direction.suggested(at: morning, calendar: calendar), .homeToWork)
        XCTAssertEqual(Direction.suggested(at: evening, calendar: calendar), .workToHome)
    }

    func testGTFSRouteNamesMapToServices() {
        XCTAssertEqual(TrainService(gtfsRouteName: "Local Weekday"), .local)
        XCTAssertEqual(TrainService(gtfsRouteName: "Local Weekend"), .local)
        XCTAssertEqual(TrainService(gtfsRouteName: "Limited"), .limited)
        XCTAssertEqual(TrainService(gtfsRouteName: "Express"), .express)
        XCTAssertEqual(TrainService(gtfsRouteName: "South County"), .southCounty)
        XCTAssertNil(TrainService(gtfsRouteName: "Bus Bridge"))
    }

    func testStationCatalogIsOrderedNorthToSouth() {
        let latitudes = StationCatalog.all.map(\.coordinate.latitude)
        XCTAssertEqual(StationCatalog.all.first?.id, "san_francisco")
        XCTAssertEqual(StationCatalog.all.last?.id, "gilroy")
        XCTAssertGreaterThan(latitudes.first!, latitudes.last!)
        XCTAssertEqual(Set(StationCatalog.all.map(\.id)).count, StationCatalog.all.count)
    }

    func testStraightLineEstimate() {
        // 4 km at 16 km/h = 15 minutes.
        XCTAssertEqual(StraightLineAccessProvider.estimate(distanceMeters: 4000, mode: .bike, bikeSpeedKph: 16), 15 * 60, accuracy: 0.1)
    }
}

final class SampleTransitProviderTests: XCTestCase {
    private let calendar = Calendar.caltrain
    private let provider = SampleTransitProvider()

    private func monday(_ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: hour))!
    }

    func testWeekdayPeakHasAllMainlineServices() async throws {
        let snapshot = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: monday(6), limit: 50)
        let services = Set(snapshot.departures.map(\.service))

        XCTAssertEqual(services, [.local, .limited, .express])
        XCTAssertEqual(snapshot.source, .sample)
    }

    func testDeparturesAreSortedAndArriveAfterDeparting() async throws {
        let snapshot = try await provider.departures(fromStation: "palo_alto", toStation: "san_francisco", after: monday(16), limit: 20)
        let times = snapshot.departures.map(\.departureTime)

        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(snapshot.departures.allSatisfy { $0.arrivalTime > $0.departureTime })
        XCTAssertTrue(snapshot.departures.allSatisfy { $0.departureTime >= monday(16) })
    }

    func testTrainNumbersFollowDirectionParity() async throws {
        let south = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: monday(7), limit: 10)
        let north = try await provider.departures(fromStation: "palo_alto", toStation: "san_francisco", after: monday(7), limit: 10)

        XCTAssertTrue(south.departures.allSatisfy { Int($0.trainNumber)! % 2 == 0 })
        XCTAssertTrue(north.departures.allSatisfy { Int($0.trainNumber)! % 2 == 1 })
    }

    func testExpressSkipsMinorStations() async throws {
        let snapshot = try await provider.departures(fromStation: "san_francisco", toStation: "belmont", after: monday(6), limit: 50)
        XCTAssertFalse(snapshot.departures.contains { $0.service == .express })
    }

    func testSouthCountyOnlyServesSouthOfSanJose() async throws {
        let snapshot = try await provider.departures(fromStation: "sj_diridon", toStation: "gilroy", after: monday(6), limit: 50)
        XCTAssertEqual(Set(snapshot.departures.map(\.service)), [.southCounty])
    }

    func testIsDeterministic() async throws {
        let first = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: monday(6), limit: 30)
        let second = try await provider.departures(fromStation: "san_francisco", toStation: "palo_alto", after: monday(6), limit: 30)
        XCTAssertEqual(first.departures, second.departures)
    }

    func testUnknownStationThrows() async {
        do {
            _ = try await provider.departures(fromStation: "nowhere", toStation: "palo_alto", after: monday(6), limit: 5)
            XCTFail("expected unknownStation")
        } catch {
            XCTAssertEqual(error as? SampleTransitError, .unknownStation("nowhere"))
        }
    }
}
