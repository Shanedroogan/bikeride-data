// BRConfig: the `config` artifact (kind 9, draft), M1.
//
// Will hold the config wire format: the standard BRDA header, `CNFG` magic, payload revision,
// the UTF-8 JSON document and an empty extension tail; its Codable document types; the writer;
// and `MappedConfig`, the reader the app and the gate open. The compiler, its sources and the
// cross-artifact reference checks live in BRBuild (`Sources/BRBuild/Config/`). Layout:
// "config (kind 9, draft)" in docs/formats.md.
//
// Empty until then; this file keeps the target compiling.
