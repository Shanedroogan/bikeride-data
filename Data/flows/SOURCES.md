# Flows build inputs

Build-only inputs of the `flows` compiler (`Sources/BRBuild/Flows/`). Nothing here ships in an
artifact: `flows.bin` records the sha-256 prefix of this file in its `dataVersion`.

The trip data itself (Citi Bike's monthly zips from the public `tripdata` bucket,
https://s3.amazonaws.com/tripdata) and anything derived from it, `flows.bin` included, is never
committed to this or any repository. The builder caches the zips in `build/trips` (gitignored).

## depots.csv

Trip-data station ids that are Citi Bike depots, shops and staff locations rather than stations.
Their trip ends are neither counted nor treated as unmatched (they are left out of the unmatched
gate's denominator), and the report lists how many there were.

`id,match,name,note`, one row per id, with a header row.

- `id`: the id as it appears in `start_station_id` / `end_station_id`, byte for byte. Quote an id
  with surrounding spaces (`"Shop "`).
- `match`: `exact` (the whole id) or `prefix` (any id starting with it).
- `name`, `note`: documentation only.

Sources: every id in the June–August 2026 NYC and JC trip files (`202606`–`202608`) that is not a
GBFS `short_name` (after the pad-0 repair) was listed with its trip-data station name, on
2026-09-27. These are the non-station ones (no counts here: figures derived from the trip data stay
out of this public repository while the licensing question is open; the build report has them):

| id | trip-data name |
|---|---|
| `1234.56` | Morgan HCT Charging |
| `SYS038` | Morgan Loading Docks |
| `SYS016` | Morgan Bike Mechanics |
| `Shop Morgan ` | Shop Morgan |
| `SYS033` | Pier 40 X2 |

The other unmatched ids of that scan are stations that have left GBFS since (for example
`5329.08` Murray St & West St, `5256.06` Vesey St & West St, `HB106` River St & Newark St) or old
variants of a station id (`6517.08_`, `5308.04_`, `3184.07_OLD`). They are not depots and stay
unmatched: the gate is about them.
