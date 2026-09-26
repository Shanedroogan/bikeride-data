import BRData
import BRGeo
@testable import BRStreetCore
import Foundation
import Testing

/// Opens a real `streets.bin` and `stations.bin` with full validation and times the checks run
/// at open. Runs only when `BR_DATA_DIR` names a data directory, e.g.
///
///     BR_DATA_DIR=build/data swift test -c release -Xswiftc -enable-testing --filter RealDataTests
///
/// (release, so the timings are the app's.)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BR_DATA_DIR"] != nil))
struct RealDataTests {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BR_DATA_DIR"] ?? ".")

    /// The fastest of `runs` timings of `body`, and the median, in milliseconds.
    func milliseconds(runs: Int, _ body: () throws -> Void) rethrows -> (best: Double, median: Double) {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        samples.sort()
        return (samples[0], samples[samples.count / 2])
    }

    func format(_ timing: (best: Double, median: Double)) -> String {
        String(format: "best %.3f ms, median %.3f ms", timing.best, timing.median)
    }

    @Test func streetsOpenValidatedAndEnumChecksAreCheap() throws {
        let url = directory.appendingPathComponent(MappedStreetGraph.fileName)
        let graph = try MappedStreetGraph(contentsOf: url, validate: true)
        #expect(graph.extensions == .empty)
        print("streets: V \(graph.nodeCount), E \(graph.edgeCount), S \(graph.segmentCount), P \(graph.shapePointCount), N \(graph.nameCount), "
            + "grid \(graph.grid.columns)×\(graph.grid.rows) (\(graph.gridEntryCount) entries), regions \(graph.regions.map(\.code))")

        let enums = try milliseconds(runs: 50) { try graph.withBuffers { b throws(StreetsFormatError) in try MappedStreetGraph.checkEnums(b) } }
        print("streets: enum range check (\(graph.edgeCount) classes + \(graph.nameCount) kinds): \(format(enums))")
        // The scans validate() gained with the enum checks' move: edge access, grid order, name UTF-8.
        let added = milliseconds(runs: 20) {
            graph.withBuffers { b in
                let usable = EdgeFlags([.walk, .bikeForward]).rawValue
                precondition(b.edgeFlags.firstIndex { $0 & usable == 0 } == nil)
                for cell in 0..<graph.grid.cellCount {
                    let first = Int(b.cellOffsets[cell]), end = Int(b.cellOffsets[cell + 1])
                    guard first < end else { continue }
                    for slot in (first + 1)..<end { precondition(b.cellSegments[slot] > b.cellSegments[slot - 1]) }
                }
                precondition(!transcode(b.nameBytes.makeIterator(), from: UTF8.self, to: UTF32.self, stoppingOnError: true, into: { _ in }))
            }
        }
        print("streets: validate()'s new scans: \(format(added))")
        let validate = try milliseconds(runs: 10) { try graph.validate() }
        print("streets: validate() in all: \(format(validate))")
        let open = try milliseconds(runs: 10) { _ = try MappedStreetGraph(contentsOf: url, validate: false) }
        print("streets: open with validate: false (maps, reads regions, checks enums): \(format(open))")
    }

    @Test func stationsOpen() throws {
        let stations = try MappedStations.load(fromDataDirectory: directory)
        #expect(stations.extensions == .empty)
        let bike = (0..<stations.count).filter { stations.bikeSnap($0) != nil }.count
        let walk = (0..<stations.count).filter { stations.walkSnap($0) != nil }.count
        var reachable = 0
        for i in 0..<stations.count { reachable += stations.row(from: i).filter { $0 != StationsFormat.unreachable }.count }
        print("stations: \(stations.count) stations, \(bike) bike-snapped, \(walk) walk-snapped, \(reachable) reachable pairs, "
            + "builtAgainst \(stations.header.builtAgainst)")
        let open = try milliseconds(runs: 10) { _ = try MappedStations.load(fromDataDirectory: directory) }
        print("stations: open (always validated): \(format(open))")
    }
}
