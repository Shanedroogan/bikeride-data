import BRCore
import BRData
import BRGeo
import Foundation

/// The `links` artifact, memory-mapped: transitively closed footpaths between transit stops,
/// each stop's street access points, and walk links between stops and Citi Bike stations.
/// Layout: `docs/formats.md`.
///
/// Stops use one **global stop index** across the five timetables: stop `local` of system `s`
/// is `stopBase(system: s) + local` (``LinksFormat/systems`` order). The header's `builtAgainst`
/// names the `tt-*`, `streets` and `stations` artifacts whose numbering this relies on.
///
/// - **Footpaths** (`footpaths(from:)`): for each routable stop p, every other routable stop q
///   reachable within ``footpathBoundSeconds(from:to:)`` = ``maxFootpathWalkSeconds`` + station
///   access at p + station access at q, as the cheapest path over street nodes, access points and
///   in-station transfers. Station access is charged once at every street↔platform transition.
///   The values are shortest-path distances, so they obey the triangle inequality, and whenever
///   p→q + q→r fits p→r's bound, p→r is listed. Sorted by (seconds, stop).
/// - **Access points** (`accessPoints(ofStop:)`): where riders join the street (subway
///   entrances; a bus, LIRR or ferry stop's own position), each with its stored snap and access
///   seconds. Walk access from a point is: walk cost to the snapped point + snap distance at
///   walking speed + ``LinkAccessPoint/accessSeconds``.
/// - **Station links** (`stops(nearStation:)`, `stations(nearStop:)`): stops whose street access
///   lies within ``stationLinkMaxWalkMeters`` of walking from a station, with seconds including
///   station access, in each direction.
///
/// ## Thread safety
/// `@unchecked Sendable` is sound because every stored property is immutable after `init`, and
/// the buffer pointers view bytes this object keeps alive (the mapping, or a private aligned copy
/// it owns) and never writes.
public final class MappedLinks: @unchecked Sendable {
    /// The raw artifact's file name inside a data directory such as `build/data`.
    public static let fileName = "links.bin"

    public let header: ArtifactHeader
    /// Stops in the global index (every stop of every timetable, routable or not).
    public let stopCount: Int
    public let stationCount: Int
    /// The walking part of the footpath bound; see ``footpathBoundSeconds(from:to:)``.
    public let maxFootpathWalkSeconds: Int
    /// In-station transfers were raised to at least this.
    public let minTransferSeconds: Int
    /// Walking speed the links were computed with.
    public let walkSpeedMetersPerSecond: Double
    /// The walk bound for station links (excluding station access), as meters at walking speed.
    public let stationLinkMaxWalkMeters: Double
    /// Zero-copy views of every array, for hot loops.
    public let raw: LinksBuffers

    private let storage: Data
    private let ownedCopy: UnsafeMutableRawBufferPointer?
    private let systemBase: [Int]
    private let systemCount: [Int]
    private let systemAccess: [Int]

    /// Maps `links.bin` from a data directory, e.g. `build/data`.
    public static func load(fromDataDirectory directory: URL) throws -> MappedLinks {
        try MappedLinks(contentsOf: directory.appendingPathComponent(fileName))
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(artifact: MappedArtifact(contentsOf: url, expecting: .links))
    }

    public init(artifact: MappedArtifact) throws {
        guard artifact.kind == .links else { throw DataFormatError.kindMismatch(expected: .links, found: artifact.kind) }
        guard artifact.header.formatVersion == ArtifactKind.links.currentFormatVersion else {
            throw LinksFormatError.unsupportedFormatVersion(artifact.header.formatVersion)
        }
        header = artifact.header
        storage = artifact.payload

        let length = storage.count
        let inPlace: UnsafeRawPointer? = storage.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, Int(bitPattern: base) % 8 == 0, length > 64 else { return nil }
            return base
        }
        var copy: UnsafeMutableRawBufferPointer?
        let base: UnsafeRawPointer
        if let inPlace {
            base = inPlace
        } else {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 8), alignment: 8)
            storage.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress, length > 0 { buffer.baseAddress!.copyMemory(from: source, byteCount: length) }
            }
            copy = buffer
            base = UnsafeRawPointer(buffer.baseAddress!)
        }
        ownedCopy = copy
        do {
            let layout = try Layout(base: base, length: length)
            raw = layout.raw
            stopCount = layout.stopCount
            stationCount = layout.stationCount
            maxFootpathWalkSeconds = layout.maxFootpathWalkSeconds
            minTransferSeconds = layout.minTransferSeconds
            systemAccess = layout.systemAccess
            walkSpeedMetersPerSecond = layout.walkSpeed
            stationLinkMaxWalkMeters = layout.stationLinkMaxWalkMeters
            systemCount = layout.systemCounts
            var bases: [Int] = []
            var running = 0
            for count in layout.systemCounts {
                bases.append(running)
                running += count
            }
            systemBase = bases
        } catch {
            copy?.deallocate()
            throw error
        }
    }

    deinit {
        ownedCopy?.deallocate()
    }

    // MARK: - Global stop index

    /// Stops of `system` in the index (its timetable's `stopCount`; 0 if it was not linked).
    public func stopCount(system: TransitSystem) -> Int { systemCount[Self.slot(system)] }

    /// The global index of `system`'s stop 0.
    public func stopBase(system: TransitSystem) -> Int { systemBase[Self.slot(system)] }

    public func globalStop(system: TransitSystem, stop: Int) -> Int {
        precondition(stop >= 0 && stop < stopCount(system: system), "stop out of range")
        return stopBase(system: system) + stop
    }

    public func system(ofGlobalStop stop: Int) -> TransitSystem {
        precondition(stop >= 0 && stop < stopCount, "stop out of range")
        for slot in 0..<LinksFormat.systems.count where stop < systemBase[slot] + systemCount[slot] {
            return LinksFormat.systems[slot]
        }
        preconditionFailure("stop out of range")
    }

    /// The stop's index within its own system's timetable.
    public func localStop(ofGlobalStop stop: Int) -> Int {
        stop - stopBase(system: system(ofGlobalStop: stop))
    }

    public func stopFlags(_ stop: Int) -> LinkStopFlags { LinkStopFlags(rawValue: raw.stopFlags[stop]) }

    /// Station access charged at `system`'s street↔platform transitions.
    public func accessSeconds(system: TransitSystem) -> Int { systemAccess[Self.slot(system)] }

    /// The longest footpath listed between two stops: the walk bound plus each end's access.
    public func footpathBoundSeconds(from origin: Int, to destination: Int) -> Int {
        maxFootpathWalkSeconds + accessSeconds(system: system(ofGlobalStop: origin)) + accessSeconds(system: system(ofGlobalStop: destination))
    }

    private static func slot(_ system: TransitSystem) -> Int {
        switch system {
        case .subway: 0
        case .bus: 1
        case .lirr: 2
        case .ferry: 3
        case .path: 4
        }
    }

    // MARK: - Footpaths

    public var footpathCount: Int { raw.footpathTarget.count }

    /// Footpaths leaving `stop` (global index), by (seconds, stop).
    public func footpaths(from stop: Int) -> FootpathList {
        let range = Int(raw.footpathStart[stop])..<Int(raw.footpathStart[stop + 1])
        return FootpathList(
            targets: UnsafeBufferPointer(rebasing: raw.footpathTarget[range]),
            seconds: UnsafeBufferPointer(rebasing: raw.footpathSeconds[range])
        )
    }

    /// The footpath from one stop to another, if listed.
    public func footpathSeconds(from origin: Int, to destination: Int) -> Int? {
        footpaths(from: origin).first { $0.stop == destination }?.seconds
    }

    // MARK: - Access points

    public var accessPointCount: Int { raw.accessPointSourceStop.count }

    public func accessPoint(_ index: Int) -> LinkAccessPoint {
        LinkAccessPoint(
            sourceStop: Int(raw.accessPointSourceStop[index]),
            coordinate: Coordinate(lat: Double(raw.accessPointLatE6[index]) / 1e6, lon: Double(raw.accessPointLonE6[index]) / 1e6),
            segment: raw.accessPointSegment[index],
            fraction: raw.accessPointFraction[index],
            snapDecimeters: raw.accessPointSnapDecimeters[index],
            accessSeconds: Int(raw.accessPointAccessSeconds[index]),
            flags: LinkAccessPointFlags(rawValue: raw.accessPointFlags[index])
        )
    }

    /// Indices of the stop's access points (empty for a ride-through-only or non-routable stop).
    public func accessPoints(ofStop stop: Int) -> UnsafeBufferPointer<UInt32> {
        UnsafeBufferPointer(rebasing: raw.stopAccessPoint[Int(raw.stopAccessStart[stop])..<Int(raw.stopAccessStart[stop + 1])])
    }

    // MARK: - Station links

    public var stationLinkCount: Int { raw.stationStopStop.count }

    /// Stops near a Citi Bike station (index into `stations`), by enter seconds (station → stop),
    /// then stop; links walkable only in the exit direction come last.
    public func stops(nearStation station: Int) -> StationStopLinks {
        let range = Int(raw.stationStopStart[station])..<Int(raw.stationStopStart[station + 1])
        return StationStopLinks(
            items: UnsafeBufferPointer(rebasing: raw.stationStopStop[range]),
            enter: UnsafeBufferPointer(rebasing: raw.stationStopEnter[range]),
            exit: UnsafeBufferPointer(rebasing: raw.stationStopExit[range])
        )
    }

    /// Citi Bike stations near a stop (global index), by exit seconds (stop → station), then
    /// station; links walkable only in the enter direction come last.
    public func stations(nearStop stop: Int) -> StationStopLinks {
        let range = Int(raw.stopStationStart[stop])..<Int(raw.stopStationStart[stop + 1])
        return StationStopLinks(
            items: UnsafeBufferPointer(rebasing: raw.stopStationStation[range]),
            enter: UnsafeBufferPointer(rebasing: raw.stopStationEnter[range]),
            exit: UnsafeBufferPointer(rebasing: raw.stopStationExit[range])
        )
    }

    // MARK: - Layout

    private struct Layout {
        var raw: LinksBuffers
        var stopCount: Int
        var stationCount: Int
        var maxFootpathWalkSeconds: Int
        var minTransferSeconds: Int
        var systemAccess: [Int]
        var walkSpeed: Double
        var stationLinkMaxWalkMeters: Double
        var systemCounts: [Int]

        init(base: UnsafeRawPointer, length: Int) throws {
            let bytes = UnsafeRawBufferPointer(start: base, count: length)
            var reader = BinaryReader(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: length, deallocator: .none))
            guard try reader.readBytes(count: 4).elementsEqual(LinksFormat.payloadMagic) else { throw LinksFormatError.badPayloadMagic }
            let revision = try reader.read(UInt32.self)
            guard revision == LinksFormat.draftRevision else { throw LinksFormatError.unsupportedDraftRevision(revision) }
            let walkSeconds = try reader.read(UInt32.self)
            let transferSeconds = try reader.read(UInt32.self)
            walkSpeed = try reader.read(Double.self)
            stationLinkMaxWalkMeters = try reader.read(Double.self)
            guard walkSeconds <= 3600, transferSeconds <= 3600, walkSpeed.isFinite, walkSpeed > 0,
                  stationLinkMaxWalkMeters.isFinite, stationLinkMaxWalkMeters >= 0
            else { throw LinksFormatError.valueOutOfRange(section: "parameters", index: 0) }
            maxFootpathWalkSeconds = Int(walkSeconds)
            minTransferSeconds = Int(transferSeconds)

            func array<T: BinaryScalar>(_: T.Type, _ section: String, count expected: Int?) throws -> UnsafeBufferPointer<T> {
                let view = try reader.readArray(of: T.self)
                if let expected, view.count != expected {
                    throw LinksFormatError.countMismatch(section: section, expected: expected, actual: view.count)
                }
                let offset = reader.offset - view.count * MemoryLayout<T>.stride
                return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + view.count * MemoryLayout<T>.stride]).bindMemory(to: T.self)
            }
            let counts = try array(UInt32.self, "systemStopCounts", count: LinksFormat.systems.count)
            systemCounts = counts.map { Int($0) }
            let access = try array(UInt32.self, "systemAccessSeconds", count: LinksFormat.systems.count)
            guard access.allSatisfy({ $0 <= 3600 }) else { throw LinksFormatError.valueOutOfRange(section: "systemAccessSeconds", index: 0) }
            systemAccess = access.map { Int($0) }
            let t = systemCounts.reduce(0, +)
            guard t < Int(UInt32.max) else { throw LinksFormatError.valueOutOfRange(section: "systemStopCounts", index: 0) }
            stopCount = t
            let stopFlags = try array(UInt8.self, "stopFlags", count: t)
            let footpathStart = try array(UInt32.self, "footpathStart", count: t + 1)
            let footpathTarget = try array(UInt32.self, "footpathTarget", count: nil)
            let footpathSeconds = try array(UInt16.self, "footpathSeconds", count: footpathTarget.count)
            let apSource = try array(UInt32.self, "accessPointSourceStop", count: nil)
            let a = apSource.count
            let apLat = try array(Int32.self, "accessPointLatE6", count: a)
            let apLon = try array(Int32.self, "accessPointLonE6", count: a)
            let apSegment = try array(UInt32.self, "accessPointSegment", count: a)
            let apFraction = try array(Float.self, "accessPointFraction", count: a)
            let apSnap = try array(UInt16.self, "accessPointSnapDecimeters", count: a)
            let apAccess = try array(UInt16.self, "accessPointAccessSeconds", count: a)
            let apFlags = try array(UInt8.self, "accessPointFlags", count: a)
            let stopAccessStart = try array(UInt32.self, "stopAccessStart", count: t + 1)
            let stopAccessPoint = try array(UInt32.self, "stopAccessPoint", count: nil)
            let stationStopStart = try array(UInt32.self, "stationStopStart", count: nil)
            guard stationStopStart.count >= 1 else { throw LinksFormatError.countMismatch(section: "stationStopStart", expected: 1, actual: 0) }
            stationCount = stationStopStart.count - 1
            let stationStopStop = try array(UInt32.self, "stationStopStop", count: nil)
            let l = stationStopStop.count
            let stationStopEnter = try array(UInt16.self, "stationStopEnter", count: l)
            let stationStopExit = try array(UInt16.self, "stationStopExit", count: l)
            let stopStationStart = try array(UInt32.self, "stopStationStart", count: t + 1)
            let stopStationStation = try array(UInt32.self, "stopStationStation", count: l)
            let stopStationEnter = try array(UInt16.self, "stopStationEnter", count: l)
            let stopStationExit = try array(UInt16.self, "stopStationExit", count: l)
            guard reader.isAtEnd else { throw LinksFormatError.trailingBytes(reader.remaining) }

            func offsets(_ values: UnsafeBufferPointer<UInt32>, total: Int, _ section: String) throws {
                guard values.first == 0, Int(values[values.count - 1]) == total else {
                    throw LinksFormatError.countMismatch(section: section, expected: total, actual: Int(values.last ?? 0))
                }
                for i in 1..<values.count where values[i] < values[i - 1] { throw LinksFormatError.notMonotonic(section: section, index: i) }
            }
            func indices(_ values: UnsafeBufferPointer<UInt32>, below bound: Int, _ section: String) throws {
                if let bad = values.firstIndex(where: { Int($0) >= bound }) { throw LinksFormatError.valueOutOfRange(section: section, index: bad) }
            }
            try offsets(footpathStart, total: footpathTarget.count, "footpathStart")
            try offsets(stopAccessStart, total: stopAccessPoint.count, "stopAccessStart")
            try offsets(stationStopStart, total: l, "stationStopStart")
            try offsets(stopStationStart, total: l, "stopStationStart")
            try indices(footpathTarget, below: t, "footpathTarget")
            try indices(apSource, below: t, "accessPointSourceStop")
            try indices(stopAccessPoint, below: a, "stopAccessPoint")
            try indices(stationStopStop, below: t, "stationStopStop")
            try indices(stopStationStation, below: stationCount, "stopStationStation")
            // Every footpath within its bound: walk + access at each end.
            var stopAccess: [Int] = []
            stopAccess.reserveCapacity(t)
            for (slot, count) in systemCounts.enumerated() { stopAccess += repeatElement(systemAccess[slot], count: count) }
            for p in 0..<t {
                for slot in Int(footpathStart[p])..<Int(footpathStart[p + 1])
                where Int(footpathSeconds[slot]) > maxFootpathWalkSeconds + stopAccess[p] + stopAccess[Int(footpathTarget[slot])] {
                    throw LinksFormatError.valueOutOfRange(section: "footpathSeconds", index: slot)
                }
            }
            if let bad = stopFlags.firstIndex(where: { !LinkStopFlags.known.contains(LinkStopFlags(rawValue: $0)) }) {
                throw LinksFormatError.valueOutOfRange(section: "stopFlags", index: bad)
            }
            if let bad = apFlags.firstIndex(where: { !LinkAccessPointFlags.known.contains(LinkAccessPointFlags(rawValue: $0)) }) {
                throw LinksFormatError.valueOutOfRange(section: "accessPointFlags", index: bad)
            }
            if let bad = apFraction.firstIndex(where: { !$0.isFinite || $0 < 0 || $0 > 1 }) {
                throw LinksFormatError.valueOutOfRange(section: "accessPointFraction", index: bad)
            }

            raw = LinksBuffers(
                stopFlags: stopFlags, footpathStart: footpathStart, footpathTarget: footpathTarget, footpathSeconds: footpathSeconds,
                accessPointSourceStop: apSource, accessPointLatE6: apLat, accessPointLonE6: apLon, accessPointSegment: apSegment,
                accessPointFraction: apFraction, accessPointSnapDecimeters: apSnap, accessPointAccessSeconds: apAccess,
                accessPointFlags: apFlags, stopAccessStart: stopAccessStart, stopAccessPoint: stopAccessPoint,
                stationStopStart: stationStopStart, stationStopStop: stationStopStop, stationStopEnter: stationStopEnter,
                stationStopExit: stationStopExit, stopStationStart: stopStationStart, stopStationStation: stopStationStation,
                stopStationEnter: stopStationEnter, stopStationExit: stopStationExit
            )
        }
    }
}

/// Every array of a `links` artifact, viewed in place. Valid while the ``MappedLinks`` that owns
/// it is alive. Semantics: `docs/formats.md`.
public struct LinksBuffers {
    public let stopFlags: UnsafeBufferPointer<UInt8>
    public let footpathStart: UnsafeBufferPointer<UInt32>
    public let footpathTarget: UnsafeBufferPointer<UInt32>
    public let footpathSeconds: UnsafeBufferPointer<UInt16>
    public let accessPointSourceStop: UnsafeBufferPointer<UInt32>
    public let accessPointLatE6: UnsafeBufferPointer<Int32>
    public let accessPointLonE6: UnsafeBufferPointer<Int32>
    public let accessPointSegment: UnsafeBufferPointer<UInt32>
    public let accessPointFraction: UnsafeBufferPointer<Float>
    public let accessPointSnapDecimeters: UnsafeBufferPointer<UInt16>
    public let accessPointAccessSeconds: UnsafeBufferPointer<UInt16>
    public let accessPointFlags: UnsafeBufferPointer<UInt8>
    public let stopAccessStart: UnsafeBufferPointer<UInt32>
    public let stopAccessPoint: UnsafeBufferPointer<UInt32>
    public let stationStopStart: UnsafeBufferPointer<UInt32>
    public let stationStopStop: UnsafeBufferPointer<UInt32>
    public let stationStopEnter: UnsafeBufferPointer<UInt16>
    public let stationStopExit: UnsafeBufferPointer<UInt16>
    public let stopStationStart: UnsafeBufferPointer<UInt32>
    public let stopStationStation: UnsafeBufferPointer<UInt32>
    public let stopStationEnter: UnsafeBufferPointer<UInt16>
    public let stopStationExit: UnsafeBufferPointer<UInt16>
}

/// One footpath: the destination stop (global index) and the walk in whole seconds, station
/// access included.
public struct Footpath: Sendable, Hashable {
    public let stop: Int
    public let seconds: Int
}

/// The footpaths leaving one stop, in place.
public struct FootpathList: RandomAccessCollection {
    public let targets: UnsafeBufferPointer<UInt32>
    public let seconds: UnsafeBufferPointer<UInt16>

    public var startIndex: Int { 0 }
    public var endIndex: Int { targets.count }

    public subscript(index: Int) -> Footpath {
        Footpath(stop: Int(targets[index]), seconds: Int(seconds[index]))
    }
}

/// Where riders join the street for one stop.
public struct LinkAccessPoint: Sendable, Hashable {
    /// Global index of the stop whose position this is: a subway entrance, the station itself
    /// (``LinkAccessPointFlags/synthetic``), or a bus, LIRR or ferry stop.
    public let sourceStop: Int
    public let coordinate: Coordinate
    /// Walk-graph segment of the `streets` artifact it snapped to.
    public let segment: UInt32
    /// Position along the segment: 0 at its A node, 1 at B.
    public let fraction: Float
    public let snapDecimeters: UInt16
    /// Station access charged at this street↔platform transition (e.g. 120 s for the subway).
    public let accessSeconds: Int
    public let flags: LinkAccessPointFlags

    public var snapMeters: Double { Double(snapDecimeters) / 10 }
}

/// One stop↔station link: `index` is the stop (in a station's list) or the station (in a
/// stop's list). `enterSeconds` walks station → stop and enters the system; `exitSeconds` leaves
/// the system and walks stop → station. Both include station access; `nil` when no access point
/// allows that direction within the walk bound.
public struct StationStopLink: Sendable, Hashable {
    public let index: Int
    public let enterSeconds: Int?
    public let exitSeconds: Int?
}

public struct StationStopLinks: RandomAccessCollection {
    /// Stops (in a station's list) or stations (in a stop's list).
    public let items: UnsafeBufferPointer<UInt32>
    public let enter: UnsafeBufferPointer<UInt16>
    public let exit: UnsafeBufferPointer<UInt16>

    public var startIndex: Int { 0 }
    public var endIndex: Int { items.count }

    public subscript(position: Int) -> StationStopLink {
        StationStopLink(
            index: Int(items[position]),
            enterSeconds: enter[position] == LinksFormat.noSeconds ? nil : Int(enter[position]),
            exitSeconds: exit[position] == LinksFormat.noSeconds ? nil : Int(exit[position])
        )
    }
}
