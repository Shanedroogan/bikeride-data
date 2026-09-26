import BRBuild
import BRCore
import BRStreetCore
import BRTimetable
import Foundation

let linksUsage = """
    USAGE: bikeride-data links [--data DIR] [--out DIR] [--report FILE] [--threads N]
                               [--max-walk-seconds S] [--no-check] [--no-xz]

    Builds the links artifact from streets.bin, stations.bin and tt-*.bin: each stop's street
    access points, transitively closed footpaths (station access once per street↔platform
    transition, in-station transfers from transfers.txt), and stop↔station walk links.

      --data DIR                 Input artifacts (default build/data)
      --out DIR                  Raw artifact and .xz (default: the data directory)
      --report FILE              Build report JSON (default <out>/../reports/links.json)
      --threads N                Parallel searches (default: every core)
      --max-walk-seconds S       Footpath walk bound; station access at both ends comes on top (default 480)
      --no-check                 Skip the exhaustive triangle-inequality check
      --no-xz                    Skip compression
    """

/// `bikeride-data links …`. Returns the process exit status.
func runLinksCommand(_ arguments: [String]) -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(linksUsage)
        return 0
    }
    do {
        let options = try CommandOptions(
            arguments, valued: ["--data", "--out", "--report", "--threads", "--max-walk-seconds"], flags: ["--no-check", "--no-xz"]
        )
        let data = options.url("--data", default: "build/data")
        let out = options.values["--out"].map(CommandOptions.absoluteURL) ?? data
        var configuration = LinksCompiler.Configuration(dataDirectory: data, outputDirectory: out)
        configuration.compress = !options.flags.contains("--no-xz")
        configuration.checkFootpaths = !options.flags.contains("--no-check")
        if let threads = try options.int("--threads") { configuration.options.threads = threads }
        if let bound = try options.int("--max-walk-seconds") {
            guard bound <= 3600 else { throw CommandOptions.UsageError(description: "--max-walk-seconds must be at most 3600") }
            configuration.options.maxFootpathWalkSeconds = UInt32(bound)
        }
        let reportURL = options.values["--report"].map(CommandOptions.absoluteURL)
            ?? out.deletingLastPathComponent().appendingPathComponent("reports/links.json")

        let report = try LinksCompiler(runner: ProcessToolRunner(), configuration: configuration).run { logLine("links", $0) }
        try writeJSONReport(report, to: reportURL)
        let artifact = report.artifact
        print("links: \(artifact.path) (\(artifact.rawBytes) bytes raw, \(artifact.xzBytes ?? 0) bytes xz), "
            + "\(report.footpaths.footpaths) footpaths, \(report.stationLinks.links) station links in "
            + String(format: "%.1f s", report.seconds["total"] ?? 0))
        print("links: report \(reportURL.path)")
        if let check = report.footpathCheck, !check.passed {
            FileHandle.standardError.write(Data("bikeride-data links: footpath check failed: \(check.examples)\n".utf8))
            return 2
        }
        return 0
    } catch let error as CommandOptions.UsageError {
        FileHandle.standardError.write(Data("bikeride-data links: \(error)\n\n\(linksUsage)\n".utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("bikeride-data links: \(error)\n".utf8))
        return 1
    }
}

let linksShowUsage = """
    USAGE: bikeride-data links-show --stop SYSTEM:STOP_ID [--data DIR] [--limit N]

    Prints one stop's access points, footpaths and station links from links.bin, with names from
    the tt-* and stations artifacts. SYSTEM is S, B, L, F or P, e.g. S:127N, B:400001 or P:781743.
    """

/// `bikeride-data links-show …`: inspect one stop's links.
func runLinksShowCommand(_ arguments: [String]) -> Int32 {
    do {
        let options = try CommandOptions(arguments, valued: ["--stop", "--data", "--limit"], flags: [])
        guard let stopText = options.values["--stop"] else { throw CommandOptions.UsageError(description: "--stop is required") }
        let data = options.url("--data", default: "build/data")
        let limit = try options.int("--limit") ?? 40
        let links = try MappedLinks.load(fromDataDirectory: data)
        var timetables: [TransitSystem: Timetable] = [:]
        for system in LinksFormat.systems {
            let url = data.appendingPathComponent(TimetableBuild.artifactFileName(system))
            if FileManager.default.fileExists(atPath: url.path) { timetables[system] = try Timetable(contentsOf: url) }
        }
        let stations = try? MappedStations.load(fromDataDirectory: data)
        let id = StopID(stopText)
        guard let system = id.system, let timetable = timetables[system], let local = timetable.stop(id: id) else {
            throw CommandOptions.UsageError(description: "no stop \(stopText)")
        }
        func describe(_ global: Int) -> String {
            let system = links.system(ofGlobalStop: global), local = links.localStop(ofGlobalStop: global)
            guard let timetable = timetables[system] else { return "#\(global)" }
            return "\(timetable.stopID(local)) \(timetable.stopName(local))"
        }
        let stop = links.globalStop(system: system, stop: local)
        print("\(describe(stop)) (global \(stop)), flags \(links.stopFlags(stop))")
        for index in links.accessPoints(ofStop: stop) {
            let point = links.accessPoint(Int(index))
            let at = String(format: "%.6f,%.6f", point.coordinate.lat, point.coordinate.lon)
            print("  access: \(describe(point.sourceStop)) at \(at), snap \(point.snapMeters) m, access \(point.accessSeconds) s, \(point.flags)")
        }
        let footpaths = links.footpaths(from: stop)
        print("  \(footpaths.count) footpaths:")
        for footpath in footpaths.prefix(limit) { print("    \(footpath.seconds) s → \(describe(footpath.stop))") }
        let near = links.stations(nearStop: stop)
        print("  \(near.count) stations:")
        for link in near.prefix(limit) {
            let name = stations.map { "\($0.stationID(link.index)) \($0.name(link.index))" } ?? "#\(link.index)"
            print("    exit \(link.exitSeconds.map(String.init) ?? "-") s, enter \(link.enterSeconds.map(String.init) ?? "-") s ↔ \(name)")
        }
        return 0
    } catch let error as CommandOptions.UsageError {
        FileHandle.standardError.write(Data("bikeride-data links-show: \(error)\n\n\(linksShowUsage)\n".utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("bikeride-data links-show: \(error)\n".utf8))
        return 1
    }
}
