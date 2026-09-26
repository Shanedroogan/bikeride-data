import BRCore

/// Constants shared by the `links` artifact writer (BRBuild `LinksArtifactWriter`) and reader
/// (``MappedLinks``). The byte layout is specified in `docs/formats.md`.
public enum LinksFormat {
    /// The first four payload bytes, `LNKS`.
    public static let payloadMagic: [UInt8] = Array("LNKS".utf8)
    /// Revision of the draft payload layout, bumped on every change while the artifact's
    /// formatVersion is still 0. Readers reject any other revision.
    public static let draftRevision: UInt32 = 1
    /// "No value" in a `u16` seconds field (e.g. a station link that cannot be walked in that
    /// direction).
    public static let noSeconds: UInt16 = .max
    /// The systems whose stops the global stop index spans, in index order. Global stop
    /// `base(system) + local` is stop `local` of that system's `tt-*` artifact.
    public static let systems: [TransitSystem] = [.subway, .bus, .lirr, .ferry]
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

    static let known: LinkStopFlags = [.routable, .streetEntry, .streetExit]
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

    static let known: LinkAccessPointFlags = [.entry, .exit, .synthetic]
}

/// A malformed or incompatible `links` payload.
public enum LinksFormatError: Error, Equatable, Sendable {
    case badPayloadMagic
    case unsupportedDraftRevision(UInt32)
    case unsupportedFormatVersion(UInt16)
    case countMismatch(section: String, expected: Int, actual: Int)
    case valueOutOfRange(section: String, index: Int)
    case notMonotonic(section: String, index: Int)
    case trailingBytes(Int)
}
