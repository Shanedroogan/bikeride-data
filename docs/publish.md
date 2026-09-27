# Publishing a set: gate, manifest, heartbeat, source archive

What `bikeride-data gate` and `bikeride-data manifest` read and write (`Sources/BRBuild/Publish/`).
The artifact formats themselves are in `formats.md`.

## Order

`streets → timetables → stations → (config) → links → (flows) → gate → manifest → heartbeat`.
The gate runs before the manifest because a soft failure changes `systems.<s>.status`. A hard
failure (`gate` exits 3) writes no manifest and no heartbeat, so the previous set stays current;
`manifest` itself refuses (exit 3) unless `reports/gate.json` passed, or failed only soft, on
exactly the raw files and `.xz` blobs in the data directory, for the same build day and previous
manifest.

## `reports/gate.json` (`GateReport`)

`{schema, generatedAt, tool, buildDay (YYYYMMDD), status: pass|softFail|fail, artifacts: {name:
rawSha256}, blobs: {name: sha256 of the .xz}, carriedForward: [name], previousSetId?, systems: {subway|bus|lirr|ferry|path: {status:
ok|noSchedule, coverageDays, dates, first, last}}, checks: [{name, status: pass|softFail|fail|skipped,
summary, failures, warnings, notes, metrics, seconds}]}`, pretty-printed.

Checks, in order:

| Check | Rule | On failure |
|---|---|---|
| `artifacts` | every core kind (streets, stations, the five `tt-*`, links) is in the data directory or carried forward; each file opens with its reader; every `builtAgainst` entry, of fresh and carried artifacts alike, equals the set's rawSha256 of that input | hard |
| `xz` | each blob is 1 stream / 1 block (`XZCheck`) and `xz -dc` gives the raw size and rawSha256 | hard |
| `coverage` | consecutive covered days from the build day ≥ `coverage.minDays` (3) | soft: `noSchedule`, real dates kept |
| `tripCounts` | active trips per date within ±`maxChangePercent` (35 %) of the previous build: same date, else the weekday median (holidays excluded), else for a holiday the nearest of its weekday / Saturday / Sunday medians; skipped without a previous build | hard |
| `streets` | each region's `keptShare` in `reports/streets.json` (which must describe this `streets.bin`) ≥ its minimum; a region with no street length at all fails (the report gives it 100 %); skipped when streets is carried forward | hard |
| `snapping` | every routable stop inside the service area has street entry and exit, and every access point snaps within `maxSnapMeters` (100 m), except as `snap-allowlist.csv` allows; no routable stop, or none inside the service area, fails; a `links.bin` in the data directory needs its `streets.bin` there too (else fail), and a carried-forward `tt-*` leaves that system's stops unchecked with a warning; skipped only when links is carried forward | hard |
| hooks | `GateCheck` implementations passed in (config reference checks, flows statistics: M1 P2b) | as they report |

Thresholds and the allowlist: `Data/gate/` (see its `SOURCES.md`); holidays:
`Data/config/calendar/holidays.csv`.

## `data/manifest.json` (`SetManifest`)

Compact JSON, keys sorted. The app fetches it through the relay every 60 s; the relay's
`/v1/health/data` reads `coverage`.

```
{"schema": 1,
 "setId": "0aa63fb1eab73f1c",            // first 16 hex of sha256 over sorted "<name>\t<sha>\n"
 "generatedAt": "2026-09-26T16:31:00Z", "tool": "bikeride-data 0.1.0 (Swift 6.4)",
 "buildDay": "20260926", "previousSetId": "…" (absent for a first set), "carriedForward": [name],
 "artifacts": {"<name>": {"sha", "bytes", "rawBytes", "rawSha256", "formatVersion", "dataVersion", "builtAgainst"}},
 "coverage": {"subway": ["2026-09-25", …], "bus": […], "lirr": […], "ferry": […], "path": […]},
 "systems": {"<system>": {"artifact": "tt-subway", "first", "last", "dates", "days", "status": "ok|noSchedule"}},
 "sources": {"<tt-name>": [{"name", "feed", "etag", "feedVersion", "datesSelected", "firstSelected", "lastSelected"}]},
 "gate": {"status", "checks": [{"name", "status"}], "warnings": […]},
 "tripCounts": {"file": "trip-counts.json", "sha256": "…"}}
```

- `sha` is the SHA-256 of the `.xz` blob (its name under `data/blobs/`), `bytes` its size;
  `rawSha256` keyed by artifact name is what `TransitDataSet`'s `.known` check takes.
- `coverage` holds exactly the five systems, every covered date as `YYYY-MM-DD`: the relay treats
  every key there as a system. A `noSchedule` system keeps its real dates, so the relay's 503 on
  short coverage is the alert.
- `setId` depends only on the blobs, never on the time: rebuilding the same bytes gives the same
  set, and `generatedAt` is the only field that differs between two such runs.
- `sources` come from each timetable's own source table (not from the build report). An archived
  version is named `<feed>@<key8>`.
- `--previous` carries forward the kinds the data directory lacks (a job that did not rebuild
  them): their artifact entries, coverage, sources and trip counts. Everything, fresh or carried,
  must match what it was built against, or the manifest is refused.

## `data/trip-counts.json` (`TripCountSidecar`)

`{schema: 1, setId, buildDay, systems: {"<system>": {"YYYY-MM-DD": activeTrips}}}`, next to the
manifest, which records its SHA-256. Only the next build's gate reads it (as `--previous`'s
sidecar); it stays out of the manifest the app polls. A sidecar that does not match its manifest's
record or `setId` is ignored with a warning.

## `data/heartbeat.json` (`SetHeartbeat`)

`{checkedAt, lastTimetableSuccessAt, setId, job, result: "built"}`, written last. The relay fails
health past 30 h (`checkedAt`) and 16 h (`lastTimetableSuccessAt`). `lastTimetableSuccessAt` is the
run's time unless `--timetables-not-run`, when it carries over from the previous heartbeat.

## Source archive (`sources/gtfs/archive/`)

`<feed>/<key>.zip` + `<feed>/<key>.json` (`GTFSSourceArchive.Record`: feed, key, url, etag,
lastModified, sha256, bytes, archivedAt, coverage ranges, calendarStart, calendarEnd). `<key>` is
the ETag without `W/` and quotes, bytes outside `[A-Za-z0-9._-]` mapped to `_`, and never empty,
dot-led or over 96 characters (the zip's SHA-256 fills in); it is also the R2 key
`sources/<feed>/<key>.zip`. The fetcher adds the current zip before a download replaces it and the
new one after, deduplicated by SHA-256. The flat `sources/gtfs/<feed>.zip` stays the current
version. Archiving is best-effort: the download record is written first, and a version whose
calendar cannot be read (a malformed row, an HTML error page served with 200) is not archived but
logged as a build warning, so the next fetch still reaches the server; the build fails when it
parses that zip, as before the archive existed.

Each build passes every feed's current zip plus the archived versions that can still be selected
on some date of the window; the compiler then takes, per date, the newest version covering it
(Last-Modified order), never merging two. A version covered on every date by a newer one is never
selected; online builds delete it (offline builds only read the sources). This replaces "keep
until the calendar ends", which for the hourly supplemented subway feed would keep dozens of
unused 19 MB zips.
