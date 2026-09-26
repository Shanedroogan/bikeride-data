import BRBuild
import BRCore
import BRGeo
import BRStreetCore
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let streetsUsage = """
    USAGE: bikeride-data streets [--sources DIR] [--out DIR] [--work DIR] [--report FILE] [--offline] [--no-xz]

    Builds the streets artifact (walk + bike graph, snap grid, service-area polygons) from the
    Geofabrik New York and New Jersey extracts and the NYC borough boundaries, downloading them into
    <sources> when missing or changed (conditional GET) unless --offline.

      --sources DIR   Source downloads (default build/sources)
      --out DIR       Raw artifact and .xz (default build/data)
      --work DIR      Intermediate .osm.pbf files (default <out>/../work/streets)
      --report FILE   Build report JSON (default <out>/../reports/streets.json)
      --offline       Use the files in <sources> as they are
      --no-xz         Skip compression

    USAGE: bikeride-data streets-route --from LAT,LON --to LAT,LON [--profile walk|ebike|classic] [--data DIR]

    Routes between two coordinates on build/data/streets.bin and prints the distance, time and
    street names.
    """

private struct StreetsArguments {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String], valued: Set<String>, flags known: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument) {
                guard index + 1 < arguments.count else { throw StreetsCommandError.usage("\(argument) needs a value") }
                values[argument] = arguments[index + 1]
                index += 2
            } else if known.contains(argument) {
                flags.insert(argument)
                index += 1
            } else {
                throw StreetsCommandError.usage("unknown argument '\(argument)'")
            }
        }
    }
}

private enum StreetsCommandError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message), .failed(let message): message
        }
    }
}

private func resolvedURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

/// Peak resident set size of this process and of its largest finished child, in bytes.
private func peakResidentBytes() -> (process: Int, children: Int) {
    (ResourceUsage.peakResidentBytes(), ResourceUsage.peakChildResidentBytes())
}

private func parseCoordinate(_ text: String) throws -> Coordinate {
    let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else { throw StreetsCommandError.usage("expected LAT,LON, got '\(text)'") }
    return Coordinate(lat: parts[0], lon: parts[1])
}

/// A checked route for the report.
private struct SanityRoute: Codable {
    var name: String
    var profile: String
    var from: [Double]
    var to: [Double]
    var expectedMiles: Double
    var toleranceShare: Double
    var miles: Double?
    var meters: Double?
    var minutes: Double?
    var snapMeters: [Double]
    var names: [String]
    var requiredName: String?
    var usesRequiredName: Bool?
    var milliseconds: Double
    var pass: Bool
}

private func streetNames(_ route: StreetRoute, in graph: MappedStreetGraph) -> [String] {
    var names: [String] = []
    for edge in route.edges {
        let name = graph.name(ofEdge: Int(edge))
        if names.last != name { names.append(name) }
    }
    return names
}

private func runRoute(
    _ name: String, graph: MappedStreetGraph, from: Coordinate, to: Coordinate, profile: String,
    expectedMiles: Double, tolerance: Double, requiredName: String? = nil
) -> SanityRoute {
    let start = Date()
    var check = SanityRoute(
        name: name, profile: profile, from: [from.lat, from.lon], to: [to.lat, to.lon],
        expectedMiles: expectedMiles, toleranceShare: tolerance, snapMeters: [], names: [],
        requiredName: requiredName, milliseconds: 0, pass: false
    )
    func route<P: CostProfile>(_ profile: P) -> StreetRoute? {
        guard let origin = graph.snap(from, profile: profile), let destination = graph.snap(to, profile: profile) else { return nil }
        check.snapMeters = [origin.distanceMeters, destination.distanceMeters]
        return try? graph.route(from: origin, to: destination, profile: profile)
    }
    let found: StreetRoute?
    switch profile {
    case "walk": found = route(WalkProfile.standard)
    case "classic": found = route(BikeProfile.classic)
    default: found = route(BikeProfile.eBike)
    }
    check.milliseconds = Date().timeIntervalSince(start) * 1000
    guard let found else { return check }
    let miles = found.lengthMeters / 1609.344
    check.meters = found.lengthMeters
    check.miles = miles
    check.minutes = Double(found.costMs) / 60_000
    check.names = streetNames(found, in: graph)
    var pass = abs(miles - expectedMiles) <= expectedMiles * tolerance
    if let requiredName {
        let uses = check.names.contains { $0.localizedCaseInsensitiveContains(requiredName) }
        check.usesRequiredName = uses
        pass = pass && uses
    }
    check.pass = pass
    return check
}

/// One-to-many search timings on this machine (host numbers, not the phone's).
private struct TreeBenchmark: Codable {
    var name: String
    var origins: Int
    var maxMinutes: Double?
    var medianMilliseconds: Double
    var maxMilliseconds: Double
    var medianReachedNodes: Int
}

/// Snaps a fixed spread of Manhattan and Brooklyn origins and times a tree from each.
private func benchmarkTrees<P: CostProfile>(_ name: String, graph: MappedStreetGraph, profile: P, maxMinutes: Double?) -> TreeBenchmark {
    let origins = [
        (40.7359, -73.9911), (40.7527, -73.9772), (40.7061, -74.0087), (40.7812, -73.9665), (40.8116, -73.9465),
        (40.6925, -73.9903), (40.6782, -73.9442), (40.7171, -73.9568), (40.7440, -73.9180), (40.7484, -73.9857),
    ].map { Coordinate(lat: $0.0, lon: $0.1) }
    var times: [Double] = [], reached: [Int] = []
    let bound = maxMinutes.map { UInt32($0 * 60_000) } ?? StreetCost.maxFinite
    for origin in origins {
        let start = Date()
        guard let (_, tree) = try? graph.shortestPathTree(from: origin, profile: profile, maxCostMs: bound) else { continue }
        times.append(Date().timeIntervalSince(start) * 1000)
        reached.append(tree.costMs.lazy.filter { $0 != ShortestPathTree.unreached }.count)
    }
    times.sort()
    reached.sort()
    return TreeBenchmark(
        name: name, origins: times.count, maxMinutes: maxMinutes,
        medianMilliseconds: times.isEmpty ? 0 : times[times.count / 2], maxMilliseconds: times.last ?? 0,
        medianReachedNodes: reached.isEmpty ? 0 : reached[reached.count / 2]
    )
}

func runStreetsCommand(_ arguments: [String]) -> Int32 {
    do {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(streetsUsage)
            return 0
        }
        let parsed = try StreetsArguments(
            arguments, valued: ["--sources", "--out", "--work", "--report"], flags: ["--offline", "--no-xz"]
        )
        let started = Date()
        let sources = resolvedURL(parsed.values["--sources"] ?? "build/sources")
        let out = resolvedURL(parsed.values["--out"] ?? "build/data")
        var configuration = StreetsCompiler.Configuration(
            sourcesDirectory: sources, outputDirectory: out, workDirectory: parsed.values["--work"].map(resolvedURL)
        )
        configuration.offline = parsed.flags.contains("--offline")
        configuration.compress = !parsed.flags.contains("--no-xz")
        let reportURL = parsed.values["--report"].map(resolvedURL)
            ?? out.deletingLastPathComponent().appendingPathComponent("reports/streets.json")

        let compiler = StreetsCompiler(runner: ProcessToolRunner(), configuration: configuration)
        let report = try compiler.run { FileHandle.standardError.write(Data("streets: \($0)\n".utf8)) }
        let buildSeconds = Date().timeIntervalSince(started)
        let peak = peakResidentBytes()

        // Sanity routes over the artifact just written (mapped fresh, as the app would).
        let openStart = Date()
        let graph = try MappedStreetGraph.load(fromDataDirectory: out, validate: true)
        let openMilliseconds = Date().timeIntervalSince(openStart) * 1000
        let unionSquare = Coordinate(lat: 40.7359, lon: -73.9911)
        let checks = [
            runRoute("Union Sq → Washington Sq (walk)", graph: graph, from: unionSquare,
                     to: Coordinate(lat: 40.7308, lon: -73.9973), profile: "walk", expectedMiles: 0.54, tolerance: 0.15),
            runRoute("Union Sq → Bedford Av, Williamsburg (bike)", graph: graph, from: unionSquare,
                     to: Coordinate(lat: 40.7171, lon: -73.9568), profile: "ebike", expectedMiles: 4.2, tolerance: 0.15,
                     requiredName: "Williamsburg Bridge"),
            // New Jersey is in the graph (Hudson County's network, apart from the city's).
            runRoute("Hoboken Terminal → Journal Square (bike)", graph: graph, from: Coordinate(lat: 40.7353, lon: -74.0290),
                     to: Coordinate(lat: 40.7327, lon: -74.0629), profile: "ebike", expectedMiles: 2.4, tolerance: 0.15),
        ]
        for check in checks {
            let miles = check.miles.map { String(format: "%.2f mi", $0) } ?? "no route"
            FileHandle.standardError.write(Data("streets: sanity \(check.pass ? "PASS" : "FAIL") \(check.name): \(miles) (expected \(check.expectedMiles) ± \(Int(check.toleranceShare * 100))%)\n".utf8))
        }

        let trees = [
            benchmarkTrees("walk tree, 20 min", graph: graph, profile: WalkProfile.standard, maxMinutes: 20),
            benchmarkTrees("e-bike tree, whole city", graph: graph, profile: BikeProfile.eBike, maxMinutes: nil),
        ]
        for tree in trees {
            FileHandle.standardError.write(Data(String(
                format: "streets: %@: median %.1f ms, max %.1f ms, %d nodes reached (median)\n",
                tree.name, tree.medianMilliseconds, tree.maxMilliseconds, tree.medianReachedNodes
            ).utf8))
        }

        struct FullReport: Encodable {
            var build: StreetsCompiler.Report
            var buildSeconds: Double
            var peakRSSBytes: Int
            var peakChildRSSBytes: Int
            var mappedOpenValidateMilliseconds: Double
            var sanity: [SanityRoute]
            var trees: [TreeBenchmark]
        }
        let full = FullReport(
            build: report, buildSeconds: buildSeconds, peakRSSBytes: peak.process, peakChildRSSBytes: peak.children,
            mappedOpenValidateMilliseconds: openMilliseconds, sanity: checks, trees: trees
        )
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(full).write(to: reportURL)
        print("streets: \(report.artifact.path) (\(report.artifact.rawBytes) bytes raw, \(report.artifact.xzBytes ?? 0) bytes xz)")
        print("streets: report \(reportURL.path)")
        return checks.allSatisfy(\.pass) ? 0 : 2
    } catch let error as StreetsCommandError {
        if case .usage = error { FileHandle.standardError.write(Data("bikeride-data streets: \(error)\n\n\(streetsUsage)\n".utf8)); return 64 }
        FileHandle.standardError.write(Data("bikeride-data streets: \(error)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("bikeride-data streets: \(error)\n".utf8))
        return 1
    }
}

func runStreetsRouteCommand(_ arguments: [String]) -> Int32 {
    do {
        let parsed = try StreetsArguments(arguments, valued: ["--from", "--to", "--profile", "--data"], flags: [])
        guard let from = parsed.values["--from"], let to = parsed.values["--to"] else {
            throw StreetsCommandError.usage("--from and --to are required")
        }
        let graph = try MappedStreetGraph.load(fromDataDirectory: resolvedURL(parsed.values["--data"] ?? "build/data"))
        let profile = parsed.values["--profile"] ?? "walk"
        let check = runRoute("route", graph: graph, from: try parseCoordinate(from), to: try parseCoordinate(to),
                             profile: profile, expectedMiles: 0, tolerance: 0)
        guard let miles = check.miles, let minutes = check.minutes else {
            print("no route")
            return 1
        }
        print(String(format: "%.2f mi (%.0f m), %.1f min, snapped %.0f m / %.0f m, %.1f ms",
                     miles, check.meters ?? 0, minutes, check.snapMeters[0], check.snapMeters[1], check.milliseconds))
        print(check.names.joined(separator: " → "))
        return 0
    } catch {
        FileHandle.standardError.write(Data("bikeride-data streets-route: \(error)\n\n\(streetsUsage)\n".utf8))
        return 64
    }
}
