# Publishing a set: gate, manifest, heartbeat, source archive

What `bikeride-data gate` and `bikeride-data manifest` read and write (`Sources/BRBuild/Publish/`).
The artifact formats themselves are in `formats.md`.

## Order: `bikeride-data all`

`streets → timetables → stations → config → links → flows → gate → manifest → heartbeat`, the
only valid order (`Pipeline`, `PipelineStep` in `Sources/BRBuild/Publish/Pipeline.swift`; `all`
runs each step's command). Config is built after the `tt-*` and `stations` its reference checks
read and before links, which is built from it and names it in `builtAgainst`; flows depends on
nothing (its `builtAgainst` is empty). The gate runs before the manifest because a soft failure
changes `systems.<s>.status`; the heartbeat is written last.

`--skip LIST` takes any of the nine names and reuses what is in `--out`. Skipping `manifest` also
skips `heartbeat` (the heartbeat names the manifest this run writes); skipping `timetables` passes
`--timetables-not-run`, so `lastTimetableSuccessAt` carries over from the heartbeat beside
`--previous` or, without `--previous`, from the last one in `--out`. With `--no-xz` there are no
blobs to publish, so `gate`, `manifest` and `heartbeat` are skipped. To build without publishing
(a fixture built around pinned artifacts: a pinned `streets.bin` has no `reports/streets.json` to
vouch for it, so the gate fails), skip `gate,manifest`; `--skip gate` alone leaves the manifest
without a gate report for these files (exit 3). `--today` and `--now` go to every step that takes
them (the manifest and heartbeat share one timestamp); `--previous FILE` goes to `gate` and
`manifest`; `--trips` and `--months` to `flows`; `--config-sources` to `config`, which `all` always
runs with `--require-references`.

Before its first step `all` moves `manifest.json`, `trip-counts.json` and `heartbeat.json` from
`--out` to `<out>/../work/published-before/` (`Pipeline.retirePublished`). They describe the set that
was there, not the files this run writes, so a run that stops (a gate hard failure, a config
failure) leaves no published documents beside artifacts they do not describe; a run that publishes
writes new ones. `--previous` may be `<out>/manifest.json`, the set in place: it is read where it
was moved. Any other file in `--out` cannot be `--previous` (its sidecar would move from under it;
exit 64).

| Step | Exit status | `all` |
|---|---|---|
| `streets` | 2: a sanity route failed | warning; go on (the artifact is written, the gate checks the set) |
| `config` | 3: a reference check failed (no config.bin); 1: a source or build error | stop: links cannot be built |
| `flows` | 4: nothing new, or offline without the listing, a zip or GBFS | warning; go on with the flows.bin in place, if any |
| `flows` | 3: the flows build's own gate failed (flows.bin and `reports/flows.json` kept, the failed build's report in `reports/flows-failed.json`) | warning; go on: the gate's `flows` check decides (below) |
| `flows` | 1: an error (a download, GBFS, the holiday calendar; nothing written) | warning; go on as for 3. With `--require-flows`: stop with 1 |
| `gate` | 3: a hard failure | stop with 3: no manifest and no heartbeat, so the previous set stays current |
| `manifest` | 3: no passing gate report for these bytes | stop with 3 |
| any | any other failure | stop with that status |

Flows is optional and fails soft: without trip data (`flows` exit 4 and no flows.bin) the set
publishes without it, with a warning in the gate's `flows` check. A flows build whose own gate
fails keeps the older flows.bin and its `reports/flows.json`, and writes its own report to
`reports/flows-failed.json` (`FlowsReport.record(at:)`); a build that passes replaces the report and
removes that file. The gate then checks the older flows.bin against its report, as on the day it
was built, and lets it go out again with the failed build as a warning, every run until a build
passes. `--require-flows` (on `all`, `gate` and `manifest`) makes a set without flows.bin fail the
`artifacts` check and the manifest refuse it, and makes a flows error stop `all`.

`manifest` itself refuses (exit 3) unless `reports/gate.json` passed, or failed only soft, on
exactly the raw files and `.xz` blobs in the data directory, for the same build day and previous
manifest. `gate` deletes any earlier `reports/gate.json` before it reads anything, so a gate run
that stops with an error leaves no report for `manifest` to take. `manifest --no-heartbeat` writes
the manifest only (`all` writes the heartbeat as its own step).

## `reports/gate.json` (`GateReport`)

`{schema, generatedAt, tool, buildDay (YYYYMMDD), status: pass|softFail|fail, artifacts: {name:
rawSha256}, blobs: {name: sha256 of the .xz}, carriedForward: [name], previousSetId?, systems: {subway|bus|lirr|ferry|path: {status:
ok|noSchedule, coverageDays, dates, first, last}}, checks: [{name, status: pass|softFail|fail|skipped,
summary, failures, warnings, notes, metrics, seconds}]}`, pretty-printed.

Checks, in order:

| Check | Rule | On failure |
|---|---|---|
| `artifacts` | every core kind (streets, stations, the five `tt-*`, config, links; flows too with `--require-flows`) is in the data directory or carried forward; each file opens with its reader (`MappedConfig`, and `MappedFlows` validated, included); a carried-forward entry's `formatVersion` is one its kind's readers support (a format-0 draft carried from an older set fails: rebuild it); every `builtAgainst` entry, of fresh and carried artifacts alike, equals the set's rawSha256 of that input | hard |
| `xz` | each blob is 1 stream / 1 block (`XZCheck`) and `xz -dc` gives the raw size and rawSha256 | hard |
| `coverage` | consecutive covered days from the build day ≥ `coverage.minDays` (3) | soft: `noSchedule`, real dates kept |
| `tripCounts` | active trips per date within ±`maxChangePercent` (35 %) of the previous build: same date, else the weekday median (holidays excluded), else for a holiday the nearest of its weekday / Saturday / Sunday medians; skipped without `--previous`; with `--previous`, a manifest that does not read or a sidecar that is missing or does not match fails (an unreadable manifest fails `artifacts` too) | hard |
| `streets` | each region's `keptShare` in `reports/streets.json` (which must describe this `streets.bin`) ≥ its minimum; a region with no street length at all fails (the report gives it 100 %); skipped when streets is carried forward | hard |
| `snapping` | every routable stop inside the service area has street entry and exit, and every access point snaps within `maxSnapMeters` (100 m), except as `snap-allowlist.csv` allows; no routable stop, or none inside the service area, fails; a `links.bin` in the data directory needs its `streets.bin` there too (else fail), and a carried-forward `tt-*` leaves that system's stops unchecked with a warning; skipped only when links is carried forward | hard |
| `configReferences` | `ReferenceChecks` over the set's `config.bin`, `tt-*` and `stations` (`ConfigReferencesCheck`): every LIRR stop with service has a fare zone and every NYC terminal is served (`lirrZones`); the MTA out-of-system and in-system pairs name subway stations and no in-system pair is in `transfers.txt` (`mtaStationPairs`); the SIR routes and fare stations exist (`statenIslandRailway`); every fixed transfer resolves (`fixedTransfers`); every valet station is in `stations.bin` within 50 m of its listed coordinate (`valetStations`); every station's region is configured (`stationRegions`). Run on every build, because `tt-*` change twice a day and config only with `Data/`. A config carried forward cannot be read: if any `tt-*` or `stations` is new the check fails (a job that rebuilds them keeps `config.bin` and `config.bin.xz` in its data directory; a raw file without its blob fails `xz` and the manifest), otherwise it is skipped. A check whose input is carried forward is skipped with a warning | hard |
| `flows` | the flows statistics (`FlowsStatisticsCheck`): a flows.bin in the data directory must be the one `reports/flows.json` describes (outcome `built`, same rawSha256), and the report must pass `FlowsGate` again (unmatched trip ends under 2 % in the newest month and 5 % over the window, per system and side; dropped ends, empty days, saturated counters, month rows). A flows.bin no report vouches for fails, unless it is the previous set's, unchanged: then skipped. After `flows` exit 3 the older file is still the one `reports/flows.json` describes, so it passes, with `reports/flows-failed.json` as a warning (a `flows.json` that is itself gate-failed, from a builder before that file, vouches for nothing). Without flows.bin: carried forward, skipped; absent, skipped with a warning | hard |

`configReferences` and `flows` join through the `GateCheck` protocol (`Gate.publishHooks`), which
`bikeride-data gate` and `all` always pass; `Gate` itself runs only the built-in six, so a test set
whose config does not describe its timetables can still be gated. The Citi Bike price drift warning
stays in the config build (the gate has no GBFS pricing plans).

Thresholds and the allowlist: `Data/gate/` (see its `SOURCES.md`); holidays:
`Data/config/calendar/holidays.csv`.

## `data/manifest.json` (`SetManifest`)

Compact JSON, keys sorted. The app fetches it through the relay every 60 s; the relay's
`/v1/health/data` reads `coverage`.

```
{"schema": 1,
 "setId": "3b0f7ece25409da6",            // first 16 hex of sha256 over sorted "<name>\t<sha>\n"
 "generatedAt": "2026-09-26T16:31:00Z", "tool": "bikeride-data 0.1.0 (Swift 6.4)",
 "buildDay": "20260926", "previousSetId": "…" (absent for a first set), "carriedForward": [name],
 "artifacts": {"<name>": {"sha", "bytes", "rawBytes", "rawSha256", "formatVersion", "dataVersion", "builtAgainst"}},
 "coverage": {"subway": ["2026-09-25", …], "bus": […], "lirr": […], "ferry": […], "path": […]},
 "systems": {"<system>": {"artifact": "tt-subway", "first", "last", "dates", "days", "status": "ok|noSchedule"}},
 "sources": {"<tt-name>": [{"name", "feed", "etag", "feedVersion", "datesSelected", "firstSelected", "lastSelected"}]},
 "gate": {"status", "checks": [{"name", "status", "warnings": count}]},
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
- `gate` publishes each check's status and warning count only; the text (which can name local
  paths) stays in `reports/gate.json`.
- `--previous` carries forward the kinds the data directory lacks (a job that did not rebuild
  them): their artifact entries, coverage, sources and trip counts. Everything, fresh or carried,
  must match what it was built against, or the manifest is refused.

## `data/trip-counts.json` (`TripCountSidecar`)

`{schema: 1, setId, buildDay, systems: {"<system>": {"YYYY-MM-DD": activeTrips}}}`, next to the
manifest, which records its SHA-256. Only the next build's gate reads it (as `--previous`'s
sidecar); it stays out of the manifest the app polls. A sidecar that is missing or does not match
its manifest's record or `setId` fails the next gate and makes `manifest --previous` refuse: a
check that quietly turned itself off, and a sidecar without the counts of the carried-forward
systems, would leave the build after that with nothing to compare either.

## `data/heartbeat.json` (`SetHeartbeat`)

`{checkedAt, lastTimetableSuccessAt, setId, job, result: "built"}`, written last. The relay fails
health past 30 h (`checkedAt`) and 16 h (`lastTimetableSuccessAt`). `lastTimetableSuccessAt` is the
run's time when at least one `tt-*` is in the data directory (not carried forward), and otherwise
carries over from the previous heartbeat, so a job that carries all five forward (flows only)
cannot reset it by forgetting a flag. `--timetables-unchanged` (the timetables job found its sources
unchanged and carried all five) makes it the run's time; `--timetables-not-run` (`tt-*` files in
the data directory that this job did not build) makes it carry over.

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
