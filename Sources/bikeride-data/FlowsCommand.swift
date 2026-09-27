import Foundation

/// `bikeride-data flows …`: builds the `flows` artifact (kind 8) from the Citi Bike trip data.
///
/// Not implemented yet (M1): says so and returns 64 (EX_USAGE), so neither a script nor `all` can
/// mistake the stub for a successful step.
func runFlowsCommand(_ arguments: [String]) -> Int32 {
    FileHandle.standardError.write(Data("bikeride-data flows: not implemented yet (M1)\n".utf8))
    return 64
}
