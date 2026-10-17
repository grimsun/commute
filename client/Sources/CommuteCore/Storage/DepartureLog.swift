import Foundation

/// Remembers commutes the rider said they already left for, so their alerts stay quiet.
public actor DepartureLog {
    private let defaults: UserDefaults
    private let key: String

    public init(suiteName: String? = nil, key: String = "commute.departed.v1") {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    public func departed(since day: Int) -> Set<CommuteKey> {
        Set(load().filter { $0.day >= day })
    }

    public func markDeparted(_ commute: CommuteKey) {
        // Entries older than a week are dropped so the list stays small.
        let cutoff = commute.day - 7
        var entries = load().filter { $0.day >= cutoff }
        entries.insert(commute)
        if let data = try? JSONEncoder().encode(Array(entries)) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() -> Set<CommuteKey> {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([CommuteKey].self, from: data) else { return [] }
        return Set(entries)
    }
}
