import BRData
import BRGeo
import Foundation

/// The `stations` artifact, memory-mapped: Citi Bike stations (by GBFS `station_id`) and the dense
/// station × station bike-distance matrix. Layout: `docs/formats.md`.
///
/// `matrix[i][j]` is the true length, in decameters, of the minimum bike-*cost* path from station
/// i to station j under ``matrixProfile`` (bike-class multipliers, one-ways), including the
/// straight legs from each station to its snapped point. Ride time is length ÷ the rider's speed.
/// ``StationsFormat/unreachable`` marks pairs without a path. Stations are ordered along a
/// Hilbert curve (neighbors get neighboring indices); ``index(ofStationID:)`` binary-searches a
/// separate id-sorted index. The matrix is stored as a high-byte plane and a low-byte plane, which
/// compresses to less than half of plain `u16`s; each lookup reads one byte from each.
///
/// ## Thread safety
/// `@unchecked Sendable` is sound because every stored property is immutable after `init`, and
/// the buffer pointers view bytes that this object keeps alive (the mapping, or a private aligned
/// copy it owns) and never writes.
public final class MappedStations: @unchecked Sendable {
    /// The raw artifact's file name inside a data directory such as `build/data`.
    public static let fileName = "stations.bin"

    public let header: ArtifactHeader
    public let count: Int
    /// The profile whose costs chose each path. Its speed does not scale the stored lengths.
    public let matrixProfile: BikeProfile

    private let storage: Data
    private let ownedCopy: UnsafeMutableRawBufferPointer?
    private let stringOffsets: UnsafeBufferPointer<UInt32>
    private let stringBytes: UnsafeBufferPointer<UInt8>
    private let ids: UnsafeBufferPointer<UInt32>
    private let idOrder: UnsafeBufferPointer<UInt32>
    private let names: UnsafeBufferPointer<UInt32>
    private let shortNames: UnsafeBufferPointer<UInt32>
    private let regions: UnsafeBufferPointer<UInt32>
    private let latE6: UnsafeBufferPointer<Int32>
    private let lonE6: UnsafeBufferPointer<Int32>
    private let capacities: UnsafeBufferPointer<UInt16>
    private let flagBits: UnsafeBufferPointer<UInt8>
    private let bikeSegments: UnsafeBufferPointer<UInt32>
    private let bikeFractions: UnsafeBufferPointer<Float>
    private let bikeDecimeters: UnsafeBufferPointer<UInt16>
    private let walkSegments: UnsafeBufferPointer<UInt32>
    private let walkFractions: UnsafeBufferPointer<Float>
    private let walkDecimeters: UnsafeBufferPointer<UInt16>
    /// Row-major `count × count` high and low bytes of each distance.
    private let matrixHigh: UnsafeBufferPointer<UInt8>
    private let matrixLow: UnsafeBufferPointer<UInt8>

    /// Maps `stations.bin` from a data directory, e.g. `build/data`.
    public static func load(fromDataDirectory directory: URL) throws -> MappedStations {
        try MappedStations(contentsOf: directory.appendingPathComponent(fileName))
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(artifact: MappedArtifact(contentsOf: url, expecting: .stations))
    }

    public init(artifact: MappedArtifact) throws {
        guard artifact.kind == .stations else {
            throw DataFormatError.kindMismatch(expected: .stations, found: artifact.kind)
        }
        guard artifact.header.formatVersion == ArtifactKind.stations.currentFormatVersion else {
            throw StationsFormatError.unsupportedFormatVersion(artifact.header.formatVersion)
        }
        header = artifact.header
        storage = artifact.payload

        // View in place when 8-aligned (always, for mapped files); otherwise use an aligned copy.
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
            let bytes = UnsafeRawBufferPointer(start: base, count: length)
            var reader = BinaryReader(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: length, deallocator: .none))
            guard try reader.readBytes(count: 4).elementsEqual(StationsFormat.payloadMagic) else {
                throw StationsFormatError.badPayloadMagic
            }
            let revision = try reader.read(UInt32.self)
            guard revision == StationsFormat.draftRevision else { throw StationsFormatError.unsupportedDraftRevision(revision) }
            let rawCount = try reader.read(UInt64.self)
            guard rawCount < UInt64(UInt16.max) else { throw StationsFormatError.valueOutOfRange(section: "count", index: 0) }
            let n = Int(rawCount)
            count = n

            func array<T: BinaryScalar>(_: T.Type, _ section: String, count expected: Int?) throws -> UnsafeBufferPointer<T> {
                let view = try reader.readArray(of: T.self)
                if let expected, view.count != expected {
                    throw StationsFormatError.countMismatch(section: section, expected: expected, actual: view.count)
                }
                let offset = reader.offset - view.count * MemoryLayout<T>.stride
                return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + view.count * MemoryLayout<T>.stride])
                    .bindMemory(to: T.self)
            }
            let profile = try array(Double.self, "matrixProfile", count: StationsFormat.profileValueCount)
            stringOffsets = try array(UInt32.self, "stringOffsets", count: nil)
            stringBytes = try array(UInt8.self, "stringBytes", count: nil)
            ids = try array(UInt32.self, "stationIDs", count: n)
            idOrder = try array(UInt32.self, "stationIDOrder", count: n)
            names = try array(UInt32.self, "stationNames", count: n)
            shortNames = try array(UInt32.self, "stationShortNames", count: n)
            regions = try array(UInt32.self, "stationRegions", count: n)
            latE6 = try array(Int32.self, "stationLatE6", count: n)
            lonE6 = try array(Int32.self, "stationLonE6", count: n)
            capacities = try array(UInt16.self, "stationCapacities", count: n)
            flagBits = try array(UInt8.self, "stationFlags", count: n)
            bikeSegments = try array(UInt32.self, "bikeSnapSegments", count: n)
            bikeFractions = try array(Float.self, "bikeSnapFractions", count: n)
            bikeDecimeters = try array(UInt16.self, "bikeSnapDecimeters", count: n)
            walkSegments = try array(UInt32.self, "walkSnapSegments", count: n)
            walkFractions = try array(Float.self, "walkSnapFractions", count: n)
            walkDecimeters = try array(UInt16.self, "walkSnapDecimeters", count: n)
            matrixHigh = try array(UInt8.self, "matrixHigh", count: n * n)
            matrixLow = try array(UInt8.self, "matrixLow", count: n * n)
            guard reader.isAtEnd else { throw StationsFormatError.trailingBytes(reader.remaining) }

            guard profile.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw StationsFormatError.valueOutOfRange(section: "matrixProfile", index: 0)
            }
            matrixProfile = BikeProfile(
                speedMetersPerSecond: profile[0],
                multipliers: BikeClassMultipliers(protected: profile[2], painted: profile[3], shared: profile[4], arterial: profile[5]),
                dismountSpeedMetersPerSecond: profile[1]
            )
            try Self.validate(
                stringOffsets: stringOffsets, stringBytes: stringBytes, fields: [ids, names, shortNames, regions],
                ids: ids, idOrder: idOrder, flags: flagBits,
                snaps: [(bikeSegments, bikeFractions, StationFlags.bikeSnapped), (walkSegments, walkFractions, .walkSnapped)],
                matrixHigh: matrixHigh, matrixLow: matrixLow, count: n
            )
        } catch {
            copy?.deallocate()
            throw error
        }
    }

    deinit {
        ownedCopy?.deallocate()
    }

    private static func validate(
        stringOffsets: UnsafeBufferPointer<UInt32>, stringBytes: UnsafeBufferPointer<UInt8>,
        fields: [UnsafeBufferPointer<UInt32>], ids: UnsafeBufferPointer<UInt32>, idOrder: UnsafeBufferPointer<UInt32>,
        flags: UnsafeBufferPointer<UInt8>, snaps: [(UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<Float>, StationFlags)],
        matrixHigh: UnsafeBufferPointer<UInt8>, matrixLow: UnsafeBufferPointer<UInt8>, count n: Int
    ) throws {
        guard stringOffsets.count >= 1, stringOffsets[0] == 0, Int(stringOffsets[stringOffsets.count - 1]) == stringBytes.count else {
            throw StationsFormatError.countMismatch(section: "stringOffsets", expected: stringBytes.count, actual: Int(stringOffsets.last ?? 0))
        }
        for i in 1..<stringOffsets.count where stringOffsets[i] < stringOffsets[i - 1] {
            throw StationsFormatError.notMonotonic(section: "stringOffsets", index: i)
        }
        let strings = stringOffsets.count - 1
        for field in fields {
            if let bad = field.firstIndex(where: { Int($0) >= strings }) {
                throw StationsFormatError.valueOutOfRange(section: "stationStrings", index: bad)
            }
        }
        func bytes(_ id: UInt32) -> UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(rebasing: stringBytes[Int(stringOffsets[Int(id)])..<Int(stringOffsets[Int(id) + 1])])
        }
        if let bad = idOrder.firstIndex(where: { Int($0) >= n }) {
            throw StationsFormatError.valueOutOfRange(section: "stationIDOrder", index: bad)
        }
        // Strictly ascending ids through the order: sorted, unique, hence a permutation.
        for i in 1..<max(1, n) where !bytes(ids[Int(idOrder[i - 1])]).lexicographicallyPrecedes(bytes(ids[Int(idOrder[i])])) {
            throw StationsFormatError.idsNotSorted(index: i)
        }
        for i in 0..<n where !StationFlags.known.contains(StationFlags(rawValue: flags[i])) {
            throw StationsFormatError.valueOutOfRange(section: "stationFlags", index: i)
        }
        for (segments, fractions, flag) in snaps {
            for i in 0..<n {
                let snapped = StationFlags(rawValue: flags[i]).contains(flag)
                guard snapped == (segments[i] != StationsFormat.noSegment),
                      fractions[i].isFinite, fractions[i] >= 0, fractions[i] <= 1
                else { throw StationsFormatError.valueOutOfRange(section: "snaps", index: i) }
            }
        }
        for i in 0..<n where matrixHigh[i * n + i] != 0 || matrixLow[i * n + i] != 0 {
            throw StationsFormatError.valueOutOfRange(section: "matrixDiagonal", index: i)
        }
    }

    // MARK: - Stations

    private func string(_ id: UInt32) -> String {
        let start = Int(stringOffsets[Int(id)]), end = Int(stringOffsets[Int(id) + 1])
        return String(decoding: UnsafeBufferPointer(rebasing: stringBytes[start..<end]), as: UTF8.self)
    }

    private func stringBytes(_ id: UInt32) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: stringBytes[Int(stringOffsets[Int(id)])..<Int(stringOffsets[Int(id) + 1])])
    }

    /// The GBFS `station_id`.
    public func stationID(_ station: Int) -> String { string(ids[station]) }
    public func name(_ station: Int) -> String { string(names[station]) }
    /// The GBFS `short_name` (trip data joins on it byte for byte).
    public func shortName(_ station: Int) -> String { string(shortNames[station]) }
    /// The GBFS `region_id`, or `nil` when the feed gave none.
    public func regionID(_ station: Int) -> String? {
        regions[station] == 0 ? nil : string(regions[station])
    }
    /// Nominal dock count (always positive; live counts may exceed it).
    public func capacity(_ station: Int) -> Int { Int(capacities[station]) }
    public func flags(_ station: Int) -> StationFlags { StationFlags(rawValue: flagBits[station]) }

    public func coordinate(_ station: Int) -> Coordinate {
        Coordinate(lat: Double(latE6[station]) / 1e6, lon: Double(lonE6[station]) / 1e6)
    }

    /// The station's index, by binary search over the id-sorted index.
    public func index(ofStationID id: String) -> Int? {
        var key = id
        return key.withUTF8 { key in
            var low = 0, high = count
            while low < high {
                let mid = (low + high) / 2
                if stringBytes(ids[Int(idOrder[mid])]).lexicographicallyPrecedes(key) { low = mid + 1 } else { high = mid }
            }
            guard low < count else { return nil }
            let station = Int(idOrder[low])
            return stringBytes(ids[station]).elementsEqual(key) ? station : nil
        }
    }

    /// Where the station joins the bike graph (the matrix's end points), if it snapped.
    public func bikeSnap(_ station: Int) -> StoredSnap? {
        bikeSegments[station] == StationsFormat.noSegment ? nil
            : StoredSnap(segment: bikeSegments[station], fraction: bikeFractions[station], distanceDecimeters: bikeDecimeters[station])
    }

    /// Where the station joins the walk graph, for walk trees to and from it.
    public func walkSnap(_ station: Int) -> StoredSnap? {
        walkSegments[station] == StationsFormat.noSegment ? nil
            : StoredSnap(segment: walkSegments[station], fraction: walkFractions[station], distanceDecimeters: walkDecimeters[station])
    }

    // MARK: - Matrix

    /// Decameters by bike from one station to another, or ``StationsFormat/unreachable``.
    @inline(__always)
    public func distanceDecameters(from origin: Int, to destination: Int) -> UInt16 {
        precondition(origin >= 0 && origin < count && destination >= 0 && destination < count, "station out of range")
        let k = origin * count + destination
        return UInt16(matrixHigh[k]) << 8 | UInt16(matrixLow[k])
    }

    /// Meters by bike, or `nil` when unreachable.
    public func distanceMeters(from origin: Int, to destination: Int) -> Double? {
        let value = distanceDecameters(from: origin, to: destination)
        return value == StationsFormat.unreachable ? nil : Double(value) * 10
    }

    /// Every distance from `origin` in decameters, indexed by destination station. Valid while
    /// `self` is alive.
    public func row(from origin: Int) -> StationMatrixRow {
        precondition(origin >= 0 && origin < count, "station out of range")
        let range = origin * count..<(origin + 1) * count
        return StationMatrixRow(high: UnsafeBufferPointer(rebasing: matrixHigh[range]), low: UnsafeBufferPointer(rebasing: matrixLow[range]))
    }
}

/// One matrix row, in place: decameters to each destination, or ``StationsFormat/unreachable``.
public struct StationMatrixRow: RandomAccessCollection {
    let high: UnsafeBufferPointer<UInt8>
    let low: UnsafeBufferPointer<UInt8>

    public var startIndex: Int { 0 }
    public var endIndex: Int { high.count }

    @inline(__always)
    public subscript(destination: Int) -> UInt16 {
        UInt16(high[destination]) << 8 | UInt16(low[destination])
    }
}
