/// The artifact compilers: GTFS zips, OSM extracts, GBFS and trip data in; artifacts out.
///
/// Built: `streets` (`StreetsCompiler`), the `tt-*` timetables (`TimetableBuild`), `stations`
/// (`StationsCompiler`) and `links` (`LinksCompiler`). Every `.xz` blob is checked for exactly
/// one stream and one block by ``XZCheck``.
///
/// M1 work, one place each:
/// - Rail bike hops in `links`: `Links/` (hop builder and one-seat table), read by
///   `BRTimetable`'s links reader; documented under "links: rail bike hops" in `docs/formats.md`.
/// - `config` (kind 9): wire format and reader in the `BRConfig` module; sources, compiler and the
///   cross-artifact reference checks in `Config/`; sources in `Data/config/` and `Data/fares/`.
/// - `flows` (kind 8): format and reader in the `BRFlows` module; trip sources, parsing, binning,
///   smoothing and the writer in `Flows/`; build-only inputs in `Data/flows/`.
/// - Archived GTFS source versions (newest version per service date): `GTFSSources` and
///   `TimetableBuild`.
/// - The validation gate, the set manifest and the heartbeat: `Publish/`.
/// - Holidays: `Data/config/calendar/holidays.csv` is the only holiday list; config ships it, and
///   the flows compiler and the gate read it directly.
public enum Compilers {}
