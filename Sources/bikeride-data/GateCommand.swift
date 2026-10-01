import BRBuild
import BRCore
import Foundation

let gateUsage = """
    USAGE: bikeride-data gate [--data DIR] [--reports DIR] [--previous FILE] [--today YYYYMMDD]
                              [--repo-data DIR] [--now ISO8601] [--require-flows]
                              [--accept-trip-count-change LIST]

    Runs the validation gate over the set in --data and writes <reports>/gate.json: every required
    artifact present, opening and consistent with builtAgainst; xz blobs one stream / one block and
    decoding to rawSha256; coverage (under 3 days fails soft: the system is marked noSchedule);
    trip counts against the previous build; per-region street shares; stop snapping; the config's
    reference checks against the set (LIRR zones, MTA and SIR stations, fixed transfers, valet
    stations, station regions); the flows statistics in <reports>/flows.json (a failed flows build's
    <reports>/flows-failed.json is a warning).

      --data DIR       The set (default build/data)
      --reports DIR    Build reports, and where gate.json goes (default <data>/../reports)
      --previous FILE  The previous set's manifest.json (its trip-counts.json beside it): trip
                       counts are compared with it, and kinds missing from --data are carried from it
      --today DATE     Build day (default today in New York)
      --repo-data DIR  The repository's Data/ (gate/thresholds.json, gate/snap-allowlist.csv,
                       config/calendar/holidays.csv); default ./Data, ./Vendor/bikeride-data/Data,
                       or the source tree this binary was built from
      --now ISO8601    Timestamp for the report (default now)
      --require-flows  A set without flows fails (by default flows is optional)
      --accept-trip-count-change LIST
                       Systems whose trip-count change a person reviewed and accepts for this run
                       (subway, bus, lirr, ferry, path; comma-separated, no spaces): their dates
                       beyond the limit are warnings ("accepted: …"), not failures, and the list is
                       recorded in gate.json as acceptedTripCountChange. Every other check, a date
                       whose trips fall by more than maxAcceptedDropPercent (thresholds.json, 90 %;
                       to none included) and a previous build whose trip counts cannot be used
                       still fail

    Exit status: 0 pass or soft failure, 3 hard failure (publish nothing), 1 error, 64 usage.
    """

/// `bikeride-data gate …`. Returns the process exit status.
func runGateCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(gateUsage)
        return 0
    }
    do {
        let options = try CommandOptions(arguments, valued: ["--data", "--reports", "--previous", "--today", "--repo-data", "--now",
                                                                     "--accept-trip-count-change"],
                                         flags: ["--require-flows"])
        let data = options.url("--data", default: "build/data")
        let reports = options.values["--reports"].map(CommandOptions.absoluteURL) ?? data.deletingLastPathComponent().appendingPathComponent("reports")
        // No gate.json may survive a run that fails before writing its own (manifest would take it).
        try Gate.removeReport(in: reports)
        let today = try publishToday(options)
        let accepted = try options.values["--accept-trip-count-change"].map(Pipeline.tripCountChangeSystems(named:)) ?? []
        if !accepted.isEmpty {
            logLine("gate", "accepting the trip-count change of \(accepted.map(SetSystems.name).sorted().joined(separator: ", ")) "
                + "for this run (--accept-trip-count-change; recorded in gate.json)")
        }
        guard let repoData = options.values["--repo-data"].map(CommandOptions.absoluteURL) ?? GateConfiguration.defaultRepoData() else {
            throw CommandOptions.UsageError(description: "no Data/ directory with gate/thresholds.json found; pass --repo-data")
        }
        logLine("gate", "configuration from \(repoData.path)")
        var gate = Gate(dataDirectory: data, reportsDirectory: reports, previousManifest: options.values["--previous"].map(CommandOptions.absoluteURL),
                        today: today, configuration: try GateConfiguration.load(repoData: repoData), runner: ProcessToolRunner())
        if let now = try publishNow(options) { gate.now = now }
        gate.requiredKinds = SetManifest.requiredKinds(requireFlows: options.flags.contains("--require-flows"))
        gate.extraChecks = Gate.publishHooks
        gate.acceptedTripCountChange = accepted
        let started = Date()
        let report = try gate.run { logLine("gate", $0) }
        print("gate: \(report.status.rawValue) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; report \(gate.reportURL.path)")
        return report.status == .fail ? 3 : 0
    } catch let error as CommandOptions.UsageError {
        FileHandle.standardError.write(Data("bikeride-data gate: \(error)\n\n\(gateUsage)\n".utf8))
        return 64
    } catch let error as Pipeline.UsageError {
        FileHandle.standardError.write(Data("bikeride-data gate: \(error)\n\n\(gateUsage)\n".utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("bikeride-data gate: \(error)\n".utf8))
        return 1
    }
}

/// `--today YYYYMMDD`, default today in New York.
func publishToday(_ options: CommandOptions) throws -> ServiceDate {
    guard let text = options.values["--today"] else { return ServiceDate(containing: Date(), in: .nyc) }
    guard let date = ServiceDate(yyyymmdd: text) else { throw CommandOptions.UsageError(description: "--today needs YYYYMMDD") }
    return date
}

/// `--now` as ISO 8601 with a zone, or nil when absent.
func publishNow(_ options: CommandOptions) throws -> Date? {
    guard let text = options.values["--now"] else { return nil }
    guard let date = ISO8601DateFormatter().date(from: text) else { throw CommandOptions.UsageError(description: "--now needs ISO 8601, e.g. 2026-09-26T16:30:00Z") }
    return date
}
