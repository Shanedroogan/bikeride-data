import Foundation

/// `bikeride-data manifest …`: writes data/manifest.json for a built set, then data/heartbeat.json.
///
/// Not implemented yet (M1): says so and returns 64 (EX_USAGE), so neither a script nor `all` can
/// mistake the stub for a successful step.
func runManifestCommand(_ arguments: [String]) -> Int32 {
    FileHandle.standardError.write(Data("bikeride-data manifest: not implemented yet (M1)\n".utf8))
    return 64
}
