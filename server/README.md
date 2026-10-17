# Commute server (planned)

A Python service for the homelab (`c1mm02`, Docker Compose) that will:

- load the Caltrain GTFS timetable and 511.org GTFS-realtime delays
- follow the same get ready → leave now → too late → next train rules as the app
  (`client/Sources/CommuteCore/Planning/CommutePlanner.swift`)
- send push notifications through ntfy
- serve a small JSON API the iOS app reads instead of `SampleTransitProvider`

Nothing is implemented yet. Station ids (`StationCatalog`) and train types (`TrainService`
raw values) in the client are the GTFS ids and wire values the server should use.
