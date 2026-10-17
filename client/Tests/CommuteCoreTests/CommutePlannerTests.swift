import XCTest
@testable import CommuteCore

final class CommutePlannerTests: XCTestCase {
    private let calendar = Calendar.caltrain

    /// 2026-10-19 is a Monday.
    private func at(_ hour: Int, _ minute: Int, day: Int = 19) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func train(_ number: String, departs: Date, service: TrainService = .local, delayMinutes: Int = 0, cancelled: Bool = false) -> TrainDeparture {
        TrainDeparture(
            tripID: number,
            trainNumber: number,
            service: service,
            scheduledDeparture: departs,
            scheduledArrival: departs.addingTimeInterval(45 * 60),
            delaySeconds: delayMinutes * 60,
            isCancelled: cancelled
        )
    }

    /// Target 8:00, 8 min ride + 2 overhead = 10 min access, 3 min buffer, 20 min prep.
    private func profile(services: Set<TrainService> = Set(TrainService.allCases)) -> CommuteProfile {
        var profile = CommuteProfile.default
        profile.morningTargetLeave = TimeOfDay(hour: 8, minute: 0)
        profile.accessOverheadMinutes = 2
        profile.stationSafetyBufferMinutes = 3
        profile.prepLeadTimeMinutes = 20
        profile.preferredServices = services
        return profile
    }

    private func planner(_ trains: [TrainDeparture], car: TrafficProvider? = nil) -> DefaultPlanner {
        DefaultPlanner(
            transit: FixedTransitProvider(departures: trains),
            access: FixedAccessProvider(seconds: 8 * 60),
            traffic: car,
            calendar: calendar
        )
    }

    func testTargetTrainIsFirstCatchableWhenLeavingAtTarget() async throws {
        let trains = [
            train("101", departs: at(8, 10)), // leave-by 7:57, before target
            train("103", departs: at(8, 20)), // leave-by 8:07
            train("105", departs: at(8, 40))
        ]
        let plan = try await planner(trains).plan(profile: profile(), direction: .homeToWork, now: at(7, 0))

        XCTAssertEqual(plan.train?.train.trainNumber, "103")
        XCTAssertEqual(plan.train?.state, .onTrack)
        XCTAssertEqual(plan.train?.fallback?.trainNumber, "105")
    }

    func testAttemptTimesUseAccessTimeAndBuffers() async throws {
        let target = train("103", departs: at(8, 20))
        let plan = try await planner([target]).plan(profile: profile(), direction: .homeToWork, now: at(7, 0))
        let attempts = try XCTUnwrap(plan.train?.attempts)

        XCTAssertEqual(attempts.tooLateAt, at(8, 10)) // departure − 10 min access
        XCTAssertEqual(attempts.leaveAt, at(8, 7)) // − 3 min buffer
        XCTAssertEqual(attempts.getReadyAt, at(7, 47)) // − 20 min prep
    }

    func testStateProgressesThroughGetReadyAndLeaveNow() async throws {
        let trains = [train("103", departs: at(8, 20)), train("105", departs: at(8, 40))]
        let planner = planner(trains)

        let getReady = try await planner.plan(profile: profile(), direction: .homeToWork, now: at(7, 50))
        XCTAssertEqual(getReady.train?.state, .getReady)

        let leaveNow = try await planner.plan(profile: profile(), direction: .homeToWork, now: at(8, 8))
        XCTAssertEqual(leaveNow.train?.state, .leaveNow)
        XCTAssertEqual(leaveNow.train?.train.trainNumber, "103")
    }

    func testRollsToNextTrainOnceTargetIsTooLate() async throws {
        let trains = [train("103", departs: at(8, 20)), train("105", departs: at(8, 40)), train("107", departs: at(9, 0))]
        let plan = try await planner(trains).plan(profile: profile(), direction: .homeToWork, now: at(8, 11))

        XCTAssertEqual(plan.train?.train.trainNumber, "105")
        XCTAssertEqual(plan.train?.state, .rolledToNextTrain)
        XCTAssertEqual(plan.train?.fallback?.trainNumber, "107")
    }

    func testLiveStateAdvancesBetweenRefreshes() async throws {
        let plan = try await planner([train("103", departs: at(8, 20))]).plan(profile: profile(), direction: .homeToWork, now: at(7, 0))
        let option = try XCTUnwrap(plan.train)

        XCTAssertEqual(option.state(at: at(7, 0)), .onTrack)
        XCTAssertEqual(option.state(at: at(7, 50)), .getReady)
        XCTAssertEqual(option.state(at: at(8, 9)), .leaveNow)
        XCTAssertEqual(option.state(at: at(8, 11)), .rolledToNextTrain)
    }

    func testDelayMovesLeaveTimeLater() async throws {
        let delayed = train("103", departs: at(8, 20), delayMinutes: 6)
        let plan = try await planner([delayed]).plan(profile: profile(), direction: .homeToWork, now: at(7, 0))

        XCTAssertEqual(plan.train?.attempts.leaveAt, at(8, 13))
    }

    func testCancelledTargetPromotesNextTrainAsTarget() async throws {
        let trains = [train("103", departs: at(8, 20), cancelled: true), train("105", departs: at(8, 40))]
        let plan = try await planner(trains).plan(profile: profile(), direction: .homeToWork, now: at(7, 0))

        XCTAssertEqual(plan.train?.train.trainNumber, "105")
        XCTAssertEqual(plan.train?.state, .onTrack)
        XCTAssertEqual(plan.upcoming.map(\.trainNumber), ["103", "105"], "cancelled trains stay visible")
    }

    func testOnlyPreferredServicesAreConsidered() async throws {
        let trains = [
            train("403", departs: at(8, 15), service: .limited),
            train("503", departs: at(8, 25), service: .express),
            train("105", departs: at(8, 40), service: .local)
        ]
        let plan = try await planner(trains).plan(profile: profile(services: [.express, .local]), direction: .homeToWork, now: at(7, 0))

        XCTAssertEqual(plan.train?.train.trainNumber, "503")
        XCTAssertEqual(plan.upcoming.map(\.trainNumber), ["503", "105"])
        XCTAssertEqual(plan.hiddenTrainCount, 1)
    }

    func testNoTrainLeftProducesPlanWithoutTrain() async throws {
        let plan = try await planner([train("199", departs: at(8, 20))]).plan(profile: profile(), direction: .homeToWork, now: at(9, 0))

        XCTAssertNil(plan.train)
        XCTAssertTrue(plan.upcoming.isEmpty)
    }

    func testEveningUsesWorkStationAndEveningTarget() async throws {
        var profile = profile()
        profile.eveningTargetLeave = TimeOfDay(hour: 17, minute: 30)
        let trains = [train("200", departs: at(17, 35)), train("202", departs: at(17, 50))]
        let plan = try await planner(trains).plan(profile: profile, direction: .workToHome, now: at(16, 0))

        XCTAssertEqual(plan.originStation.id, "palo_alto")
        XCTAssertEqual(plan.destinationStation.id, "san_francisco")
        XCTAssertEqual(plan.train?.train.trainNumber, "202")
    }

    func testSameStationIsRejected() async {
        var profile = profile()
        profile.workStationID = profile.homeStationID
        do {
            _ = try await planner([]).plan(profile: profile, direction: .homeToWork, now: at(7, 0))
            XCTFail("expected sameStation")
        } catch {
            XCTAssertEqual(error as? PlannerError, .sameStation)
        }
    }

    func testCarTrafficComparedWithFreeFlow() async throws {
        let heavy = try await planner([], car: FixedTrafficProvider(eta: 50 * 60, freeFlowETA: 35 * 60))
            .plan(profile: profile(), direction: .homeToWork, now: at(7, 0))
        XCTAssertEqual(heavy.car?.isTrafficGood, false)

        let light = try await planner([], car: FixedTrafficProvider(eta: 40 * 60, freeFlowETA: 35 * 60))
            .plan(profile: profile(), direction: .homeToWork, now: at(7, 0))
        XCTAssertEqual(light.car?.isTrafficGood, true)
    }
}
