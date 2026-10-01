import BRBuild
import BRCore
import Foundation

let allUsage = """
    USAGE: bikeride-data all [--sources DIR] [--out DIR] [--trips DIR] [--months LIST] [--config-sources DIR]
                             [--previous FILE] [--offline] [--no-xz] [--skip LIST] [--require-flows]
                             [--today YYYYMMDD] [--now ISO8601] [--job NAME]
                             [--accept-trip-count-change LIST] [--strict-sources]

    Builds and publishes a set, in the only valid order:
      streets → timetables → stations → config → links → flows → gate → manifest → heartbeat
    (config after the tt-* and stations its reference checks read, and before links, which is built
    from it and names it in builtAgainst; flows depends on nothing). Each step writes its report to
    <out>/../reports/<step>.json; manifest.json, trip-counts.json and heartbeat.json go to <out>.
    Before the first step, those three are moved from <out> to <out>/../work/published-before/: they
    describe the set that was there, so a run that stops leaves no published documents behind.

      --sources DIR         Source downloads (default build/sources)
      --out DIR             Artifacts (default build/data)
      --trips DIR           Citi Bike trip-zip cache and saved listing for flows (default build/trips)
      --months LIST         Flows months instead of the newest three (YYYYMM-YYYYMM or YYYYMM,YYYYMM,…)
      --config-sources DIR  Reviewed config sources (default ./Data, else ./Vendor/bikeride-data/Data)
      --previous FILE       The previous set's manifest.json: the gate compares trip counts with it, and
                            gate and manifest carry forward the kinds missing from --out. It may be
                            <out>/manifest.json (read where it is moved to)
      --offline             Use the sources and trip data already downloaded
      --no-xz               Skip compression; nothing can be published, so gate, manifest and heartbeat
                            are skipped
      --skip LIST           Comma-separated steps to skip (any of the nine above), reusing what is in
                            --out, e.g. streets,stations. Skipping manifest skips heartbeat; skipping
                            timetables tells the heartbeat the timetables were not built, so
                            lastTimetableSuccessAt carries over from the heartbeat beside --previous
                            (without --previous, from the last one in --out). To build without
                            publishing (pinned artifacts no report vouches for), skip gate,manifest
      --require-flows       A set without flows.bin fails the gate, and a flows error stops the run
                            (by default flows is optional)
      --today DATE          Build day for timetables, gate and manifest (default today in New York; the
                            timetable window starts the day before). Fixtures pin it
      --now ISO8601         Timestamp for gate.json, the manifest and the heartbeat (default: the time
                            each is written). Pin it to make two runs byte-identical
      --job NAME            The job this run belongs to, recorded in the heartbeat: all (default),
                            timetables, streets or flows (the M4 workflow jobs)
      --accept-trip-count-change LIST
                            Systems whose trip-count change a person reviewed and accepts for this run
                            (subway, bus, lirr, ferry, path; comma-separated, no spaces), passed to
                            the gate: their trip-count changes beyond the limit are accepted
                            warnings, not failures, and gate.json records the list
      --strict-sources      Passed to timetables: the subway is not built without entrances (no
                            download and no usable cached file is an error, not a warning). CI
                            passes it; a fresh runner has only the copy the restore step put there

    Step outcomes:
      streets 2 (a sanity route failed)   warning; the run goes on
      config 3 (a reference check failed), or any config failure: stop (no config.bin, no links)
      flows 4 (nothing new, or offline without trip data), 3 (its gate failed: reports/flows-failed.json)
            or 1 (an error; without --require-flows): warning; the flows.bin in place, if any, and its
            reports/flows.json are kept and the run goes on. The gate's flows check passes that
            file if its report still does (without flows.bin the set publishes without flows)
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
    let job: PublishJob
    let acceptedTripCountChange: Set<TransitSystem>?
    do {
        options = try CommandOptions(
            arguments, valued: ["--sources", "--out", "--trips", "--months", "--config-sources", "--previous", "--skip", "--today", "--now",
                     "--job", "--accept-trip-count-change"],
            flags: ["--offline", "--no-xz", "--require-flows", "--strict-sources"])
        requested = try Pipeline.steps(named: options.values["--skip"] ?? "")
        today = try publishToday(options)
        pinnedNow = try publishNow(options)
        job = try options.values["--job"].map(Pipeline.job(named:)) ?? .all
        acceptedTripCountChange = try options.values["--accept-trip-count-change"].map(Pipeline.tripCountChangeSystems(named:))
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

    // The published documents in --out describe the set that was there, not the one this run builds.
    var retired = Pipeline.Retired(moved: [], directory: Pipeline.retiredDirectory(for: out), previous: previous, previousHeartbeat: nil)
    if PipelineStep.allCases.contains(where: { !skip.contains($0) }) {
        do {
            retired = try Pipeline.retirePublished(in: out, previous: previous)
        } catch let error as Pipeline.UsageError {
            return usageError("\(error)")
        } catch {
            logLine("all", "cannot move the published documents out of \(out.path): \(error)")
            return 1
        }
        if !retired.moved.isEmpty {
            logLine("all", "moved the last run's \(retired.moved.joined(separator: ", ")) to \(retired.directory.path)"
                + (retired.previous != previous ? " (--previous now reads them there)" : ""))
        }
    }

    let offline = options.flags.contains("--offline") ? ["--offline"] : []
    let noXZ = compress ? [] : ["--no-xz"]
    let todayArgument = ["--today", today.yyyymmdd]
    let strictSources = options.flags.contains("--strict-sources") ? ["--strict-sources"] : []
    let previousArgument = retired.previous.map { ["--previous", $0.path] } ?? []
    let flowsRequired = options.flags.contains("--require-flows")
    let requireFlows = flowsRequired ? ["--require-flows"] : []
    // The gate parses the list again and records it in gate.json.
    let acceptTripCountChange = acceptedTripCountChange.map {
        ["--accept-trip-count-change", $0.map(SetSystems.name).sorted().joined(separator: ",")]
    } ?? []
    func value(_ name: String) -> [String] { options.values[name].map { [name, $0] } ?? [] }
    func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    // One timestamp for the manifest and the heartbeat that names it.
    var publishedAt = pinnedNow

    let started = Date()
    let outcome = Pipeline.run(skip: skip, requireFlows: flowsRequired, log: { logLine("all", $0) }) { step in
        logLine("all", "\(step.rawValue)…")
        let stepStart = Date()
        let status: Int32
        switch step {
        case .streets:
            status = runStreetsCommand(["--sources", sources, "--out", out.path] + offline + noXZ)
        case .timetables:
            status = runTimetablesCommand(["--sources", sources, "--out", out.path] + offline + noXZ + todayArgument + strictSources)
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
            status = runGateCommand(["--data", out.path] + todayArgument + previousArgument + requireFlows + acceptTripCountChange
                + (pinnedNow.map { ["--now", timestamp($0)] } ?? []))
        case .manifest:
            let now = publishedAt ?? Date()
            publishedAt = now
            status = runManifestCommand(["--data", out.path, "--no-heartbeat", "--now", timestamp(now)] + todayArgument + previousArgument
                + requireFlows + (skip.contains(.timetables) ? ["--timetables-not-run"] : []))
        case .heartbeat:
            status = runHeartbeatStep(data: out, previousHeartbeat: retired.previousHeartbeat, now: publishedAt ?? Date(), job: job,
                                       notRun: skip.contains(.timetables))
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
private func runHeartbeatStep(data: URL, previousHeartbeat: URL?, now: Date, job: PublishJob, notRun: Bool) -> Int32 {
    do {
        let manifest = try SetManifest.load(data.appendingPathComponent(SetManifest.fileName))
        let url = try writeHeartbeat(for: manifest, data: data, previousHeartbeat: previousHeartbeat, now: now,
                                     job: job.rawValue, notRun: notRun, unchanged: false)
        print("heartbeat: \(url.path) (set \(manifest.setId))")
        return 0
    } catch {
        FileHandle.standardError.write(Data("bikeride-data all: heartbeat: \(error)\n".utf8))
        return 1
    }
}
