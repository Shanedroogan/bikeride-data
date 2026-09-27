import BRBuild
import BRCore
import Foundation

let configUsage = """
    USAGE: bikeride-data config [--config-sources DIR] [--data DIR] [--sources DIR] [--out DIR]
                                [--report FILE] [--offline] [--no-xz] [--require-references]

    Builds the config artifact from the reviewed sources in DIR/config and DIR/fares (read
    strictly: an unknown or misspelled key fails), checks it against the tt-* and stations
    artifacts (MTA and SIR stations, LIRR zones, fixed transfers, valet stations, station
    regions), and warns when Citi Bike's GBFS pricing plans differ from the configured prices.

      --config-sources DIR  Reviewed sources (default ./Data, else ./Vendor/bikeride-data/Data)
      --data DIR            Artifacts the reference checks read (default build/data); checks
                            whose artifact is missing are skipped with a warning
      --sources DIR         Source downloads; the GBFS pricing plans go to DIR/gbfs (default build/sources)
      --out DIR             config.bin and .xz (default: the data directory)
      --report FILE         Build report JSON (default <out>/../reports/config.json)
      --offline             Use the pricing plans already downloaded (skip the drift warning if absent)
      --no-xz               Skip compression
      --require-references  A missing reference input is an error (the pipeline sets this)

    Exit status: 0 built; 1 a source or build error; 3 a reference check failed (no config.bin
    is written; the report lists the errors).
    """

/// `bikeride-data config …`. Returns the process exit status.
func runConfigCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(configUsage)
        return 0
    }
    do {
        let options = try CommandOptions(
            arguments, valued: ["--config-sources", "--data", "--sources", "--out", "--report"],
            flags: ["--offline", "--no-xz", "--require-references"]
        )
        let sourcesDirectory = try options.values["--config-sources"].map(CommandOptions.absoluteURL) ?? defaultConfigSources()
        let data = options.url("--data", default: "build/data")
        let out = options.values["--out"].map(CommandOptions.absoluteURL) ?? data
        var configuration = ConfigCompiler.Configuration(
            sourcesDirectory: sourcesDirectory, dataDirectory: data, outputDirectory: out,
            gbfsDirectory: options.url("--sources", default: "build/sources").appendingPathComponent("gbfs")
        )
        configuration.offline = options.flags.contains("--offline")
        configuration.compress = !options.flags.contains("--no-xz")
        configuration.requireReferences = options.flags.contains("--require-references")
        let reportURL = options.values["--report"].map(CommandOptions.absoluteURL)
            ?? out.deletingLastPathComponent().appendingPathComponent("reports/config.json")

        let report = try ConfigCompiler(runner: ProcessToolRunner(), configuration: configuration).run { logLine("config", $0) }
        try writeJSONReport(report, to: reportURL)
        let passed = report.checks.filter(\.passed).count, skipped = report.checks.filter { $0.skipped != nil }.count
        print("config: \(report.checks.count) reference checks, \(passed) passed, \(skipped) skipped, "
            + "\(report.errors.count) errors, \(report.warnings.count) warnings")
        print("config: report \(reportURL.path)")
        guard let artifact = report.artifact else {
            let message = "bikeride-data config: reference checks failed; config.bin not written:\n  "
                + report.errors.joined(separator: "\n  ") + "\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 3
        }
        print("config: \(artifact.path) (\(artifact.rawBytes) bytes raw, \(artifact.xzBytes ?? 0) bytes xz), "
            + "payload sha256 \(report.payloadSha256)")
        return 0
    } catch let error as CommandOptions.UsageError {
        FileHandle.standardError.write(Data("bikeride-data config: \(error)\n\n\(configUsage)\n".utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("bikeride-data config: \(error)\n".utf8))
        return 1
    }
}

/// `./Data` when it holds the config sources (run from the bikeride-data checkout), else
/// `./Vendor/bikeride-data/Data` (run from the app repo).
private func defaultConfigSources() throws -> URL {
    for path in ["Data", "Vendor/bikeride-data/Data"] {
        let url = CommandOptions.absoluteURL(path)
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("config/app.json").path) { return url }
    }
    throw CommandOptions.UsageError(description: "no Data/config/app.json here; pass --config-sources DIR")
}
