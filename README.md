# bikeride-data

The public data pipeline for **Bike Ride**, an iOS app that plans New York City trips combining
Citi Bike, the subway, buses, the LIRR, PATH, the Staten Island Ferry and walking. All routing runs on
the phone; this package compiles public schedules and OpenStreetMap street data into compact,
memory-mappable binary artifacts that the app downloads.

This repository contains **no Citi Bike data** (test fixtures are synthetic), **no secrets**
(credentials live only in CI secrets) and no app code.

## Modules

| Module | Contents |
|---|---|
| `BRCore` | `Clock`, the service-day time model, typed IDs, `ToolRunner`, `SplitMix64` |
| `BRGeo` | Coordinates, haversine and bearings, local projection, point-in-polygon, polyline codec, grid index |
| `BRData` | Binary reader/writer, artifact header, `MappedArtifact`, `DatasetHandle`, xz codecs, SHA-256 |
| `BRStreetCore` | CSR street graph, walk and bike cost profiles, Dijkstra (one-to-many, multi-source, forward/reverse), A*; the mapped `streets` and `stations` readers and snapping |
| `BRTimetable` | The mapped `tt-*` timetable and `links` readers: stops, patterns, trips, calendars, day views, real-time match tables, footpaths |
| `BRConfig` | The `config` artifact's wire types, writer and reader (draft format 0 until the M1 freeze) |
| `BRFlows` | The Citi Bike `flows` artifact's format and reader (M1; empty for now) |
| `BRBuild` | Artifact compilers (streets, timetables, stations, links) and the streaming byte-level CSV and OPL readers |
| `bikeride-data` | The command-line tool: `streets`, `timetables`, `stations`, `links`, `all` (and, in M1, `config`, `flows`, `gate`, `manifest`) |

Engine modules use Foundation only and build on macOS and Linux. Apple-only paths (CryptoKit,
the Compression framework) sit behind `#if canImport(...)` with portable fallbacks.

## Requirements

- Swift 6.0 or later (CI uses 6.4).
- Tools the CLI shells out to: `xz`, `osmium-tool`, `unzip`.
  - macOS: `brew bundle` (see `Brewfile`).
  - Debian/Ubuntu: `xargs -a apt-packages.txt sudo apt-get install -y`.

## Build and test

```sh
swift build
swift test
swift run bikeride-data version
```

Codec tests need `xz` and are skipped, with a message, when it is missing.

## Documentation

- [`docs/formats.md`](docs/formats.md): artifact header, binary primitives and each artifact's layout.
- [`docs/osm-derivation.md`](docs/osm-derivation.md): how the street data is derived from
  OpenStreetMap (the ODbL derivation recipe).

## Licenses and attribution

The code is MIT licensed (see `LICENSE`).

Street data is derived from OpenStreetMap, © OpenStreetMap contributors, available under the
[Open Database License](https://opendatacommons.org/licenses/odbl/). `docs/osm-derivation.md`
publishes how the derived street data is produced from it.

Transit schedules come from public GTFS feeds published by the MTA and NYC DOT and are used
under their terms. Bike Ride is not affiliated with or endorsed by the MTA, NYC DOT, Citi Bike
or Lyft.
