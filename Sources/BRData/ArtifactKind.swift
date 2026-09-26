import BRCore

/// The artifacts in a data set. Raw values are the `kind` codes stored in headers and must never
/// be reused.
public enum ArtifactKind: UInt16, CaseIterable, Sendable {
    case streets = 1
    case stations = 2
    case ttSubway = 3
    case ttBus = 4
    case ttLirr = 5
    case ttFerry = 6
    case links = 7
    case flows = 8
    case config = 9
    case ttPath = 10

    /// The name used in manifests, file names and `builtAgainst`.
    public var name: String {
        switch self {
        case .streets: "streets"
        case .stations: "stations"
        case .ttSubway: "tt-subway"
        case .ttBus: "tt-bus"
        case .ttLirr: "tt-lirr"
        case .ttFerry: "tt-ferry"
        case .ttPath: "tt-path"
        case .links: "links"
        case .flows: "flows"
        case .config: "config"
        }
    }

    public init?(name: String) {
        guard let kind = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = kind
    }

    public static func timetable(for system: TransitSystem) -> ArtifactKind {
        switch system {
        case .subway: .ttSubway
        case .bus: .ttBus
        case .lirr: .ttLirr
        case .ferry: .ttFerry
        case .path: .ttPath
        }
    }

    /// The payload format this build writes. `0` marks an unfrozen draft that may change without
    /// a version bump; from `1` on, `docs/formats.md` ("Compatibility") governs every change.
    public var currentFormatVersion: UInt16 {
        switch self {
        case .streets, .stations, .ttSubway, .ttBus, .ttLirr, .ttFerry, .ttPath:
            1 // Frozen 2026-09-26 (S1).
        case .links, .flows, .config:
            0 // TODO(M1): freeze at 1.
        }
    }

    /// The formatVersions this build's readers accept; they reject any other with their kind's
    /// `unsupportedFormatVersion` error. Always contains ``currentFormatVersion``. Listed per kind
    /// rather than derived from it: when a frozen kind moves to a new format, its readers keep
    /// accepting the old one while pinned sets can still hold it, and that is a deliberate entry
    /// here. A draft accepts only itself.
    public var supportedFormatVersions: [UInt16] {
        switch self {
        case .streets, .stations, .ttSubway, .ttBus, .ttLirr, .ttFerry, .ttPath:
            [1]
        case .links, .flows, .config:
            [0]
        }
    }
}
