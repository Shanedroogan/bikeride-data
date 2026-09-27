import BRBuild
import BRCore
import Foundation

let allUsage = """
    USAGE: bikeride-data all [--sources DIR] [--out DIR] [--trips DIR] [--months LIST] [--config-sources DIR]
                             [--previous FILE] [--offline] [--no-xz] [--skip LIST] [--require-flows]
                             [--today YYYYMMDD] [--now ISO8601]

    Builds and publishes a set, in the only valid order:
      streets → timetables → stations → config → links → flows → gate → manifest → heartbeat
    (config after the tt-* and stations its reference checks read, and before links, which is built
    from it and names it in builtAgainst; flows depends on nothing). Each step writes its report to
    <out>/../reports/<step>.json; manifest.json, trip-counts.json and heartbeat.json go to <out>.

      --sources DIR         Source downloads (default build/sources)
      --out DIR             Artifacts (default build/data)
      --trips DIR           Citi Bike trip-zip cache and saved listing for flows (default build/trips)
      --months LIST         Flows months instead of the newest three (YYYYMM-YYYYMM or YYYYMM,YYYYMM,…)
      --config-sources DIR  Reviewed config sources (default ./Data, else ./Vendor/bikeride-data/Data)
      --previous FILE       The previous set's manifest.json: the gate compares trip counts with it, and
                            gate and manifest carry forward the kinds missing from --out
      --offline             Use the sources and trip data already downloaded
      --no-xz               Skip compression; nothing can be published, so gate, manifest and heartbeat
                            are skipped
      --skip LIST           Comma-separated steps to skip (any of the nine above), reusing what is in
                            --out, e.g. streets,stations. Skipping manifest skips heartbeat; skipping
                            timetables tells the heartbeat the timetables were not built
      --require-flows       A set without flows.bin fails the gate (by default flows is optional)
      --today DATE          Build day for timetables, gate and manifest (default today in New York; the
                            timetable window starts the day before). Fixtures pin it
      --now ISO8601         Timestamp for gate.json, the manifest and the heartbeat (default: the time
                            each is written). Pin it to make two runs byte-identical

    Step outcomes:
      streets 2 (a sanity route failed)   warning; the run goes on
      config 3 (a reference check failed), or any config failure: stop (no config.bin, no links)
      flows 4 (nothing new, or offline without trip data) or 3 (its gate failed): the flows.bin in
                place, if any, is kept and the run goes on; the gate's flows check decides whether that
                file may be published (without flows.bin the set publishes without flows)
      gate 3 (a hard failure)             stop with 3: no manifest and no heartbeat are written
      any other failure                   stop with that step's status

    Exit status: 0 published (or built, with --no-xz or --skip manifest); otherwise the status of the
    step that stopped the run (3: config reference failure, gate hard failure or manifest refusal;
    1 an error; 64 usage).
    """

/// `bikeride-data all …`. Returns the process exit status.
func runAllCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(allUsage)
        return 0
    }
    func usageError(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("bikeride-data all: \(message)\n\n\(allUsage)\n".utf8))
        return 64
    }
    let options: CommandOptions
    let requested: Set<PipelineStep>
    let today: ServiceDate
    let pinnedNow: Date?
    do {
        options = try CommandOptions(
            arguments, valued: ["--sources", "--out", "--trips", "--months", "--config-sources", "--previous", "--skip", "--today", "--now"],
            flags: ["--offline", "--no-xz", "--require-flows"])
        requested = try Pipeline.steps(named: options.values["--skip"] ?? "")
        today = try publishToday(options)
        pinnedNow = try publishNow(options)
    } catch {
        return usageError("\(error)")
    }
    if let text = options.values["--months"], TripMonth.parseList(text) == nil {
        return usageError("--months needs YYYYMM-YYYYMM or YYYYMM,YYYYMM,… (1 to 12 consecutive months)")
    }
    let previous = options.values["--previous"].map(CommandOptions.absoluteURL)
    if let previous, !FileManager.default.fileExists(atPath: previous.path) {
        return usageError("--previous \(previous.path) does not exist")
    }
    let compress = !options.flags.contains("--no-xz")
    let (skip, notes) = Pipeline.effectiveSkips(requested, compress: compress)
    for note in notes { logLine("all", note) }

    let sources = options.url("--sources", default: "build/sources").path
    let out = options.url("--out", default: "build/data")
    let offline = options.flags.contains("--offline") ? ["--offline"] : []
    let noXZ = compress ? [] : ["--no-xz"]
    let todayArgument = ["--today", today.yyyymmdd]
    let previousArgument = previous.map { ["--previous", $0.path] } ?? []
    let requireFlows = options.flags.contains("--require-flows") ? ["--require-flows"] : []
    func value(_ name: String) -> [String] { options.values[name].map { [name, $0] } ?? [] }
    func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    // One timestamp for the manifest and the heartbeat that names it.
    var publishedAt = pinnedNow

    let started = Date()
    let outcome = Pipeline.run(skip: skip, log: { logLine("all", $0) }) { step in
        logLine("all", "\(step.rawValue)…")
        let stepStart = Date()
        let status: Int32
        switch step {
        case .streets:
            status = runStreetsCommand(["--sources", sources, "--out", out.path] + offline + noXZ)
        case .timetables:
            status = runTimetablesCommand(["--sources", sources, "--out", out.path] + offline + noXZ + todayArgument)
        case .stations:
            status = runStationsCommand(["--sources", sources, "--out", out.path] + offline + noXZ)
        case .config:
            status = runConfigCommand(["--data", out.path, "--sources", sources, "--require-references"]
                + value("--config-sources") + offline + noXZ)
        case .links:
            status = runLinksCommand(["--data", out.path] + noXZ)
        case .flows:
            status = runFlowsCommand(["--sources", sources, "--out", out.path] + value("--trips") + value("--months") + offline + noXZ)
        case .gate:
            status = runGateCommand(["--data", out.path] + todayArgument + previousArgument + requireFlows
                + (pinnedNow.map { ["--now", timestamp($0)] } ?? []))
        case .manifest:
            let now = publishedAt ?? Date()
            publishedAt = now
            status = runManifestCommand(["--data", out.path, "--no-heartbeat", "--now", timestamp(now)] + todayArgument + previousArgument
                + requireFlows + (skip.contains(.timetables) ? ["--timetables-not-run"] : []))
        case .heartbeat:
            status = runHeartbeatStep(data: out, previous: previous, now: publishedAt ?? Date(), notRun: skip.contains(.timetables))
        }
        logLine("all", String(format: "%@ finished with status %d in %.1f s", step.rawValue, status, Date().timeIntervalSince(stepStart)))
        return status
    }
    let summary = outcome.ran.map { "\($0.step.rawValue) \($0.status)" }.joined(separator: ", ")
    for warning in outcome.warnings { logLine("all", "warning: \(warning)") }
    if let stopped = outcome.stoppedAt {
        logLine("all", "stopped at \(stopped.rawValue) with status \(outcome.status) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s (\(summary))")
        return outcome.status
    }
    logLine("all", String(format: "done in %.1f s (%@)", Date().timeIntervalSince(started), summary))
    return 0
}

/// The heartbeat step: `heartbeat.json` for the manifest the manifest step of this run just wrote.
private func runHeartbeatStep(data: URL, previous: URL?, now: Date, notRun: Bool) -> Int32 {
    do {
        let manifest = try SetManifest.load(data.appendingPathComponent(SetManifest.fileName))
        let url = try writeHeartbeat(for: manifest, data: data, previousHeartbeat: previousHeartbeatURL(beside: previous), now: now,
                                     job: "all", notRun: notRun, unchanged: false)
        print("heartbeat: \(url.path) (set \(manifest.setId))")
        return 0
    } catch {
        FileHandle.standardError.write(Data("bikeride-data all: heartbeat: \(error)\n".utf8))
        return 1
    }
}
