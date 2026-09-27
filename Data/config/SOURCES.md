# Config sources

Reviewed inputs of the `config` artifact, besides the fares in `../fares/`. `bikeride-data
config` reads them strictly: an unknown or misspelled JSON key, a missing key, a wrong type, or a
CSV whose header is not exactly the one below fails the build. Keys and units: "config" in
`docs/formats.md`. Set-like lists may be in any order here; the compiler sorts them.

| File | Artifact key | Contents |
|---|---|---|
| `app.json` | `minAppFormat`, `flags` | App semantics level 1; no flags yet |
| `calendar/holidays.csv` | `calendar.holidays` | The single holiday list (its own `calendar/SOURCES.md`) |
| `calendar/lirr-off-peak.csv` | `calendar.holidays[].lirrOffPeak` | Holidays on which every LIRR train is off-peak |
| `transit.json` | `transit` (all but `links.fixedTransfers`) | Change times, slack, search bounds; the `links` build parameters |
| `fixed-transfers.csv` | `transit.links.fixedTransfers` | PATH↔subway walk minimums |
| `bikeshare/` | `bikeShare` | Its own `SOURCES.md` |
| `alerts/path-keywords.csv` | `alerts.pathKeywords` | PATH alert title keywords |

The values were transcribed on 2026-09-27 from the literals they replace (BikeRideKit
`RaptorConfig.swift`, `TransitPlanner.snapMeters`, `ServiceAlert.swift`; bikeride-data
`LinkNetwork.swift`), unchanged.

## transit.json

The plan's change-time table ("Change times and slack"): same stop subway 30 s, bus 60 s;
guaranteed LIRR pair 0 s; after a bike leg max(60 s, 10% of the ride); after walk access 30 s + 5%
of the walk. Same-parent-station changes come from each feed's `transfers.txt`, floored at
`minimumPlatformChangeSeconds` (30 s: 59 subway rows say 0 s).

**Not confirmed:** the same-stop change times for the **LIRR (180 s)**, the **ferry (60 s)** and
**PATH (30 s, like the subway)** are not in the plan's table; they are the engine's assumptions,
to be calibrated in M6. A stop-level self row in `transfers.txt` replaces the default for that
stop (LIRR Jamaica: 300 s; the only such LIRR row, M1 audit).

The other transit values: round-4 rule (a journey whose 4th leg is boarded must save more than
480 s over the best with fewer), 6 h journey horizon, 20 min walk trees, 60 min direct walk, 250 m
origin snap.

`links`: station access once per street↔platform transition (subway 120 s, bus 30 s, LIRR 240 s,
PATH 120 s from the plan; ferry 120 s assumed); access-point snap limits (150 m, ferry 250 m;
LIRR stops farther than 150 m from a street are ride-through only); an 8 min footpath walk bound;
30 s minimum in-station transfer; 350 m station links; walking at 3.5 mph; PATH stations outside
the service area (Newark, Harrison) get no street access. `links` bakes these in.

## calendar/lirr-off-peak.csv

`date,source_note`: one row per holiday on which every LIRR train is off-peak. Each date must be
in `calendar/holidays.csv` (the build fails otherwise); the compiler sets `lirrOffPeak` on those
holidays and clears it on the rest.

**Empty for now**: the LIRR's holiday fare rule has not been verified, and the engine applies no
holiday today (`LIRRPeakRule.holidays` is empty), so every weekday holiday is priced by the peak
windows. The effect is small: the rule only decides trains whose GTFS trip has no `peak_offpeak`
flag (301 of 2,089 v1 trips carry the peak flag; flagged trips follow the flag).

## fixed-transfers.csv

`from,to,seconds,note`, system-qualified ids (`P:place_WTC`, `S:E01`). The plan's PATH↔subway
minimums: WTC → WTC Cortlandt (1) about 4 min and → World Trade Center (E) about 6 min via the
Oculus; 14th and 23rd St → the F/M about 3 min; 33rd St → 34 St-Herald Sq about 4 min. Each row
applies both ways between every routable platform of each end, so an unordered pair appears
once. The compiler checks every end resolves to a routable stop in the `tt-*` artifacts.

## alerts/path-keywords.csv

`severity,keywords`, keywords separated by `|`, rows in priority order (the first rule with a
keyword the lowercased title contains wins; no match is `info`). Severity is one of the app's
alert severities (`docs/formats.md`). Transcribed from `AlertSeverity(pathTitle:)`.
