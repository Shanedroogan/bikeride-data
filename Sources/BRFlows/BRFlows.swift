// BRFlows: the `flows` artifact (kind 8, draft), M1.
//
// Will hold the Citi Bike station flows format: the sectioned `FLOW` payload (info, holidays,
// keys, station metadata, per-bin f16 rate and variance planes), `MappedFlows` (the reader,
// with a stations-to-row join by GBFS short_name) and the bit-exact half-float codec. The trip
// parsing, binning, smoothing and the writer live in BRBuild (`Sources/BRBuild/Flows/`). Layout:
// "flows (kind 8, draft)" in docs/formats.md.
//
// Empty until then; this file keeps the target compiling.
