import BRBuild
import BRCore
import Foundation

let manifestUsage = """
    USAGE: bikeride-data manifest [--data DIR] [--reports DIR] [--previous FILE] [--previous-heartbeat FILE]
                                  [--today YYYYMMDD] [--now ISO8601] [--job NAME] [--require-flows]
                                  [--timetables-not-run | --timetables-unchanged] [--no-heartbeat]

    Writes <data>/trip-counts.json, <data>/manifest.json and, last, <data>/heartbeat.json for the
    set in --data. Requires <reports>/gate.json from a gate run that passed (or failed only soft) on
    exactly these files, for the same build day and previous manifest.

      --data DIR                 The set (default build/data)
      --reports DIR              Where gate.json is (default <data>/../reports)
      --previous FILE            The previous manifest: kinds missing from --data are carried forward
      --previous-heartbeat FILE  Its heartbeat (default heartbeat.json beside --previous)
      --today DATE               Build day (default today in New York)
      --now ISO8601              generatedAt / checkedAt (default now)
      --job NAME                 Recorded in the heartbeat (default all)
      --require-flows            A set without flows is refused (by default flows is optional)
      --no-heartbeat             Write the manifest only (`all` writes the heartbeat as its own last step)
      --timetables-not-run       This job did not build the timetables although tt-* files are in
                                 --data: lastTimetableSuccessAt carries over from the previous heartbeat
      --timetables-unchanged     This job checked the timetable sources, found them unchanged and
                                 carried every tt-* forward: lastTimetableSuccessAt is now
    Without either flag, lastTimetableSuccessAt is now when at least one tt-* is in --data (not
    carried forward), else it carries over.

    Exit status: 0 written, 3 no passing gate report for this set (nothing written), 1 error, 64 usage.
    """

/// `bikeride-data manifest …`. Returns the process exit status.
func runManifestCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(manifestUsage)
        return 0
    }
    do {
        let options = try CommandOptions(
            arguments, valued: ["--data", "--reports", "--previous", "--previous-heartbeat", "--today", "--now", "--job"],
            flags: ["--timetables-not-run", "--timetables-unchanged", "--require-flows", "--no-heartbeat"])
        let notRun = options.flags.contains("--timetables-not-run"), unchanged = options.flags.contains("--timetables-unchanged")
        guard !(notRun && unchanged) else {
            throw CommandOptions.UsageError(description: "--timetables-not-run and --timetables-unchanged contradict each other")
        }
        let data = options.url("--data", default: "build/data")
        let reports = options.values["--reports"].map(CommandOptions.absoluteURL) ?? data.deletingLastPathComponent().appendingPathComponent("reports")
        let previous = options.values["--previous"].map(CommandOptions.absoluteURL)
        let now = try publishNow(options) ?? Date()
        var builder = SetManifestBuilder(dataDirectory: data, reportsDirectory: reports, previousManifest: previous,
                                         today: try publishToday(options), now: now, runner: ProcessToolRunner())
        builder.requiredKinds = SetManifest.requiredKinds(requireFlows: options.flags.contains("--require-flows"))
        let manifest: SetManifest
        do {
            manifest = try builder.write()
        } catch let error as SetManifest.ManifestError {
            switch error {
            case .noGateReport, .gateFailed, .gateStale:
                FileHandle.standardError.write(Data("bikeride-data manifest: \(error)\n".utf8))
                return 3
            default: throw error
            }
        }
        let days = manifest.systems.keys.sorted().map { "\($0) \(manifest.systems[$0]!.days)" }.joined(separator: ", ")
        print("manifest: set \(manifest.setId), \(manifest.artifacts.count) artifacts (\(manifest.carriedForward.count) carried forward), "
            + "gate \(manifest.gate.status.rawValue); coverage days: \(days)")
        print("manifest: \(builder.manifestURL.path), \(builder.tripCountsURL.path)")
        guard !options.flags.contains("--no-heartbeat") else { return 0 }
        let heartbeatURL = try writeHeartbeat(
            for: manifest, data: data,
            previousHeartbeat: options.values["--previous-heartbeat"].map(CommandOptions.absoluteURL) ?? previousHeartbeatURL(beside: previous),
            now: now, job: options.values["--job"] ?? "all", notRun: notRun, unchanged: unchanged)
        print("manifest: \(heartbeatURL.path)")
        return 0
    } catch let error as CommandOptions.UsageError {
        FileHandle.standardError.write(Data("bikeride-data manifest: \(error)\n\n\(manifestUsage)\n".utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("bikeride-data manifest: \(error)\n".utf8))
        return 1
    }
}

/// `heartbeat.json` beside a previous manifest.
func previousHeartbeatURL(beside previousManifest: URL?) -> URL? {
    previousManifest.map { $0.deletingLastPathComponent().appendingPathComponent(SetHeartbeat.fileName) }
}

/// Writes `<data>/heartbeat.json` for `manifest` (written by this run), last. Returns its URL.
func writeHeartbeat(for manifest: SetManifest, data: URL, previousHeartbeat: URL?, now: Date, job: String,
                    notRun: Bool, unchanged: Bool) throws -> URL {
    let heartbeat = SetHeartbeat.after(manifest, now: now, job: job,
                                       timetablesSucceeded: SetHeartbeat.timetablesSucceeded(manifest, notRun: notRun, unchanged: unchanged),
                                       previous: previousHeartbeat.flatMap { try? SetHeartbeat.load($0) })
    let url = data.appendingPathComponent(SetHeartbeat.fileName)
    try heartbeat.write(to: url)
    if heartbeat.lastTimetableSuccessAt == nil { logLine("manifest", "warning: no lastTimetableSuccessAt (no previous heartbeat)") }
    return url
}
