// Publish: what runs after the artifacts are built, M1.
//
// Will hold the validation gate (`bikeride-data gate`, reports/gate.json), the set manifest
// (data/manifest.json, `bikeride-data manifest`) and the heartbeat (data/heartbeat.json, written
// last). The gate's xz check reuses `XZCheck`; its holiday list is
// Data/config/calendar/holidays.csv.
//
// Empty until then; this file keeps the directory in place.
