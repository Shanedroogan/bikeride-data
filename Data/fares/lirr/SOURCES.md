# LIRR station zones and zone fares, 2026

Input for the fare engine (`BRPlanner`) now and the M1 `config` artifact later. Checked by an
independent pass (`VERIFY.md`): every station zone and all 36 zone-pair fares match MTA's adopted
chart effective 2026-01-04. Belmont Park (zone 4, no service in feed GO202_26) was appended by hand
after `build.py` ran, so a future feed that serves it still prices.

The Far Rockaway Ticket (from `VERIFY.md` D1/D2) is valid only from Far Rockaway, where it is
sold (or in TrainTime near it), to Zone 1 stations other than Mets-Willets Point, so a trip *to*
Far Rockaway, from it to a zone 3 station, or from it to Mets-Willets Point pays the zone fare.

Mets-Willets Point (`L:199`) is excluded (`farRockawayTicket.excludedDestinations` in `lirr.json`):
confirmed by the user in TrainTime, 2026-09-29 (Mets-Willets Point is on the Port Washington
Branch, and the ticket does not offer it). This agrees with MTA's archived 2024 CityTicket page,
https://web.archive.org/web/20250317191428id_/https://www.mta.info/fares/cityticket ("Updated Sep
4, 2024", captured 2025-03-17), whose Far Rockaway Ticket destinations are the Zone 1 stations
other than Mets-Willets Point. The 2026 fares page says only "Zone 1". So Far Rockaway →
Mets-Willets Point costs the zone 4↔1 fare, $13.50 peak / $10.00 off-peak.

Outputs in this folder:

- `lirr-stations-2026.csv`: `stop_id,gtfs_name,zone,city_fare,source_note`. 125 rows, one for each public LIRR station with service in the GTFS fixture.
- `lirr-zone-fares-2026.csv`: `from_zone,to_zone,peak_cents,offpeak_cents`. One-way adult fares for 36 rows, which are all unordered pairs of the 8 zones in use (1, 3, 4, 7, 9, 10, 12, 14), including same-zone pairs. `from_zone <= to_zone`. `FareEngine.ZonePair` normalizes to (min, max) when it looks a fare up (FareEngine.swift:188-194), so one row per pair is enough.
- `build.py`: regenerates both CSVs from `raw/` and the GTFS zip. All checks below are asserts in this script.
- `lirr.json`: the rest of `fares.lirr` in the `config` artifact: which CSVs hold the station zones and zone fares (so a new fare year adds new CSVs and points here), CityTicket and the Far Rockaway Ticket ($7.25 peak / $5.25 off-peak; the Far Rockaway Ticket only to Zone 1, excluding Mets-Willets Point), the peak rule (NYC terminal arrivals 06:00–10:00, departures 16:00–20:00, from the fares page quoted below) and the NYC terminals it is evaluated at (Penn Station, Grand Central Madison, Atlantic Terminal, Hunterspoint Avenue, Long Island City; all zone 1). `bikeride-data config` checks every station with boarding or alighting service in `tt-lirr` is zoned.
- `raw/`: the source PDFs as downloaded (`doc194866.pdf`, `doc186866.pdf`), their `pdftotext` output, and a 60 dpi render of the fare chart (`map60-1.png`).

## Sources

| Source | URL (opened) | Effective / dated | Used for |
|---|---|---|---|
| **MTA/Long Island Rail Road Station Fares: Fare Chart - Ticket Types** (1-page PDF: the zone map "LIRR Stations and Fare Zones" plus the full 8x8 zone fare table) | https://www.mta.info/document/194866 | Title says "Effective: January 4, 2026". The PDF was created 2025-12-19. sha256 `46c648aa…cff304` | **Primary source for fares** (the adopted tariff). Also used to check each station's zone against its band on the map |
| **Long Island Rail Road – Proposed Fares: Zones & Stations** (2026 fare-change materials, 4 pages) | https://www.mta.info/document/186866 | PDF created 2025-09-27. Has "Current" and "Proposed" columns. sha256 `3fb8cacf…f37312` | **Primary source for station→zone** (a plain text table). Also used to check fares: its "Proposed" figures match the adopted chart exactly (see below) |
| **LIRR and Metro-North fares** (HTML) | https://www.mta.info/fares-tolls/lirr-metro-north | Page has no date. Its "LIRR Fare tables PDF" link points to /document/194866, so that chart is still the current table as of 2026-09-26 | CityTicket and Far Rockaway Ticket rules and prices. Peak definition |
| **Yaphank-BNL station page** | https://www.mta.info/stations/yaphank-bnl | n/a | Page opened. It does not state a fare zone |
| LIRR GTFS (local fixture) | `build/fixtures/static-20260926/sources/gtfs/gtfslirr.zip` (from https://rrgtfsfeeds.s3.amazonaws.com/gtfslirr.zip, Last-Modified Thu 24 Sep 2026) | feed_version `GO202_26`, calendar_dates 2026-09-24 → 2026-11-08 | Station list, stop IDs, which stops have service |

Quotes from the fares page, as returned by WebFetch:

> "For travel on one railroad within New York City without changing directions, a one-way CityTicket costs $5.25 for off-peak trains and $7.25 for peak trains."
>
> "For travel between Far Rockaway and LIRR stations in Zone 1, a one-way Far Rockaway Ticket costs $5.25 during off-peak hours and $7.25 during peak hours."
>
> "Peak fares are charged during weekday rush hours on trains scheduled to arrive in NYC terminals between 6 a.m. and 10 a.m. or depart NYC terminals between 4 p.m. and 8 p.m."

These URLs were tried and failed. Akamai returned HTTP 403, so none of them count as sources:

- https://www.mta.info/fares/cityticket, https://mta.info/fares/cityticket and https://www.mta.info/fares/cityticket/
- http://web.mta.info/mta/cityticket.htm, which redirects 301 → https://new.mta.info/fares-and-tolls/cityticket, which redirects 301 → https://www.mta.info/fares-and-tolls/cityticket, which returns 403
- https://www.mta.info/press-release/icymi-governor-hochul-announces-official-opening-of-new-yaphank-bnl-long-island-rail
- plain `curl` of www.mta.info/fares/lirr, /lirr/fares, /fares-tolls/lirr, /fares and /document/194866. Both PDFs were saved through WebFetch instead.

Some facts come only from web-search snippets, because the pages behind them returned 403. They are listed here so nobody mistakes them for opened sources:

- (a) the CityTicket page says "CityTickets cannot be used for travel to or from Belmont Park, Elmont-UBS Arena, or Far Rockaway stations (because these trips travel through Nassau County)".
- (b) the Far Rockaway Ticket is for "direct travel between Far Rockaway and stations in LIRR Zone 1, with some exceptions".
- (c) Yaphank-BNL opened with service starting Saturday, July 18 [2026], and replaces the old Yaphank station.

The stations CSV does not depend on any of these: (a) and (b) agree with the pages that were opened, and (c) only affects a note.

## How the files were parsed

1. **Fares.** `pdftotext -layout` on doc 194866. The script takes the 8 `One-Way Peak` lines and the 8 `One-Way Off-Peak` lines (skipping the `Onboard …` lines). Rows are the origin zones 1, 3, 4, 7, 9, 10, 12, 14 in the order printed. Columns are the destination zones in the same order. Asserts:
   - the matrix is symmetric;
   - peak equals off-peak for every pair inside zones 4–14. The chart's footnote says so, and the CSV keeps both columns equal there;
   - all 18 figures in doc 186866's "Proposed" columns match exactly. That covers the 8 fares to/from Zone 1 and the 10 "Intermediate Fares" pairs (3-3, 4-3, 7-3, 7-4, 9-3, 9-4, 9-7, 10-3, 10-4, 10-7). So the adopted tariff equals the proposal for these fares;
   - CityTicket (zones 1 and 3) and the Far Rockaway Ticket (zone 4) are $7.25 peak / $5.25 off-peak. This matches `PeakFare.cityTicket2026`.
2. **Station → zone.** `pdftotext -raw` on page 1 of doc 186866. This keeps the table's cell order: a zone number followed by its comma-separated station list. It prints 126 names: 11/14/31/29/11/15/4/11 in zones 1/3/4/7/9/10/12/14. Some spaces are lost ("HunterspointAvenue"), so names are compared with all whitespace removed.
3. **Check against the map.** `pdftotext -bbox` on doc 194866. The map on the left is split into horizontal bands that line up with the fare table's zone blocks. The top of each band is taken as the y of that block's first "Monthly" row, minus 4 pt. The script finds every station label word by word, including labels printed across lines ("Hempstead / Gardens", "Country Life / Press") and lines that hold two labels ("FAR ROCKAWAY Lynbrook"). Case matters, so the terminal `HEMPSTEAD` never matches "Hempstead Gardens". Every one of the 126 names lands in exactly one band, and that band matches doc 186866's zone in every case. The closest label to a band edge is Albertson, 7.2 pt inside zone 7. A few labels match more than once (Islip / Central Islip, Massapequa / Massapequa Park, the two HEMPSTEADs, Glen Cove), but every match falls in the same band.
4. **GTFS.** LIRR `stops.txt` has no `location_type` or `parent_station` column, so every row is a station. The engine's ID is `StopID(system: .lirr, gtfsID:)` = `"L:" + stop_id` (BRCore/Identifiers.swift, BRTimetable/Timetable.swift:633). No parent stations are made up for the LIRR; that only happens for PATH. Of the 127 rows, 125 go into the CSV. Two are left out, as listed in the next section. Three GTFS names differ from MTA's names: `Elmont-UBS Arena` = "Elmont-UBS", `Flushing Main Street` = "Flushing", `Yaphank-BNL` = "Yaphank". Every served GTFS station matches exactly one MTA name, and every MTA name is used except Belmont Park.
5. **city_fare.**
   - `cityTicket`: all zone 1 and zone 3 stations, 25 in total. That is 2 in Manhattan (Penn Station, Grand Central), 3 in Brooklyn (Atlantic Terminal, Nostrand Avenue, East New York) and 20 in Queens. Doc 186866's CityTicket table covers exactly zones 1 and 3.
   - `farRockaway`: Far Rockaway only. It is in zone 4 and in Queens, but its trains run through Inwood and Lawrence in Nassau. Locust Manor, Laurelton and Rosedale are the other Queens stations on the Far Rockaway Branch. They are in zone 3 and do not pass through Nassau to reach the rest of the city, so they are `cityTicket`. The Far Rockaway Ticket applies to Far Rockaway alone.
   - `none`: everything else, 99 stations. All are in Nassau or Suffolk, except possibly Elmont-UBS Arena (below). Bellerose sits at the Queens line but is in Nassau. Elmont-UBS Arena is right on the Queens/Nassau line, and its county was not checked. That does not matter here: MTA excludes CityTicket there because its trips run through Nassau, and the Far Rockaway Ticket does not cover it. The borough of each station comes from geography; the MTA PDFs print boroughs only for the terminals.

Stations per zone in the CSV: z1 11, z3 14, z4 30, z7 29, z9 11, z10 15, z12 4, z14 11.

## Stations left out or uncertain

- **Belmont Park** (`L:24`): not in the CSV. Both MTA documents put it in zone 4, and `city_fare` would be `none`. It has no stop_times in feed GO202_26. If a later feed brings service back, add `L:24,Belmont Park,4,none`.
- **Hillside Facility** (`L:86`): not in the CSV. All 240 of its stop_times have pickup_type=1 and drop_off_type=1. It is an employee-only support facility and does not appear on either MTA document.
- **Yaphank-BNL** (`L:223`): given **zone 12, not confirmed**. It is the new station, opened July 2026, and replaced the old Yaphank. The only official zone listing is the January 2026 chart, which predates the new station and lists "Yaphank**" in zone 12. The fares page still links that chart as current. The new station is on the Main Line between Medford (zone 10) and Riverhead (zone 14). A search snippet puts it about 3.5 mi east of the old site. The Yaphank-BNL station page does not state a zone. A Wikipedia snippet also says zone 12, but that is not an official source.
- Every other served station was placed from both documents, and the two agree.

## Where the data and FareEngine disagree (repo is read-only, so this is not fixed)

(Settled since: the engine offers the Far Rockaway Ticket only from Far Rockaway to Zone 1, and not to Mets-Willets Point; the paragraph at the top of this file.)

1. **The Far Rockaway Ticket covers Zone 1 only.** The MTA wording is "between Far Rockaway and LIRR stations in Zone 1". `FareEngine.lirrFare` offers it for any `(.farRockaway, .cityTicket)` pair, which also includes the zone 3 stations. For example, Far Rockaway ↔ Jamaica should cost the 4↔3 zone fare, 900 peak / 675 off-peak. The engine would charge 725 / 525 instead. The `CityFare` enum has no way to say "Zone 1 only". Two possible fixes: a separate flag, or limiting the pairing to zone-1 stations.
2. **CityTicket never wins under the engine's tie rule.** In 2026, 1↔1 and 1↔3 cost 725/525, the same as CityTicket, and 3↔3 is cheaper at 600/450. Ties go to the zone ticket, so the engine never picks CityTicket. It only ever picks the zone fare or, for Far Rockaway ↔ Zone 1, the Far Rockaway Ticket (725/525 against a zone fare of 1350/1000). The prices come out right; only the ticket label is affected.
3. CityTicket is valid only "without changing directions". The engine doesn't model this. It rarely matters now that CityTicket is never cheaper.

Context: the 2026 change cut 1↔3 from $11.25 / $8.25 to $7.25 / $5.25, and zone 1 one-way from $9.25 / $6.75 to $7.25 / $5.25. It raised CityTicket from $7.00 / $5.00 to $7.25 / $5.25. These figures are from doc 186866's Current and Proposed columns.

## Spot-check fares (verbatim from doc 194866, `pdftotext -layout`)

1. Zone 1 row, `One-Way Peak` (columns are zones 1, 3, 4, 7, 9, 10, 12, 14):
   `One-Way Peak                           7.25         7.25     13.50        15.25        18.25        21.50        25.50        33.00`
   → CSV `1,1,725,…`, `1,3,725,…`, `1,4,1350,…`, …, `1,14,3300,…`
2. Zone 3 row, `One-Way Off-Peak`:
   `One-Way Off-Peak                       5.25       4.50          6.75       8.00           9.75      12.25        16.25        21.00`
   → CSV `3,3,600,450` (off-peak 450), `3,4,900,675`, `3,14,2825,2100`
3. Zone 4 row, `One-Way Off-Peak` (the line also contains map labels):
   `Malverne Nassau Boulevard … One-Way Off-Peak                   10.00            6.75        3.75         3.75       6.50         8.25        12.25        19.50`
   → CSV `1,4,1350,1000`, `4,4,375,375`, `4,14,1950,1950`

Footnote on the chart: "* Note: For trips within Zones 4-14, Peak and Off-Peak fares cost the same. On ticket machines, paper tickets, and in the TrainTime app, these tickets are labeled as Peak."
