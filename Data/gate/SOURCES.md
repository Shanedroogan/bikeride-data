# Validation gate inputs

Read by `bikeride-data gate` (`Sources/BRBuild/Publish/Gate.swift`), never shipped to devices.
The gate also reads the shared holiday list, `Data/config/calendar/holidays.csv`.

## thresholds.json

Parsed strictly: an unknown key is an error.

- `tripCounts.maxChangePercent` (35): per system and service date, active trips may differ from
  the previous build by at most this much either way. The reference is the previous build's
  **same date** when it covered it; otherwise its median for that weekday with holidays excluded,
  and for a date in `holidays.csv` the nearest of its `holidayProfiles` medians (the date's own
  weekday, Saturday, Sunday). Same date first is what lets most holidays pass: bus service on
  Thanksgiving, Christmas and New Year's Day is 37 % under a normal weekday (M1 audit), but an
  earlier build already carried the same holiday schedule. The profiles cover holidays new to a
  build (a feed extended its calendar). Sunday alone is not enough: Columbus Day and Veterans Day
  run weekday service, 51 % (subway), 44 % and 57 % (bus) and 86 % (PATH) over the Sunday median
  in the 2026-09-26 build; against the nearest profile every holiday of that build is within 18 %.
  Without a previous build the check is skipped with a warning.
- `coverage.minDays` (3): a system with fewer consecutive covered days from the build day fails
  soft. The manifest marks it `noSchedule`, keeps its real dates in `coverage`, and the relay's
  `/v1/health/data` returns 503 for it: that 503 is the alert.
- `snapping.maxSnapMeters` (100): every access point of a routable stop inside the service area
  snaps to a walkable street within this distance, and the stop has street entry and exit, unless
  `snap-allowlist.csv` says otherwise. Stops outside the service area (New Jersey bus stops, LIRR
  east of the city) are only counted.
- `streets.regions` / `streets.minKeptSharePercent`: each service-area region (a borough, Jersey
  City, Hoboken) keeps at least this share of its street length through the component filter
  (`stats.regions` in `reports/streets.json`). Per region rather than city-wide: the largest
  component alone holds only 78 % of all length, since Staten Island and New Jersey are separate
  components by design, while a region losing its network would barely move the overall 97.6 %.
  The per-region minimums are 3 points under the values of the 2026-09-26 build, rounded down
  (see the file's `notes`); `minKeptSharePercent` applies to a region with no entry.

## snap-allowlist.csv

`stop,rule,maxMeters,reason`; `rule` is `snap` (access points may snap up to `maxMeters`) or
`noStreetAccess` (the stop may lack street entry or exit; `maxMeters` empty). The reason runs to
the end of the line. An entry that no longer matches anything is reported as a warning, so fixed
or removed stops get deleted from the list. The four entries come from the M1 audit of the
2026-09-26 build: the only routable in-area stop beyond 100 m, and the three in-area stops with
no street access.
