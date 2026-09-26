import BRCore
import BRData
import BRTimetable
import Foundation

/// Serializes the `links` artifact (layout: `docs/formats.md`; reader: ``BRTimetable/MappedLinks``).
public enum LinksArtifactWriter {
    public static func artifact(_ links: CompiledLinks, dataVersion: String, builtAgainst: [String: String]) -> Data {
        let header = ArtifactHeader(
            kind: .links, formatVersion: ArtifactKind.links.currentFormatVersion,
            dataVersion: dataVersion, builderSwiftVersion: BuildInfo.swiftVersion, builtAgainst: builtAgainst
        )
        return header.assemble(payload: payload(links))
    }

    public static func payload(_ links: CompiledLinks) -> Data {
        let network = links.network
        let t = network.stopCount
        precondition(links.footpaths.start.count == t + 1 && links.stationLinks.stopStart.count == t + 1, "tables do not match the network")

        // Only snapped access points are stored.
        var storedIndex = [Int](repeating: -1, count: network.accessPoints.count)
        var stored: [StreetAccessPoint] = []
        for (index, point) in network.accessPoints.enumerated() where point.snap != nil && point.anchor != nil {
            storedIndex[index] = stored.count
            stored.append(point)
        }
        var stopFlags = [UInt8](repeating: 0, count: t)
        var accessStart: [UInt32] = [0]
        var accessPoints: [UInt32] = []
        accessStart.reserveCapacity(t + 1)
        for stop in 0..<t {
            var flags: LinkStopFlags = network.routable[stop] ? .routable : []
            if network.routable[stop] {
                let access = network.streetAccess(of: stop)
                if access.entry { flags.insert(.streetEntry) }
                if access.exit { flags.insert(.streetExit) }
                for index in network.stopAccess[stop] where storedIndex[index] >= 0 { accessPoints.append(UInt32(storedIndex[index])) }
            }
            stopFlags[stop] = flags.rawValue
            accessStart.append(UInt32(accessPoints.count))
        }

        let footpaths = links.footpaths, stations = links.stationLinks
        var writer = BinaryWriter(reservingCapacity: 1024 + footpaths.count * 6 + stored.count * 32 + stations.count * 16 + t * 16)
        writer.append(bytes: LinksFormat.payloadMagic)
        writer.append(LinksFormat.draftRevision)
        writer.append(links.options.maxFootpathWalkSeconds)
        writer.append(links.options.minTransferSeconds)
        writer.append(links.options.walk.speedMetersPerSecond)
        writer.append(links.options.stationLinkMaxWalkMeters)
        writer.append(array: network.systemStopCounts.map { UInt32($0) })
        writer.append(array: LinksFormat.systems.map { links.options.access($0) })
        writer.append(array: stopFlags)
        writer.append(array: footpaths.start)
        writer.append(array: footpaths.target)
        writer.append(array: footpaths.seconds)
        writer.append(array: stored.map { UInt32($0.sourceStop) })
        writer.append(array: stored.map { Int32(($0.coordinate.lat * 1e6).rounded()) })
        writer.append(array: stored.map { Int32(($0.coordinate.lon * 1e6).rounded()) })
        writer.append(array: stored.map { $0.snap!.segment })
        writer.append(array: stored.map { $0.snap!.fraction })
        writer.append(array: stored.map { $0.snap!.distanceDecimeters })
        writer.append(array: stored.map { UInt16(min(UInt32(UInt16.max), $0.accessSeconds)) })
        writer.append(array: stored.map { point -> UInt8 in
            var flags: LinkAccessPointFlags = []
            if point.entry { flags.insert(.entry) }
            if point.exit { flags.insert(.exit) }
            if point.kind == .station { flags.insert(.synthetic) }
            return flags.rawValue
        })
        writer.append(array: accessStart)
        writer.append(array: accessPoints)
        writer.append(array: stations.stationStart)
        writer.append(array: stations.stationStop)
        writer.append(array: stations.stationEnter)
        writer.append(array: stations.stationExit)
        writer.append(array: stations.stopStart)
        writer.append(array: stations.stopStation)
        writer.append(array: stations.stopEnter)
        writer.append(array: stations.stopExit)
        return writer.data
    }
}

/// The footpath invariants the planner relies on, checked exhaustively over a table.
public struct FootpathCheck: Codable, Sendable, Equatable {
    public var stops = 0
    public var footpaths = 0
    /// (p, q, r) with p→q and q→r listed and r ≠ p.
    public var triplesChecked = 0
    /// Listed p→r longer than p→q + q→r.
    public var triangleViolations = 0
    /// p→q + q→r within p→r's bound, but p→r not listed.
    public var closureViolations = 0
    public var selfLoops = 0
    /// Rows not sorted by (seconds, stop), or with a repeated stop.
    public var unsortedRows = 0
    public var overBound = 0
    /// Up to 20 descriptions of violations.
    public var examples: [String] = []

    /// No violation of any kind.
    public private(set) var passed = false

    public init() {}

    /// Checks every row and every two-step chain. The bound of p→r is `walkSeconds` plus
    /// `stopAccessSeconds[p]` and `stopAccessSeconds[r]`.
    public static func run(_ table: FootpathTable, walkSeconds: Int, stopAccessSeconds: [UInt32]) -> FootpathCheck {
        precondition(stopAccessSeconds.count == table.start.count - 1, "one access time per stop")
        func bound(_ p: Int, _ r: Int) -> Int { walkSeconds + Int(stopAccessSeconds[p]) + Int(stopAccessSeconds[r]) }
        var check = FootpathCheck()
        let t = table.start.count - 1
        check.stops = t
        check.footpaths = table.count
        var owner = [Int32](repeating: -1, count: t)
        var value = [UInt16](repeating: 0, count: t)
        func note(_ text: @autoclosure () -> String) { if check.examples.count < 20 { check.examples.append(text()) } }
        for p in 0..<t {
            let row = Int(table.start[p])..<Int(table.start[p + 1])
            var previous: (UInt16, UInt32)?
            for slot in row {
                let q = table.target[slot], s = table.seconds[slot]
                if Int(q) == p { check.selfLoops += 1; note("self loop at \(p)") }
                if Int(s) > bound(p, Int(q)) { check.overBound += 1 }
                if let previous, (previous.0, previous.1) >= (s, q) { check.unsortedRows += 1; note("row \(p) unsorted") }
                previous = (s, q)
                owner[Int(q)] = Int32(p)
                value[Int(q)] = s
            }
            for slot in row {
                let q = Int(table.target[slot]), first = Int(table.seconds[slot])
                for next in Int(table.start[q])..<Int(table.start[q + 1]) {
                    let r = Int(table.target[next])
                    guard r != p else { continue }
                    let sum = first + Int(table.seconds[next])
                    check.triplesChecked += 1
                    if owner[r] == Int32(p) {
                        if Int(value[r]) > sum {
                            check.triangleViolations += 1
                            note("\(p)→\(r) \(value[r]) s > \(p)→\(q)→\(r) \(sum) s")
                        }
                    } else if sum <= bound(p, r) {
                        check.closureViolations += 1
                        note("\(p)→\(q)→\(r) is \(sum) s but \(p)→\(r) is missing")
                    }
                }
            }
        }
        check.passed = check.triangleViolations == 0 && check.closureViolations == 0 && check.selfLoops == 0
            && check.unsortedRows == 0 && check.overBound == 0
        return check
    }
}
