import BRBuild
import BRCore
import BRData
import BRTimetable
import Foundation

/// Where each fixed array of a `links` payload lives, found by reading each array's `u64` count
/// at the next 8-aligned offset (`docs/formats.md`, "links"), so tests can change single bytes.
struct LinksPayloadLayout {
    struct Field {
        /// Payload offset of element 0.
        let offset: Int
        let count: Int
        let size: Int

        func at(_ index: Int) -> Int {
            precondition(index >= 0 && index < count, "element out of range")
            return offset + index * size
        }
    }

    /// The fixed arrays in payload order, with their element sizes.
    static let fields: [(name: String, size: Int)] = [
        ("systemStopCounts", 4), ("systemAccessSeconds", 4), ("stopFlags", 1),
        ("footpathStart", 4), ("footpathTarget", 4), ("footpathSeconds", 2),
        ("accessPointSourceStop", 4), ("accessPointLatE6", 4), ("accessPointLonE6", 4), ("accessPointSegment", 4),
        ("accessPointFraction", 4), ("accessPointSnapDecimeters", 2), ("accessPointAccessSeconds", 2), ("accessPointFlags", 1),
        ("stopAccessStart", 4), ("stopAccessPoint", 4),
        ("stationStopStart", 4), ("stationStopStop", 4), ("stationStopEnter", 2), ("stationStopExit", 2),
        ("stopStationStart", 4), ("stopStationStation", 4), ("stopStationEnter", 2), ("stopStationExit", 2),
    ]

    private(set) var fields: [String: Field] = [:]
    /// Where the extension tail starts: everything before it is the fixed part.
    private(set) var tail = 0

    init(_ payload: Data) {
        let bytes = Data(payload)
        var offset = 32 // magic, revision, two u32 and two f64 parameters
        for (name, size) in Self.fields {
            offset = (offset + 7) / 8 * 8
            let count = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
            fields[name] = Field(offset: offset + 8, count: count, size: size)
            offset += 8 + count * size
        }
        tail = offset
    }

    subscript(name: String) -> Field { fields[name]! }
}

extension Data {
    /// A copy with the little-endian `value` written at `offset`.
    func replacing<T: FixedWidthInteger>(_ value: T, at offset: Int) -> Data {
        var copy = Data(self)
        let start = copy.startIndex + offset
        Swift.withUnsafeBytes(of: value.littleEndian) { copy.replaceSubrange(start..<start + MemoryLayout<T>.size, with: $0) }
        return copy
    }

    /// The little-endian value at `offset`.
    func value<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        T(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    /// `self` (a payload's fixed part) followed by an extension tail written by hand, so ids may
    /// be out of order. Returns the bytes and the payload offset of each entry's id.
    func withRawExtensionTail(_ entries: [(id: UInt32, bytes: [UInt8])]) -> (payload: Data, idOffsets: [Int]) {
        var writer = BinaryWriter()
        writer.append(bytes: self)
        writer.append(UInt32(entries.count))
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(writer.count)
            writer.append(entry.id)
            writer.append(array: entry.bytes)
        }
        return (writer.data, offsets)
    }
}

/// Lowercase-hex SHA-256 of the payload alone (the bytes from headerLength on): the header
/// embeds builderSwiftVersion, so the file's own hash changes with every toolchain.
func linksPayloadSHA256(_ file: Data) throws -> String {
    let payload = Data(try ArtifactHeader.decode(from: file).payload)
    #if canImport(CryptoKit)
    return CryptoKitHasher().sha256(of: payload).hex
    #else
    return try ProcessHasher(runner: ProcessToolRunner()).sha256(of: payload).hex
    #endif
}
