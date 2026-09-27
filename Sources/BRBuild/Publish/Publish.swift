// Publish: what runs after the artifacts are built (M1).
//
// - `Gate` (`bikeride-data gate`): the validation gate over a built set, writing
//   `reports/gate.json` (`GateReport`). Its rules are functions of plain inputs in `GateChecks`;
//   its thresholds, snapping allowlist and holiday list come from the repository's `Data/`
//   (`GateConfiguration`). Other checks join through the `GateCheck` protocol.
// - `SetManifestBuilder` (`bikeride-data manifest`): `data/manifest.json` (`SetManifest`) and the
//   trip-count sidecar the next build's gate reads (`TripCountSidecar`), for a set the gate passed.
// - `SetHeartbeat`: `data/heartbeat.json`, written last.
// - `SetArtifacts`, `SetSystems`: reading a set's files; the system names and date form a set uses.
