import BRCore
import Foundation

/// One street entrance of a subway station, from the data.ny.gov dataset "MTA Subway Entrances
/// and Exits: 2024" (`i9wp-a4ja`). The timetable compiler adds each as a ``BRTimetable/StopKind``
/// `.entrance` stop whose parent is the GTFS station, for access snapping and station access.
public struct SubwayEntrance: Sendable, Equatable {
    /// The GTFS parent station `stop_id`, e.g. `R01`.
    public var stationGTFSID: String
    public var latE6: Int32
    public var lonE6: Int32
    /// E.g. `Stair`, `Elevator`, `Escalator`, `Easement - Street`, `Station House`.
    public var entranceType: String
    public var entryAllowed: Bool
    public var exitAllowed: Bool

    public init(stationGTFSID: String, latE6: Int32, lonE6: Int32, entranceType: String,
                entryAllowed: Bool, exitAllowed: Bool) {
        self.stationGTFSID = stationGTFSID
        self.latE6 = latE6
        self.lonE6 = lonE6
        self.entranceType = entranceType
        self.entryAllowed = entryAllowed
        self.exitAllowed = exitAllowed
    }
}

public enum SubwayEntrances {
    /// CSV export of the dataset.
    public static let url = "https://data.ny.gov/api/views/i9wp-a4ja/rows.csv?accessType=DOWNLOAD"
    /// File name under `<sources>/nyc/`.
    public static let fileName = "subway-entrances.csv"

    /// Parses the CSV export. An entrance listed for a complex (`GTFS Stop ID` = `A12; D13`)
    /// yields one entrance per station. Rows without a station or coordinates are counted in
    /// `issues` and skipped.
    public static func parse(_ source: some ByteChunkSource) throws -> (entrances: [SubwayEntrance], issues: [String: Int]) {
        var reader = CSVReader(source)
        guard let headerRecord = try reader.next() else { return ([], [:]) }
        let header = CSVHeader(headerRecord)
        let station = try header.requireIndex(of: "GTFS Stop ID")
        let type = try header.requireIndex(of: "Entrance Type")
        let entry = try header.requireIndex(of: "Entry Allowed")
        let exit = try header.requireIndex(of: "Exit Allowed")
        let lat = try header.requireIndex(of: "Entrance Latitude")
        let lon = try header.requireIndex(of: "Entrance Longitude")
        var entrances: [SubwayEntrance] = []
        var issues: [String: Int] = [:]
        while let record = try reader.next() {
            guard let latE6 = GTFSField.microdegrees(record[lat].bytes), let lonE6 = GTFSField.microdegrees(record[lon].bytes) else {
                issues["entrance without coordinates", default: 0] += 1
                continue
            }
            let stations = GTFSField.string(record[station].bytes).split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !stations.isEmpty else {
                issues["entrance without GTFS Stop ID", default: 0] += 1
                continue
            }
            if stations.count > 1 { issues["entrance shared by several stations", default: 0] += 1 }
            for id in stations {
                entrances.append(SubwayEntrance(
                    stationGTFSID: id, latE6: latE6, lonE6: lonE6,
                    entranceType: GTFSField.string(record[type].bytes),
                    entryAllowed: !isNo(record[entry]), exitAllowed: !isNo(record[exit])
                ))
            }
        }
        return (entrances, issues)
    }

    /// `NO` in any case, ignoring blanks. Anything else (including empty) allows.
    private static func isNo(_ field: CSVField) -> Bool {
        let bytes = GTFSField.trimmed(field.bytes)
        return bytes.count == 2 && bytes.first! | 0x20 == UInt8(ascii: "n") && bytes.last! | 0x20 == UInt8(ascii: "o")
    }

    public static func parse(fileAt url: URL) throws -> (entrances: [SubwayEntrance], issues: [String: Int]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parse(FileHandleChunkSource(handle))
    }
}
