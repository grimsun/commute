import Foundation

public protocol CommuteProfileStore: Sendable {
    func loadProfile() async -> CommuteProfile?
    func saveProfile(_ profile: CommuteProfile) async
}

public actor InMemoryProfileStore: CommuteProfileStore {
    private var profile: CommuteProfile?

    public init(profile: CommuteProfile? = nil) {
        self.profile = profile
    }

    public func loadProfile() async -> CommuteProfile? {
        profile
    }

    public func saveProfile(_ profile: CommuteProfile) async {
        self.profile = profile
    }
}

/// Persists the profile as JSON in `UserDefaults` so settings survive relaunches.
public actor UserDefaultsProfileStore: CommuteProfileStore {
    private let defaults: UserDefaults
    private let key: String

    public init(suiteName: String? = nil, key: String = "commute.profile.v2") {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    public func loadProfile() async -> CommuteProfile? {
        Self.decode(defaults.data(forKey: key))
    }

    /// The saved profile, read right away: at launch, so the first frame already has the
    /// rider's appearance rather than switching to it once `loadProfile()` returns.
    public nonisolated static func savedProfile(key: String = "commute.profile.v2") -> CommuteProfile? {
        decode(UserDefaults.standard.data(forKey: key))
    }

    private static func decode(_ data: Data?) -> CommuteProfile? {
        data.flatMap { try? JSONDecoder().decode(CommuteProfile.self, from: $0) }
    }

    public func saveProfile(_ profile: CommuteProfile) async {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }
}
