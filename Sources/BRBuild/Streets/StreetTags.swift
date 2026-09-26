/// The OSM tag keys the street profiles read. Everything else on a way is ignored.
enum StreetTagKey: Int, CaseIterable {
    case highway, footway, path, crossing, area, access, foot, bicycle, vehicle, motorroad
    case sidewalk, sidewalkBoth, sidewalkLeft, sidewalkRight
    case oneway, onewayBicycle, junction
    case cycleway, cyclewayBoth, cyclewayLeft, cyclewayRight
    case cyclewayOneway, cyclewayBothOneway, cyclewayLeftOneway, cyclewayRightOneway
    case name, bridgeName, ref, bridge, service

    var osmKey: String {
        switch self {
        case .highway: "highway"
        case .footway: "footway"
        case .path: "path"
        case .crossing: "crossing"
        case .area: "area"
        case .access: "access"
        case .foot: "foot"
        case .bicycle: "bicycle"
        case .vehicle: "vehicle"
        case .motorroad: "motorroad"
        case .sidewalk: "sidewalk"
        case .sidewalkBoth: "sidewalk:both"
        case .sidewalkLeft: "sidewalk:left"
        case .sidewalkRight: "sidewalk:right"
        case .oneway: "oneway"
        case .onewayBicycle: "oneway:bicycle"
        case .junction: "junction"
        case .cycleway: "cycleway"
        case .cyclewayBoth: "cycleway:both"
        case .cyclewayLeft: "cycleway:left"
        case .cyclewayRight: "cycleway:right"
        case .cyclewayOneway: "cycleway:oneway"
        case .cyclewayBothOneway: "cycleway:both:oneway"
        case .cyclewayLeftOneway: "cycleway:left:oneway"
        case .cyclewayRightOneway: "cycleway:right:oneway"
        case .name: "name"
        case .bridgeName: "bridge:name"
        case .ref: "ref"
        case .bridge: "bridge"
        case .service: "service"
        }
    }
}

/// Byte-string lookup tables built once. Keys are matched by an FNV-1a hash and then
/// compared byte for byte, so a lookup allocates nothing.
struct ByteKeyTable<Value: Sendable>: Sendable {
    private var entries: [UInt64: [(bytes: [UInt8], value: Value)]] = [:]

    init(_ pairs: [(String, Value)]) {
        for (key, value) in pairs {
            let bytes = Array(key.utf8)
            entries[Self.hash(bytes), default: []].append((bytes, value))
        }
    }

    func lookup(_ bytes: UnsafeBufferPointer<UInt8>) -> Value? {
        guard let bucket = entries[Self.hash(bytes)] else { return nil }
        for entry in bucket where entry.bytes.elementsEqual(bytes) { return entry.value }
        return nil
    }

    @inline(__always)
    static func hash<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            h ^= UInt64(byte)
            h &*= 0x0000_0100_0000_01B3
        }
        return h
    }
}

/// The recognized tags of one way: each key's value as a byte range into the OPL line.
struct WayTags {
    static let keys = ByteKeyTable(StreetTagKey.allCases.map { ($0.osmKey, $0) })

    private var slots: [OPLTag?] = Array(repeating: nil, count: StreetTagKey.allCases.count)

    mutating func load(_ way: OPLWay) {
        for index in slots.indices { slots[index] = nil }
        for tag in way.tags {
            if let key = Self.keys.lookup(way.key(tag)) { slots[key.rawValue] = tag }
        }
    }

    func tag(_ key: StreetTagKey) -> OPLTag? {
        slots[key.rawValue]
    }

    func has(_ key: StreetTagKey) -> Bool {
        slots[key.rawValue] != nil
    }

    /// Whether the raw value of `key` equals `value` (values compared are plain ASCII).
    func value(_ key: StreetTagKey, in way: OPLWay, is value: String) -> Bool {
        guard let tag = slots[key.rawValue] else { return false }
        return way.value(tag).elementsEqual(value.utf8)
    }

    /// The value of `key` looked up in `table`; `nil` if absent or not in the table.
    func lookup<Value>(_ key: StreetTagKey, in way: OPLWay, _ table: ByteKeyTable<Value>) -> Value? {
        guard let tag = slots[key.rawValue] else { return nil }
        return table.lookup(way.value(tag))
    }

    func string(_ key: StreetTagKey, in way: OPLWay) -> String? {
        guard let tag = slots[key.rawValue] else { return nil }
        let value = way.decodedValue(tag)
        return value.isEmpty ? nil : value
    }
}
