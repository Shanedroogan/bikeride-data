// BRFlows: the `flows` artifact (kind 8, format 0 until the M1 freeze).
//
// The Citi Bike station flows format: the sectioned `FLOW` payload (info, holidays, keys, station
// metadata, per-bin binary16 mean and variance cells), its writer (`FlowsData`), `MappedFlows`
// (the reader, with the stations-to-row join by GBFS short_name) and the bit-exact half-float
// codec (`HalfFloat`). The trip download, parsing, binning, smoothing and the build report live in
// BRBuild (`Sources/BRBuild/Flows/`). Layout: "flows" in docs/formats.md.
