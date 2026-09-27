import BRBuild
import BRCore
import Foundation

let flowsUsage = """
    USAGE: bikeride-data flows [--sources DIR] [--trips DIR] [--out DIR] [--report FILE] [--months LIST]
                               [--holidays FILE] [--depots FILE] [--threads N] [--offline] [--no-xz]

    Builds the flows artifact from the public Citi Bike trip data: the newest three months published
    for both NYC and JC (s3.amazonaws.com/tripdata), joined on GBFS short_name against the full
    station_information (capacity 0 included), binned by 15 minutes, smoothed, and gated. The gate
    must pass for flows.bin to be replaced.

      --sources DIR   Source downloads; GBFS goes to DIR/gbfs (default build/sources)
      --trips DIR     Trip-zip cache and saved listing (default build/trips). Trip data and flows
                      files never go into a repository
      --out DIR       Raw artifact and .xz (default build/data)
      --report FILE   Build report JSON (default <out>/../reports/flows.json); also the previous
                      report the month row counts are compared against
      --months LIST   Build these months instead of the newest three: YYYYMM-YYYYMM or YYYYMM,YYYYMM,…
      --holidays FILE Holiday calendar (default: this package's Data/config/calendar/holidays.csv)
      --depots FILE   Depot ids (default: this package's Data/flows/depots.csv)
      --threads N     Parallel zip entries (default: every core)
      --offline       Use the saved listing and the cached zips and GBFS
      --no-xz         Skip compression

    EXIT STATUS: 0 built; 3 gate failure (flows.bin kept); 4 nothing new, or offline without the
    inputs (flows.bin kept; the report is left as it was); 1 any other error; 64 usage.
    """

/// This package's `Data/` directory, found from this source file's path at build time.
private let packageDataDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Data")

/// `--months`: `YYYYMM-YYYYMM` (inclusive), or a comma-separated list of consecutive months.
func parseMonths(_ text: String) throws -> [TripMonth] {
    let usage = CommandOptions.UsageError(description: "--months needs YYYYMM-YYYYMM or YYYYMM,YYYYMM,… (consecutive)")
    var months: [TripMonth]
    if text.contains("-") {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = TripMonth(yyyymm: parts[0]), let last = TripMonth(yyyymm: parts[1]), first <= last else { throw usage }
        months = [first]
        while let current = months.last, current < last { months.append(current.adding(1)) }
    } else {
        months = try text.split(separator: ",", omittingEmptySubsequences: false).map { part in
            guard let month = TripMonth(yyyymm: part.trimmingCharacters(in: .whitespaces)) else { throw usage }
            return month
        }
    }
    guard !months.isEmpty, months.count <= 12, zip(months, months.dropFirst()).allSatisfy({ $0.adding(1) == $1 }) else { throw usage }
    return months
}

/// `bikeride-data flows …`. Returns the process exit status.
func runFlowsCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(flowsUsage)
        return 0
    }
    let configuration: FlowsCompiler.Configuration
    let reportURL: URL
    do {
        let options = try CommandOptions(
            arguments, valued: ["--sources", "--trips", "--out", "--report", "--months", "--holidays", "--depots", "--threads"],
            flags: ["--offline", "--no-xz"]
        )
        let out = options.url("--out", default: "build/data")
        var config = FlowsCompiler.Configuration(
            sourcesDirectory: options.url("--sources", default: "build/sources"),
            tripsDirectory: options.url("--trips", default: "build/trips"),
            outputDirectory: out,
            holidaysFile: options.values["--holidays"].map(CommandOptions.absoluteURL)
                ?? packageDataDirectory.appendingPathComponent("config/calendar/holidays.csv"),
            depotsFile: options.values["--depots"].map(CommandOptions.absoluteURL)
                ?? packageDataDirectory.appendingPathComponent("flows/depots.csv")
        )
        config.offline = options.flags.contains("--offline")
        config.compress = !options.flags.contains("--no-xz")
        if let threads = try options.int("--threads") { config.threads = threads }
        if let months = options.values["--months"] { config.months = try parseMonths(months) }
        configuration = config
        reportURL = options.values["--report"].map(CommandOptions.absoluteURL)
            ?? out.deletingLastPathComponent().appendingPathComponent("reports/flows.json")
    } catch {
        FileHandle.standardError.write(Data("bikeride-data flows: \(error)\n\n\(flowsUsage)\n".utf8))
        return 64
    }
    for file in [configuration.holidaysFile, configuration.depotsFile] where !FileManager.default.fileExists(atPath: file.path) {
        FileHandle.standardError.write(Data("bikeride-data flows: \(file.path) does not exist (pass --holidays / --depots)\n".utf8))
        return 64
    }

    do {
        var previous: FlowsReport?
        if let data = try? Data(contentsOf: reportURL) {
            previous = try? JSONDecoder().decode(FlowsReport.self, from: data)
            if previous == nil { logLine("flows", "warning: \(reportURL.path) is not a flows report; month row counts will not be compared") }
        }
        let report = try FlowsCompiler(runner: ProcessToolRunner(), configuration: configuration).run(previous: previous) { logLine("flows", $0) }
        switch report.outcome {
        case .built:
            try writeJSONReport(report, to: reportURL)
            let artifact = report.artifact
            print("flows: \(artifact?.path ?? "") (\(artifact?.rawBytes ?? 0) bytes raw, \(artifact?.xzBytes ?? 0) bytes xz), "
                + "\(report.gbfs?.keys ?? 0) keys, \(report.months.map(\.yyyymm).joined(separator: "-")) "
                + "in \(String(format: "%.1f", report.seconds["total"] ?? 0)) s")
            for system in report.systems {
                print(String(format: "flows: %@ unmatched %.3f%% start, %.3f%% end in %@ (window %.3f%%, %.3f%%); end pad-0 repairs %.3f%%",
                             system.system.rawValue, 100 * system.newestMonthStartSide.unmatchedShare, 100 * system.newestMonthEndSide.unmatchedShare,
                             system.newestMonth.yyyymm, 100 * system.startSide.unmatchedShare, 100 * system.endSide.unmatchedShare,
                             100 * system.endSide.repairedShare))
            }
            print("flows: report \(reportURL.path)")
            return 0
        case .gateFailed:
            try writeJSONReport(report, to: reportURL)
            for failure in report.gate.failures { logLine("flows", "gate failed: \(failure)") }
            logLine("flows", "kept the previous flows.bin; report \(reportURL.path)")
            return 3
        case .keptPrevious:
            logLine("flows", "\(report.reason ?? "nothing to build"); kept the previous flows.bin")
            return 4
        }
    } catch {
        FileHandle.standardError.write(Data("bikeride-data flows: \(error)\n".utf8))
        return 1
    }
}
