import Foundation

/// Scheduled trains from the downloaded Caltrain timetable. No realtime delays.
public struct TimetableTransitProvider: TransitProvider {
    private let store: TimetableStore
    private let calendar: Calendar

    public init(store: TimetableStore, calendar: Calendar = .caltrain) {
        self.store = store
        self.calendar = calendar
    }

    public func departures(fromStation originID: String, toStation destinationID: String, after: Date, limit: Int) async throws -> TransitSnapshot {
        let timetable = try await store.current()
        let departures = timetable.departures(from: originID, to: destinationID, after: after, limit: limit, calendar: calendar)

        var notice: String?
        if let range = timetable.validRange, DateKey.key(for: after, calendar: calendar) > range.upperBound {
            notice = "The timetable has expired. Refresh it in Settings."
        }
        return TransitSnapshot(departures: departures, source: .timetable, fetchedAt: timetable.downloadedAt, notice: notice)
    }
}

/// Uses `primary` and falls back to `fallback` when it fails, flagging the snapshot.
public struct FallbackTransitProvider: TransitProvider {
    private let primary: TransitProvider
    private let fallback: TransitProvider
    private let notice: String

    public init(primary: TransitProvider, fallback: TransitProvider, notice: String) {
        self.primary = primary
        self.fallback = fallback
        self.notice = notice
    }

    public func departures(fromStation originID: String, toStation destinationID: String, after: Date, limit: Int) async throws -> TransitSnapshot {
        do {
            return try await primary.departures(fromStation: originID, toStation: destinationID, after: after, limit: limit)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var snapshot = try await fallback.departures(fromStation: originID, toStation: destinationID, after: after, limit: limit)
            snapshot.notice = notice
            return snapshot
        }
    }
}
