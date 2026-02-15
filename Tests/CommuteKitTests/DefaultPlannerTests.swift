import XCTest
@testable import CommuteKit

final class DefaultPlannerTests: XCTestCase {
    private let profile = CommuteProfile(
        homeAddress: "Home",
        workAddress: "Work",
        homeStation: "Home Station",
        workStation: "Work Station",
        trainLine: "Blue",
        bikeBufferMinutes: 0,
        stationSafetyBufferMinutes: 5,
        prepLeadTimeMinutes: 20,
        carGoodDeltaMinutes: 10,
        defaultPlanningMode: .arriveBy
    )

    func testFeasibilityUsesOneMinuteRule() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let transit = MockTransitProvider(
            departures: [
                // Missed by 30s against 1-minute rule
                TrainDeparture(
                    tripId: "T1",
                    departureTime: now.addingTimeInterval(9 * 60 + 30),
                    arrivalTime: now.addingTimeInterval(30 * 60)
                ),
                TrainDeparture(
                    tripId: "T2",
                    departureTime: now.addingTimeInterval(12 * 60),
                    arrivalTime: now.addingTimeInterval(35 * 60)
                )
            ]
        )
        let planner = DefaultPlanner(
            trafficProvider: MockTrafficProvider(currentETA: 30 * 60, baselineETA: 25 * 60),
            transitProvider: transit,
            bikeProvider: MockBikeETAProvider(etaSeconds: 9 * 60)
        )

        let request = TripRequest(
            direction: .homeToWork,
            modePreference: .auto,
            planningMode: .arriveBy,
            targetDateTime: now.addingTimeInterval(45 * 60)
        )

        let plan = try await planner.computePlan(profile: profile, tripRequest: request, now: now)
        XCTAssertEqual(plan.multimodalOption.selectedTrain.tripId, "T2")
    }

    func testArriveByAttemptsAreComputed() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let selected = TrainDeparture(
            tripId: "T10",
            departureTime: now.addingTimeInterval(20 * 60),
            arrivalTime: now.addingTimeInterval(42 * 60)
        )
        let planner = DefaultPlanner(
            trafficProvider: MockTrafficProvider(currentETA: 30 * 60, baselineETA: 25 * 60),
            transitProvider: MockTransitProvider(departures: [selected]),
            bikeProvider: MockBikeETAProvider(etaSeconds: 8 * 60)
        )

        let request = TripRequest(
            direction: .homeToWork,
            modePreference: .auto,
            planningMode: .arriveBy,
            targetDateTime: now.addingTimeInterval(45 * 60)
        )

        let plan = try await planner.computePlan(profile: profile, tripRequest: request, now: now)
        XCTAssertEqual(plan.multimodalOption.attemptTimes.tooLateAt, selected.departureTime.addingTimeInterval(-60))
        XCTAssertEqual(plan.multimodalOption.attemptTimes.leaveAt, selected.departureTime.addingTimeInterval(-(8 * 60)))
    }

    func testLeaveAtUsesRequestedDepartureWindow() async throws {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let leaveAt = now.addingTimeInterval(10 * 60)
        let planner = DefaultPlanner(
            trafficProvider: MockTrafficProvider(currentETA: 18 * 60, baselineETA: 20 * 60),
            transitProvider: MockTransitProvider(
                departures: [
                    TrainDeparture(
                        tripId: "TooEarly",
                        departureTime: now.addingTimeInterval(8 * 60),
                        arrivalTime: now.addingTimeInterval(28 * 60)
                    ),
                    TrainDeparture(
                        tripId: "Good",
                        departureTime: now.addingTimeInterval(17 * 60),
                        arrivalTime: now.addingTimeInterval(37 * 60)
                    )
                ]
            ),
            bikeProvider: MockBikeETAProvider(etaSeconds: 6 * 60)
        )

        let request = TripRequest(
            direction: .homeToWork,
            modePreference: .auto,
            planningMode: .leaveAt,
            targetDateTime: leaveAt
        )

        let plan = try await planner.computePlan(profile: profile, tripRequest: request, now: now)
        XCTAssertEqual(plan.multimodalOption.selectedTrain.tripId, "Good")
    }

    func testCarTrafficGoodThreshold() async throws {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let planner = DefaultPlanner(
            trafficProvider: MockTrafficProvider(currentETA: 33 * 60, baselineETA: 22 * 60),
            transitProvider: MockTransitProvider(referenceNow: now),
            bikeProvider: MockBikeETAProvider()
        )
        let request = TripRequest(
            direction: .workToHome,
            modePreference: .auto,
            planningMode: .arriveBy,
            targetDateTime: now.addingTimeInterval(60 * 60)
        )

        let plan = try await planner.computePlan(profile: profile, tripRequest: request, now: now)
        XCTAssertFalse(plan.carOption.isTrafficGood)
    }
}
