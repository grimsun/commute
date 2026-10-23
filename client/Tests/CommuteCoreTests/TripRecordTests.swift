import XCTest
@testable import CommuteCore

final class TripRecordTests: XCTestCase {
    private let calendar = Calendar.caltrain
    private let key = CommuteKey(day: 20261019, direction: .homeToWork)

    /// 2026-10-19 is a Monday.
    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: hour, minute: minute))!
    }

    private func train(_ number: String, departs: Date, delayMinutes: Int = 0) -> TrainDeparture {
        TrainDeparture(
            tripID: number,
            trainNumber: number,
            service: .local,
            scheduledDeparture: departs,
            scheduledArrival: departs.addingTimeInterval(40 * 60),
            delaySeconds: delayMinutes * 60
        )
    }

    /// Target 8:00, 10 min to the station, 10 min from it, no buffer.
    private func plan(upcoming: [TrainDeparture], enRoute: [TrainDeparture] = [], now: Date) -> CommutePlan {
        let first = upcoming.first ?? enRoute.first!
        return CommutePlan(
            generatedAt: now,
            direction: .homeToWork,
            originStation: StationCatalog.all[0],
            destinationStation: StationCatalog.all[15],
            targetLeave: at(8, 0),
            accessTime: 600,
            egressTime: 600,
            safetyBuffer: 0,
            prepLeadTime: 0,
            train: TrainOption(train: first, attempts: AttemptRules.attempts(for: first, accessTime: 600, safetyBuffer: 0, prepLeadTime: 0), state: .onTrack, fallback: nil),
            upcoming: upcoming,
            enRoute: enRoute,
            transitSource: .timetable,
            transitFetchedAt: now,
            car: nil
        )
    }

    func testArrivingAlertsOnlyForTripsUnderWayOnTheirTrain() {
        var trips = TripRecord()
        trips.take("103", for: key)
        let taken = train("103", departs: at(8, 20))
        let plans = [Direction.homeToWork: plan(upcoming: [taken], now: at(8, 15))]

        let alerts = LeaveAlertPlanner.arrivingAlerts(trips: trips, plans: plans, preferred: [.local], now: at(8, 15))
        XCTAssertEqual(alerts.map(\.kind), [.arriving])
        XCTAssertEqual(alerts.first?.fireDate, taken.arrivalTime.addingTimeInterval(-LeaveAlertPlanner.arrivingLead))
        XCTAssertEqual(alerts.first?.title, "Next stop: \(StationCatalog.all[15].name)")

        XCTAssertTrue(LeaveAlertPlanner.arrivingAlerts(trips: trips, plans: plans, preferred: [.local], now: at(9, 0)).isEmpty, "past its stop")
        XCTAssertTrue(LeaveAlertPlanner.arrivingAlerts(trips: TripRecord(), plans: plans, preferred: [.local], now: at(8, 15)).isEmpty, "no trip under way")
    }

    func testTakenTrainComesFromThePlanWithItsDelay() {
        var trips = TripRecord()
        trips.take("103", for: key)
        let late = train("103", departs: at(8, 20), delayMinutes: 4)
        let plan = plan(upcoming: [train("101", departs: at(8, 10)), late], now: at(8, 15))

        XCTAssertEqual(trips.takenTrain(for: key, in: plan, preferred: [.local], now: at(8, 15))?.delaySeconds, 240)
        XCTAssertFalse(trips.isComplete(key, in: plan, preferred: [.local], now: at(8, 15)))
    }

    func testWithoutANumberTheLatestRunningTrainIsAssumed() {
        var trips = TripRecord()
        trips.take(nil, for: key)
        let running = [train("101", departs: at(8, 10)), train("103", departs: at(8, 20))]
        let plan = plan(upcoming: [train("105", departs: at(8, 40))], enRoute: running, now: at(8, 30))

        XCTAssertEqual(trips.takenTrain(for: key, in: plan, preferred: [.local], now: at(8, 30))?.trainNumber, "103")
    }

    func testTripIsCompleteAtTheDoorOrWhenItsTrainIsGone() {
        var trips = TripRecord()
        trips.take("101", for: key)
        let ridden = train("101", departs: at(8, 10)) // arrives 8:50, door 9:00
        let onLastLeg = plan(upcoming: [train("105", departs: at(9, 10))], enRoute: [ridden], now: at(8, 55))
        XCTAssertFalse(trips.isComplete(key, in: onLastLeg, preferred: [.local], now: at(8, 55)))
        XCTAssertTrue(trips.isComplete(key, in: onLastLeg, preferred: [.local], now: at(9, 0)))

        let later = plan(upcoming: [train("105", departs: at(9, 10))], now: at(9, 5))
        XCTAssertNil(trips.takenTrain(for: key, in: later, preferred: [.local], now: at(9, 5)))
        XCTAssertTrue(trips.isComplete(key, in: later, preferred: [.local], now: at(9, 5)))
    }

    func testEndingAndTakingAgain() {
        var trips = TripRecord()
        trips.take("101", for: key)
        trips.end(key)
        XCTAssertFalse(trips.isUnderWay(key))
        XCTAssertEqual(trips.ended, [key])
        XCTAssertNil(trips.trainNumbers[key])

        trips.take("103", for: key)
        XCTAssertTrue(trips.isUnderWay(key))
        XCTAssertTrue(trips.ended.isEmpty)
    }
}
