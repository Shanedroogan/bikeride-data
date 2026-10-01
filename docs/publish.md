# Publishing a set: gate, manifest, heartbeat, source archive, R2

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
runs with `--require-references`. `--job NAME` (`all`, the default, or the workflow jobs
`timetables`, `streets`, `flows`) is recorded as the heartbeat's `job`; anything else is a usage
error (64), on `manifest --job` too. `--accept-trip-count-change LIST` (systems, comma-separated, no
spaces, as strict as the workflow's check) is passed to `gate`: see `tripCounts` below.
`--strict-sources` is passed to `timetables`, where it makes "built without entrances" an error:
with neither a fresh download nor a usable cached `<sources>/nyc/subway-entrances.csv` (an empty
one counts as none), the subway is not built and the run stops. CI passes it. A download whose
body has no usable rows (data.ny.gov answering 200 with an empty export or a changed header) is
refused before it is saved, so the cached copy is kept and used, as for a failed download.
`--cached-extracts` is passed to `streets`: when a Geofabrik extract's `-latest` and both dated
copies fail, the extract already in `--sources` is used instead of stopping the run. Only the Mac
fallback passes it (with a seeded `--sources`); data-build restores the last published streets.

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
rawSha256}, blobs: {name: sha256 of the .xz}, carriedForward: [name], previousSetId?, acceptedTripCountChange?: [system], systems: {subway|bus|lirr|ferry|path: {status:
ok|noSchedule, coverageDays, dates, first, last}}, checks: [{name, status: pass|softFail|fail|skipped,
summary, failures, warnings, notes, metrics, seconds}]}`, pretty-printed.

Checks, in order:

| Check | Rule | On failure |
|---|---|---|
| `artifacts` | every core kind (streets, stations, the five `tt-*`, config, links; flows too with `--require-flows`) is in the data directory or carried forward; each file opens with its reader (`MappedConfig`, and `MappedFlows` validated, included); a carried-forward entry's `formatVersion` is one its kind's readers support (a format-0 draft carried from an older set fails: rebuild it); every `builtAgainst` entry, of fresh and carried artifacts alike, equals the set's rawSha256 of that input | hard |
| `xz` | each blob is 1 stream / 1 block (`XZCheck`) and `xz -dc` gives the raw size and rawSha256 | hard |
| `coverage` | consecutive covered days from the build day ≥ `coverage.minDays` (3) | soft: `noSchedule`, real dates kept |
| `tripCounts` | active trips per date within ±`maxChangePercent` (35 %) of the previous build: same date, else the weekday median (holidays excluded), else for a holiday the nearest of its weekday / Saturday / Sunday medians; skipped without `--previous`, and when no `tt-*` is new (a flows-only set); with `--previous`, a manifest that does not read or a sidecar that is missing or does not match fails (an unreadable manifest fails `artifacts` too). `--accept-trip-count-change LIST`: a listed system's dates beyond the limit are warnings (`accepted: …`, counted in `<system>.acceptedDates`) instead of failures, except a drop of more than `maxAcceptedDropPercent` (90 %, to no trips included), which still fails (a broken or truncated feed, not a reviewed pick; rises are not bounded), and the list is recorded as `acceptedTripCountChange`; a listed system with nothing to accept is a warning; it never covers an unusable previous build | hard, unless accepted |
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

Compact JSON, keys sorted. The relay serves it at `/v1/data/manifest.json` from a 60 s edge cache
(per colo, with a last-good copy), and its `/v1/health/data` reads `coverage`. The app fetches it
through the relay on a cold launch, on returning to the foreground more than 2 h after the last
check, and from a background refresh scheduled about 45 min after each publish slot; never on a
timer.

```
{"schema": 1,
 "setId": "3b0f7ece25409da6",            // first 16 hex of sha256 over sorted "<name>\t<sha>\n"
 "generatedAt": "2026-09-26T16:31:00Z", "minAppFormat": 1, "tool": "bikeride-data 0.1.0 (Swift 6.4)",
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
- `minAppFormat` mirrors the set's config (`config/app.json`): from `config.bin` when the data
  directory has it, else the previous manifest's, carried with the config. The app compares it
  with its own engine level and refuses a set it must not apply before downloading anything. A
  carried config whose previous manifest has no `minAppFormat` (written before the mirror) makes
  the manifest refuse (exit 1): rebuild config.
- `--previous` carries forward the kinds the data directory lacks (a job that did not rebuild
  them): their artifact entries, coverage, sources and trip counts. Everything, fresh or carried,
  must match what it was built against, or the manifest is refused.

## The trip-count sidecar (`TripCountSidecar`)

`{schema: 1, setId, buildDay, systems: {"<system>": {"YYYY-MM-DD": activeTrips}}}`. Locally it is
`trip-counts.json` next to the manifest, which records its SHA-256 (`tripCounts.file`,
`tripCounts.sha256`); in R2 it is content-addressed, `data/trip-counts/<sha256>.json`, and restored
by that sha256 into `prev/trip-counts.json` beside the previous manifest. Only the next build's gate reads it (as `--previous`'s
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

## R2 (M4)

The design of record for publishing to R2 (the private repository's `docs/plans/m4-plan.md`). As of
M4 S0, `scripts/r2.sh` is complete and tested; `restore-state.sh`, `publish-set.sh`,
`sync-sources.sh`, `gc-data.sh`, `publish-local.sh` and `rollback.sh` parse their arguments and
stop with 69 before any R2 call, and `.github/workflows/data-build.yml` is a skeleton around them.
M4 lane Q writes their bodies.

### Keys

`data/` and `sources/` are meant for a bucket of their own, `bike-ride-data`, with a token scoped
to it (open question 16); `private/flows/` stays in `bike-ride`. Without the split, all of it shares
`bike-ride` with `history/` and `fixtures/`, and the `r2.sh` allowlist is the only guard.

| Key | Writer | Content | Retention |
|---|---|---|---|
| `data/blobs/<sha256 of the .xz>.xz` | `publish-set.sh` | The artifacts' blobs, content-addressed; locally built ones are always PUT | GC only |
| `data/manifests/<YYYYMMDDTHHMMSSZ>-<setId>.json` | `publish-set.sh` | An immutable copy of each published manifest; every retained one is a GC root | The newest 7, plus 30 days |
| `data/trip-counts/<sha256>.json` | `publish-set.sh` | The sidecar the next gate reads; the relay never serves it | While a retained manifest names it |
| `data/manifest.json` | `publish-set.sh` | The current set | Overwritten |
| `data/heartbeat.json` | `publish-set.sh` | Written last by every successful run | Overwritten |
| `data/hold.json` | `rollback.sh`, or by hand | `{reason, until}`: publishing paused | Removed by hand, or at `until` |
| `sources/<feed>/<key>.{zip,json}` | data-build | The GTFS source archive (above) | The build's prune, plus `calendarEnd < today − 30` |
| `sources/aux/{subway-entrances.csv,borough-boundaries.geojson}` | data-build | The last good copy of each | Overwritten |
| `private/flows/reports/<rawSha256>.json` | the private `flows.yml` | `reports/flows.json` of each published flows build | 400 days |
| `private/flows/sources/station_information-<last_updated>.json` | the private `flows.yml` | The GBFS input of that build | 400 days |

`history/` and `fixtures/` belong to the private repository's jobs; nothing here touches them.

### `scripts/r2.sh`

Every R2 call of these scripts goes through it, on the pinned AWS CLI 2.27.0 (`--endpoint-url
https://<account>.r2.cloudflarestorage.com --region auto`):

- Keys and list prefixes must be under `data/` or `sources/`, or `private/flows/` with
  `R2_ALLOW_PRIVATE_FLOWS=1` (the private caller). `history/` and `fixtures/` are refused by name
  first. Keys are plain (`[A-Za-z0-9._/-]`, no empty, `.` or `..` segment), and a list needs a
  prefix: there is no listing of the whole bucket.
- The CLI's stderr goes to a private temp file that is never printed (AWS error text names keys,
  and debug output holds signed URLs); a failure prints one fixed line with the exit status.
- Not found (10) is told apart from access denied (11) and every other failure (12). A 404 on
  `data/manifest.json` means a first run; a 403 or a 5xx is never taken for "not there".
- Uploads are `s3api put-object --content-md5`, never `s3 cp`, which goes multipart above 8 MB
  (tt-bus is 8.35 MB) and has no whole-object MD5; each is followed by a HEAD that compares
  `ContentLength`.
- `R2_DRY_RUN=1` prints put and delete instead of doing them.

`scripts/test/r2-test.sh` runs it against `scripts/test/fake-aws`, a stand-in CLI that serves a
local directory as the bucket, records each call and injects failures in the CLI's own error
shapes, printing the key pair and a signed URL each time; the test checks none reaches the output.

### `data-build.yml`

Dispatched only by cron-job.org (`workflow_dispatch`; no `schedule:`): `timetables` at 03:15 and
13:00, `streets` Sundays at 05:00, America/New_York; `gc` by hand. Inputs: `job`
(`timetables|streets|gc`), `dry_run` (default true), `accept_trip_count_change` (checked against
`^(subway|bus|lirr|ferry|path)(,(subway|bus|lirr|ferry|path))*$`). The R2 keys are in the
Environment `r2-publish`, restricted to `main` (so no other ref can run the workflow, dry run or
not), and reach only the steps that call R2; the
container is `swift:6.4-noble` pinned by digest; the build is retried 3 times (the SwiftPM
planner crash). One run at a time (`concurrency: data-publish`).

1. Check the inputs; install the tools and the AWS CLI; build `bikeride-data` (release).
2. `restore-state.sh`: the hold (while active: exit 0 with a summary line); `prev/manifest.json`,
   `prev/heartbeat.json`, `prev/trip-counts.json` (a 404 on the manifest is a first run, which CI
   refuses: the first set is published from the Mac; open: this also stops the plan's I1 dry runs
   on an empty bucket, see the TODO at the restore step); the `sources/` records still in use
   (`calendarEnd ≥ build day − 1`) and `sources/aux/` as the builder's cache; for `timetables`, the
   streets and stations blobs. No `flows.bin` may be in the data directory.
3. `all --previous prev/manifest.json --require-flows --strict-sources --job <job>` with `--skip
   streets,stations,flows` (timetables) or `--skip flows` (streets). Flows is always carried from
   the previous set: the public runner never sees trip data or `flows.bin`.
4. `sync-sources.sh upload`, add-only, on every real run that restored, even a failed one.
5. `publish-set.sh`: HEAD every blob the manifest names (carried ones too) and compare
   `ContentLength`; PUT the local blobs, the sidecar and the dated manifest; re-GET
   `data/manifest.json` and stop unless its setId is still the previous one (or it is still a 404
   on a first run); PUT `data/manifest.json`; PUT `data/heartbeat.json`, last.
6. `sync-sources.sh prune` and `gc-data.sh`, only after a publish succeeded (or `job=gc`).
7. The step summary: setIds, sizes, coverage, gate checks, "flows: carried from set <prev>"; no
   key outside `data/` and `sources/`.

### Failures

- A gate, config or manifest failure writes nothing; the previous set stays current.
- Two callers racing: the re-read guard stops the later one; its next run builds on the new set.
- A publish torn between PUTs leaves only orphan blobs, which GC removes after 48 h.
- A bad set: `rollback.sh <setId>` puts an earlier manifest back with a new `generatedAt` (the
  app takes only a strictly newer set) and writes `data/hold.json`.
- `tripCounts` beyond ±35 % stops the run unless a person dispatches with
  `accept_trip_count_change` (`all --accept-trip-count-change`; recorded in `gate.json` as
  `acceptedTripCountChange`, for the step summary).

### GC

After a successful publish, inside `data-publish`: re-read `data/manifest.json` and list
`data/manifests/`; the roots are the current manifest and every retained dated manifest; delete
blobs and sidecars no root names whose LastModified is over 48 h old, and the dated manifests
outside retention. It stops at the first list, GET or parse error, deletes at most 200 objects a
run, only under `data/`, and fails the run when `data/` is over 1.5 GB.
