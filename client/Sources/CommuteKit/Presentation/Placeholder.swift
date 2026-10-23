import SwiftUI

/// Stand-in data for the loading card: a full-size layout (every line included).
enum Placeholder {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let plan: CommutePlan = {
        let origin = StationCatalog.all[0]
        let destination = StationCatalog.all[15]
        let train = TrainDeparture(
            tripID: "placeholder",
            trainNumber: "000",
            service: .local,
            scheduledDeparture: now.addingTimeInterval(40 * 60),
            scheduledArrival: now.addingTimeInterval(80 * 60)
        )
        let attempts = AttemptRules.attempts(for: train, accessTime: 600, safetyBuffer: 180, prepLeadTime: 1200)
        return CommutePlan(
            generatedAt: now,
            direction: .homeToWork,
            originStation: origin,
            destinationStation: destination,
            targetLeave: now,
            accessTime: 600,
            egressTime: 600,
            safetyBuffer: 180,
            prepLeadTime: 1200,
            train: TrainOption(train: train, attempts: attempts, state: .onTrack, fallback: nil),
            upcoming: [],
            transitSource: .timetable,
            transitFetchedAt: now,
            car: nil
        )
    }()
}
