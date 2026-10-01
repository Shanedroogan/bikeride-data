import BRBuild
import BRCore
import Foundation

let timetablesUsage = """
    USAGE: bikeride-data timetables [--sources <dir>] [--out <dir>] [--report <file>] [--offline]
                                    [--systems subway,bus,lirr,ferry,path] [--today YYYYMMDD] [--no-xz]
                                    [--strict-sources] [--previous FILE]

    Downloads the GTFS feeds into <sources>/gtfs (conditional GET; skipped with --offline),
    compiles tt-subway, tt-bus, tt-lirr, tt-ferry and tt-path into <out> as raw artifacts plus .xz blobs,
    and writes a JSON report (default <out>/../reports/timetables.json).

    OPTIONS:
      --sources <dir>   Source cache (default build/sources)
      --out <dir>       Artifact directory (default build/data)
      --report <file>   Report path; entries for systems not built this run are kept
      --offline         Use the zips already in <sources>/gtfs
      --systems <list>  Comma-separated subset (default all)
      --today <date>    Build day (default today in New York); the window starts the day before
      --no-xz           Skip compression
      --strict-sources  Fail instead of building the subway without entrances when neither the
                        download nor the cached <sources>/nyc file is usable (CI passes it)
      --previous FILE   The live set's manifest.json: a feed whose download failed is not built
                        from an archived copy older than the version that set was built from
                        (an unreadable file is an error, as it is for the gate)
    """

/// `bikeride-data timetables …`. Returns the process exit status.
func runTimetablesCommand(_ arguments: [String]) -> Int32 {
    var sources = URL(fileURLWithPath: "build/sources")
    var output = URL(fileURLWithPath: "build/data")
    var report: URL?
    var offline = false
    var compress = true
    var strictSources = false
    var previous: URL?
    var systems = TransitSystem.allCases
    var today = ServiceDate(containing: Date(), in: .nyc)

    func usageError(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("bikeride-data timetables: \(message)\n\n\(timetablesUsage)\n".utf8))
        return 64
    }

    var index = 0
    func value() -> String? {
        index += 1
        return index < arguments.count ? arguments[index] : nil
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--sources":
            guard let path = value() else { return usageError("--sources needs a directory") }
            sources = URL(fileURLWithPath: path)
        case "--out":
            guard let path = value() else { return usageError("--out needs a directory") }
            output = URL(fileURLWithPath: path)
        case "--report":
            guard let path = value() else { return usageError("--report needs a file") }
            report = URL(fileURLWithPath: path)
        case "--offline":
            offline = true
        case "--no-xz":
            compress = false
        case "--strict-sources":
            strictSources = true
        case "--previous":
            guard let path = value() else { return usageError("--previous needs a file") }
            previous = URL(fileURLWithPath: path)
        case "--systems":
            guard let list = value() else { return usageError("--systems needs a list") }
            var chosen: [TransitSystem] = []
            for name in list.split(separator: ",") {
                switch name.lowercased() {
                case "subway", "s": chosen.append(.subway)
                case "bus", "b": chosen.append(.bus)
                case "lirr", "l": chosen.append(.lirr)
                case "ferry", "f": chosen.append(.ferry)
                case "path", "p": chosen.append(.path)
                default: return usageError("unknown system '\(name)'")
                }
            }
            systems = chosen
        case "--today":
            guard let text = value(), let date = ServiceDate(yyyymmdd: text) else { return usageError("--today needs YYYYMMDD") }
            today = date
        case "-h", "--help":
            print(timetablesUsage)
            return 0
        default:
            return usageError("unknown option '\(arguments[index])'")
        }
        index += 1
    }

    let reportURL = report ?? output.deletingLastPathComponent().appendingPathComponent("reports/timetables.json")
    var build = TimetableBuild(
        sourcesDirectory: sources, outputDirectory: output, reportURL: reportURL, systems: systems,
        offline: offline, today: today, compress: compress, runner: ProcessToolRunner()
    )
    build.strictSources = strictSources
    if let previous {
        do {
            build.liveSources = TimetableBuild.liveSources(of: try SetManifest.load(previous))
        } catch {
            FileHandle.standardError.write(Data("bikeride-data timetables: previous manifest \(previous.path) unreadable (\(error))\n".utf8))
            return 1
        }
    }
    do {
        let started = Date()
        try build.run { print($0) }
        print(String(format: "timetables: done in %.1f s; report %@", Date().timeIntervalSince(started), reportURL.path))
        return 0
    } catch {
        FileHandle.standardError.write(Data("bikeride-data timetables: \(error)\n".utf8))
        return 1
    }
}
