# Artifact formats

Every artifact is one file: a header, then a payload. The same bytes are what the pipeline
writes, what `xz` compresses into a blob, and what the app memory-maps after decoding. Readers
view arrays in place, so the layout rules below are about alignment as much as about content.

Implementation: `Sources/BRData` (`BinaryWriter`, `BinaryReader`, `ArtifactHeader`).

## Conventions

- **Little-endian** throughout. Supported hosts are little-endian (enforced at compile time), so
  values are never byte-swapped.
- **Offsets** are in bytes from the start of the file. Payload offsets are from the start of the
  payload, which is itself 8-aligned in the file.
- **Padding** is always zero bytes. Readers reject non-zero padding, which catches layout bugs.
- **Deterministic.** Equal inputs produce identical bytes: maps are written in key order and no
  timestamps are embedded beyond `dataVersion`. Blobs are content-addressed, so this matters.
- **Bounds-checked.** Every read is checked against the buffer; a malformed file is an error,
  never a crash.

## Primitives

| Type | Encoding |
|---|---|
| `u8` `u16` `u32` `u64`, `i8` `i16` `i32` `i64` | Fixed-width integers, little-endian, unaligned |
| `f32` `f64` | IEEE 754 binary32 / binary64, little-endian, unaligned |
| `bytes[n]` | `n` raw bytes; `n` is known from context |
| `str` | `u32` byte length, then that many UTF-8 bytes. No terminator, no padding. Invalid UTF-8 is an error |
| `array<T>` | Zero padding to the next multiple of 8, a `u64` element count, then `count` elements of `T` back to back. Aligning the count keeps the elements 8-aligned, so `T` up to 8 bytes can be viewed in place |

Scalars outside arrays need no alignment and are read with unaligned loads.

## Header

Layout version **1**. All artifacts share it.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | magic | ASCII `BRDA` |
| 4 | 2 | `u16` headerLayout | `1` |
| 6 | 2 | `u16` kind | See the kind table |
| 8 | 2 | `u16` formatVersion | Payload format of this kind |
| 10 | 2 | `u16` reserved | `0` |
| 12 | 4 | `u32` headerLength | Total header bytes including padding; a multiple of 8; the payload starts here |
| 16 | 8 | `u64` payloadLength | Must equal file length − headerLength exactly |
| 24 | … | `str` dataVersion | Identifies the build inputs, e.g. source ETags or a UTC build stamp |
| … | … | `str` builderSwiftVersion | Compiler that built the artifact, e.g. `6.4` |
| … | 4 | `u32` builtAgainstCount | |
| … | … | builtAgainstCount × (`str` name, `str` rawSha256) | Sorted by name; names are unique. Each input artifact this one was built against, with the lowercase-hex SHA-256 of that input's raw bytes |
| … | … | padding | Zero bytes up to headerLength |

A reader rejects a file whose magic, layout, kind, lengths or padding do not check out, or whose
`builtAgainst` repeats a name.

## Kinds and format versions

| Code | Name | Format | Freezes at v1 in |
|---|---|---|---|
| 1 | `streets` | 0 (draft) | S1 |
| 2 | `stations` | 0 (draft) | S1 |
| 3 | `tt-subway` | 0 (draft) | S1 |
| 4 | `tt-bus` | 0 (draft) | S1 |
| 5 | `tt-lirr` | 0 (draft) | S1 |
| 6 | `tt-ferry` | 0 (draft) | S1 |
| 7 | `links` | 0 (draft) | M1 |
| 8 | `flows` | 0 (draft) | M1 |
| 9 | `config` | 0 (draft) | M1 |
| 10 | `tt-path` | 0 (draft) | S1 |

Codes are permanent and never reused. Format `0` marks an unfrozen draft that may change without a
bump. After a format freezes, any change a current reader cannot parse bumps its formatVersion.

## Integrity and compression

- The set manifest records each artifact's `rawBytes` and `rawSha256` (of the file above), and its
  blob's size and SHA-256. Blobs are named by the SHA-256 of their `.xz` bytes.
- Blobs are compressed with `xz -6 -T1 --check=crc32`: exactly one stream with one block.
- Apple's LZMA decoder stops after the first xz stream and reports success, so a blob with
  concatenated streams would silently decode short. `AppleLZMACodec` rejects any input after the
  first stream and, given `rawBytes`, any size mismatch. The publish gate also checks
  `xz --list` for one stream and one block.

## Payload layouts

<!-- TODO(M1): flows, config; rail bike-hop pairs in links. -->

Each payload layout is documented here. A draft (format `0`) may change without a version bump;
the draft revision inside the payload tells readers which draft they hold.

### `streets` (kind 1, format 0, draft revision 2)

The walk and bike street graph, its geometry and names, the snap grid and the service-area
polygons (the five boroughs, Hudson County and the Newark Penn area).
Writer: `StreetsArtifactWriter` (BRBuild). Reader: `MappedStreetGraph` (BRStreetCore), which
views every array in place. How the data is derived: `docs/osm-derivation.md`.

**Terms.** A *node* is a graph vertex. A *segment* is one undirected piece of street between two
nodes, oriented from its start node A to its end node B, with one name and one geometry. It yields
up to two directed *edges*, A→B and B→A; a direction nobody may use is not stored. Walkable
segments are walkable both ways, so walking is symmetric; riding follows one-ways.

Counts: V nodes, E edges, S segments, P shape points, N names. Coordinates are `i32`
microdegrees (10⁻⁶°), latitude first.

| Field | Encoding | Notes |
|---|---|---|
| magic | `bytes[4]` | ASCII `STRT` |
| draftRevision | `u32` | `2` (revision 2 added the New Jersey regions). Readers reject any other |
| V, E, S, P, N | 5 × `u64` | Each below 2³² − 1 |
| nodeCoordinates | `array<i32>`, 2V | lat, lon per node. Nodes are numbered along a Hilbert curve |
| forwardOffsets | `array<u32>`, V + 1 | Edges leaving node u: `forwardOffsets[u] ..< forwardOffsets[u + 1]`. First 0, last E |
| edgeTargets | `array<u32>`, E | Target node. Edges are sorted by (source, target, segment code) |
| edgeLengthDecimeters | `array<u32>`, E | True length along the full-resolution geometry |
| edgeFlags | `array<u16>`, E | Bit 0 walk, 1 bikeForward (ride from source to target), 2 stairs, 3 bridge, 4 park, 5 connector, 6 dismount; others 0. Every stored edge has walk or bikeForward |
| edgeBikeClasses | `array<u8>`, E | 0 protected, 1 painted, 2 shared, 3 arterial (the class in this edge's direction) |
| edgeSegments | `array<u32>`, E | Segment index; bit 31 set when the edge runs B→A |
| reverseOffsets | `array<u32>`, V + 1 | Edges entering node v: `reverseOffsets[v] ..< reverseOffsets[v + 1]` |
| reverseSources | `array<u32>`, E | Source node of each entering edge |
| reverseEdges | `array<u32>`, E | Its forward edge index. Within a node, in forward edge order |
| segmentNodes | `array<u32>`, 2S | A, B per segment. A = B for a loop (e.g. a plaza outline). Sorted by (A, B) |
| segmentNameIDs | `array<u32>`, S | Index into the name table |
| segmentBearings | `array<u8>`, 2S | Travel direction leaving A and arriving at B, over about 10 m, in 1/256 turn clockwise from north. B→A uses each value + 128, swapped |
| segmentShapeOffsets | `array<u32>`, S + 1 | Interior points of segment s: `[offsets[s], offsets[s + 1])`. First 0, last P |
| shapePoints | `array<i32>`, 2P | lat, lon; ordered A → B; the end nodes are not repeated |
| nameOffsets | `array<u32>`, N + 1 | Name n is `nameBytes[offsets[n] ..< offsets[n + 1]]`, UTF-8 |
| nameBytes | `array<u8>` | Concatenated names, sorted by bytes; unique per (text, kind) |
| nameKinds | `array<u8>`, N | 0 tagged (`name` or `bridge:name`), 1 `ref`, 2 derived label (e.g. `bike path`) |
| grid origin | 2 × `i32` | originLat, originLon (microdegrees): the south-west corner of cell (0, 0) |
| grid cell size | 2 × `i32` | cellLat, cellLon (microdegrees), about 100 m each; both > 0 |
| grid shape | 2 × `u32` | columns, rows; columns × rows < 2³² − 1 |
| gridCellOffsets | `array<u32>`, columns × rows + 1 | Cell (x, y) is index `y × columns + x`; x counts east, y north |
| gridCellSegments | `array<u32>` | Segments listed per cell, ascending: every segment whose stored geometry passes through the cell |
| regionCount | `u32` | Service-area regions |
| regions | regionCount × (`u16` code, `str` name) | NYC DCP borough codes 1 Manhattan, 2 Bronx, 3 Brooklyn, 4 Queens, 5 Staten Island; New Jersey county FIPS codes 34013 Newark Penn area (the part of Essex County served), 34017 Hudson County; ascending code |
| regionPolygonOffsets | `array<u32>`, regionCount + 1 | Polygons of each region |
| polygonRingOffsets | `array<u32>`, polygons + 1 | Rings of each polygon: the exterior first, then holes |
| ringPointOffsets | `array<u32>`, rings + 1 | Points of each ring |
| ringPoints | `array<i32>` | lat, lon; rings closed (first point repeated) |

Nothing follows the last array. A cell (x, y) covers longitudes
`originLon + x·cellLon ..< originLon + (x + 1)·cellLon`, and latitudes likewise.

Invariants, checked by `MappedStreetGraph(… validate: true)` (the default; a few ms for the city):
offsets start at 0, never decrease and end at their array's count; every index is in range; every
edge's segment joins that edge's own source and target in the direction bit 31 states; the reverse
index lists every edge exactly once, at its target; bike classes and name kinds are known values.
The five-borough area is the union of regions 1–5; the service area is the union of all regions
(Hudson County and the Newark Penn disc overlap at Harrison, which is harmless: containment is
"in any polygon").

### `tt-subway`, `tt-bus`, `tt-lirr`, `tt-ferry`, `tt-path` (kinds 3–6 and 10, format 0, draft revision 1)

One timetable per system, compiled from that system's GTFS feeds. Writer: `TimetableData`
(BRTimetable), filled by `GTFSTimetableCompiler` (BRBuild). Reader: `Timetable` (BRTimetable),
which maps the file and views every section in place after checking every length and index.
All five kinds share this layout; `info.system` must match the header kind.

**Payload.** ASCII `BRTT`, a `u32` section count, then that many 24-byte table-of-contents
entries (`u32` section id, `u32` element size, `u64` byte offset from the payload start, `u64`
element count), then the sections. Each section is one array of one scalar type, starts
8-aligned, and is followed by zero padding to 8. Ids are permanent; a reader rejects a missing,
repeated, misaligned or out-of-bounds section, or one whose element size is not the documented
one. Sections are written in id order.

**Conventions.** `none` = `0xFFFFFFFF` in any `u32` index, time or color. A *string* is a `u32`
index into the string pool (`stringOffsets`, `stringBytes`); string 0 is empty. A `…Start`
section is a CSR offset array with one more entry than the table it indexes: item i owns
`[start[i], start[i+1])`, the first entry is 0 and the last is the target's count. Days are `i32`
days since 1970-01-01 (proleptic Gregorian). Times are `u32` seconds from the service day's
origin, noon − 12 h in `info.timeZone` (so `25:10:00` is 90,600 and trips past midnight stay on
their service day). Coordinates are `i32` microdegrees.

**Window and sources.** Day `d` of the window is `windowStartDay + d`, `0 ≤ d < dayCount`; the
build starts it the day before the build date so day view D−1 exists. A *source* is one version
of one GTFS zip; sources in one *slot* are alternative versions of the same feed (subway:
supplemented and regular; bus: one slot per zip, six slots; LIRR, ferry and PATH: one). For every slot
and window day exactly one source, or none, is *selected*: among the versions whose
`calendar.txt` ranges ∪ added `calendar_dates` cover the day, the lowest priority (supplemented
0, regular 1), then the newest. Versions are never merged for a day and calendars are never
extended. The system *covers* a day when every slot has a selected source on it (a lapsed bus
zip makes the day uncovered, so the planner extrapolates it rather than silently losing routes).
A feed may name a documented *fallback* version in its slot (PATH: the stale Trillium feed
behind PANYNJ's National RTAP feed). The fallback is fetched and parsed only when the primary
fails to download or has no local zip, and then, having the higher priority number, is selected
only on days the primary (if cached) does not cover.

**Service rules.** One per (source, `service_id`) that runs on at least one selected window day.
A rule runs on day D when its source is selected on D and, by GTFS: an exception on D decides
(1 added, 2 removed); otherwise, if it has a `calendar.txt` row, D lies in `[start, end]` and
D's weekday bit is set. LIRR has only `calendar_dates` (weekday byte 0, no row).

*Extrapolation* (coverage policy step 2, `Timetable.isActiveExtrapolated`). On a day D after the
last day its slot covers, a rule runs when it belongs to the source selected on that last day,
has a `calendar.txt` row with `start ≤ D ≤ end + 14`, and ran on the slot's *reference day* for
D's weekday: of the slot's last five covered days with that weekday, the one whose set of running
rules is most common (ties: the latest), exceptions included. Readers compute reference days at
open; nothing about them is stored.

**Patterns and FIFO.** Trips are grouped by (slot, route, stop sequence, per-stop pickup and
drop-off bits) into a base pattern (`patternBaseKey`), sorted by first departure, then split
greedily into sub-patterns so that any two trips of one sub-pattern whose rules share a running
window day never overtake: the earlier trip's arrival and departure are ≤ the later one's at
every stop. So every *day view* (the active trips of one pattern on one date, in trip order) is
FIFO at every stop, extrapolated days included, since those copy one real day of one slot. Stops
whose every call has `pickup_type` = `drop_off_type` = 1 are dropped from the trips calling
there (and from the stop table).

Stop times are one trip-major matrix per pattern: trip `patternTripStart[p] + j` at position `i`
is `departures[patternDepartureStart[p] + j·n + i]`, with n the pattern's stop count. Arrivals use
the same layout at `patternArrivalStart[p]`; a pattern whose every arrival equals its departure
has flag bit 0 set, arrival start `none`, and no arrivals stored. A feed that restarts the clock
at midnight inside a trip instead of writing `24:00:00`+ (PATH: `23:59:42` then `0:01:42`) is
unwrapped first: a time more than 12 h before the trip's previous time is taken to be on the next
day, so the trip keeps its service day and runs past 24:00. Hours need not be zero-padded
(`0:48:00`), and a UTF-8 BOM before a header is ignored. Missing intermediate times are
interpolated by position; times are made non-decreasing along each trip.

**Stops.** Every stop some kept trip calls at, every ancestor (`parent_station`) of one, and for
the subway the street entrances from the data.ny.gov dataset "MTA Subway Entrances and Exits:
2024" (`i9wp-a4ja`) as `stopKind` 2 children of their station (id `<station>-E<n>`, numbered per
station in (lat, lon, type) order; an entrance listed for a complex appears under each of its
stations). IDs are bare GTFS ids; qualified ids prefix the system code (`S:`, `B:`, `L:`, `F:`, `P:`).
Bus stops are merged by bare `stop_id` across the six zips, with name and coordinates from the
zip that has the most `stop_times` rows at the stop.

**PATH stations and transfers.** PANYNJ's feed has no parent stations and no `transfers.txt`:
each station is a `place_XXX` row (no `location_type`, no children) plus two boarding stops (four
at Journal Square) with the same name and coordinate. The compiler (`synthesizePATHStations`,
options `PATHStationOptions`) makes every place with platforms a station (`stopKind` 1),
gives each boarding stop the place with the same name within 150 m (else the nearest place
within 150 m) as its parent, and fails the build if any boarding stop is left without one.
It then adds a `transfer_type` 2 row between every two platforms of one station, both ways,
stored like the subway's `transfers.txt` rows: 60 s, or 120 s at Journal Square and World Trade
Center (different levels). Both steps are skipped for a feed that already has stations,
respectively transfers.

**Real-time match tables.** Subway keys are parsed from static trip ids with
`_(-?\d{6})_([A-Z0-9]+)\.+([NS])(.*)$` (leftmost match; `SubwayTripKey`), sorted by (route
bytes, direction, origin, path bytes, trip). LIRR matches exact trip ids through `tripIDOrder`;
bus SIRI refs match bare trip ids the same way and resolve to (agency, trip). Callers filter
matches to trips active on the real-time service date. PATH real time (`ridepath.json`) carries
no trip ids, only per station and direction a line color and seconds to arrival, so nothing is
stored for it: `Timetable.scheduledCalls(atStop:route:direction:boardingOnly:in:)` lists a
station's (or platform's) calls on one day view, in departure order, filtered by route index and
`direction_id` (PATH: 0 toward New York, 1 toward New Jersey), and the overlay matcher
(BikeRideKit, M2b) pairs predictions with those calls in order.

| Id | Section | Type | Count | Meaning |
|---|---|---|---|---|
| 1 | info | `i64` | 6 | system (ASCII code of `S`/`B`/`L`/`F`/`P`), windowStartDay, dayCount, timeZone (string), wordsPerSource (= ⌈dayCount / 64⌉), draftRevision (`1`; readers reject any other) |
| 2 | stringOffsets | `u32` | strings + 1 | CSR into stringBytes |
| 3 | stringBytes | `u8` | | UTF-8, concatenated |
| 10–13 | sourceName, sourceVersion, sourceETag, sourceSlot | `u32` | sources | Feed name (e.g. `gtfs_b`), `feed_info.feed_version`, HTTP ETag (strings); slot index |
| 14 | sourceSelectedDays | `u64` | sources × wordsPerSource | Bit `d % 64` of word `source·wordsPerSource + d / 64`: selected on window day d |
| 20–22 | agencyGTFSID, agencyName, agencyTimezone | `u32` | agencies | Strings |
| 30 | routeAgency | `u32` | routes | Agency index |
| 31–33 | routeGTFSID, routeShortName, routeLongName | `u32` | routes | Strings |
| 34, 35 | routeColor, routeTextColor | `u32` | routes | `0xRRGGBB`, or none |
| 36 | routeMode | `u8` | routes | 0 subway, 1 local bus, 2 SBS (`route_id` ends `+`), 3 express bus (`route_id` starts X, BM, BxM, QM or SIM, any case), 4 LIRR, 5 ferry, 6 PATH |
| 37 | routeType | `u16` | routes | GTFS `route_type` |
| 40–42 | stopGTFSID, stopName, stopCode | `u32` | stops | Strings |
| 43, 44 | stopLatE6, stopLonE6 | `i32` | stops | |
| 45 | stopParent | `u32` | stops | Stop index, or none |
| 46 | stopKind | `u8` | stops | GTFS `location_type`: 0 stop/platform, 1 station, 2 entrance |
| 47 | stopAccess | `u8` | stops | Bit 0 entry, bit 1 exit allowed. 3 for every GTFS stop |
| 48 | stopEntranceType | `u32` | stops | Entrance type (`Stair`, `Elevator`, `Easement - Street`, …) string; 0 for non-entrances |
| 50 | ruleGTFSID | `u32` | rules | `service_id` string |
| 51 | ruleSource | `u32` | rules | Source index |
| 52 | ruleWeekdays | `u8` | rules | Bit 0 Monday … bit 6 Sunday; bit 7 set when a `calendar.txt` row exists |
| 53, 54 | ruleStartDay, ruleEndDay | `i32` | rules | `calendar.txt` range, inclusive; 0 without a row |
| 55 | ruleExceptionStart | `u32` | rules + 1 | CSR into exception* |
| 56 | exceptionDay | `i32` | exceptions | Strictly ascending within a rule |
| 57 | exceptionType | `u8` | exceptions | 1 added, 2 removed |
| 60 | patternRoute | `u32` | patterns | Route index |
| 61 | patternStopStart | `u32` | patterns + 1 | CSR into patternStop* (at least 2 stops each) |
| 62 | patternTripStart | `u32` | patterns + 1 | CSR over trips: a pattern's trips are contiguous, by first departure |
| 63 | patternFlags | `u8` | patterns | Bit 0 arrivals equal departures; bit 1 shape synthesized from stops |
| 64 | patternDepartureStart | `u32` | patterns | Start of the pattern's departure matrix |
| 65 | patternArrivalStart | `u32` | patterns | Start of its arrival matrix, or none (flag bit 0) |
| 66 | patternShape | `u32` | patterns | Shape index, or none |
| 67 | patternBaseKey | `u32` | patterns | Equal for sub-patterns split from one key |
| 70 | patternStopIndex | `u32` | pattern stops | Stop index, in calling order |
| 71 | patternStopFlags | `u8` | pattern stops | Bit 0 pickup allowed (`pickup_type` ≠ 1), bit 1 drop-off allowed |
| 72 | patternStopShapeVertex | `u32` | pattern stops | Index of the stop's vertex within the pattern's shape (non-decreasing), or none |
| 80 | departures | `u32` | stop events | Seconds from the service day's origin |
| 81 | arrivals | `u32` | stored arrivals | Same |
| 90 | tripPattern | `u32` | trips | Pattern index |
| 91 | tripRule | `u32` | trips | Rule index |
| 92–94 | tripGTFSID, tripHeadsign, tripShortName | `u32` | trips | Strings |
| 95 | tripDirection | `u8` | trips | `direction_id`, or 255 |
| 100 | stopPatternStart | `u32` | stops + 1 | CSR into stopPattern* |
| 101, 102 | stopPatternRef, stopPatternPosition | `u32` | pattern stops | Each pattern calling at the stop, and the stop's position in it |
| 110, 111 | transferFromStop, transferToStop | `u32` | transfers | Stop indices (parent-level rows keep their station ids; PATH's synthesized rows are platform-level) |
| 112, 113 | transferFromTrip, transferToTrip | `u32` | transfers | Trip indices, or none |
| 114 | transferType | `u8` | transfers | GTFS `transfer_type`; 1 with both trips = guaranteed (LIRR) |
| 115 | transferMinSeconds | `u32` | transfers | `min_transfer_time`, or none. Rows sorted by (fromTrip, toTrip, fromStop, toStop, type, time), none last |
| 120 | shapeGTFSID | `u32` | shapes | `shape_id` string; 0 for a shape synthesized through the stops |
| 121 | shapePointStart | `u32` | shapes + 1 | CSR into shape points |
| 122, 123 | shapeLatE6, shapeLonE6 | `i32` | shape points | Douglas–Peucker at 5 m, keeping every vertex a stop maps to |
| 130 | subwayKeyRoute | `u32` | keys | Route token string (subway only; empty elsewhere) |
| 131 | subwayKeyDirection | `u8` | keys | ASCII `N` or `S` |
| 132 | subwayKeyOrigin | `i32` | keys | Origin in hundredths of a minute past the service day's origin |
| 133 | subwayKeyPath | `u32` | keys | The rest of the id after the direction, string |
| 134 | subwayKeyTrip | `u32` | keys | Trip index |
| 140 | tripIDOrder | `u32` | trips | Trip indices sorted by `trip_id` bytes, then index |
| 141 | stopIDOrder | `u32` | stops | Stop indices sorted by `stop_id` bytes, then index |

Invariants, checked by `Timetable` at open (bounds only, a few ms; the compiler also runs
`TimetableData.validate()` before writing): offsets start at 0, never decrease and end at their
target's count; parallel sections have equal counts; every index and string id is in range
(`none` only where allowed); each trip lies in its pattern's range; each pattern's matrices lie
inside `departures`/`arrivals`; shape vertices lie inside the pattern's shape; dates are
representable; `info` agrees with the header kind and `wordsPerSource`; the time zone is a known
IANA id.

### `stations` (kind 2, format 0, draft revision 1)

Citi Bike stations and the dense station × station bike-distance matrix. Writer:
`StationsArtifactWriter`, filled by `StationsCompiler` / `StationsBuilder` (BRBuild). Reader:
`MappedStations` (BRStreetCore), which views every array in place. `builtAgainst` names the
`streets` artifact whose segment numbering the stored snaps use.

**Stations.** From GBFS 2.3 `station_information` (found through Citi Bike's discovery feed,
English feeds). A station is kept when its `region_id` is 71, 185 or 158 (New York City), 70
(Jersey City) or 311 (Hoboken), or it has no `region_id` and lies inside the service area (the
union of the `streets` regions), and its `capacity` is positive; any other region, such as the
test regions 189 and 190, is dropped. A repeated `station_id` keeps its first entry. Stations are
ordered along a Hilbert curve through the fixed box 40.4680–40.9270 N, 74.2710–73.6880 W (the
New York extract's clip, which also covers Jersey City and Hoboken), ties broken by the UTF-8 bytes of the id, so neighbors get neighboring indices; a
separate id-sorted index serves lookups by id.

**Snaps.** Each station is snapped twice, within 250 m: to the nearest segment the matrix
profile can ride (the matrix's end points) and to the nearest walkable segment (for walk trees).
A snap is stored as (segment, fraction along it from its A node as `f32`, straight-line distance
as `u16` decimeters); `MappedStreetGraph.snappedPoint(_:query:)` rebuilds the `SnappedPoint`.
The matrix is computed from the stored values, so the app reproduces it exactly.

**Matrix.** `matrix[i][j]` is the true length, in decameters, of the minimum *cost* path from
station i to station j under the stored bike profile (class multipliers protected 0.8, painted
0.9, shared 1.0, arterial 1.3; one-ways; dismount edges at walking pace), plus both snap legs.
The path is the one `Dijkstra` seeded with `SnappedPoint.searchSeeds` finds, read with
`ShortestPathTree.arrival(at:)` (ties to the A→B edge), or the straight run along a shared
segment when that costs no more. Lengths round to the nearest decameter; `0xFFFF` marks no path
(including every pair with a station that did not snap) or a length above 655,340 m; the
diagonal is 0. Every pair between a New Jersey and a Manhattan, Brooklyn, Queens or Bronx
station is `0xFFFF`: no bike path crosses the Hudson (New Jersey's streets join only Staten
Island's, over the Bayonne Bridge path), so riders change bikes only through PATH. Ride time is length ÷ the rider's speed, computed on the device.

Counts: N stations, S strings.

| Field | Encoding | Notes |
|---|---|---|
| magic | `bytes[4]` | ASCII `STNS` |
| draftRevision | `u32` | `1`. Readers reject any other |
| N | `u64` | Below 65,535 |
| matrixProfile | `array<f64>`, 6 | speed (m/s), dismount speed (m/s), multipliers protected, painted, shared, arterial |
| stringOffsets | `array<u32>`, S + 1 | String s is `stringBytes[offsets[s] ..< offsets[s + 1]]`; string 0 is empty |
| stringBytes | `array<u8>` | UTF-8, concatenated, each distinct string once |
| stationIDs | `array<u32>`, N | GBFS `station_id` (string id), unique |
| stationIDOrder | `array<u32>`, N | Station indices sorted by id bytes (strictly ascending) |
| stationNames | `array<u32>`, N | `name` |
| stationShortNames | `array<u32>`, N | `short_name` (trip data joins on it byte for byte) |
| stationRegions | `array<u32>`, N | `region_id`, or 0 when absent |
| stationLatE6, stationLonE6 | `array<i32>`, N each | Microdegrees |
| stationCapacities | `array<u16>`, N | Nominal docks, > 0 |
| stationFlags | `array<u8>`, N | Bit 0 charging, 1 kept by the service-area test (no region), 2 bike-snapped, 3 walk-snapped |
| bikeSnapSegments | `array<u32>`, N | Segment, or `0xFFFFFFFF` when not bike-snapped |
| bikeSnapFractions | `array<f32>`, N | In [0, 1]; 0 when not snapped |
| bikeSnapDecimeters | `array<u16>`, N | Snap distance |
| walkSnapSegments, walkSnapFractions, walkSnapDecimeters | as the three above | The walk snap |
| matrixHigh | `array<u8>`, N² | High byte of `matrix[i][j]` at `i·N + j` |
| matrixLow | `array<u8>`, N² | Low byte, same order |

Nothing follows the last array. Two byte planes rather than `u16`s: the slowly varying high
bytes compress far better apart from the noisy low ones (NYC alone: 11.4 MB raw, 3.2 MB xz, against
7.3 MB xz for plain `u16`s in id order). A lookup reads one byte from each plane.

Invariants, checked by `MappedStations` at open: lengths match N; string offsets start at 0,
never decrease and end at the byte count; every string id is in range; `stationIDOrder` is in
range with strictly ascending id bytes (so ids are unique); flags hold only known bits; a snap
segment is present exactly when its snapped flag is set, and fractions lie in [0, 1]; the
diagonal is 0; the profile values are finite and positive.

### `links` (kind 7, format 0, draft revision 2)

Footpaths between transit stops, each stop's street access points, and walk links between stops
and Citi Bike stations. Writer: `LinksArtifactWriter`, filled by `LinksCompiler` /
`LinksBuilder` (BRBuild). Reader: `MappedLinks` (BRTimetable). `builtAgainst` names the
`streets`, `stations` and `tt-*` artifacts it was built from.

**Global stop index.** One index over every stop of the five timetables, in the order subway,
bus, LIRR, ferry, PATH (draft revision 2 added PATH): stop `local` of system s is `base(s) + local`, where `base` is the running sum
of `systemStopCounts`. A system that was not linked has count 0. A stop is *routable* when a
route pattern calls there; footpaths and station links exist only between routable stops.

**Access points.** Where riders pass between the street and a routable stop: the subway
station's entrances (data.ny.gov entrances, with their entry/exit permissions); a station with no
entrance of its own uses its own coordinate (flag *synthetic*); a bus, LIRR or ferry stop uses its
own position (a PATH station, having no entrance data, uses its own coordinate). Each is snapped
to the nearest walkable segment within 150 m (250 m for the ferry) and stored like the station
snaps above. LIRR stops with nothing within 150 m (all of
Long Island) have no access point: they are ride-through only. New Jersey's PATH stations snap to
the Hudson County and Newark streets like any other stop. Station access is charged once at
every street↔platform transition: subway 120 s, LIRR 240 s, bus 30 s, ferry 120 s, PATH 120 s. Walk access
from a point to a stop is the walk cost to the access point's snapped position + its snap
distance at walking speed (3.5 mph) + its access seconds.

**Footpaths.** Shortest paths over one directed graph: street nodes (walkable edges at walking
cost, stairs ×2); per access point an *exit* node (joined to its segment's ends by the partial
edges, rounded exactly as `SnappedPoint.searchSeeds` and `ShortestPathTree.arrival(at:)` round)
and an *entry* node (joined from them); a straight run between access points on one segment;
platform → exit node and entry node → platform at access + snap leg (only where the access
point allows exit, respectively entry); and platform → platform transfers. Transfers come from
`transfers.txt` rows without trips and with `transfer_type` ≠ 3: a parent-level row expands to
every pair of routable child platforms (a station's row to itself links its own platforms), at
`min_transfer_time` raised to at least `minTransferSeconds` (MTA lists 0 s for about 60
cross-platform rows), or the straight-line walking time when the row gives none. Configured
*fixed transfers* (`LinksOptions.fixedTransfers`) add indoor or very short walks between
stations of different systems the same way, both ways between every routable platform of each
end: PATH↔subway WTC → WTC Cortlandt (1) 240 s and → World Trade Center (E) 360 s via the Oculus,
14th St → 14 St (F M) and 23rd St → 23 St (F M) 180 s, 33rd St → 34 St-Herald Sq (B D F M and
N Q R W) 240 s. The street walk still wins where it is quicker.

p → q is listed when its cost is at most `maxFootpathWalkSeconds` + access(p) + access(q)
(each end's system access), i.e. at most 8 min of walking (about 750 m) between the two stops'
street access, or an in-station transfer. Costs are milliseconds while searching, then rounded
up to whole seconds. Because the values are shortest-path distances and rounding up preserves
sums, the triangle inequality holds exactly, and whenever p→q + q→r fits p→r's bound, p→r is
listed: RAPTOR never needs to chain footpaths. Walking through a platform (entering and leaving)
is allowed but pays access twice. Rows are sorted by (seconds, stop).

**Station links.** For every station with a walk snap, every routable stop with an access point
whose walk from the station (both snap legs included, station access excluded) costs at most
`stationLinkMaxWalkMeters` at walking speed (350 m ≈ 224 s). *Enter* seconds walk station →
stop through the best entry-allowed access point and include its access; *exit* seconds leave
through the best exit-allowed point and walk to the station. Walking is symmetric in the
streets artifact, so one search per station yields both. Stored both ways: per station by
(enter, stop), and per stop by (exit, station); `0xFFFF` marks a direction with no access
point within the bound.

Counts: T global stops, F footpaths, A access points, K stop→access-point entries, S stations,
L station links.

| Field | Encoding | Notes |
|---|---|---|
| magic | `bytes[4]` | ASCII `LNKS` |
| draftRevision | `u32` | `2`. Readers reject any other |
| maxFootpathWalkSeconds | `u32` | 480. At most 3,600 |
| minTransferSeconds | `u32` | 30 |
| walkSpeed | `f64` | m/s (3.5 mph) |
| stationLinkMaxWalkMeters | `f64` | 350 |
| systemStopCounts | `array<u32>`, 5 | Stops of tt-subway, tt-bus, tt-lirr, tt-ferry, tt-path (0 when not linked); T is their sum |
| systemAccessSeconds | `array<u32>`, 5 | Station access per system, same order |
| stopFlags | `array<u8>`, T | Bit 0 routable, 1 an access point allows entry from the street, 2 one allows exit to it |
| footpathStart | `array<u32>`, T + 1 | Footpaths of stop p: `[start[p], start[p + 1])` |
| footpathTarget | `array<u32>`, F | Global stop, never p itself |
| footpathSeconds | `array<u16>`, F | Whole seconds, station access included |
| accessPointSourceStop | `array<u32>`, A | Global stop whose position it is: an entrance, a station (synthetic) or the stop |
| accessPointLatE6, accessPointLonE6 | `array<i32>`, A each | Microdegrees |
| accessPointSegment | `array<u32>`, A | Walk segment of the `streets` artifact |
| accessPointFraction | `array<f32>`, A | In [0, 1], from the segment's A node |
| accessPointSnapDecimeters | `array<u16>`, A | Snap distance |
| accessPointAccessSeconds | `array<u16>`, A | Access at this transition |
| accessPointFlags | `array<u8>`, A | Bit 0 entry, 1 exit, 2 synthetic |
| stopAccessStart | `array<u32>`, T + 1 | Access points of stop p: `stopAccessPoint[start[p] ..< start[p + 1]]` |
| stopAccessPoint | `array<u32>`, K | Access point indices (only snapped points are stored) |
| stationStopStart | `array<u32>`, S + 1 | S is the `stations` artifact's count |
| stationStopStop | `array<u32>`, L | Global stop |
| stationStopEnter, stationStopExit | `array<u16>`, L each | Seconds or `0xFFFF` |
| stopStationStart | `array<u32>`, T + 1 | |
| stopStationStation | `array<u32>`, L | Station index |
| stopStationEnter, stopStationExit | `array<u16>`, L each | The same links, indexed by stop |

Nothing follows the last array. Rail bike-hop pairs (pickups near parent station A × docks near
B, rides of 5–25 min) join this artifact in M1.

Invariants, checked by `MappedLinks` at open: the parameters are in range; lengths match T, A, L
and S; every offset array starts at 0, never decreases and ends at its target's count; every
stop, access point and station index is in range; each footpath is within its bound (walk bound
+ both ends' access); flags hold only known bits; fractions lie in [0, 1]. `LinksCompiler` also
runs `FootpathCheck` over the whole table (every row and two-step chain: triangle inequality,
closure, sorting, no self-loops) and records the result in its report.
