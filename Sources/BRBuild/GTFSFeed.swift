import BRCore
import BRTimetable
import Foundation

/// Identifies one version of one GTFS feed and where it sits in source selection.
public struct GTFSSourceInfo: Sendable, Codable, Equatable {
    /// Feed name, e.g. `gtfs_supplemented`, `gtfs_b`.
    public var name: String
    /// Sources in one slot are alternative versions of one feed; exactly one is chosen per
    /// service date. The six bus zips are six slots (each covers different routes).
    public var slot: String
    /// Lower wins among versions covering a date (supplemented subway 0, regular subway 1).
    public var priority: Int
    /// Among equal priorities the newest wins; any sortable stamp (e.g. ISO 8601 Last-Modified).
    public var publishedAt: String
    public var etag: String

    public init(name: String, slot: String, priority: Int = 0, publishedAt: String = "", etag: String = "") {
        self.name = name
        self.slot = slot
        self.priority = priority
        self.publishedAt = publishedAt
        self.etag = etag
    }
}

/// One GTFS feed parsed into flat arrays. Strings are kept only for the small tables; ids read
/// from the large files are interned bytes.
public struct GTFSFeed: Sendable {
    public struct Agency: Sendable {
        public var id: String
        public var name: String
        public var timezone: String
    }

    public struct Route: Sendable {
        public var id: String
        public var agencyID: String
        public var shortName: String
        public var longName: String
        public var type: Int
        public var color: UInt32?
        public var textColor: UInt32?
    }

    public struct Stop: Sendable {
        public var id: String
        public var code: String
        public var name: String
        public var latE6: Int32
        public var lonE6: Int32
        public var locationType: UInt8
        public var parentID: String
    }

    public struct Service: Sendable {
        public var id: String
        /// Bit 0 = Monday … bit 6 = Sunday; bit 7 set when a `calendar.txt` row exists.
        public var weekdays: UInt8 = 0
        public var startDay: Int32 = 0
        public var endDay: Int32 = 0
        /// `(day, exception_type)`, ascending by day, one per day (the last row wins).
        public var exceptions: [(day: Int32, type: UInt8)] = []

        public var hasCalendar: Bool { weekdays & 0x80 != 0 }
    }

    public struct Transfer: Sendable {
        public var fromStop: String
        public var toStop: String
        public var fromTrip: String
        public var toTrip: String
        public var type: Int
        public var minTransferSeconds: Int?
    }

    public var source: GTFSSourceInfo
    public var agencies: [Agency] = []
    public var feedVersion = ""
    public var routes: [Route] = []
    public var routeIndex: [String: Int] = [:]
    public var stops: [Stop] = []
    public var stopIDs = ByteInterner()
    public var services: [Service] = []
    public var serviceIndex: [String: Int] = [:]

    // trips.txt, in file order
    public var tripIDs = ByteInterner()
    public var tripRoute: [Int32] = []
    public var tripService: [Int32] = []
    public var tripHeadsign: [UInt32] = []
    public var tripShortName: [UInt32] = []
    public var tripDirection: [UInt8] = []
    public var tripShape: [Int32] = []
    /// Headsigns and short names.
    public var texts = ByteInterner()

    // stop_times.txt: trip t owns events eventOffset[t] ..< eventOffset[t] + eventCount[t], in
    // stop_sequence order. Rows stay in file order when each trip's rows are contiguous and
    // ordered (the norm); otherwise they are regrouped.
    public var eventOffset: [UInt32] = []
    public var eventCount: [UInt32] = []
    public var eventStop: [UInt32] = []
    /// Seconds from the service day's origin, or `TimetableFormat.none` when the feed omits it.
    public var eventArrival: [UInt32] = []
    public var eventDeparture: [UInt32] = []
    /// Low nibble `pickup_type`, high nibble `drop_off_type` (0 when absent).
    public var eventPickupDropOff: [UInt8] = []
    /// stop_times rows per stop (for choosing among duplicate stops across feeds).
    public var stopEventCount: [UInt32] = []

    // shapes.txt, grouped by shape in shape_pt_sequence order
    public var shapeIDs = ByteInterner()
    public var shapePointStart: [UInt32] = [0]
    public var shapeLatE6: [Int32] = []
    public var shapeLonE6: [Int32] = []

    public var transfers: [Transfer] = []
    public var frequencyRows = 0
    /// Rows skipped or repaired while parsing, by reason.
    public var issues: [String: Int] = [:]

    public var tripCount: Int { tripRoute.count }
    public var stopTimeRows: Int { eventStop.count }

    /// Days on which this feed claims service: every `calendar.txt` range ∪ every added date.
    public func coverageDays() -> (first: Int32, last: Int32)? {
        var first = Int32.max, last = Int32.min
        for service in services {
            if service.hasCalendar {
                first = min(first, service.startDay)
                last = max(last, service.endDay)
            }
            for exception in service.exceptions where exception.type == 1 {
                first = min(first, exception.day)
                last = max(last, exception.day)
            }
        }
        return first <= last ? (first, last) : nil
    }

    /// Whether `day` lies in a `calendar.txt` range or is an added date.
    public func covers(day: Int32) -> Bool {
        services.contains { service in
            (service.hasCalendar && day >= service.startDay && day <= service.endDay)
                || service.exceptions.contains { $0.day == day && $0.type == 1 }
        }
    }
}

extension GTFSFeed {
    /// Parses every file the compiler uses. `stop_times.txt` and `shapes.txt` are streamed
    /// field by field without creating strings.
    public static func parse(_ files: some GTFSFeedFiles, source: GTFSSourceInfo) throws -> GTFSFeed {
        var feed = GTFSFeed(source: source)
        let names = try files.fileNames()
        for required in ["agency.txt", "routes.txt", "stops.txt", "trips.txt", "stop_times.txt"] where !names.contains(required) {
            throw GTFSError.missingFile(feed: files.location, file: required)
        }
        guard names.contains("calendar.txt") || names.contains("calendar_dates.txt") else {
            throw GTFSError.missingFile(feed: files.location, file: "calendar.txt or calendar_dates.txt")
        }
        try feed.parseAgencies(files)
        try feed.parseFeedInfo(files)
        try feed.parseRoutes(files)
        try feed.parseStops(files)
        try feed.parseCalendars(files)
        try feed.parseTrips(files)
        try feed.parseStopTimes(files)
        try feed.parseShapes(files)
        try feed.parseTransfers(files)
        try files.forEachRecord(in: "frequencies.txt", required: false) { _, _, _ in feed.frequencyRows += 1 }
        return feed
    }

    private mutating func note(_ issue: String, _ count: Int = 1) {
        issues[issue, default: 0] += count
    }

    private static func column(_ header: CSVHeader, _ name: String, _ files: some GTFSFeedFiles, _ file: String) throws -> Int {
        guard let index = header.index(of: name) else {
            throw GTFSError.missingColumn(feed: files.location, file: file, column: name)
        }
        return index
    }

    private mutating func parseAgencies(_ files: some GTFSFeedFiles) throws {
        try files.forEachRecord(in: "agency.txt", required: true) { header, record, _ in
            let id = header.index(of: "agency_id").map { GTFSField.string(record[$0].bytes) } ?? ""
            let name = header.index(of: "agency_name").map { GTFSField.string(record[$0].bytes) } ?? ""
            let zone = header.index(of: "agency_timezone").map { GTFSField.string(record[$0].bytes) } ?? ""
            agencies.append(Agency(id: id, name: name, timezone: zone))
        }
    }

    private mutating func parseFeedInfo(_ files: some GTFSFeedFiles) throws {
        try files.forEachRecord(in: "feed_info.txt", required: false) { header, record, _ in
            if let index = header.index(of: "feed_version"), feedVersion.isEmpty {
                feedVersion = GTFSField.string(record[index].bytes)
            }
        }
    }

    private mutating func parseRoutes(_ files: some GTFSFeedFiles) throws {
        let defaultAgency = agencies.first?.id ?? ""
        try files.forEachRecord(in: "routes.txt", required: true) { header, record, number in
            let idColumn = try Self.column(header, "route_id", files, "routes.txt")
            let id = GTFSField.string(record[idColumn].bytes)
            guard !id.isEmpty, routeIndex[id] == nil else {
                note("routes.txt: empty or duplicate route_id")
                return
            }
            var agency = header.index(of: "agency_id").map { GTFSField.string(record[$0].bytes) } ?? ""
            if agency.isEmpty { agency = defaultAgency }
            routeIndex[id] = routes.count
            routes.append(Route(
                id: id,
                agencyID: agency,
                shortName: header.index(of: "route_short_name").map { GTFSField.string(record[$0].bytes) } ?? "",
                longName: header.index(of: "route_long_name").map { GTFSField.string(record[$0].bytes) } ?? "",
                type: header.index(of: "route_type").flatMap { GTFSField.int(record[$0].bytes) } ?? 3,
                color: header.index(of: "route_color").flatMap { GTFSField.color(record[$0].bytes) },
                textColor: header.index(of: "route_text_color").flatMap { GTFSField.color(record[$0].bytes) }
            ))
        }
    }

    private mutating func parseStops(_ files: some GTFSFeedFiles) throws {
        try files.forEachRecord(in: "stops.txt", required: true) { header, record, number in
            let idColumn = try Self.column(header, "stop_id", files, "stops.txt")
            let idBytes = GTFSField.trimmed(record[idColumn].bytes)
            guard !idBytes.isEmpty, stopIDs.lookup(idBytes) == nil else {
                note("stops.txt: empty or duplicate stop_id")
                return
            }
            let locationType = header.index(of: "location_type").flatMap { GTFSField.int(record[$0].bytes) } ?? 0
            let lat = header.index(of: "stop_lat").flatMap { GTFSField.microdegrees(record[$0].bytes) }
            let lon = header.index(of: "stop_lon").flatMap { GTFSField.microdegrees(record[$0].bytes) }
            guard let lat, let lon else {
                // Only generic nodes and boarding areas may omit coordinates; we use neither.
                note("stops.txt: stop without coordinates")
                return
            }
            stopIDs.intern(idBytes)
            stops.append(Stop(
                id: String(decoding: idBytes, as: UTF8.self),
                code: header.index(of: "stop_code").map { GTFSField.string(record[$0].bytes) } ?? "",
                name: header.index(of: "stop_name").map { GTFSField.string(record[$0].bytes) } ?? "",
                latE6: lat,
                lonE6: lon,
                locationType: UInt8(clamping: locationType),
                parentID: header.index(of: "parent_station").map { GTFSField.string(record[$0].bytes) } ?? ""
            ))
        }
        stopEventCount = [UInt32](repeating: 0, count: stops.count)
    }

    private mutating func parseCalendars(_ files: some GTFSFeedFiles) throws {
        func service(_ id: String) -> Int {
            if let index = serviceIndex[id] { return index }
            serviceIndex[id] = services.count
            services.append(Service(id: id))
            return services.count - 1
        }
        try files.forEachRecord(in: "calendar.txt", required: false) { header, record, number in
            let id = GTFSField.string(record[try Self.column(header, "service_id", files, "calendar.txt")].bytes)
            let dayColumns = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
            var mask: UInt8 = 0x80
            for (bit, name) in dayColumns.enumerated() {
                let column = try Self.column(header, name, files, "calendar.txt")
                if GTFSField.int(record[column].bytes) == 1 { mask |= 1 << UInt8(bit) }
            }
            let startText = record[try Self.column(header, "start_date", files, "calendar.txt")].bytes
            let endText = record[try Self.column(header, "end_date", files, "calendar.txt")].bytes
            guard let start = GTFSField.day(startText), let end = GTFSField.day(endText) else {
                throw GTFSError.invalidValue(feed: files.location, file: "calendar.txt", record: number,
                                             column: "start_date/end_date", value: GTFSField.string(startText))
            }
            let index = service(id)
            services[index].weekdays = mask
            services[index].startDay = start
            services[index].endDay = end
        }
        try files.forEachRecord(in: "calendar_dates.txt", required: false) { header, record, number in
            let id = GTFSField.string(record[try Self.column(header, "service_id", files, "calendar_dates.txt")].bytes)
            let dateText = record[try Self.column(header, "date", files, "calendar_dates.txt")].bytes
            let typeValue = GTFSField.int(record[try Self.column(header, "exception_type", files, "calendar_dates.txt")].bytes)
            guard let day = GTFSField.day(dateText), let typeValue, typeValue == 1 || typeValue == 2 else {
                throw GTFSError.invalidValue(feed: files.location, file: "calendar_dates.txt", record: number,
                                             column: "date/exception_type", value: GTFSField.string(dateText))
            }
            services[service(id)].exceptions.append((day, UInt8(typeValue)))
        }
        for index in services.indices {
            // Sort by day, keeping the last row for a repeated day.
            var byDay: [Int32: UInt8] = [:]
            for exception in services[index].exceptions { byDay[exception.day] = exception.type }
            services[index].exceptions = byDay.keys.sorted().map { ($0, byDay[$0]!) }
        }
    }

    private mutating func parseTrips(_ files: some GTFSFeedFiles) throws {
        texts.intern("")
        try files.forEachRecord(in: "trips.txt", required: true) { header, record, number in
            let tripColumn = try Self.column(header, "trip_id", files, "trips.txt")
            let routeColumn = try Self.column(header, "route_id", files, "trips.txt")
            let serviceColumn = try Self.column(header, "service_id", files, "trips.txt")
            let tripBytes = GTFSField.trimmed(record[tripColumn].bytes)
            guard !tripBytes.isEmpty, tripIDs.lookup(tripBytes) == nil else {
                note("trips.txt: empty or duplicate trip_id")
                return
            }
            guard let route = routeIndex[GTFSField.string(record[routeColumn].bytes)] else {
                note("trips.txt: unknown route_id")
                return
            }
            guard let service = serviceIndex[GTFSField.string(record[serviceColumn].bytes)] else {
                note("trips.txt: service_id without calendar")
                return
            }
            tripIDs.intern(tripBytes)
            tripRoute.append(Int32(route))
            tripService.append(Int32(service))
            tripHeadsign.append(header.index(of: "trip_headsign").map { texts.intern(GTFSField.trimmed(record[$0].bytes)) } ?? 0)
            tripShortName.append(header.index(of: "trip_short_name").map { texts.intern(GTFSField.trimmed(record[$0].bytes)) } ?? 0)
            let direction = header.index(of: "direction_id").flatMap { GTFSField.int(record[$0].bytes) }
            tripDirection.append(direction.map { UInt8(clamping: $0) } ?? 255)
            let shape = header.index(of: "shape_id").map { GTFSField.trimmed(record[$0].bytes) } ?? []
            tripShape.append(shape.isEmpty ? -1 : Int32(shapeIDs.intern(shape)))
        }
    }

    private mutating func parseStopTimes(_ files: some GTFSFeedFiles) throws {
        // Rows in file order; regrouped by trip below.
        var rowTrip: [UInt32] = [], rowSequence: [UInt32] = [], rowStop: [UInt32] = []
        var rowArrival: [UInt32] = [], rowDeparture: [UInt32] = [], rowFlags: [UInt8] = []
        var columns: (trip: Int, arrival: Int, departure: Int, stop: Int, sequence: Int, pickup: Int, dropOff: Int)?
        var lastTripBytes: [UInt8] = []
        var lastTrip: UInt32? = nil
        var unknownTrips = 0, unknownStops = 0, badSequences = 0, badTimes = 0
        try files.forEachRecord(in: "stop_times.txt", required: true) { header, record, number in
            if columns == nil {
                columns = (
                    try Self.column(header, "trip_id", files, "stop_times.txt"),
                    try Self.column(header, "arrival_time", files, "stop_times.txt"),
                    try Self.column(header, "departure_time", files, "stop_times.txt"),
                    try Self.column(header, "stop_id", files, "stop_times.txt"),
                    try Self.column(header, "stop_sequence", files, "stop_times.txt"),
                    header.index(of: "pickup_type") ?? -1,
                    header.index(of: "drop_off_type") ?? -1
                )
            }
            let c = columns!
            let tripBytes = GTFSField.trimmed(record[c.trip].bytes)
            if !tripBytes.elementsEqual(lastTripBytes) {
                lastTripBytes.removeAll(keepingCapacity: true)
                lastTripBytes.append(contentsOf: tripBytes)
                lastTrip = tripIDs.lookup(tripBytes)
            }
            guard let trip = lastTrip else {
                unknownTrips += 1
                return
            }
            guard let stop = stopIDs.lookup(GTFSField.trimmed(record[c.stop].bytes)) else {
                unknownStops += 1
                return
            }
            guard let sequence = GTFSField.int(record[c.sequence].bytes), sequence <= Int(UInt32.max) else {
                badSequences += 1
                return
            }
            let arrivalField = record[c.arrival].bytes, departureField = record[c.departure].bytes
            var arrival = GTFSField.time(arrivalField)
            var departure = GTFSField.time(departureField)
            if (arrival == nil && !GTFSField.trimmed(arrivalField).isEmpty)
                || (departure == nil && !GTFSField.trimmed(departureField).isEmpty) {
                badTimes += 1
            }
            if arrival == nil { arrival = departure }
            if departure == nil { departure = arrival }
            let pickup = c.pickup >= 0 ? (GTFSField.int(record[c.pickup].bytes) ?? 0) : 0
            let dropOff = c.dropOff >= 0 ? (GTFSField.int(record[c.dropOff].bytes) ?? 0) : 0
            rowTrip.append(trip)
            rowSequence.append(UInt32(sequence))
            rowStop.append(stop)
            rowArrival.append(arrival ?? TimetableFormat.none)
            rowDeparture.append(departure ?? TimetableFormat.none)
            rowFlags.append(UInt8(min(pickup, 15)) | UInt8(min(dropOff, 15)) << 4)
        }
        if unknownTrips > 0 { note("stop_times.txt: unknown trip_id", unknownTrips) }
        if unknownStops > 0 { note("stop_times.txt: unknown stop_id", unknownStops) }
        if badSequences > 0 { note("stop_times.txt: invalid stop_sequence", badSequences) }
        if badTimes > 0 { note("stop_times.txt: unparseable time (treated as missing)", badTimes) }

        // Fast path: every trip's rows are one contiguous run in stop_sequence order.
        let trips = tripCount
        let rows = rowTrip.count
        var offset = [UInt32](repeating: TimetableFormat.none, count: trips)
        var count = [UInt32](repeating: 0, count: trips)
        var contiguous = true
        var row = 0
        while row < rows {
            let trip = Int(rowTrip[row])
            if offset[trip] != TimetableFormat.none {
                contiguous = false
                break
            }
            var end = row + 1
            while end < rows, rowTrip[end] == rowTrip[row] {
                if rowSequence[end] < rowSequence[end - 1] { contiguous = false }
                end += 1
            }
            if !contiguous { break }
            offset[trip] = UInt32(row)
            count[trip] = UInt32(end - row)
            row = end
        }
        if contiguous {
            for trip in 0..<trips where offset[trip] == TimetableFormat.none { offset[trip] = 0 }
            rowTrip = []
            rowSequence = []
            eventOffset = offset
            eventCount = count
            eventStop = rowStop
            eventArrival = rowArrival
            eventDeparture = rowDeparture
            eventPickupDropOff = rowFlags
        } else {
            // Stable counting sort by trip, then order each trip by stop_sequence.
            var start = [UInt32](repeating: 0, count: trips + 1)
            for trip in rowTrip { start[Int(trip) + 1] += 1 }
            for index in 0..<trips { start[index + 1] += start[index] }
            var cursor = start
            var order = [Int](repeating: 0, count: rows)
            for (row, trip) in rowTrip.enumerated() {
                order[Int(cursor[Int(trip)])] = row
                cursor[Int(trip)] += 1
            }
            rowTrip = []
            var resorted = 0
            for trip in 0..<trips {
                let range = Int(start[trip])..<Int(start[trip + 1])
                var ascending = true
                var index = range.lowerBound + 1
                while index < range.upperBound {
                    if rowSequence[order[index]] < rowSequence[order[index - 1]] { ascending = false; break }
                    index += 1
                }
                if !ascending {
                    order[range].sort { rowSequence[$0] < rowSequence[$1] || (rowSequence[$0] == rowSequence[$1] && $0 < $1) }
                    resorted += 1
                }
            }
            if resorted > 0 { note("stop_times.txt: trips not in stop_sequence order (sorted)", resorted) }
            rowSequence = []
            eventOffset = Array(start.dropLast())
            eventCount = (0..<trips).map { start[$0 + 1] - start[$0] }
            eventStop = order.map { rowStop[$0] }
            eventArrival = order.map { rowArrival[$0] }
            eventDeparture = order.map { rowDeparture[$0] }
            eventPickupDropOff = order.map { rowFlags[$0] }
        }
        for stop in eventStop { stopEventCount[Int(stop)] += 1 }
    }

    /// The event range of `trip`.
    @inline(__always)
    public func events(ofTrip trip: Int) -> Range<Int> {
        Int(eventOffset[trip])..<Int(eventOffset[trip] + eventCount[trip])
    }

    private mutating func parseShapes(_ files: some GTFSFeedFiles) throws {
        var rowShape: [UInt32] = [], rowSequence: [UInt32] = [], rowLat: [Int32] = [], rowLon: [Int32] = []
        var columns: (shape: Int, lat: Int, lon: Int, sequence: Int)?
        var lastBytes: [UInt8] = []
        var lastShape: UInt32? = nil
        var unknown = 0, bad = 0
        let present = try files.forEachRecord(in: "shapes.txt", required: false) { header, record, number in
            if columns == nil {
                columns = (
                    try Self.column(header, "shape_id", files, "shapes.txt"),
                    try Self.column(header, "shape_pt_lat", files, "shapes.txt"),
                    try Self.column(header, "shape_pt_lon", files, "shapes.txt"),
                    try Self.column(header, "shape_pt_sequence", files, "shapes.txt")
                )
            }
            let c = columns!
            let idBytes = GTFSField.trimmed(record[c.shape].bytes)
            if !idBytes.elementsEqual(lastBytes) {
                lastBytes.removeAll(keepingCapacity: true)
                lastBytes.append(contentsOf: idBytes)
                lastShape = shapeIDs.lookup(idBytes)
            }
            // Shapes no trip uses are skipped.
            guard let shape = lastShape else {
                unknown += 1
                return
            }
            guard let lat = GTFSField.microdegrees(record[c.lat].bytes),
                  let lon = GTFSField.microdegrees(record[c.lon].bytes),
                  let sequence = GTFSField.int(record[c.sequence].bytes)
            else {
                bad += 1
                return
            }
            rowShape.append(shape)
            rowSequence.append(UInt32(clamping: sequence))
            rowLat.append(lat)
            rowLon.append(lon)
        }
        if bad > 0 { note("shapes.txt: invalid point", bad) }
        _ = unknown
        let shapes = shapeIDs.count
        var start = [UInt32](repeating: 0, count: shapes + 1)
        guard present else {
            shapePointStart = start
            return
        }
        for shape in rowShape { start[Int(shape) + 1] += 1 }
        for index in 0..<shapes { start[index + 1] += start[index] }
        var cursor = start
        var order = [Int](repeating: 0, count: rowShape.count)
        for (row, shape) in rowShape.enumerated() {
            order[Int(cursor[Int(shape)])] = row
            cursor[Int(shape)] += 1
        }
        for shape in 0..<shapes {
            let range = Int(start[shape])..<Int(start[shape + 1])
            order[range].sort { rowSequence[$0] < rowSequence[$1] || (rowSequence[$0] == rowSequence[$1] && $0 < $1) }
        }
        shapePointStart = start
        shapeLatE6 = order.map { rowLat[$0] }
        shapeLonE6 = order.map { rowLon[$0] }
    }

    private mutating func parseTransfers(_ files: some GTFSFeedFiles) throws {
        try files.forEachRecord(in: "transfers.txt", required: false) { header, record, _ in
            func field(_ name: String) -> String {
                header.index(of: name).map { GTFSField.string(record[$0].bytes) } ?? ""
            }
            let from = field("from_stop_id"), to = field("to_stop_id")
            guard !from.isEmpty, !to.isEmpty else {
                note("transfers.txt: row without stops")
                return
            }
            transfers.append(Transfer(
                fromStop: from, toStop: to,
                fromTrip: field("from_trip_id"), toTrip: field("to_trip_id"),
                type: header.index(of: "transfer_type").flatMap { GTFSField.int(record[$0].bytes) } ?? 0,
                minTransferSeconds: header.index(of: "min_transfer_time").flatMap { GTFSField.int(record[$0].bytes) }
            ))
        }
    }
}
