import BRCore
import BRData
import Foundation

/// The build parameters of the rail bike hops, stored at the head of the hop block (extension id
/// ``LinksFormat/hopsExtensionID``). Integers only, so a hop's arithmetic is the same on every
/// platform. Layout: `docs/formats.md`, "links: rail bike hops".
public struct LinkHopParameters: Sendable, Hashable {
    /// A pair was kept only if some speed in [``minSpeedMmPerSecond``, ``maxSpeedMmPerSecond``]
    /// gives its best tuple a ride within [``minRideSeconds``, ``maxRideSeconds``].
    public var minRideSeconds: Int
    public var maxRideSeconds: Int
    public var minSpeedMmPerSecond: Int
    public var maxSpeedMmPerSecond: Int
    /// The speed that ranked the pickups and docks.
    public var rankSpeedMmPerSecond: Int
    /// Charged per ride when ranking: unlocking at the pickup, docking at the drop-off.
    public var unlockSeconds: Int
    public var dockSeconds: Int
    /// Pickup and dock slots per hop (kP, kD).
    public var pickupsPerHop: Int
    public var docksPerHop: Int

    public init(minRideSeconds: Int, maxRideSeconds: Int, minSpeedMmPerSecond: Int, maxSpeedMmPerSecond: Int,
                rankSpeedMmPerSecond: Int, unlockSeconds: Int, dockSeconds: Int, pickupsPerHop: Int, docksPerHop: Int) {
        self.minRideSeconds = minRideSeconds
        self.maxRideSeconds = maxRideSeconds
        self.minSpeedMmPerSecond = minSpeedMmPerSecond
        self.maxSpeedMmPerSecond = maxSpeedMmPerSecond
        self.rankSpeedMmPerSecond = rankSpeedMmPerSecond
        self.unlockSeconds = unlockSeconds
        self.dockSeconds = dockSeconds
        self.pickupsPerHop = pickupsPerHop
        self.docksPerHop = docksPerHop
    }

    /// The values in stored order.
    public var stored: [UInt32] {
        [minRideSeconds, maxRideSeconds, minSpeedMmPerSecond, maxSpeedMmPerSecond, rankSpeedMmPerSecond,
         unlockSeconds, dockSeconds, pickupsPerHop, docksPerHop].map { UInt32($0) }
    }

    /// Whether every value is in the range readers accept: seconds at most 3,600, speeds in
    /// (0, 20,000] mm/s, 1–8 pickup and dock slots, and each minimum at most its maximum.
    public var isInRange: Bool {
        let seconds = [minRideSeconds, maxRideSeconds, unlockSeconds, dockSeconds]
        let speeds = [minSpeedMmPerSecond, maxSpeedMmPerSecond, rankSpeedMmPerSecond]
        return seconds.allSatisfy { (0...3600).contains($0) } && speeds.allSatisfy { (1...20_000).contains($0) }
            && (1...8).contains(pickupsPerHop) && (1...8).contains(docksPerHop)
            && minRideSeconds <= maxRideSeconds && minSpeedMmPerSecond <= maxSpeedMmPerSecond
    }
}

/// Per-hop bits.
public struct LinkHopFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Some scheduled trip rides from A to B without a change, but the bike was not beaten by it
    /// at midday, so the hop was kept. A hint: nothing depends on it.
    public static let oneSeatRideExists = LinkHopFlags(rawValue: 1 << 0)

    /// The bits this reader defines; ``LinkHops`` drops the rest.
    public static let known: LinkHopFlags = [.oneSeatRideExists]
}

/// The rail bike hops of a `links` artifact, viewed in place: for a rail parent station A, the
/// parent stations B worth a mid-trip bike ride, each with up to kP Citi Bike pickups near A and
/// kD docks near B. Pickup slot 0 and dock slot 0 form the best tuple (least exit + unlock + ride
/// at the rank speed + dock + enter). Rows are keyed by the global stop index of A (a station's
/// parent stop, or a LIRR stop itself); valid while the ``MappedLinks`` that owns it is alive.
public struct LinkHops: @unchecked Sendable {
    public let parameters: LinkHopParameters
    public let hopStart: UnsafeBufferPointer<UInt32>
    public let hopTarget: UnsafeBufferPointer<UInt32>
    public let hopPickup: UnsafeBufferPointer<UInt16>
    public let hopDock: UnsafeBufferPointer<UInt16>
    public let hopMinDecameters: UnsafeBufferPointer<UInt16>
    public let hopMinWalkSeconds: UnsafeBufferPointer<UInt16>
    public let hopFlags: UnsafeBufferPointer<UInt8>

    /// Hops over every origin.
    public var count: Int { hopTarget.count }

    /// Hops from rail parent `origin` (global stop index), by ascending target.
    public func hops(fromParent origin: Int) -> LinkHopRows {
        LinkHopRows(hops: self, rows: Int(hopStart[origin])..<Int(hopStart[origin + 1]))
    }

    public func hop(_ row: Int) -> LinkHop {
        let p = parameters.pickupsPerHop, d = parameters.docksPerHop
        return LinkHop(
            row: row, target: Int(hopTarget[row]),
            pickupSlots: UnsafeBufferPointer(rebasing: hopPickup[row * p..<(row + 1) * p]),
            dockSlots: UnsafeBufferPointer(rebasing: hopDock[row * d..<(row + 1) * d]),
            minDecameters: Int(hopMinDecameters[row]), minWalkSeconds: Int(hopMinWalkSeconds[row]),
            flags: LinkHopFlags(rawValue: hopFlags[row]).intersection(.known)
        )
    }
}

public struct LinkHopRows: RandomAccessCollection {
    let hops: LinkHops
    public let rows: Range<Int>

    public var startIndex: Int { 0 }
    public var endIndex: Int { rows.count }

    public subscript(position: Int) -> LinkHop { hops.hop(rows.lowerBound + position) }
}

/// One hop A → B.
public struct LinkHop {
    /// Its row in the hop arrays (e.g. for a journey's parent record).
    public let row: Int
    /// B, the destination rail parent (global stop index).
    public let target: Int
    /// Station indices, best first, `0xFFFF` in unused slots (always after the used ones).
    public let pickupSlots: UnsafeBufferPointer<UInt16>
    public let dockSlots: UnsafeBufferPointer<UInt16>
    /// The least matrix distance over the stored tuples that have a path: a pruning bound.
    public let minDecameters: Int
    /// The least exit (from A's nearest platform to the pickup) + enter (from the dock to B's
    /// nearest platform) over the stored tuples that have a path, station access included.
    public let minWalkSeconds: Int
    public let flags: LinkHopFlags

    public var pickups: [Int] { pickupSlots.prefix { $0 != LinksFormat.noStation }.map(Int.init) }
    public var docks: [Int] { dockSlots.prefix { $0 != LinksFormat.noStation }.map(Int.init) }
}

extension LinkHops {
    /// Parses the hop block (the bytes of extension id ``LinksFormat/hopsExtensionID``) in place.
    /// `base` is 8-aligned: extension bytes start 8-aligned in the payload. `stopCount`,
    /// `stationCount` and `railStops` (the global index ranges of subway, LIRR and PATH) come from
    /// the fixed part. Structure and index ranges are always checked; with `validate`, the
    /// invariants too.
    static func parse(base: UnsafeRawPointer, length: Int, stopCount t: Int, stationCount s: Int,
                      railStops: [Range<Int>], validate: Bool) throws -> LinkHops {
        guard Int(bitPattern: base) % 8 == 0 else { throw LinksFormatError.valueOutOfRange(section: "hops", index: 0) }
        let bytes = UnsafeRawBufferPointer(start: base, count: length)
        var reader = BinaryReader(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: length, deallocator: .none))
        var values: [Int] = []
        for _ in 0..<9 { values.append(Int(try reader.read(UInt32.self))) }
        let parameters = LinkHopParameters(
            minRideSeconds: values[0], maxRideSeconds: values[1], minSpeedMmPerSecond: values[2], maxSpeedMmPerSecond: values[3],
            rankSpeedMmPerSecond: values[4], unlockSeconds: values[5], dockSeconds: values[6], pickupsPerHop: values[7], docksPerHop: values[8]
        )
        guard parameters.isInRange else { throw LinksFormatError.valueOutOfRange(section: "hopParameters", index: 0) }
        func array<T: BinaryScalar>(_: T.Type, _ section: String, count expected: Int?) throws -> UnsafeBufferPointer<T> {
            let view = try reader.readArray(of: T.self)
            if let expected, view.count != expected {
                throw LinksFormatError.countMismatch(section: section, expected: expected, actual: view.count)
            }
            let offset = reader.offset - view.count * MemoryLayout<T>.stride
            return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + view.count * MemoryLayout<T>.stride]).bindMemory(to: T.self)
        }
        let start = try array(UInt32.self, "hopStart", count: t + 1)
        let target = try array(UInt32.self, "hopTarget", count: nil)
        let h = target.count
        let kP = parameters.pickupsPerHop, kD = parameters.docksPerHop
        let pickup = try array(UInt16.self, "hopPickup", count: h * kP)
        let dock = try array(UInt16.self, "hopDock", count: h * kD)
        let minDecameters = try array(UInt16.self, "hopMinDecameters", count: h)
        let minWalk = try array(UInt16.self, "hopMinWalkSeconds", count: h)
        let flags = try array(UInt8.self, "hopFlags", count: h)
        guard reader.isAtEnd else { throw LinksFormatError.trailingBytes(reader.remaining) }

        // Structure and indices: always.
        guard start[0] == 0, Int(start[t]) == h else { throw LinksFormatError.countMismatch(section: "hopStart", expected: h, actual: Int(start[t])) }
        for i in 1...t where start[i] < start[i - 1] { throw LinksFormatError.notMonotonic(section: "hopStart", index: i) }
        if let bad = target.firstIndex(where: { Int($0) >= t }) { throw LinksFormatError.valueOutOfRange(section: "hopTarget", index: bad) }
        for (section, slots) in [("hopPickup", pickup), ("hopDock", dock)] {
            if let bad = slots.firstIndex(where: { $0 != LinksFormat.noStation && Int($0) >= s }) {
                throw LinksFormatError.valueOutOfRange(section: section, index: bad)
            }
        }
        let hops = LinkHops(parameters: parameters, hopStart: start, hopTarget: target, hopPickup: pickup, hopDock: dock,
                            hopMinDecameters: minDecameters, hopMinWalkSeconds: minWalk, hopFlags: flags)
        if validate { try hops.checkInvariants(stopCount: t, railStops: railStops) }
        return hops
    }

    /// Rows only from rail stops, to other rail stops, strictly ascending; slot 0 used, unused
    /// slots trailing, no station twice in a row's pickups or docks; bounds present.
    func checkInvariants(stopCount t: Int, railStops: [Range<Int>]) throws {
        func violated(_ rule: String, _ index: Int) -> LinksFormatError { .invariantViolated(rule: rule, index: index) }
        func isRail(_ stop: Int) -> Bool { railStops.contains { $0.contains(stop) } }
        let kP = parameters.pickupsPerHop, kD = parameters.docksPerHop
        for origin in 0..<t {
            let rows = Int(hopStart[origin])..<Int(hopStart[origin + 1])
            guard !rows.isEmpty else { continue }
            if !isRail(origin) { throw violated("hopFromNonRailStop", origin) }
            var previous = -1
            for row in rows {
                let destination = Int(hopTarget[row])
                if destination == origin { throw violated("hopToItself", row) }
                if destination <= previous { throw violated("hopRowOrder", row) }
                previous = destination
                if !isRail(destination) { throw violated("hopToNonRailStop", row) }
                if hopMinDecameters[row] == StationsNoPath.value || hopMinWalkSeconds[row] == LinksFormat.noSeconds {
                    throw violated("hopWithoutBound", row)
                }
                for (slots, k, rule) in [(hopPickup, kP, "hopPickups"), (hopDock, kD, "hopDocks")] {
                    let used = UnsafeBufferPointer(rebasing: slots[row * k..<(row + 1) * k])
                    if used[0] == LinksFormat.noStation { throw violated("\(rule)Empty", row) }
                    var padded = false
                    for (i, slot) in used.enumerated() {
                        if slot == LinksFormat.noStation { padded = true; continue }
                        if padded { throw violated("\(rule)PaddingNotTrailing", row) }
                        if used[..<i].contains(slot) { throw violated("\(rule)Repeat", row) }
                    }
                }
            }
        }
    }
}

/// The matrix's "no path" (`StationsFormat.unreachable` in BRStreetCore, which BRTimetable does
/// not import).
enum StationsNoPath {
    static let value: UInt16 = 0xFFFF
}
