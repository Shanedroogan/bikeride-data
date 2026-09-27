import Foundation

/// `bikeride-data gate …`: runs the validation gate over a built set and writes reports/gate.json.
///
/// Not implemented yet (M1): says so and returns 64 (EX_USAGE), so neither a script nor `all` can
/// mistake the stub for a successful step.
func runGateCommand(_ arguments: [String]) -> Int32 {
    FileHandle.standardError.write(Data("bikeride-data gate: not implemented yet (M1)\n".utf8))
    return 64
}
