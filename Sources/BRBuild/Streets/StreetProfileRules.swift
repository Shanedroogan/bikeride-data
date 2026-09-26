import BRStreetCore
import Foundation

/// The `highway=*` values the profiles route on. Every other value (motorway, construction,
/// proposed, platform, corridor, busway, raceway, …) is dropped.
enum HighwayType: Sendable {
    case trunk, trunkLink, primary, primaryLink, secondary, secondaryLink, tertiary, tertiaryLink
    case unclassified, residential, livingStreet, service, road
    case footway, path, cycleway, pedestrian, steps, track, bridleway

    static let table = ByteKeyTable<HighwayType>([
        ("trunk", .trunk), ("trunk_link", .trunkLink), ("primary", .primary), ("primary_link", .primaryLink),
        ("secondary", .secondary), ("secondary_link", .secondaryLink), ("tertiary", .tertiary),
        ("tertiary_link", .tertiaryLink), ("unclassified", .unclassified), ("residential", .residential),
        ("living_street", .livingStreet), ("service", .service), ("road", .road),
        ("footway", .footway), ("path", .path), ("cycleway", .cycleway), ("pedestrian", .pedestrian),
        ("steps", .steps), ("track", .track), ("bridleway", .bridleway),
    ])

    var isTrunk: Bool { self == .trunk || self == .trunkLink }

    /// Roads that carry traffic and get the arterial bike class when they have no bike lane.
    var isArterial: Bool {
        switch self {
        case .trunk, .trunkLink, .primary, .primaryLink, .secondary, .secondaryLink, .tertiary, .tertiaryLink: true
        default: false
        }
    }

    /// Off-street ways: paths, plazas and steps. These may get the park flag.
    var isPathLike: Bool {
        switch self {
        case .footway, .path, .cycleway, .pedestrian, .steps, .track, .bridleway: true
        default: false
        }
    }
}

/// An access tag value, reduced to what the profiles need.
enum AccessValue: Sendable {
    case allowed, denied, useSidepath, dismount

    static let table = ByteKeyTable<AccessValue>([
        ("yes", .allowed), ("designated", .allowed), ("permissive", .allowed), ("destination", .allowed),
        ("official", .allowed), ("customers", .allowed), ("delivery", .allowed), ("discouraged", .allowed),
        ("no", .denied), ("private", .denied), ("use_sidepath", .useSidepath), ("dismount", .dismount),
    ])
}

enum OnewayValue: Sendable {
    case forward, backward, twoWay, reversible

    static let table = ByteKeyTable<OnewayValue>([
        ("yes", .forward), ("true", .forward), ("1", .forward), ("-1", .backward), ("reverse", .backward),
        ("no", .twoWay), ("false", .twoWay), ("0", .twoWay), ("reversible", .reversible), ("alternating", .reversible),
    ])
}

/// A `cycleway*=*` value: the infrastructure it describes and whether it is a legacy
/// `opposite*` contraflow value.
struct CyclewayValue: Sendable {
    /// `nil` for `no`, `none` and unknown values.
    var bikeClass: BikeClass?
    var opposite: Bool

    static let table = ByteKeyTable<CyclewayValue>([
        ("track", .init(bikeClass: .protected, opposite: false)),
        ("separate", .init(bikeClass: .protected, opposite: false)),
        ("opposite_track", .init(bikeClass: .protected, opposite: true)),
        ("lane", .init(bikeClass: .painted, opposite: false)),
        ("share_busway", .init(bikeClass: .painted, opposite: false)),
        ("opposite_lane", .init(bikeClass: .painted, opposite: true)),
        ("opposite_share_busway", .init(bikeClass: .painted, opposite: true)),
        ("shared_lane", .init(bikeClass: .shared, opposite: false)),
        ("shoulder", .init(bikeClass: .shared, opposite: false)),
        ("opposite", .init(bikeClass: .shared, opposite: true)),
    ])
}

/// `footway=*` / `path=*` subtypes that are part of the sidewalk network.
enum SidewalkPart: Sendable {
    case sidewalk, crossing, trafficIsland, link, accessAisle

    static let table = ByteKeyTable<SidewalkPart>([
        ("sidewalk", .sidewalk), ("crossing", .crossing), ("traffic_island", .trafficIsland),
        ("link", .link), ("access_aisle", .accessAisle),
    ])
}

enum ServiceValue: Sendable {
    case driveway, parkingAisle, alley

    static let table = ByteKeyTable<ServiceValue>([
        ("driveway", .driveway), ("parking_aisle", .parkingAisle), ("alley", .alley), ("drive-through", .driveway),
    ])
}

/// A generic label for a way without `name`, `bridge:name` or `ref`.
enum DerivedLabel: UInt8, Sendable, CaseIterable {
    case road, serviceRoad, driveway, parkingAisle, alley
    case footpath, path, bikePath, steps, pedestrianStreet, plaza, track, bridlePath
    case parkPath, bridgePath, sidewalk

    var text: String {
        switch self {
        case .road: "road"
        case .serviceRoad: "service road"
        case .driveway: "driveway"
        case .parkingAisle: "parking aisle"
        case .alley: "alley"
        case .footpath: "footpath"
        case .path: "path"
        case .bikePath: "bike path"
        case .steps: "steps"
        case .pedestrianStreet: "pedestrian street"
        case .plaza: "plaza"
        case .track: "track"
        case .bridlePath: "bridle path"
        case .parkPath: "park path"
        case .bridgePath: "bridge path"
        case .sidewalk: "sidewalk"
        }
    }

    /// The label for a piece of this way that lies inside a park.
    var inPark: DerivedLabel {
        switch self {
        case .footpath, .path, .pedestrianStreet, .plaza, .track: .parkPath
        default: self
        }
    }
}

/// What the profiles allow on one way, oriented along the way's node order.
struct WayRule: Hashable, Sendable {
    var walk = false
    var bikeForward = false
    var bikeBackward = false
    var classForward = BikeClass.shared
    var classBackward = BikeClass.shared
    var stairs = false
    var bridge = false
    /// Off-street; gets ``EdgeFlags/park`` where it lies inside a park.
    var pathLike = false
    var connector = false
    var label = DerivedLabel.road

    var isUsable: Bool { walk || bikeForward || bikeBackward }
}

enum DropReason: String, CaseIterable, Sendable {
    case notRoutableHighway = "not_routable_highway"
    case motorroad
    case area
    case sidewalkNetwork = "sidewalk_or_crossing"
    case noAccess = "no_access"
    case outsideCity = "outside_city"
    case tooFewNodes = "too_few_nodes"
}

enum WayVerdict {
    case keep(WayRule)
    /// Dropped from routing, but walkable: kept aside to synthesize connectors.
    case sidewalkNetwork
    case drop(DropReason)
}

/// The walk and bike profiles, as tag rules. `docs/osm-derivation.md` states them in prose; keep
/// the two in sync.
enum StreetProfileRules {
    static func classify(_ tags: WayTags, _ way: OPLWay) -> WayVerdict {
        guard let highway = tags.lookup(.highway, in: way, HighwayType.table) else { return .drop(.notRoutableHighway) }
        if tags.value(.motorroad, in: way, is: "yes") { return .drop(.motorroad) }

        let footAccess = tags.lookup(.foot, in: way, AccessValue.table)
        let bicycleAccess = tags.lookup(.bicycle, in: way, AccessValue.table)
        let generalDenied = tags.lookup(.access, in: way, AccessValue.table) == .denied
        let vehicleDenied = tags.lookup(.vehicle, in: way, AccessValue.table) == .denied
        let bicycleExplicitlyAllowed = bicycleAccess == .allowed

        // Pedestrian areas are walked along their outline; any other area is not a street.
        let isArea = tags.value(.area, in: way, is: "yes")
        if isArea && highway != .pedestrian && highway != .footway { return .drop(.area) }

        // The sidewalk network: sidewalks, crossings and their links. Walking uses street
        // centerlines instead; bikes keep the pieces explicitly open to them.
        if highway == .footway || highway == .path || highway == .cycleway {
            let part = tags.lookup(.footway, in: way, SidewalkPart.table) ?? tags.lookup(.path, in: way, SidewalkPart.table)
            let unnamedCrossing = highway != .cycleway && tags.has(.crossing) && !tags.value(.crossing, in: way, is: "no")
            if part != nil || unnamedCrossing {
                if highway == .cycleway || (bicycleExplicitlyAllowed && !isArea) {
                    var rule = WayRule()
                    rule.bikeForward = true
                    rule.bikeBackward = true
                    rule.classForward = highway == .cycleway ? .protected : .shared
                    rule.classBackward = rule.classForward
                    rule.pathLike = true
                    rule.label = .bikePath
                    rule.bridge = isBridge(tags, way)
                    applyOneway(tags, way, highway: highway, rule: &rule)
                    return .keep(rule)
                }
                let walkable = footAccess != .denied && !(generalDenied && footAccess == nil)
                return walkable ? .sidewalkNetwork : .drop(.sidewalkNetwork)
            }
        }

        var rule = WayRule()
        rule.stairs = highway == .steps
        rule.bridge = isBridge(tags, way)
        rule.pathLike = highway.isPathLike
        rule.label = label(highway, tags, way, isArea: isArea)

        // Walking.
        var walk: Bool
        if highway.isTrunk {
            walk = !sidewalkNone(tags, way)
        } else {
            walk = true
        }
        switch footAccess {
        case .allowed?, .useSidepath?, .dismount?: walk = true
        case .denied?: walk = false
        case nil: if generalDenied { walk = false }
        }
        if highway.isTrunk, footAccess == .useSidepath { walk = !sidewalkNone(tags, way) }
        rule.walk = walk

        // Biking.
        var bike: Bool
        switch highway {
        case .steps: bike = false
        case .trunk, .trunkLink, .footway, .path, .pedestrian, .bridleway: bike = bicycleExplicitlyAllowed
        case .primary, .primaryLink, .secondary, .secondaryLink, .tertiary, .tertiaryLink, .unclassified,
             .residential, .livingStreet, .service, .road, .cycleway, .track:
            switch bicycleAccess {
            case .allowed?: bike = true
            case .denied?, .useSidepath?, .dismount?: bike = false
            case nil: bike = !(generalDenied || vehicleDenied)
            }
        }
        if isArea { bike = false }
        if highway == .steps { bike = false }
        rule.bikeForward = bike
        rule.bikeBackward = bike

        if bike {
            assignBikeClasses(highway, tags, way, rule: &rule)
            applyOneway(tags, way, highway: highway, rule: &rule)
        }
        guard rule.isUsable else { return .drop(.noAccess) }
        return .keep(rule)
    }

    /// The name to show: `name`, then `bridge:name` on a bridge, then `ref`; `nil` when a
    /// derived label should be used instead.
    static func name(_ tags: WayTags, _ way: OPLWay) -> (text: String, kind: StreetNameKind)? {
        if let name = tags.string(.name, in: way) { return (name, .tagged) }
        if isBridge(tags, way), let name = tags.string(.bridgeName, in: way) { return (name, .tagged) }
        if let ref = tags.string(.ref, in: way) {
            let parts = ref.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (parts.joined(separator: " / "), .ref)
        }
        return nil
    }

    private static func isBridge(_ tags: WayTags, _ way: OPLWay) -> Bool {
        tags.has(.bridge) && !tags.value(.bridge, in: way, is: "no")
    }

    /// `sidewalk=no|none`, `sidewalk:both=no|none`, or both sides `no|none`.
    private static func sidewalkNone(_ tags: WayTags, _ way: OPLWay) -> Bool {
        func none(_ key: StreetTagKey) -> Bool {
            tags.value(key, in: way, is: "no") || tags.value(key, in: way, is: "none")
        }
        return none(.sidewalk) || none(.sidewalkBoth) || (none(.sidewalkLeft) && none(.sidewalkRight))
    }

    private static func label(_ highway: HighwayType, _ tags: WayTags, _ way: OPLWay, isArea: Bool) -> DerivedLabel {
        switch highway {
        case .steps: return .steps
        case .cycleway: return .bikePath
        case .footway: return isArea ? .plaza : (isBridge(tags, way) ? .bridgePath : .footpath)
        case .path: return isBridge(tags, way) ? .bridgePath : .path
        case .pedestrian: return isArea ? .plaza : .pedestrianStreet
        case .track: return .track
        case .bridleway: return .bridlePath
        case .service:
            switch tags.lookup(.service, in: way, ServiceValue.table) {
            case .driveway?: return .driveway
            case .parkingAisle?: return .parkingAisle
            case .alley?: return .alley
            case nil: return .serviceRoad
            }
        default: return .road
        }
    }

    /// Per-direction bike class from the `cycleway*` tags. Right-hand traffic: without a
    /// one-way, a right-side lane serves the way's direction and a left-side lane the opposite.
    private static func assignBikeClasses(_ highway: HighwayType, _ tags: WayTags, _ way: OPLWay, rule: inout WayRule) {
        switch highway {
        case .cycleway:
            rule.classForward = .protected
            rule.classBackward = .protected
            return
        case .footway, .path, .track, .bridleway:
            rule.classForward = .protected // off-street path
            rule.classBackward = .protected
            return
        case .pedestrian, .livingStreet:
            rule.classForward = .shared
            rule.classBackward = .shared
            return
        default:
            break
        }
        let oneway = roadOneway(tags, way)
        let base: BikeClass = highway.isArterial ? .arterial : .shared
        var forward = base, backward = base

        func better(_ a: BikeClass, _ b: BikeClass) -> BikeClass { a.rawValue <= b.rawValue ? a : b }
        func apply(_ value: CyclewayValue, serves direction: OnewayValue) {
            guard let infra = value.bikeClass else { return }
            var direction = direction
            if value.opposite {
                // A legacy contraflow value: the lane runs against the one-way.
                direction = oneway == .backward ? .forward : .backward
            }
            switch direction {
            case .forward: forward = better(forward, infra)
            case .backward: backward = better(backward, infra)
            case .twoWay, .reversible:
                forward = better(forward, infra)
                backward = better(backward, infra)
            }
        }
        /// The direction a side's lane serves: its own `:oneway` tag, else the road's one-way,
        /// else right = forward and left = backward.
        func side(_ key: StreetTagKey, _ onewayKey: StreetTagKey, default fallback: OnewayValue) {
            guard let value = tags.lookup(key, in: way, CyclewayValue.table) else { return }
            let sideOneway = tags.lookup(onewayKey, in: way, OnewayValue.table)
            let direction = sideOneway ?? (oneway == .twoWay ? fallback : oneway)
            apply(value, serves: direction)
        }
        side(.cycleway, .cyclewayOneway, default: .twoWay)
        side(.cyclewayBoth, .cyclewayBothOneway, default: .twoWay)
        side(.cyclewayRight, .cyclewayRightOneway, default: .forward)
        side(.cyclewayLeft, .cyclewayLeftOneway, default: .backward)
        rule.classForward = forward
        rule.classBackward = backward
    }

    /// The way's one-way for traffic: `oneway`, else implied by a roundabout.
    private static func roadOneway(_ tags: WayTags, _ way: OPLWay) -> OnewayValue {
        if let oneway = tags.lookup(.oneway, in: way, OnewayValue.table) { return oneway }
        if tags.value(.junction, in: way, is: "roundabout") || tags.value(.junction, in: way, is: "circular") { return .forward }
        return .twoWay
    }

    /// Restricts bike directions by the one-way, unless bikes are exempt (`oneway:bicycle=no`)
    /// or a contraflow lane is tagged.
    private static func applyOneway(_ tags: WayTags, _ way: OPLWay, highway: HighwayType, rule: inout WayRule) {
        var direction = roadOneway(tags, way)
        if let bicycle = tags.lookup(.onewayBicycle, in: way, OnewayValue.table) {
            direction = bicycle
        } else if direction == .forward || direction == .backward, hasContraflow(tags, way, oneway: direction) {
            direction = .twoWay
        }
        switch direction {
        case .twoWay: break
        case .forward: rule.bikeBackward = false
        case .backward: rule.bikeForward = false
        case .reversible:
            rule.bikeForward = false
            rule.bikeBackward = false
        }
    }

    /// A lane that lets bikes ride against a one-way: an `opposite*` value, or a side whose
    /// `:oneway` is `-1` or `no` relative to a forward one-way (or `yes`/`no` for a reversed one).
    private static let cyclewaySides: [(StreetTagKey, StreetTagKey)] = [
        (.cycleway, .cyclewayOneway), (.cyclewayBoth, .cyclewayBothOneway),
        (.cyclewayLeft, .cyclewayLeftOneway), (.cyclewayRight, .cyclewayRightOneway),
    ]

    private static func hasContraflow(_ tags: WayTags, _ way: OPLWay, oneway: OnewayValue) -> Bool {
        for (key, onewayKey) in cyclewaySides {
            guard let value = tags.lookup(key, in: way, CyclewayValue.table), value.bikeClass != nil else { continue }
            if value.opposite { return true }
            switch tags.lookup(onewayKey, in: way, OnewayValue.table) {
            case .twoWay?: return true
            case .backward?: if oneway == .forward { return true }
            case .forward?: if oneway == .backward { return true }
            default: break
            }
        }
        return false
    }
}
