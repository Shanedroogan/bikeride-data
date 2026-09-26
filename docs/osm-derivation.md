# How the street data is derived from OpenStreetMap

This is the **ODbL derivation recipe** for the `streets` artifact (and the `stations` matrix built
on it). It publishes how Bike Ride's street data is produced from OpenStreetMap, as the Open
Database License asks. OpenStreetMap data is © OpenStreetMap contributors and available under the
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/).

Everything below is what `bikeride-data streets` does. The code of record is
`Sources/BRBuild/Streets` (`StreetsCompiler`, `StreetProfileRules`, `StreetNetworkBuilder`); this
file changes in the same commit as the rules. The binary layout is in `docs/formats.md`.

## Sources

| Source | URL | Used for |
|---|---|---|
| Geofabrik New York extract | <https://download.geofabrik.de/north-america/us/new-york-latest.osm.pbf> | Streets, paths, parks |
| NYC Open Data *Borough Boundaries (Water Areas Included)*, NYC Department of City Planning | <https://data.cityofnewyork.us/resource/wh2p-dxnf.geojson> | Borough polygons, the city mask |

Downloads are conditional (`If-None-Match` with the saved ETag, `If-Modified-Since` from the file
time), so an unchanged source is not fetched again. `--offline` uses whatever is in `--sources`.

The water-included boundaries are used rather than the shoreline-clipped ones (`tqmj-j8zm`) so
that points on piers, at the water's edge and on bridges land in a borough; borough lines run
mid-river. Each ring is simplified with Douglas–Peucker at **10 m**, then stored at microdegree
precision.

## Commands

Run by `StreetsCompiler` through `ToolRunner` (paths shortened; intermediates live in
`build/work/streets/`):

```sh
# 0. Fetch (each source; the flags after --time-cond are added once the file exists).
curl --silent --show-error --fail --location --remote-time --retry 3 --connect-timeout 30 \
  --dump-header <file>.headers --output <file>.partial --write-out '%{http_code}' \
  --time-cond <file> --etag-compare <file>.etag <url>

# 1. Clip the state extract to the five boroughs' extent plus about 1 km (west,south,east,north).
#    complete_ways keeps every node of a way that crosses the box.
osmium extract --bbox=-74.271,40.468,-73.688,40.927 --strategy=complete_ways \
  --overwrite --no-progress -o nyc-bbox.osm.pbf new-york-latest.osm.pbf

# 2. Park areas, for the park flag and "park path" labels.
osmium tags-filter nyc-bbox.osm.pbf a/leisure=park,garden,nature_reserve a/landuse=recreation_ground \
  --overwrite --no-progress -o nyc-parks.osm.pbf

# 3. Every way with a highway tag. The profile rules below decide what each one becomes, so the
#    filter stays coarse: the rules need to see sidewalks and crossings too (see Connectors).
osmium tags-filter nyc-bbox.osm.pbf w/highway --overwrite --no-progress -o nyc-highways.osm.pbf

# 4. Inline node locations into the ways.
osmium add-locations-to-ways nyc-highways.osm.pbf --overwrite --no-progress -o nyc-highways-located.osm.pbf

# 5. Park polygons as GeoJSON lines, streamed into the compiler.
osmium export nyc-parks.osm.pbf -f geojsonseq --geometry-types=polygon --no-progress

# 6. The ways as OPL text, streamed into the compiler's byte-level line parser.
osmium cat nyc-highways-located.osm.pbf -t way -f opl,add_metadata=false,locations_on_ways=true

# 7. Compress to exactly one xz stream with one block, and check it.
xz -6 -T1 --check=crc32 --keep --force streets.bin
xz --robot --list streets.bin.xz
```

**City mask.** The box also covers parts of New Jersey, Westchester and Nassau. A way is kept
only if at least one of its nodes lies within **1 km** of a borough polygon (a 100 m raster of the
polygons, dilated by 1 km), so streets that leave and re-enter the city stay whole.

## Profile rules

### Which ways are streets

- **Routed `highway` values:** `trunk`, `trunk_link`, `primary`, `primary_link`, `secondary`,
  `secondary_link`, `tertiary`, `tertiary_link`, `unclassified`, `residential`, `living_street`,
  `service`, `road`, `footway`, `path`, `cycleway`, `pedestrian`, `steps`, `track`, `bridleway`.
- **Dropped:** every other value, including `motorway`, `motorway_link`, `construction`,
  `proposed`, `platform`, `corridor`, `busway` and `raceway`; and any way with `motorroad=yes`.
- **Areas:** `area=yes` is dropped, except `highway=pedestrian` and `highway=footway` areas
  (plazas), which are walked along their outline.
- **Access:** `access=no|private` removes both modes unless `foot=*` / `bicycle=*` grants one back.
  Values that allow: `yes`, `designated`, `permissive`, `destination`, `official`, `customers`,
  `delivery`, `discouraged`. Values that deny: `no`, `private`.

### The sidewalk network (dropped for walking)

**`footway=sidewalk` and `footway=crossing` are dropped**, along with the rest of the separately
mapped sidewalk network: `footway` or `path` = `sidewalk`, `crossing`, `traffic_island`, `link`,
`access_aisle`, and any `highway=footway|path` with a `crossing=*` tag other than `no`. Walking
follows street centerlines instead, which avoids directions like "turn onto the walkway".

Exceptions: a `highway=cycleway` in the sidewalk network (e.g. a bike crossing), or a sidewalk
piece with `bicycle=yes|designated|…`, is kept as a **bike-only** path.

**Connectors.** Park and plaza paths in New York often meet only the sidewalk network, never a
street centerline, so dropping sidewalks would strand them. The compiler walks the (walkable)
sidewalk network, sidewalks and crossings together, and adds each walk it needs as one edge,
flagged `connector` and named "sidewalk":

1. from every node where a kept walkable path touches the sidewalk network but no walkable
   street, to the nearest street-centerline node, at most **300 m**;
2. then, from every walkable component still too small to keep (see Components below) that
   touches the sidewalk network, such as a mews, a courtyard or a parking lot, to the nearest node
   of a component large enough to keep: one connector per such island, at most **2 km**. The
   longer limit is for islands reached on foot only along a bridge sidewalk: the Roosevelt Island
   Bridge carriageway is `foot=no`, so the island's walkable streets join the network only
   through a 431 m connector along the bridge's separately mapped sidewalk.

Bikes may be walked along connectors (`dismount`, priced at 3 mph). Instructions absorb
connectors instead of naming them.

### Walking

- Every routed way is walkable in both directions (one-ways do not apply), except:
  - `trunk` / `trunk_link` with `sidewalk=no|none`, `sidewalk:both=no|none`, or both
    `sidewalk:left` and `sidewalk:right` `no|none`;
  - `foot=no|private`, or denied general access without a `foot` grant.
- `foot=use_sidepath` keeps the centerline walkable, because the sidepath is a dropped sidewalk.
- **Steps** are walk-only, flagged `stairs`, and cost **twice** their length.
- Bridge promenades are ordinary footways with the `bridge` flag.

### Biking

- **Allowed by default:** `cycleway`, `track`, and roads below trunk (`primary` … `tertiary` and
  their links, `unclassified`, `residential`, `living_street`, `service`, `road`), unless
  `bicycle=no|private|use_sidepath|dismount`, or `access` / `vehicle` = `no|private` without a
  `bicycle` grant.
- **Only with an explicit `bicycle` grant:** `trunk`, `trunk_link`, `footway`, `path`,
  `pedestrian`, `bridleway`.
- **Never:** `steps`, areas.
- **One-ways** (`oneway=yes|true|1`, `-1|reverse`; `reversible|alternating` closes both ways;
  `junction=roundabout|circular` implies `yes`) apply to bikes unless:
  - `oneway:bicycle` is set (its value replaces `oneway` for bikes, e.g. `no`), or
  - a contraflow lane is tagged: any `cycleway*=opposite*` value, or a lane/track on
    `cycleway`, `cycleway:both`, `cycleway:left` or `cycleway:right` whose `:oneway` is `-1` or
    `no` against a forward one-way (`yes` or `no` against a reversed one).

### Bike infrastructure class (per direction)

| Class | Cost multiplier | When |
|---|---|---|
| protected | 0.8 | `highway=cycleway`; `footway`/`path`/`track`/`bridleway` open to bikes; a road side tagged `track`, `separate` or `opposite_track` |
| painted | 0.9 | A road side tagged `lane`, `share_busway`, `opposite_lane` or `opposite_share_busway` |
| shared | 1.0 | Residential and other minor roads, `pedestrian`, `living_street`, connectors; a side tagged `shared_lane`, `shoulder` or `opposite` |
| arterial | 1.3 | `trunk`, `primary`, `secondary`, `tertiary` (and links) with no better infrastructure in that direction |

Which direction a road's `cycleway*` tag serves: its own `…:oneway` tag if present; else, on a
one-way road, the one-way's direction; else `cycleway` and `cycleway:both` serve both directions,
`cycleway:right` the way's direction and `cycleway:left` the opposite (right-hand traffic).
`opposite*` values serve the direction against the one-way. The best class in each direction wins.

### Flags and names

- `bridge`: `bridge=*` other than `no`. `park`: a path-like way (`footway`, `path`, `cycleway`,
  `pedestrian`, `steps`, `track`, `bridleway`) whose midpoint lies in a park polygon from step 2.
  `stairs`, `connector`, `dismount`: as above.
- **Name:** `name`; else `bridge:name` on a bridge; else `ref` (a `;` list is shown as
  `A / B`); else a label derived from the way: `road`, `service road`, `driveway`,
  `parking aisle`, `alley`, `footpath`, `path`, `bike path`, `steps`, `pedestrian street`,
  `plaza`, `track`, `bridle path`, `bridge path`, `park path` (a footpath, path, pedestrian
  street, plaza or track inside a park) and `sidewalk` (connectors). Each name records which of
  the three it is, so instructions can describe a derived label rather than "turn onto" it.

## Graph construction

1. **Vertices** are way end nodes and nodes shared by two or more kept ways (or repeated within
   one). Every way is cut at its vertices into pieces.
2. **Degree-2 compression.** Pieces are joined through a vertex that only continues one street:
   exactly two piece ends meet there and they agree on name, flags, walk and bike access and bike
   class in each direction. Closed loops are anchored at one node. Interior nodes become shape
   points.
3. **Components.** Connected components over all usable segments are measured by length; those
   holding at least **5 %** of the largest one's length are kept. This keeps **Staten Island**,
   which no street joins to the rest of the city (the Verrazzano-Narrows Bridge is a motorway and
   the ferry is transit), and drops islets such as disconnected private paths. Then walk access
   is kept only inside walking components that pass the same test, and bike access only inside
   strongly connected components of the directed riding graph that pass it, so every rideable
   edge can be ridden to and from. Segments left with neither mode are removed.
4. **Per segment:** length from the full-resolution OSM geometry (haversine at 10⁻⁷°), stored in
   decimeters; entry and exit bearings measured over the first and last 10 m, quantized to
   1/256 turn; interior shape points simplified with Douglas–Peucker at **1 m** and stored as
   microdegrees.
5. **Order:** graph nodes along a Hilbert curve (neighbors close in memory), segments by their end
   nodes, names by UTF-8 bytes, so equal inputs give byte-identical artifacts.
6. **Snap grid:** 100 m cells; each cell lists every segment whose stored geometry passes through it.

The build report (`build/reports/streets.json`) records counts per drop reason, connectors,
components and the share of length each step removed.
