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

    /// Target 8:00, 10 min home ↔ station, 15 min work ↔ station, 3 min buffer, 20 min prep.
    private func profile(services: Set<TrainService> = Set(TrainService.allCases)) -> CommuteProfile {
        var profile = CommuteProfile.default
        profile.morningTargetLeave = TimeOfDay(hour: 8, minute: 0)
        profile.homeStationMinutes = 10
        profile.workStationMinutes = 15
        profile.stationSafetyBufferMinutes = 3
        profile.prepLeadTimeMinutes = 20
        profile.preferredServices = services
        return profile
    }

    private func planner(_ trains: [TrainDeparture], car: TrafficProvider? = nil) -> DefaultPlanner {
        DefaultPlanner(
            transit: FixedTransitProvider(departures: trains),
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

    func testEnRouteKeepsTrainsTheRiderCouldStillBeOn() async throws {
        // Each ride is 45 min; the work end is 15 min from its station.
        let trains = [
            train("101", departs: at(8, 0)),  // door by 9:00
            train("103", departs: at(8, 20)),
            train("105", departs: at(8, 30)),
            train("107", departs: at(8, 40)),
            train("109", departs: at(9, 10))
        ]
        let plan = try await planner(trains).plan(profile: profile(), direction: .homeToWork, now: at(8, 55))

        XCTAssertEqual(plan.upcoming.map(\.trainNumber), ["105", "107", "109"], "only two departed rows")
        XCTAssertEqual(plan.enRoute.map(\.trainNumber), ["101", "103", "105", "107"], "101 arrived at 8:45 but the rider may still be on the last leg")
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

    func testReplacementTrainAdvancesToLeaveNow() async throws {
        let plan = try await planner([train("103", departs: at(8, 20)), train("105", departs: at(9, 0))])
            .plan(profile: profile(), direction: .homeToWork, now: at(8, 11))
        let option = try XCTUnwrap(plan.train)
        XCTAssertEqual(option.state(at: at(8, 11)), .rolledToNextTrain)
        XCTAssertEqual(option.state(at: at(8, 30)), .getReady)
        XCTAssertEqual(option.state(at: at(8, 48)), .leaveNow)
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
        XCTAssertEqual(plan.upcoming.map(\.trainNumber), ["403", "503", "105"], "the list shows every service")
    }

    func testListLeadsWithTwoDepartedTrains() async throws {
        let trains = (0..<5).map { train("10\($0)", departs: at(7, 0).addingTimeInterval(Double($0) * 15 * 60)) }
        let plan = try await planner(trains).plan(profile: profile(), direction: .homeToWork, now: at(7, 40))

        // 7:00, 7:15, 7:30 left; 7:45 and 8:00 are ahead.
        XCTAssertEqual(plan.upcoming.map(\.trainNumber), ["101", "102", "103", "104"])
    }

    func testPickedTrainOverridesTargetWhileCatchable() async throws {
        let trains = [
            train("103", departs: at(8, 20)),
            train("403", departs: at(8, 30), service: .limited),
            train("105", departs: at(8, 40))
        ]
        let planner = planner(trains)
        let localsOnly = profile(services: [.local])

        let picked = try await planner.plan(profile: localsOnly, direction: .homeToWork, now: at(7, 0), pickedTripID: "403")
        XCTAssertEqual(picked.train?.train.trainNumber, "403", "a pick may be any service")
        XCTAssertEqual(picked.train?.isManual, true)
        XCTAssertEqual(picked.train?.fallback?.trainNumber, "105", "fallback stays within preferred services")

        let expired = try await planner.plan(profile: localsOnly, direction: .homeToWork, now: at(8, 21), pickedTripID: "403")
        XCTAssertEqual(expired.train?.train.trainNumber, "105")
        XCTAssertEqual(expired.train?.isManual, false)
    }

    func testRollsForFourHoursThenMovesToTomorrow() async throws {
        let trains = [
            train("103", departs: at(8, 20)), // today's target, missed
            train("117", departs: at(11, 50)),
            train("199", departs: at(12, 20)),
            train("203", departs: at(8, 20, day: 20)) // tomorrow's target
        ]
        let planner = planner(trains)

        let within = try await planner.plan(profile: profile(), direction: .homeToWork, now: at(11, 30))
        XCTAssertEqual(within.train?.train.trainNumber, "117")
        XCTAssertEqual(within.train?.state, .rolledToNextTrain)

        let after = try await planner.plan(profile: profile(), direction: .homeToWork, now: at(12, 5))
        XCTAssertEqual(after.targetLeave, at(8, 0, day: 20))
        XCTAssertEqual(after.train?.train.trainNumber, "203")
        XCTAssertEqual(after.train?.state, .onTrack)
    }

    func testFutureTargetBeyondFirstSchedulePage() async throws {
        let early = (0..<35).map { train("early-\($0)", departs: at(6, 0).addingTimeInterval(Double($0) * 10 * 60)) }
        let target = train("evening", departs: at(17, 50))
        let plan = try await planner(early + [target]).plan(profile: profile(), direction: .workToHome, now: at(6, 0))
        XCTAssertEqual(plan.train?.train.tripID, "evening")
    }

    func testNoFutureTargetDoesNotSelectTrainBeforeTargetTime() async throws {
        let plan = try await planner([train("early", departs: at(7, 30))])
            .plan(profile: profile(), direction: .homeToWork, now: at(7, 0))
        XCTAssertNil(plan.train)
        XCTAssertEqual(plan.upcoming.count, 1, "earlier trains remain available for manual selection")
    }

    func testNoTrainLeftProducesPlanWithoutTrain() async throws {
        let plan = try await planner([train("199", departs: at(8, 20))]).plan(profile: profile(), direction: .homeToWork, now: at(9, 0))

        XCTAssertNil(plan.train)
        XCTAssertEqual(plan.upcoming.map(\.trainNumber), ["199"], "only the departed train, for context")
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

    func testDoorArrivalAddsStationToDoorMinutes() async throws {
        let plan = try await planner([train("103", departs: at(8, 20))]).plan(profile: profile(), direction: .homeToWork, now: at(7, 0))
        let option = try XCTUnwrap(plan.train)

        // Arrives at the station 9:05, then 15 minutes to work.
        XCTAssertEqual(plan.doorArrival(for: option.train), at(9, 20))
    }

    func testEveningUsesWorkStationMinutesForAccess() async throws {
        let plan = try await planner([train("202", departs: at(17, 50))]).plan(profile: profile(), direction: .workToHome, now: at(16, 0))
        XCTAssertEqual(plan.train?.attempts.tooLateAt, at(17, 35))
    }

    func testBetterTrainIsAnExpressOvertakingTheLocal() async throws {
        let local = TrainDeparture(tripID: "105", trainNumber: "105", service: .local, scheduledDeparture: at(8, 20), scheduledArrival: at(9, 10))
        let express = TrainDeparture(tripID: "505", trainNumber: "505", service: .express, scheduledDeparture: at(8, 30), scheduledArrival: at(9, 0))
        let earlierExpress = TrainDeparture(tripID: "503", trainNumber: "503", service: .express, scheduledDeparture: at(8, 10), scheduledArrival: at(8, 40))
        let plan = try await planner([earlierExpress, local, express]).plan(profile: profile(), direction: .homeToWork, now: at(7, 0))

        XCTAssertEqual(plan.betterTrain(than: local, preferred: [.local, .express])?.trainNumber, "505", "leaves later, arrives 10 min earlier")
        XCTAssertNil(plan.betterTrain(than: local, preferred: [.local]), "only preferred services")
        XCTAssertNil(plan.betterTrain(than: express, preferred: [.local, .express]), "nothing beats it without leaving earlier")
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
