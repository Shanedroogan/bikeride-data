import BRBuild
import BRCore
import Foundation

let stationsUsage = """
    USAGE: bikeride-data stations [--sources DIR] [--out DIR] [--streets FILE] [--report FILE]
                                  [--threads N] [--offline] [--no-xz]

    Builds the stations artifact: Citi Bike stations from GBFS station_information (region 71,
    185, 158, 70 or 311, or no region and inside the service area; capacity > 0), snapped to the streets
    graph, and the dense station × station bike-distance matrix.

      --sources DIR   Source downloads; GBFS goes to DIR/gbfs (default build/sources)
      --out DIR       Raw artifact and .xz (default build/data)
      --streets FILE  Streets artifact to route on (default <out>/streets.bin)
      --report FILE   Build report JSON (default <out>/../reports/stations.json)
      --threads N     Parallel searches (default: every core)
      --offline       Use the GBFS files already in <sources>/gbfs
      --no-xz         Skip compression
    """

/// `bikeride-data stations …`. Returns the process exit status.
func runStationsCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(stationsUsage)
        return 0
    }
    do {
        let options = try CommandOptions(
            arguments, valued: ["--sources", "--out", "--streets", "--report", "--threads"], flags: ["--offline", "--no-xz"]
        )
        let out = options.url("--out", default: "build/data")
        var configuration = StationsCompiler.Configuration(
            sourcesDirectory: options.url("--sources", default: "build/sources"), outputDirectory: out,
            streetsFile: options.values["--streets"].map(CommandOptions.absoluteURL)
        )
        configuration.offline = options.flags.contains("--offline")
        configuration.compress = !options.flags.contains("--no-xz")
        if let threads = try options.int("--threads") { configuration.threads = threads }
        let reportURL = options.values["--report"].map(CommandOptions.absoluteURL)
            ?? out.deletingLastPathComponent().appendingPathComponent("reports/stations.json")

        let report = try StationsCompiler(runner: ProcessToolRunner(), configuration: configuration).run { logLine("stations", $0) }
        try writeJSONReport(report, to: reportURL)
        let artifact = report.artifact
        print("stations: \(artifact.path) (\(artifact.rawBytes) bytes raw, \(artifact.xzBytes ?? 0) bytes xz), "
            + "\(report.matrix.stations) stations in \(String(format: "%.1f", report.seconds["total"] ?? 0)) s")
        print("stations: report \(reportURL.path)")
        return 0
    } catch let error as CommandOptions.UsageError {
        FileHandle.standardError.write(Data("bikeride-data stations: \(error)\n\n\(stationsUsage)\n".utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("bikeride-data stations: \(error)\n".utf8))
        return 1
    }
}

func writeJSONReport<T: Encodable>(_ report: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: url, options: .atomic)
}
