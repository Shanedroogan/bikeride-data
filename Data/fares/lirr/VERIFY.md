# VERIFY: LIRR stations, zones and fares, 2026

Verified 2026-09-26 by a second agent. I re-downloaded and re-parsed every source myself and did not rely on README.md or build.py. I did not run build.py, because it writes into this folder.

**Verdict: verified = true.** Every value in both CSVs matches the official sources. None of the discrepancies below is a wrong CSV value:

- two are gaps in the engine's Far Rockaway Ticket rule (D1, D2);
- two correct the earlier agent's README and summary (D3, D4);
- one is a documented, low-impact omission (D5, Belmont Park).

## Sources opened

| URL | Result | Used for |
|---|---|---|
| https://www.mta.info/document/194866 | Opened with WebFetch; curl got 403. sha256 `46c648aa…6cff304`, the same bytes as `raw/doc194866.pdf`. The PDF was created 2025-12-19. | The adopted fare chart. Its title reads "MTA/LONG ISLAND RAIL ROAD STATION FARES - Effective: January 4, 2026". It has the zone map and the full 8×8 fare table. |
| https://www.mta.info/document/186866 | Opened with WebFetch; curl got 403. sha256 `3fb8cacf…4f37312`, the same bytes as `raw/doc186866.pdf`. | "Long Island Rail Road – Proposed Fares: Zones & Stations": the zone list, plus the Zone 1, CityTicket, Far Rockaway Ticket and intermediate fares. |
| https://www.mta.info/document/186881 | Opened with WebFetch; a 31-page PDF dated September 30, 2025. | "2026 Fare Change Materials": makes the Peak CityTicket and Far Rockaway Ticket permanent. The pilots start "on or about January 4, 2026". |
| https://www.mta.info/fares-tolls/lirr-metro-north | Opened with WebFetch. Also read from the Wayback capture `20260916172018` (raw HTML via `id_`). | The live rules for CityTicket, the Far Rockaway Ticket and peak hours. Its "Long Island Rail Road fares" link goes to /document/194866. |
| https://web.archive.org/web/20250317191428id_/https://www.mta.info/fares/cityticket | Archived copy of an official MTA page. The page says "Updated Sep 4, 2024"; it was captured 2025-03-17. | The CityTicket station list, and the Far Rockaway Ticket's valid destinations and exceptions. |
| https://web.archive.org/cdx/search/cdx?url=mta.info/fares/cityticket (2 queries), plus CDX for mta.info/fares-and-tolls/cityticket and mta.info/fares-tolls/lirr-metro-north | CDX index | Finding the captures. The last capture of /fares/cityticket is from March 2025; the page seems to have merged into /fares-tolls/lirr-metro-north. |
| https://www.mta.info/stations/yaphank-bnl | Opened | Gives no fare zone. Says "This station has no ticket machines." |
| https://www.governor.ny.gov/news/governor-hochul-announces-official-opening-new-yaphank-bnl-long-island-rail-road-station | Opened (official NYS source) | Service began "Saturday, July 18"; the station was "Relocated from its original site". No zone given. |
| https://www.mta.info/article/service-changes-line-and-rockaway-park-shuttle-2025 | Opened | A special fare that ended May 19, 2025 and no longer applies. Cited only for the wording "If you're traveling to Jamaica, buy a ticket to a destination in Zone 1". |
| https://greaterlongisland.com/lirr-opens-new-yaphank-bnl-station-launches-study-of-east-end-service-upgrades/ | Opened, **not official** | The move to the new site ("three miles east"). No zone given. |
| https://www.mta.info/fares/cityticket, https://www.mta.info/fares-and-tolls/cityticket, https://www.mta.info/press-release/icymi-governor-hochul-announces-official-opening-of-new-yaphank-bnl-long-island-rail | **403** | Not used |
| http://neweast.mta.info/fares/cityticket | **DNS failure** | Not used |
| https://archive.org/wayback/available?... | **429** | Not used |
| https://web.archive.org/web/2026/https://www.mta.info/fares/cityticket | **WebFetch refused**: "unable to fetch from web.archive.org". I used curl with `id_` instead. | Not used |

Local inputs:

- `build/fixtures/static-20260926/sources/gtfs/gtfslirr.zip`: feed_version `GO202_26`, Last-Modified 24 Sep 2026. I read `stops.txt` and `stop_times.txt`.
- Stop IDs: `Vendor/bikeride-data/Sources/BRCore/Identifiers.swift` defines `lirr = "L"`, and `BRTimetable/Timetable.swift:633` builds `stopID = StopID(system:, gtfsID: stopGTFSID)`. So the engine's ID is `"L:" + stop_id`.
- LIRR `stops.txt` has no `parent_station` or `location_type` column, so each stop_id is its own station.

## Checks

### Fare matrix: 36 of 36 pairs match

I parsed doc 194866 myself with `pdftotext -layout`, taking the `One-Way Peak` and `One-Way Off-Peak` lines and skipping Onboard and Sr.Cit. The matrix is symmetric and all 36 unordered pairs equal the CSV: 0 mismatches. I also read the 10 random pairs below off the 80 dpi render, in both directions.

| Pair | CSV peak / off-peak | Chart row → column (peak / off-peak) | Chart reverse direction | doc186866 "Proposed" |
|---|---|---|---|---|
| 1↔1 | 725 / 525 | 7.25 / 5.25 | same cell | $7.25 / $5.25 |
| 1↔3 | 725 / 525 | row 1, col 3: 7.25 / 5.25 | row 3, col 1: 7.25 / 5.25 | $7.25 / $5.25 (Zone 3 row) |
| 3↔3 | 600 / 450 | 6.00 / 4.50 | same cell | $6.00 / $4.50 |
| 3↔9 | 1325 / 975 | 13.25 / 9.75 | 13.25 / 9.75 | 9→3: $13.25 / $9.75 |
| 3↔12 | 2200 / 1625 | 22.00 / 16.25 | 22.00 / 16.25 | n/a |
| 4↔7 | 375 / 375 | 3.75 / 3.75 | 3.75 / 3.75 | 7→4: $3.75 / $3.75 |
| 4↔12 | 1225 / 1225 | 12.25 / 12.25 | 12.25 / 12.25 | n/a |
| 7↔10 | 650 / 650 | 6.50 / 6.50 | 6.50 / 6.50 | 10→7: $6.50 / $6.50 |
| 7↔12 | 1075 / 1075 | 10.75 / 10.75 | 10.75 / 10.75 | n/a |
| 9↔9 | 375 / 375 | 3.75 / 3.75 | same cell | n/a |

Chart footnote: "For trips within Zones 4-14, Peak and Off-Peak fares cost the same." The CSV has peak equal to off-peak for every such pair.

### Station zones: 125 of 125 match

I typed doc 186866's zone list from my own `pdftotext -layout` output. It has 126 names: 11/14/31/29/11/15/4/11 in zones 1/3/4/7/9/10/12/14. I compared it with all 125 CSV rows, using three aliases: `Elmont-UBS Arena`→`Elmont-UBS`, `Flushing Main Street`→`Flushing`, `Yaphank-BNL`→`Yaphank`. There are 0 zone mismatches, and the only unused MTA name is Belmont Park. I also checked each zone band of the map on the rendered chart image: every band lists the same names as doc 186866. The 15 sampled stations:

| # | Stop | Station | CSV | doc186866 | Map band (chart image) | Archived CityTicket list |
|---|---|---|---|---|---|---|
| 1 | L:237 | Penn Station (Manhattan) | 1, cityTicket | 1 | 1 | Zone 1 ✓ |
| 2 | L:349 | Grand Central (Madison) | 1, cityTicket | 1 | 1 | Zone 1 ✓ |
| 3 | L:102 | Jamaica | 3, cityTicket | 3 | 3 | Zone 3 ✓ |
| 4 | L:241 | Atlantic Terminal (Brooklyn) | 1, cityTicket | 1 | 1 | Zone 1 ✓ |
| 5 | L:65 | Far Rockaway (Queens) | 4, farRockaway | 4 | 4 | Excluded from CityTicket (live page) ✓ |
| 6 | L:25 | Bayside (Port Washington branch, Queens) | 3, cityTicket | 3 | 3 | Zone 3 ✓ |
| 7 | L:199 | Mets-Willets Point (Queens) | 1, cityTicket | 1 | 1 ("Mets-Willets Point\*\*") | Zone 1 ✓ |
| 8 | L:90 | Hunterspoint Avenue (Queens) | 1, cityTicket | 1 | 1 | Zone 1 ✓ |
| 9 | L:72 | Great Neck (Nassau) | 4, none | 4 | 4 | not listed ✓ |
| 10 | L:36 | Country Life Press (Nassau) | 4, none | 4 | 4 | not listed ✓ |
| 11 | L:187 | Seaford (Nassau) | 7, none | 7 | 7 | not listed ✓ |
| 12 | L:99 | Island Park (Nassau) | 7, none | 7 | 7 | not listed ✓ |
| 13 | L:198 | Speonk (Suffolk) | 12, none | 12 | 12 | not listed ✓ |
| 14 | L:223 | Yaphank-BNL (Suffolk) | 12, none | "Yaphank" 12 | 12 ("Yaphank\*\*") | not listed ✓ (zone caveat below) |
| 15 | L:141 | Montauk (Suffolk) | 14, none | 14 | 14 | not listed ✓ |

The sample is Penn, Grand Central, Jamaica, Atlantic, Far Rockaway and Montauk, plus 9 rows drawn with `random.seed(20260926)`.

### CityTicket and Far Rockaway classification of every NYC station

- **25 `cityTicket` rows.** The archived official CityTicket page lists exactly these LIRR stations under "Zone 1" (11) and "Zone 3" (14). A script compared both names and zones against the CSV, with the alias `Flushing-Main Street`, and found them equal with 0 differences.
- **Excluded stations.** The live fares page says CityTickets "are not valid for travel to/from Belmont Park, Elmont-UBS Arena or Far Rockaway". The CSV has Far Rockaway as `farRockaway`, Elmont-UBS Arena as `none`, and Belmont Park omitted.
- **Far Rockaway (L:65)** is the only `farRockaway` row. It is correct as the only station that sells the Far Rockaway Ticket.
- **Other NYC stations.** None exist outside zones 1 and 3 except Far Rockaway and, at most, the border stations Elmont-UBS Arena and Belmont Park. Both border stations are excluded from CityTicket by name, so `none` is correct whatever their county.
- **CSV well-formed.** `awk -F, 'NF!=5'` finds 0 malformed rows in the stations CSV, and `NF!=4` finds 0 in the fares CSV. There are no duplicate stop IDs.

### Completeness against stops.txt

`stops.txt` has 127 rows. 125 are in the CSV, and every CSV stop exists in the GTFS with the same name. The two left out:

- **L:24 Belmont Park**: 0 stop_times in GO202_26. MTA lists it in zone 4. See D5.
- **L:86 Hillside Facility**: 240 stop_times, all with pickup_type=1 and drop_off_type=1, and it is on neither MTA document. Leaving it out is correct.

### Plan facts

- **CityTicket $5.25 off-peak / $7.25 peak: confirmed.** The live page says: "a one-way CityTicket costs $5.25 for off-peak trains and $7.25 for peak trains". doc 186866 has Proposed $7.25 / $5.25 for zones 1 and 3. This equals `PeakFare.cityTicket2026`.
- **Far Rockaway Ticket costs the same: confirmed.** The live page gives "$5.25 during off-peak hours and $7.25 during peak hours". doc 186866 has $7.25 / $5.25.
- **Zone 3↔3 $4.50 off-peak / $6.00 peak: confirmed.** Chart row 3, column 3 reads 6.00 / 4.50, and doc 186866's Intermediate 3→3 Proposed reads $6.00 / $4.50.
- **Effective date: January 4, 2026**, from the chart title. The live page (read 2026-09-26) still links the chart as "Long Island Rail Road fares", and the 2026-09-16 capture's HTML contains `href="/document/194866"`.

## Discrepancies

**D1 [engine-model, medium]: the Far Rockaway Ticket's scope is wider in the engine than in MTA's rules.**

- **What the engine does:** `FareEngine.lirrFare` prices every `(.farRockaway, .cityTicket)` pair at 725/525, which covers all 25 zone 1 and zone 3 stations.
- **Live page (2026):** "For travel between Far Rockaway and LIRR stations in Zone 1…". Nothing about zone 3.
- **Archived official CityTicket page (Sep 2024):** "It can be used for direct travel between Far Rockaway and stations in LIRR Zone 1, with some exceptions." Its valid destinations are the 10 zone 1 stations other than **Mets-Willets Point**. It adds: "Far Rockaway Ticket can also be used for travel to Rosedale, Laurelton, Locust Manor, and Jamaica. You must buy the ticket with a destination within Zone 1."
- **Wrong under both texts:** Far Rockaway ↔ Hollis, Queens Village, St. Albans, Flushing Main Street, Murray Hill, Broadway, Auburndale, Bayside, Douglaston, Little Neck (10 stations). The engine charges 725/525; the correct price is the 4↔3 zone fare, 900/675.
- **Possibly wrong:** Far Rockaway ↔ Mets-Willets Point. The engine charges 725/525; the zone 4↔1 fare is 1350/1000. The 2024 destination list leaves it out; the 2026 text just says "Zone 1".
- **Unclear:** Far Rockaway ↔ Jamaica, Rosedale, Laurelton, Locust Manor. The 2024 text allows the ticket there; the 2026 text doesn't say. So the underpricing covers 10 stations for certain and up to 15 at most.
- **Can the CSV fix it?** No. `CityFare` can't express it. Changing Far Rockaway to `none` would overprice Far Rockaway ↔ Zone 1 at 1350/1000.

**D2 [engine-model, medium]: the Far Rockaway Ticket can only be bought at Far Rockaway.**

- **Live page:** "A paper Far Rockaway Ticket can only be purchased at the ticket machine at Far Rockaway Station. Far Rockaway Ticket cannot be purchased at other LIRR stations. A mobile Far Rockaway Ticket can only be purchased if you share your location with the TrainTime app to confirm you are near Far Rockaway station. It can be purchased on board a train only if you are a senior citizen or a person with a disability."
- **Engine:** the `(.cityTicket, .farRockaway)` case works in both directions. So a one-way Penn Station → Far Rockaway trip is priced 725/525.
- **What the rider pays:** someone starting in Zone 1 can't buy that ticket and pays the 1↔4 zone fare, 1350/1000. The exception is a rider who already holds a return ticket or Day Pass bought at Far Rockaway.
- **Can the CSV fix it?** No, this is direction-dependent.

**D3 [readme-provenance, low]: the earlier summary's Far Rockaway example and count.**

- The README and summary say the engine underprices Far Rockaway ↔ "the 14 zone 3 stations", with Far Rockaway ↔ Jamaica as the example at 900/675.
- The archived official page allows the Far Rockaway Ticket for travel to Jamaica, and to Rosedale, Laurelton and Locust Manor, so the example is the weakest one to use.
- The part that holds under both texts is the 10 stations in D1. Mets-Willets Point, a zone 1 station, is a possible gap the summary missed.

**D4 [readme-provenance, low]: two facts are not only from search snippets.**

- The summary says the CityTicket exclusion at Belmont Park, Elmont-UBS Arena and Far Rockaway, and the July 18 opening of Yaphank-BNL, "come only from search-result snippets".
- The first is on the live fares page, word for word: "They are not valid for travel to/from Belmont Park, Elmont-UBS Arena or Far Rockaway."
- The second is on governor.ny.gov: "first trains departing Yaphank-BNL at 5:36 a.m. … on Saturday, July 18".
- The README's snippet (b), "with some exceptions", is the archived CityTicket page. That page is now readable, and its exceptions are the ones listed in D1.

**D5 [completeness, low]: Belmont Park is left out.**

- L:24 Belmont Park is a public LIRR station in `stops.txt`. It is zone 4 on both MTA documents and is excluded from CityTicket by name.
- It was left out because GO202_26 has no trips there. If a later feed restores service, `FareEngine` throws `FareError.unknownLIRRStation("L:24")`.
- Adding `L:24,Belmont Park,4,none` is harmless and follows the task's "every LIRR station" requirement. The omission is documented, so it doesn't change the verdict.

## Notes (not discrepancies)

- **Yaphank-BNL (L:223) zone 12 is not confirmed by an official source.** The zone comes from "Yaphank\*\*" on the January 2026 chart, which predates the July 18, 2026 move. Neither the MTA station page nor the governor's release gives a zone, and the MTA press release returned 403. The only support is the location: the station sits between Medford (zone 10) and Riverhead (zone 14), at the same longitude as Mastic-Shirley (zone 12): −72.8645 vs −72.8644. The chart's "\*\*" means no ticket machines, which the station page confirms.
- **CityTicket and zone 3 ↔ zone 3.** The archived 2024 page says "On LIRR, you can use CityTicket for trips within Zone 1 or between Zones 1 and 3". The engine also allows CityTicket for 3↔3, but it makes no difference: 3↔3 costs 600/450, less than CityTicket's 725/525.
- **CityTicket never wins.** The earlier agent's point holds: 1↔1 and 1↔3 cost exactly the CityTicket price, and ties go to the zone ticket, so the ticket label is never CityTicket. The price is right either way.
- **Peak rule matches.** The live text, "arrive in NYC terminals between 6 a.m. and 10 a.m. or depart NYC terminals between 4 p.m. and 8 p.m.", matches `LIRRPeakRule.weekdayCommute`.
- **Holidays aren't built in.** The live page lists holidays that are off-peak all day, including MLK Day and the day after Thanksgiving, when the LIRR runs a weekday schedule. `LIRRPeakRule.holidays` defaults to empty, so the config must supply them.
- **Not modeled, and only matters if CityTicket wins:** "without changing directions", with changes allowed at Jamaica per the 2024 page, and at Woodside for Mets-Willets Point per the live page.
