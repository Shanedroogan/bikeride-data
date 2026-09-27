import BRCore
import BRData
import BRFlows
import Foundation

/// A scratch directory removed when the value is no longer needed.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brflows-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// Writes `contents` to `name` (creating parent directories) and returns its URL.
    @discardableResult
    func write(_ name: String, _ contents: String) throws -> URL {
        let target = file(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
        return target
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func date(_ yyyymmdd: String) -> ServiceDate {
    guard let date = ServiceDate(yyyymmdd: yyyymmdd) else { preconditionFailure("bad date \(yyyymmdd)") }
    return date
}

/// Lowercase-hex SHA-256 of some bytes.
func sha256Hex(_ data: Data) throws -> String {
    #if canImport(CryptoKit)
    return CryptoKitHasher().sha256(of: data).hex
    #else
    return try ProcessHasher(runner: ProcessToolRunner()).sha256(of: data).hex
    #endif
}

/// A small `flows` file typed by hand: three keys, every parameter spelled out, and every cell a
/// dyadic fraction that binary16 holds exactly, so no platform floating point reaches the bytes.
/// Nothing is compiled from trip data or GBFS. The keys take the forms Citi Bike's short_names do
/// but are made up (none is a station's short_name), as is every coordinate, capacity, day count,
/// flag and cell. The payload golden and the committed v1 file (``FlowsV1Tests``) are made from it.
enum HandBuiltFlows {
    static let keys = ["9901.1", "9902.08", "JC901"]
    static let window = FlowWindow(start: date("20260601"), dayCount: 92)
    static let smoothing = FlowSmoothingParameters(
        kappaCellMilli: 4_000, kappaHourMilli: 8_000, kappaDispersionMilli: 6_000, neighborCount: 8, neighborRadiusMeters: 1_000
    )

    /// Quarters and eighths of small integers: exact in binary16.
    static func value(_ row: Int, _ dayType: FlowDayType, _ direction: FlowDirection, _ slot: FlowSlot, _ bin: Int) -> Double {
        let classic = Double((row * 7 + Int(dayType.rawValue) * 3 + Int(direction.rawValue) + bin % 5) % 17) / 8
        let ebike = Double((row + bin % 3) % 11) / 4
        switch slot {
        case .meanClassic: return classic
        case .varianceClassic: return classic * 1.5
        case .meanEbike: return ebike
        case .varianceEbike: return ebike * 2
        case .varianceAny: return classic * 1.5 + ebike * 2 + 0.25
        }
    }

    static func data(keys: [String] = keys) -> FlowsData {
        var cells = [UInt16](repeating: 0, count: keys.count * FlowsFormat.cellsPerKey)
        for row in keys.indices {
            for dayType in FlowDayType.allCases {
                for direction in FlowDirection.allCases {
                    for slot in FlowSlot.allCases {
                        for bin in 0..<FlowsFormat.binsPerDay {
                            cells[FlowsFormat.cellIndex(row: row, dayType: dayType, direction: direction, slot: slot, bin: bin)] =
                                HalfFloat.bits(from: value(row, dayType, direction, slot, bin))
                        }
                    }
                }
            }
        }
        let stations = keys.enumerated().map { row, key in
            FlowStation(
                key: key, latE6: 40_700_000 + Int32(row) * 1_000, lonE6: -74_000_000 - Int32(row) * 2_000,
                capacity: UInt16(row * 10), activeDays: [UInt16(60 + row), UInt16(61 + row), UInt16(20 + row), UInt16(21 + row)],
                flags: row == 0 ? [.inGBFS, .lowData] : [.inGBFS]
            )
        }
        return FlowsData(
            departureWindow: window, arrivalWindow: window, flags: [.customerTripsOnly], smoothing: smoothing,
            holidays: [date("20260703"), date("20260907")].filter { window.contains($0) }, stations: stations, cells: cells
        )
    }

    static func artifact(_ data: FlowsData = data(), dataVersion: String = "hand-built") throws -> Data {
        try data.artifactBytes(dataVersion: dataVersion)
    }
}

/// The committed v1 files in `Tests/Fixtures/v1` (see the stations tests' `V1Fixtures`):
/// `flows.bin` was written from ``HandBuiltFlows`` when the format froze (2026-09-27), and every
/// later reader must still open it. It is frozen, not regenerated when the writer changes:
/// `BR_WRITE_V1_FIXTURES=1 swift test --filter FlowsV1Tests` rewrites it (and skips the tests that
/// read it), for a deliberate reason only.
enum V1Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("v1")
    static let dataVersion = "v1-fixture"
    static let regenerating = ProcessInfo.processInfo.environment["BR_WRITE_V1_FIXTURES"] == "1"

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func write(_ bytes: Data, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// `file` with its header's formatVersion (the `u16` at byte 8) replaced.
    static func withFormatVersion(_ version: UInt16, _ file: Data) -> Data {
        var copy = Data(file)
        copy[copy.startIndex + 8] = UInt8(version & 0xFF)
        copy[copy.startIndex + 9] = UInt8(version >> 8)
        return copy
    }

    /// Lowercase-hex SHA-256 of the payload alone (the bytes from headerLength on): the header
    /// embeds builderSwiftVersion, so the file's own hash changes with every toolchain.
    static func payloadSHA256(_ file: Data) throws -> String {
        try sha256Hex(Data(ArtifactHeader.decode(from: file).payload))
    }
}

extension Data {
    /// A copy with a little-endian value written at `offset` (from the start of the data).
    func replacing<T: FixedWidthInteger>(_ value: T, at offset: Int) -> Data {
        var copy = Data(self)
        Swift.withUnsafeBytes(of: value.littleEndian) { bytes in
            copy.replaceSubrange(copy.startIndex + offset..<copy.startIndex + offset + bytes.count, with: bytes)
        }
        return copy
    }
}

/// Writes zips of stored (uncompressed) entries, so the zip tests need `unzip` (which CI installs)
/// but not `zip` (which it does not): local headers, a central directory and the end record, a
/// fixed 1980-01-01 timestamp, no data descriptors.
enum StoredZip {
    static var unzipInstalled: Bool { ProcessToolRunner().locate("unzip") != nil }

    static func write(_ entries: [(name: String, data: Data)], to url: URL) throws {
        var out = Data()
        var central = Data()
        func u16(_ value: Int, _ data: inout Data) { Swift.withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32, _ data: inout Data) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dosTime = 0, dosDate = 1 << 5 | 1 // 1980-01-01 00:00
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data), size = UInt32(entry.data.count), offset = UInt32(out.count)
            u32(0x0403_4B50, &out)
            u16(20, &out); u16(0, &out); u16(0, &out); u16(dosTime, &out); u16(dosDate, &out)
            u32(crc, &out); u32(size, &out); u32(size, &out)
            u16(name.count, &out); u16(0, &out)
            out.append(name)
            out.append(entry.data)

            u32(0x0201_4B50, &central)
            u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central); u16(dosTime, &central); u16(dosDate, &central)
            u32(crc, &central); u32(size, &central); u32(size, &central)
            u16(name.count, &central); u16(0, &central); u16(0, &central) // name, extra, comment lengths
            u16(0, &central); u16(0, &central); u32(0, &central)          // disk, internal and external attributes
            u32(offset, &central)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out)
        u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(centralOffset, &out)
        u16(0, &out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url)
    }

    /// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
}
