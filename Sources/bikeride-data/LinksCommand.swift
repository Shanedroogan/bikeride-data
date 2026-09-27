import BRBuild
import BRCore
import BRStreetCore
import BRTimetable
import Foundation

let linksUsage = """
    USAGE: bikeride-data links [--data DIR] [--out DIR] [--report FILE] [--threads N]
                               [--max-walk-seconds S] [--no-check] [--no-xz]

    Builds the links artifact from config.bin, streets.bin, stations.bin and tt-*.bin: each
    stop's street access points, transitively closed footpaths (station access once per
    street↔platform transition, in-station transfers from transfers.txt, the configured fixed
    transfers), stop↔station walk links, and the rail bike hops. The build parameters come from
    config.bin (transit.links; build it first with `bikeride-data config`), which the header's
    builtAgainst names. A fixed transfer that doesn't resolve fails the build.

      --data DIR                 Input artifacts (default build/data)
      --out DIR                  Raw artifact and .xz (default: the data directory)
      --report FILE              Build report JSON (default <out>/../reports/links.json)
      --threads N                Parallel searches (default: every core)
      --max-walk-seconds S       Replace the config's footpath walk bound (station access at both
                                 ends comes on top), for experiments; the report warns
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
        if let threads = try options.int("--threads") { configuration.threads = threads }
        if let bound = try options.int("--max-walk-seconds") {
            guard bound <= 3600 else { throw CommandOptions.UsageError(description: "--max-walk-seconds must be at most 3600") }
            configuration.maxFootpathWalkSeconds = UInt32(bound)
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
    USAGE: bikeride-data links-show --stop SYSTEM:STOP_ID [--data DIR] [--limit N] [--hop-to SYSTEM:STOP_ID]

    Prints one stop's access points, footpaths and station links from links.bin, with names from
    the tt-* and stations artifacts, and the rail bike hops from its parent station. SYSTEM is S,
    B, L, F or P, e.g. S:127N, B:400001 or P:781743. --hop-to prints only the hop to that stop's
    parent station (or says there is none).
    """

/// `bikeride-data links-show …`: inspect one stop's links.
func runLinksShowCommand(_ arguments: [String]) -> Int32 {
    do {
        let options = try CommandOptions(arguments, valued: ["--stop", "--data", "--limit", "--hop-to"], flags: [])
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

        // Rail bike hops, keyed by the parent station (or the stop itself when it has none).
        func parent(_ system: TransitSystem, _ local: Int) -> Int {
            links.globalStop(system: system, stop: timetables[system]!.stopParent(local) ?? local)
        }
        guard let hops = links.hops else {
            print("  no hop block (built without stations)")
            return 0
        }
        let origin = parent(system, local)
        let rows = hops.hops(fromParent: origin)
        func stationName(_ index: Int) -> String { stations.map { $0.name(index) } ?? "#\(index)" }
        func show(_ hop: LinkHop) {
            let flags = hop.flags.contains(.oneSeatRideExists) ? " (one-seat ride exists)" : ""
            print("    → \(describe(hop.target)): ≥ \(hop.minDecameters * 10) m, walks ≥ \(hop.minWalkSeconds) s\(flags); "
                + "pickups \(hop.pickups.map(stationName)), docks \(hop.docks.map(stationName))")
        }
        if let destinationText = options.values["--hop-to"] {
            let destination = StopID(destinationText)
            guard let destinationSystem = destination.system, let destinationTimetable = timetables[destinationSystem],
                  let destinationLocal = destinationTimetable.stop(id: destination) else {
                throw CommandOptions.UsageError(description: "no stop \(destinationText)")
            }
            let target = parent(destinationSystem, destinationLocal)
            print("  hop \(describe(origin)) → \(describe(target)):")
            if let hop = rows.first(where: { $0.target == target }) { show(hop) } else { print("    none") }
            return 0
        }
        print("  \(rows.count) hops from \(describe(origin)):")
        for hop in rows.prefix(limit) { show(hop) }
        return 0
    } catch let error as CommandOptions.UsageError {
        FileHandle.standardError.write(Data("bikeride-data links-show: \(error)\n\n\(linksShowUsage)\n".utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("bikeride-data links-show: \(error)\n".utf8))
        return 1
    }
}
