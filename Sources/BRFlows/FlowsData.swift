import BRCore
import BRData
import Foundation

/// One key of a `flows` file: a GBFS `short_name` and what the builder knew about its station.
public struct FlowStation: Sendable, Equatable {
    /// The GBFS `short_name`, byte for byte (the trip data's `start_station_id` / `end_station_id`).
    public var key: String
    public var latE6: Int32
    public var lonE6: Int32
    /// GBFS `capacity` at build time; 0 when the feed gave 0 or none.
    public var capacity: UInt16
    /// Active days per `[dayType][direction]` (``FlowsFormat/activeDaysIndex(row:dayType:direction:)``
    /// with row 0): the denominators of the station's means.
    public var activeDays: [UInt16]
    public var flags: FlowStationFlags

    public init(key: String, latE6: Int32, lonE6: Int32, capacity: UInt16, activeDays: [UInt16], flags: FlowStationFlags) {
        self.key = key
        self.latE6 = latE6
        self.lonE6 = lonE6
        self.capacity = capacity
        self.activeDays = activeDays
        self.flags = flags
    }

    public func activeDays(_ dayType: FlowDayType, _ direction: FlowDirection) -> UInt16 {
        activeDays[FlowsFormat.activeDaysIndex(row: 0, dayType: dayType, direction: direction)]
    }
}

/// The contents of a `flows` payload, and its writer. The builder (BRBuild `FlowsCompiler`) and
/// synthetic fixtures fill it; ``encodedPayload()`` lays it out as `docs/formats.md` ("flows")
/// specifies and refuses anything ``MappedFlows`` would reject.
public struct FlowsData: Sendable, Equatable {
    public var departureWindow: FlowWindow
    public var arrivalWindow: FlowWindow
    public var flags: FlowsInfoFlags
    public var smoothing: FlowSmoothingParameters
    /// Dates inside the windows that were treated as weekend days although they are weekdays
    /// (holidays with the `weekend` profile). Strictly ascending.
    public var holidays: [ServiceDate]
    /// Strictly ascending by the UTF-8 bytes of ``FlowStation/key``.
    public var stations: [FlowStation]
    /// Binary16 bit patterns, `stations.count × FlowsFormat.cellsPerKey`, laid out as
    /// ``FlowsFormat/cellIndex(row:dayType:direction:slot:bin:)``.
    public var cells: [UInt16]

    public init(
        departureWindow: FlowWindow, arrivalWindow: FlowWindow, flags: FlowsInfoFlags = [.customerTripsOnly],
        smoothing: FlowSmoothingParameters, holidays: [ServiceDate], stations: [FlowStation], cells: [UInt16]
    ) {
        self.departureWindow = departureWindow
        self.arrivalWindow = arrivalWindow
        self.flags = flags
        self.smoothing = smoothing
        self.holidays = holidays
        self.stations = stations
        self.cells = cells
    }

    /// The payload bytes (without the artifact header). Throws the error ``MappedFlows`` would
    /// throw on them: the bytes are validated by the reader's own checks before they are returned.
    public func encodedPayload() throws -> Data {
        let payload = encodedSections()
        try payload.withUnsafeBytes { raw in
            // `Data` storage is at least 16-aligned; copy anyway if it ever is not.
            if let base = raw.baseAddress, Int(bitPattern: base) % 8 == 0 {
                _ = try FlowsLayout(base: base, length: raw.count, validate: true)
            } else {
                let aligned = UnsafeMutableRawBufferPointer.allocate(byteCount: max(raw.count, 8), alignment: 8)
                defer { aligned.deallocate() }
                aligned.copyMemory(from: raw)
                _ = try FlowsLayout(base: UnsafeRawPointer(aligned.baseAddress!), length: raw.count, validate: true)
            }
        }
        return payload
    }

    /// A complete artifact file: a `flows` header (current format version, empty `builtAgainst`:
    /// flows is built from trip data and GBFS, never from another artifact) and the payload.
    public func artifactBytes(dataVersion: String) throws -> Data {
        let header = ArtifactHeader(
            kind: .flows, formatVersion: ArtifactKind.flows.currentFormatVersion,
            dataVersion: dataVersion, builderSwiftVersion: BuildInfo.swiftVersion, builtAgainst: [:]
        )
        return header.assemble(payload: try encodedPayload())
    }

    /// The payload without validation, so tests can hand the reader bytes the writer refuses.
    public func encodedSections() -> Data {
        var info = [Int64](repeating: 0, count: FlowsInfoField.allCases.count)
        info[FlowsInfoField.departureWindowStartDay.rawValue] = Int64(departureWindow.start.daysSinceEpoch)
        info[FlowsInfoField.departureWindowDayCount.rawValue] = Int64(departureWindow.dayCount)
        info[FlowsInfoField.arrivalWindowStartDay.rawValue] = Int64(arrivalWindow.start.daysSinceEpoch)
        info[FlowsInfoField.arrivalWindowDayCount.rawValue] = Int64(arrivalWindow.dayCount)
        info[FlowsInfoField.binMinutes.rawValue] = Int64(FlowsFormat.binMinutes)
        info[FlowsInfoField.binsPerDay.rawValue] = Int64(FlowsFormat.binsPerDay)
        info[FlowsInfoField.dayTypes.rawValue] = Int64(FlowsFormat.dayTypeCount)
        info[FlowsInfoField.bikeTypes.rawValue] = Int64(FlowsFormat.bikeTypeCount)
        info[FlowsInfoField.slotsPerSeries.rawValue] = Int64(FlowsFormat.slotCount)
        info[FlowsInfoField.flags.rawValue] = flags.rawValue
        info[FlowsInfoField.kappaCellMilli.rawValue] = smoothing.kappaCellMilli
        info[FlowsInfoField.kappaHourMilli.rawValue] = smoothing.kappaHourMilli
        info[FlowsInfoField.kappaDispersionMilli.rawValue] = smoothing.kappaDispersionMilli
        info[FlowsInfoField.neighborCount.rawValue] = smoothing.neighborCount
        info[FlowsInfoField.neighborRadiusMeters.rawValue] = smoothing.neighborRadiusMeters

        var keyOffsets: [UInt32] = [0]
        var keyBytes: [UInt8] = []
        for station in stations {
            keyBytes.append(contentsOf: station.key.utf8)
            keyOffsets.append(UInt32(truncatingIfNeeded: keyBytes.count))
        }
        var sections = FlowsSectionWriter()
        sections.add(.info, info)
        sections.add(.holidays, holidays.map { Int32(truncatingIfNeeded: $0.daysSinceEpoch) })
        sections.add(.keyOffsets, keyOffsets)
        sections.add(.keyBytes, keyBytes)
        sections.add(.stationLatE6, stations.map(\.latE6))
        sections.add(.stationLonE6, stations.map(\.lonE6))
        sections.add(.stationCapacity, stations.map(\.capacity))
        sections.add(.stationActiveDays, stations.flatMap(\.activeDays))
        sections.add(.stationFlags, stations.map(\.flags.rawValue))
        sections.add(.cells, cells)
        return sections.payload()
    }
}

/// Lays out sections behind the preamble and table of contents, each 8-aligned and zero padded,
/// in the order they are added.
struct FlowsSectionWriter {
    private struct Pending {
        let id: UInt32
        let elementSize: Int
        let count: Int
        let bytes: Data
    }

    private var pending: [Pending] = []

    mutating func add<T: BinaryScalar>(_ section: FlowsSection, _ values: [T]) {
        precondition(MemoryLayout<T>.stride == section.elementSize, "element size mismatch for \(section)")
        add(id: section.rawValue, elementSize: section.elementSize, values)
    }

    /// Any id, for tests of readers that must skip sections they don't know.
    mutating func add<T: BinaryScalar>(id: UInt32, elementSize: Int, _ values: [T]) {
        let bytes = values.withUnsafeBufferPointer { Data(buffer: $0) }
        pending.append(Pending(id: id, elementSize: elementSize, count: values.count, bytes: bytes))
    }

    func payload() -> Data {
        var writer = BinaryWriter(reservingCapacity: pending.reduce(0) { $0 + $1.bytes.count + 8 } + 4096)
        writer.append(bytes: FlowsFormat.magic)
        writer.append(FlowsFormat.payloadRevision)
        writer.append(UInt32(pending.count))
        writer.append(UInt32(0))
        let tocStart = writer.count
        for _ in pending {
            writer.append(UInt32(0)); writer.append(UInt32(0)); writer.append(UInt64(0)); writer.append(UInt64(0))
        }
        for (index, item) in pending.enumerated() {
            writer.pad(toMultipleOf: 8)
            let entry = tocStart + index * FlowsFormat.tocEntrySize
            writer.overwrite(item.id, at: entry)
            writer.overwrite(UInt32(item.elementSize), at: entry + 4)
            writer.overwrite(UInt64(writer.count), at: entry + 8)
            writer.overwrite(UInt64(item.count), at: entry + 16)
            writer.append(bytes: item.bytes)
        }
        writer.pad(toMultipleOf: 8)
        return writer.data
    }
}
