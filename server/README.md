# Commute server (planned)

An optional Python service, packaged to run anywhere with Docker. The app works without it
(standalone mode, Caltrain timetable on the phone). With it, the app gets:

- realtime delays and cancellations from 511.org GTFS-realtime
- push notifications through ntfy that follow delays (the app stops scheduling its own)

The server should apply the same get ready → leave now → too late → next train rules as
`client/Sources/CommuteCore/Planning/CommutePlanner.swift`.

Nothing is implemented yet. The client already speaks the API below
(`ServerTransitProvider`), so the server only has to match it.

## API v1

All times are ISO 8601 with a zone. Station ids are Caltrain GTFS parent-station ids
(`san_francisco`, `palo_alto`, `place_MLBR`, … see `StationCatalog`).

### `GET /v1/health`

```json
{ "status": "ok", "version": "0.1.0" }
```

Settings → Test connection calls this.

### `GET /v1/departures?from=<station>&to=<station>&after=<iso8601>&limit=<n>`

Trains that stop at `from` and later at `to`, departing at or after `after`.
Include cancelled trains with `isCancelled: true`.

```json
{
  "fetchedAt": "2026-10-19T15:02:10Z",
  "departures": [
    {
      "tripID": "20261019-408",
      "trainNumber": "408",
      "service": "limited",
      "scheduledDeparture": "2026-10-19T14:48:00Z",
      "scheduledArrival": "2026-10-19T15:29:00Z",
      "delaySeconds": 180,
      "isCancelled": false,
      "platform": null
    }
  ]
}
```

`service` is one of `local`, `limited`, `express`, `southCounty` (from GTFS
`route_short_name`: "Local Weekday"/"Local Weekend" → `local`, and so on).

If the server is unreachable or answers with an error, the app falls back to its own timetable
and shows a notice.
