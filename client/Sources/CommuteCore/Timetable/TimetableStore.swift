import Foundation

/// Produces a fresh timetable, typically by downloading a GTFS feed.
public protocol TimetableSource: Sendable {
    func fetchTimetable() async throws -> Timetable
}

public enum TimetableSourceError: Error, Equatable {
    case badStatus(Int)
}

/// Downloads and parses Caltrain's published GTFS feed. No API key needed.
public struct GTFSTimetableSource: TimetableSource {
    public static let caltrainFeedURL = URL(string: "https://data.trilliumtransit.com/gtfs/caltrain-ca-us/caltrain-ca-us.zip")!

    private let url: URL
    private let session: URLSession

    public init(url: URL = Self.caltrainFeedURL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func fetchTimetable() async throws -> Timetable {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TimetableSourceError.badStatus(http.statusCode)
        }
        return try GTFSParser.parse(archive: ZipArchive(data: data), downloadedAt: Date())
    }
}

public struct TimetableInfo: Equatable, Sendable {
    public var downloadedAt: Date
    public var feedVersion: String?
    public var validFrom: Date?
    public var validUntil: Date?
    public var tripCount: Int

    init(_ timetable: Timetable) {
        downloadedAt = timetable.downloadedAt
        feedVersion = timetable.feedVersion
        validFrom = timetable.validRange.flatMap { DateKey.date(for: $0.lowerBound) }
        validUntil = timetable.validRange.flatMap { DateKey.date(for: $0.upperBound) }
        tripCount = timetable.trips.count
    }
}

/// Keeps one timetable in memory and on disk. Downloads only when nothing is cached
/// or when asked to refresh.
public actor TimetableStore {
    private let source: TimetableSource
    private let cacheURL: URL?
    private var timetable: Timetable?
    private var didReadCache = false
    private var download: Task<Timetable, Error>?

    public init(source: TimetableSource, cacheURL: URL? = TimetableStore.defaultCacheURL) {
        self.source = source
        self.cacheURL = cacheURL
    }

    public static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Commute", directoryHint: .isDirectory)
            .appending(path: "caltrain-timetable.json")
    }

    /// The cached timetable, downloading it the first time.
    public func current() async throws -> Timetable {
        if let cached = cachedTimetable() {
            return cached
        }
        return try await downloadOnce()
    }

    /// Downloads a fresh timetable and replaces the cache.
    @discardableResult
    public func refresh() async throws -> TimetableInfo {
        TimetableInfo(try await downloadOnce())
    }

    /// The schedule running on `date`'s service day, from the cache; never downloads.
    public func scheduleDay(for date: Date) -> ScheduleDay? {
        cachedTimetable()?.scheduleDay(for: date)
    }

    /// What is cached, without downloading.
    public func info() -> TimetableInfo? {
        cachedTimetable().map(TimetableInfo.init)
    }

    private func cachedTimetable() -> Timetable? {
        if timetable == nil, !didReadCache {
            didReadCache = true
            timetable = readCache()
        }
        return timetable
    }

    /// Concurrent callers share one download.
    private func downloadOnce() async throws -> Timetable {
        if let download {
            return try await download.value
        }
        let task = Task { [source] in try await source.fetchTimetable() }
        download = task
        defer { download = nil }
        let fresh = try await task.value
        timetable = fresh
        writeCache(fresh)
        return fresh
    }

    private func readCache() -> Timetable? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(Timetable.self, from: data),
              cached.schemaVersion == Timetable.currentSchemaVersion else { return nil }
        return cached
    }

    private func writeCache(_ timetable: Timetable) {
        guard let cacheURL, let data = try? JSONEncoder().encode(timetable) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
