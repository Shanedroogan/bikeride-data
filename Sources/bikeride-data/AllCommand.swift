import BRCore
import Foundation

let allUsage = """
    USAGE: bikeride-data all [--sources DIR] [--out DIR] [--offline] [--no-xz] [--skip LIST] [--today YYYYMMDD]

    Runs every artifact build in dependency order: streets → timetables → stations → links.
    Each step writes its report to <out>/../reports/<step>.json. Stops at the first failure;
    a streets sanity-route failure (exit 2) is reported but does not stop the run.

      --sources DIR   Source downloads (default build/sources)
      --out DIR       Artifacts (default build/data)
      --offline       Use the sources already downloaded
      --no-xz         Skip compression
      --skip LIST     Comma-separated steps to skip, e.g. streets,timetables (reuses their artifacts)
      --today DATE    Build day for the timetables (default today in New York; the window starts
                      the day before). Fixtures pin it so a rebuild reproduces the same set
    """

/// `bikeride-data all …`. Returns the process exit status.
func runAllCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(allUsage)
        return 0
    }
    let steps = ["streets", "timetables", "stations", "links"]
    let options: CommandOptions
    do {
        options = try CommandOptions(arguments, valued: ["--sources", "--out", "--skip", "--today"], flags: ["--offline", "--no-xz"])
    } catch {
        FileHandle.standardError.write(Data("bikeride-data all: \(error)\n\n\(allUsage)\n".utf8))
        return 64
    }
    let skip = Set((options.values["--skip"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    if let unknown = skip.first(where: { !steps.contains($0) }) {
        FileHandle.standardError.write(Data("bikeride-data all: unknown step '\(unknown)'\n\n\(allUsage)\n".utf8))
        return 64
    }
    let sources = options.url("--sources", default: "build/sources").path
    let out = options.url("--out", default: "build/data").path
    let offline = options.flags.contains("--offline") ? ["--offline"] : []
    let noXZ = options.flags.contains("--no-xz") ? ["--no-xz"] : []
    var today: [String] = []
    if let text = options.values["--today"] {
        guard ServiceDate(yyyymmdd: text) != nil else {
            FileHandle.standardError.write(Data("bikeride-data all: --today needs YYYYMMDD\n\n\(allUsage)\n".utf8))
            return 64
        }
        today = ["--today", text]
    }

    let started = Date()
    var warnings: [String] = []
    for step in steps where !skip.contains(step) {
        logLine("all", "\(step)…")
        let stepStart = Date()
        let status: Int32
        switch step {
        case "streets": status = runStreetsCommand(["--sources", sources, "--out", out] + offline + noXZ)
        case "timetables": status = runTimetablesCommand(["--sources", sources, "--out", out] + offline + noXZ + today)
        case "stations": status = runStationsCommand(["--sources", sources, "--out", out] + offline + noXZ)
        default: status = runLinksCommand(["--data", out] + noXZ)
        }
        logLine("all", String(format: "%@ finished with status %d in %.1f s", step, status, Date().timeIntervalSince(stepStart)))
        if step == "streets" && status == 2 {
            warnings.append("streets sanity routes failed (see reports/streets.json)")
            continue
        }
        guard status == 0 else {
            logLine("all", "stopping: \(step) failed")
            return status
        }
    }
    for warning in warnings { logLine("all", "warning: \(warning)") }
    logLine("all", String(format: "done in %.1f s", Date().timeIntervalSince(started)))
    return 0
}
