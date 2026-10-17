import Foundation

public struct Station: Codable, Hashable, Identifiable, Sendable {
    /// GTFS parent-station id, shared with the server and the 511 feeds.
    public let id: String
    public let name: String
    public let coordinate: Coordinate

    public init(id: String, name: String, coordinate: Coordinate) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
}

/// Caltrain stations ordered north to south, from the Caltrain GTFS feed.
public enum StationCatalog {
    public static let all: [Station] = [
        station("san_francisco", "San Francisco", 37.776404, -122.394911),
        station("22nd_street", "22nd Street", 37.756972, -122.392492),
        station("bayshore", "Bayshore", 37.70766, -122.401665),
        station("south_sf", "South San Francisco", 37.655941, -122.404979),
        station("san_bruno", "San Bruno", 37.630460, -122.411709),
        station("place_MLBR", "Millbrae", 37.5999, -122.38675),
        station("broadway", "Broadway", 37.58726, -122.362),
        station("burlingame", "Burlingame", 37.57985, -122.34418),
        station("san_mateo", "San Mateo", 37.56824, -122.3239),
        station("hayward_park", "Hayward Park", 37.553161, -122.309494),
        station("hillsdale", "Hillsdale", 37.542393, -122.301612),
        station("belmont", "Belmont", 37.52133, -122.2763),
        station("san_carlos", "San Carlos", 37.508033, -122.2602),
        station("redwood_city", "Redwood City", 37.485865, -122.2315),
        station("menlo_park", "Menlo Park", 37.4548, -122.18245),
        station("palo_alto", "Palo Alto", 37.44322, -122.16429),
        station("stanford", "Stanford", 37.43895, -122.15715),
        station("california_ave", "California Avenue", 37.428834, -122.14113),
        station("san_antonio", "San Antonio", 37.407239, -122.107116),
        station("mountain_view", "Mountain View", 37.395067, -122.07722),
        station("sunnyvale", "Sunnyvale", 37.378934, -122.0315),
        station("lawrence", "Lawrence", 37.3707, -121.9969),
        station("santa_clara", "Santa Clara", 37.353384, -121.936465),
        station("college_park", "College Park", 37.34289, -121.91565),
        station("sj_diridon", "San Jose Diridon", 37.329694, -121.903208),
        station("tamien", "Tamien", 37.31269, -121.8847),
        station("capitol", "Capitol", 37.284016, -121.841899),
        station("blossom_hill", "Blossom Hill", 37.252606, -121.797907),
        station("morgan_hill", "Morgan Hill", 37.129644, -121.650558),
        station("san_martin", "San Martin", 37.085984, -121.61048),
        station("gilroy", "Gilroy", 37.004466, -121.566727)
    ]

    public static func station(id: String) -> Station? {
        all.first { $0.id == id }
    }

    /// Position along the line, 0 = San Francisco.
    public static func index(of id: String) -> Int? {
        all.firstIndex { $0.id == id }
    }

    /// Stations without regular service: Stanford only opens for football game days.
    public static let specialServiceOnly: Set<String> = ["stanford"]

    /// The nearest station with regular service, for suggesting one from an address.
    public static func nearest(to coordinate: Coordinate) -> Station {
        all.filter { !specialServiceOnly.contains($0.id) }
            .min { $0.coordinate.distance(to: coordinate) < $1.coordinate.distance(to: coordinate) } ?? all[0]
    }

    private static func station(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
        Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
    }
}
