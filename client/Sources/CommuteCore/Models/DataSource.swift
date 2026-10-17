import Foundation

/// Where the app gets trains and who sends leave alerts.
public enum DataMode: String, Codable, CaseIterable, Sendable {
    /// Caltrain timetable downloaded to the phone; the app schedules its own alerts.
    case standalone
    /// A Commute server provides realtime trains and sends push notifications.
    case server
}

public struct DataSourceSettings: Codable, Equatable, Sendable {
    public var mode: DataMode
    /// Kept while in standalone mode so switching back does not lose it.
    public var serverURL: String

    public init(mode: DataMode = .standalone, serverURL: String = "") {
        self.mode = mode
        self.serverURL = serverURL
    }

    /// The server base URL, if the text is a usable http(s) URL.
    public var parsedServerURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
