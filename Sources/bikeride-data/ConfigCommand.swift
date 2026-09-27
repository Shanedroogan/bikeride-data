import Foundation

/// `bikeride-data config …`: builds the `config` artifact (kind 9) from the reviewed sources in
/// Data/config and Data/fares.
///
/// Not implemented yet (M1): says so and returns 64 (EX_USAGE), so neither a script nor `all` can
/// mistake the stub for a successful step.
func runConfigCommand(_ arguments: [String]) -> Int32 {
    FileHandle.standardError.write(Data("bikeride-data config: not implemented yet (M1)\n".utf8))
    return 64
}
