import BRCore

/// Constants shared by the `links` artifact writer (BRBuild `LinksArtifactWriter`) and reader
/// (``MappedLinks``). The byte layout is specified in `docs/formats.md`.
public enum LinksFormat {
    /// The first four payload bytes, `LNKS`.
    public static let payloadMagic: [UInt8] = Array("LNKS".utf8)
    /// The payload revision (`docs/formats.md`, "Compatibility"). While the artifact's
    /// formatVersion is still 0 it is bumped on every layout change, and readers reject any other
    /// value. Draft history: 2 added PATH as the fifth system (``systems``); 3 added the
    /// extension tail (with the rail bike hops as id ``hopsExtensionID``) and flag masking. The
    /// format-1 freeze sets it to 1.
    public static let payloadRevision: UInt32 = 3
    /// Extension-tail id of the rail bike-hop block (``LinkHops``). A reader that skips it has no
    /// hops, which is still correct; a revised hop layout takes a new id.
    public static let hopsExtensionID: UInt32 = 1
    /// The systems whose parent stations have bike hops: rail only (SIR rides in `tt-subway`).
    public static let hopSystems: [TransitSystem] = [.subway, .lirr, .path]
    /// "No station" in a `u16` station slot (an unused hop pickup or dock slot).
    public static let noStation: UInt16 = .max
    /// "No value" in a `u16` seconds field (e.g. a station link that cannot be walked in that
    /// direction).
    public static let noSeconds: UInt16 = .max
    /// The systems whose stops the global stop index spans, in index order. Global stop
    /// `base(system) + local` is stop `local` of that system's `tt-*` artifact.
    public static let systems: [TransitSystem] = [.subway, .bus, .lirr, .ferry, .path]
}

/// Per-stop bits in the `links` artifact (global stop index).
public struct LinkStopFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Some route pattern calls here, so RAPTOR can board or alight: footpaths and station
    /// links exist only between routable stops.
    public static let routable = LinkStopFlags(rawValue: 1 << 0)
    /// At least one access point lets riders in from the street.
    public static let streetEntry = LinkStopFlags(rawValue: 1 << 1)
    /// At least one access point lets riders out to the street.
    public static let streetExit = LinkStopFlags(rawValue: 1 << 2)

    /// The bits this reader defines; ``MappedLinks/stopFlags(_:)`` drops the rest (a later
    /// writer may define them as hints).
    public static let known: LinkStopFlags = [.routable, .streetEntry, .streetExit]
}

/// Per-access-point bits.
public struct LinkAccessPointFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Riders may enter the system here (street → platform).
    public static let entry = LinkAccessPointFlags(rawValue: 1 << 0)
    /// Riders may leave the system here (platform → street).
    public static let exit = LinkAccessPointFlags(rawValue: 1 << 1)
    /// No entrance is known for the station, so its own coordinate stands in for one.
    public static let synthetic = LinkAccessPointFlags(rawValue: 1 << 2)

    /// The bits this reader defines; ``MappedLinks/accessPoint(_:)`` drops the rest.
    public static let known: LinkAccessPointFlags = [.entry, .exit, .synthetic]
}

/// A malformed or incompatible `links` payload.
public enum LinksFormatError: Error, Equatable, Sendable {
    case badPayloadMagic
    case unsupportedPayloadRevision(UInt32)
    case unsupportedFormatVersion(UInt16)
    case countMismatch(section: String, expected: Int, actual: Int)
    case valueOutOfRange(section: String, index: Int)
    case notMonotonic(section: String, index: Int)
    case trailingBytes(Int)
    /// A structurally valid payload that breaks a documented invariant (`docs/formats.md`,
    /// "links", Invariants): `rule` names it, `index` is the first offending element.
    case invariantViolated(rule: String, index: Int)
}
