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

    func testProfileDecodingIgnoresRemovedFields() throws {
        let json = #"{"accessOverheadMinutes":2,"homeStationMinutes":7}"#
        let profile = try JSONDecoder().decode(CommuteProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.homeStationMinutes, 7)
        XCTAssertEqual(profile.dataSource.mode, .standalone)
    }

    func testServerURLValidation() {
        XCTAssertEqual(DataSourceSettings(mode: .server, serverURL: " http://192.168.1.57:8080 ").parsedServerURL?.host, "192.168.1.57")
        XCTAssertNil(DataSourceSettings(mode: .server, serverURL: "not a url").parsedServerURL)
        XCTAssertNil(DataSourceSettings(mode: .server, serverURL: "ftp://example.com").parsedServerURL)
    }

    func testProfileRoundTrips() throws {
        var profile = CommuteProfile.default
        profile.accessMode = .walk
        profile.dataSource = DataSourceSettings(mode: .server, serverURL: "https://commute.example.com")
        profile.commuteDays = [2, 4]
        profile.eveningTargetLeave = TimeOfDay(hour: 18, minute: 5)
        profile.scheduleRoute = StationRoute(originStationID: "hillsdale", destinationStationID: "san_jose_diridon")
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(CommuteProfile.self, from: data), profile)
    }

    func testTimeOfDayUsesPacificTime() {
        let calendar = Calendar.caltrain
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 3))!
        let date = TimeOfDay(hour: 8, minute: 15).date(on: day, calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.hour, .minute, .day], from: date), DateComponents(day: 19, hour: 8, minute: 15))
    }

    func testCommuteWindowRollsOverFourHoursAfterTarget() {
        let calendar = Calendar.caltrain
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let profile = CommuteProfile.default // 8:00 and 17:30 targets

        XCTAssertEqual(CommuteWindow.activeDirection(profile: profile, now: at(19, 6), calendar: calendar), .homeToWork)
        XCTAssertEqual(CommuteWindow.activeDirection(profile: profile, now: at(19, 11, 59), calendar: calendar), .homeToWork, "within 4 h of 8:00")
        XCTAssertEqual(CommuteWindow.activeDirection(profile: profile, now: at(19, 12, 1), calendar: calendar), .workToHome)
        XCTAssertEqual(CommuteWindow.activeDirection(profile: profile, now: at(19, 21, 29), calendar: calendar), .workToHome, "within 4 h of 17:30")
        XCTAssertEqual(CommuteWindow.activeDirection(profile: profile, now: at(19, 21, 31), calendar: calendar), .homeToWork, "tomorrow morning")

        XCTAssertEqual(CommuteWindow.targetLeave(for: .homeToWork, profile: profile, now: at(19, 11), calendar: calendar), at(19, 8))
        XCTAssertEqual(CommuteWindow.targetLeave(for: .homeToWork, profile: profile, now: at(19, 13), calendar: calendar), at(20, 8))
    }

    func testCommuteModeOnlyAroundTargetsOnCommuteDays() {
        let calendar = Calendar.caltrain
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let profile = CommuteProfile.default // 8:00 and 17:30, Monday to Friday
        func isCommute(_ date: Date, holiday: Bool = false) -> Bool {
            CommuteWindow.isCommuteTime(profile: profile, now: date, isHoliday: holiday, calendar: calendar)
        }

        // Monday, October 19.
        XCTAssertFalse(isCommute(at(19, 5, 59)), "more than two hours before 8:00")
        XCTAssertTrue(isCommute(at(19, 6)))
        XCTAssertTrue(isCommute(at(19, 11, 59)))
        XCTAssertFalse(isCommute(at(19, 13)), "midday gap")
        XCTAssertTrue(isCommute(at(19, 15, 30)))
        XCTAssertTrue(isCommute(at(19, 21, 29)))
        XCTAssertFalse(isCommute(at(19, 22)))
        XCTAssertFalse(isCommute(at(19, 8), holiday: true))
        // Saturday and Sunday.
        XCTAssertFalse(isCommute(at(24, 8)))
        XCTAssertFalse(isCommute(at(25, 17, 30)))
    }

    func testLateEveningWindowContinuesAcrossMidnight() {
        let calendar = Calendar.caltrain
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        var profile = CommuteProfile.default
        profile.eveningTargetLeave = TimeOfDay(hour: 23, minute: 0)
        XCTAssertEqual(CommuteWindow.activeDirection(profile: profile, now: at(20, 1)), .workToHome)
        XCTAssertEqual(CommuteWindow.targetLeave(for: .workToHome, profile: profile, now: at(20, 1)), at(19, 23))
        XCTAssertEqual(CommuteWindow.activeDirection(profile: profile, now: at(20, 3)), .homeToWork)
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

    func testNearestStationSkipsGameDayOnlyStanford() {
        let stanfordQuad = Coordinate(latitude: 37.4275, longitude: -122.1697)
        XCTAssertEqual(StationCatalog.nearest(to: stanfordQuad).id, "palo_alto")
        let masonic = Coordinate(latitude: 37.7915, longitude: -122.4130)
        XCTAssertEqual(StationCatalog.nearest(to: masonic).id, "san_francisco")
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

final class DepartureDetectionTests: XCTestCase {
    private let home = Coordinate(latitude: 37.7764, longitude: -122.3946)
    private let target = Date(timeIntervalSince1970: 2_000_000_000)

    private func fix(metersNorth: Double, accuracy: Double = 20) -> LocationFix {
        LocationFix(coordinate: Coordinate(latitude: home.latitude + metersNorth / 111_000, longitude: home.longitude), accuracy: accuracy)
    }

    func testLeftOnceBeyondRadius() {
        let train = target.addingTimeInterval(1200)
        XCTAssertFalse(DepartureDetection.hasLeft(origin: home, fix: fix(metersNorth: 100), targetLeave: target, trainDeparture: train, now: target))
        XCTAssertTrue(DepartureDetection.hasLeft(origin: home, fix: fix(metersNorth: 600), targetLeave: target, trainDeparture: train, now: target))
    }

    func testInaccurateFixNeedsMoreDistance() {
        let train = target.addingTimeInterval(1200)
        XCTAssertFalse(DepartureDetection.hasLeft(origin: home, fix: fix(metersNorth: 400, accuracy: 300), targetLeave: target, trainDeparture: train, now: target))
    }

    func testBeyondStationMeansOnATrain() {
        let station = Coordinate(latitude: home.latitude + 1000 / 111_000, longitude: home.longitude) // 1 km away
        XCTAssertFalse(DepartureDetection.isBeyondStation(origin: home, station: station, fix: fix(metersNorth: 1200)), "on the way to the station")
        XCTAssertTrue(DepartureDetection.isBeyondStation(origin: home, station: station, fix: fix(metersNorth: 5000)), "past it, so on a train")
    }

    func testIgnoredOutsideTripWindow() {
        let train = target.addingTimeInterval(1200)
        let early = target.addingTimeInterval(-3 * 3600)
        XCTAssertFalse(DepartureDetection.hasLeft(origin: home, fix: fix(metersNorth: 2000), targetLeave: target, trainDeparture: train, now: early))
        XCTAssertFalse(DepartureDetection.hasLeft(origin: home, fix: fix(metersNorth: 2000), targetLeave: target, trainDeparture: train, now: train.addingTimeInterval(60)))
    }
}
