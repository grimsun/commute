import Foundation

/// Remembers commutes the rider left for (and on which train), so their alerts stay quiet.
public actor DepartureLog {
    private let defaults: UserDefaults
    private let key: String
    private var trainsKey: String { key + ".trains" }
    private var endedKey: String { key + ".ended" }

    public init(suiteName: String? = nil, key: String = "commute.departed.v1") {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    /// Train numbers the rider said they took, by commute.
    public func trainNumbers(since day: Int) -> [CommuteKey: String] {
        var result: [CommuteKey: String] = [:]
        for key in departed(since: day) {
            if let number = loadTrains()[key.identifier] {
                result[key] = number
            }
        }
        return result
    }

    public func departed(since day: Int) -> Set<CommuteKey> {
        Set(load().filter { $0.day >= day })
    }

    /// `trainNumber` records which train, when known.
    public func markDeparted(_ commute: CommuteKey, trainNumber: String? = nil) {
        // Entries older than a week are dropped so the list stays small.
        let cutoff = commute.day - 7
        var entries = load().filter { $0.day >= cutoff }
        entries.insert(commute)
        save(entries)
        var ended = load(endedKey)
        if ended.remove(commute) != nil {
            save(ended, key: endedKey)
        }
        var trains = loadTrains().filter { id, _ in entries.contains { $0.identifier == id } }
        trains[commute.identifier] = trainNumber
        defaults.set(trains, forKey: trainsKey)
    }

    /// Trips the rider ended by hand ("End trip"); location shouldn't start them again.
    public func ended(since day: Int) -> Set<CommuteKey> {
        Set(load(endedKey).filter { $0.day >= day })
    }

    /// Undoes `markDeparted` and remembers the trip as ended by hand.
    public func markEnded(_ commute: CommuteKey) {
        clear(commute)
        var entries = load(endedKey).filter { $0.day >= commute.day - 7 }
        entries.insert(commute)
        save(entries, key: endedKey)
    }

    /// Undoes `markDeparted`, e.g. when the rider isn't taking that trip after all.
    public func clear(_ commute: CommuteKey) {
        var entries = load()
        entries.remove(commute)
        save(entries)
        var trains = loadTrains()
        trains[commute.identifier] = nil
        defaults.set(trains, forKey: trainsKey)
    }

    private func save(_ entries: Set<CommuteKey>, key: String? = nil) {
        if let data = try? JSONEncoder().encode(Array(entries)) {
            defaults.set(data, forKey: key ?? self.key)
        }
    }

    private func loadTrains() -> [String: String] {
        defaults.dictionary(forKey: trainsKey) as? [String: String] ?? [:]
    }

    private func load(_ key: String? = nil) -> Set<CommuteKey> {
        guard let data = defaults.data(forKey: key ?? self.key),
              let entries = try? JSONDecoder().decode([CommuteKey].self, from: data) else { return [] }
        return Set(entries)
    }
}
