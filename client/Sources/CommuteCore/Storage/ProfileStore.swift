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
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CommuteProfile.self, from: data)
    }

    public func saveProfile(_ profile: CommuteProfile) async {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }
}
