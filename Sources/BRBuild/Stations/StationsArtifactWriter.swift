import BRCore
import BRData
import BRStreetCore
import Foundation

/// Serializes the `stations` artifact (layout: `docs/formats.md`; reader:
/// ``BRStreetCore/MappedStations``).
public enum StationsArtifactWriter {
    /// A complete artifact file. `stations` must have unique ids, in the order
    /// ``StationsBuilder/select(_:area:rules:)`` returns them, and `matrix` must be row-major in
    /// that order.
    public static func artifact(
        stations: [CompiledStation], matrix: [UInt16], profile: BikeProfile,
        dataVersion: String, builtAgainst: [String: String]
    ) -> Data {
        let header = ArtifactHeader(
            kind: .stations, formatVersion: ArtifactKind.stations.currentFormatVersion,
            dataVersion: dataVersion, builderSwiftVersion: BuildInfo.swiftVersion, builtAgainst: builtAgainst
        )
        return header.assemble(payload: payload(stations: stations, matrix: matrix, profile: profile))
    }

    public static func payload(stations: [CompiledStation], matrix: [UInt16], profile: BikeProfile) -> Data {
        let n = stations.count
        precondition(matrix.count == n * n, "matrix is not count × count")
        let idOrder = (0..<UInt32(n)).sorted { stations[Int($0)].id.utf8.lexicographicallyPrecedes(stations[Int($1)].id.utf8) }
        precondition(zip(idOrder, idOrder.dropFirst()).allSatisfy { stations[Int($0)].id != stations[Int($1)].id },
                     "station ids must be unique")

        var strings = StringPool()
        let ids = stations.map { strings.intern($0.id) }
        let names = stations.map { strings.intern($0.name) }
        let shortNames = stations.map { strings.intern($0.shortName) }
        let regions = stations.map { $0.regionID.map { strings.intern($0) } ?? 0 }

        var writer = BinaryWriter(reservingCapacity: 256 + n * 64 + matrix.count * 2)
        writer.append(bytes: StationsFormat.payloadMagic)
        writer.append(StationsFormat.draftRevision)
        writer.append(UInt64(n))
        let multipliers = profile.multipliers
        writer.append(array: [profile.speedMetersPerSecond, profile.dismountSpeedMetersPerSecond,
                              multipliers.protected, multipliers.painted, multipliers.shared, multipliers.arterial])
        writer.append(array: strings.offsets)
        writer.append(array: strings.bytes)
        writer.append(array: ids)
        writer.append(array: idOrder)
        writer.append(array: names)
        writer.append(array: shortNames)
        writer.append(array: regions)
        writer.append(array: stations.map(\.latE6))
        writer.append(array: stations.map(\.lonE6))
        writer.append(array: stations.map(\.capacity))
        writer.append(array: stations.map(\.flags.rawValue))
        writer.append(array: stations.map { $0.bikeSnap?.segment ?? StationsFormat.noSegment })
        writer.append(array: stations.map { $0.bikeSnap?.fraction ?? 0 })
        writer.append(array: stations.map { $0.bikeSnap?.distanceDecimeters ?? 0 })
        writer.append(array: stations.map { $0.walkSnap?.segment ?? StationsFormat.noSegment })
        writer.append(array: stations.map { $0.walkSnap?.fraction ?? 0 })
        writer.append(array: stations.map { $0.walkSnap?.distanceDecimeters ?? 0 })
        // Two byte planes: every entry's high byte, then every low byte. xz compresses the
        // slowly varying high bytes far better apart from the noisy low ones.
        writer.append(array: matrix.map { UInt8($0 >> 8) })
        writer.append(array: matrix.map { UInt8($0 & 0xFF) })
        return writer.data
    }
}

/// Unique strings in first-use order; string 0 is always empty.
struct StringPool {
    private(set) var offsets: [UInt32] = [0, 0]
    private(set) var bytes: [UInt8] = []
    private var index: [String: UInt32] = ["": 0]

    mutating func intern(_ string: String) -> UInt32 {
        if let id = index[string] { return id }
        let id = UInt32(offsets.count - 1)
        bytes.append(contentsOf: string.utf8)
        offsets.append(UInt32(bytes.count))
        index[string] = id
        return id
    }
}
