// BRConfig: the `config` artifact (kind 9, draft format 0). Layout, JSON schema and
// compatibility rules: "config" in docs/formats.md.
//
// - ``ConfigDocument`` and the `Config*` types: the JSON document (wire types).
// - ``ConfigArtifactWriter``: canonical JSON, payload and artifact bytes.
// - ``MappedConfig``: the reader the app and the gate open.
// - ``ConfigValidation``: the intrinsic checks, shared by the reader and the compiler.
//
// The compiler, its reviewed sources and the cross-artifact reference checks live in BRBuild
// (`Sources/BRBuild/Config/`); the sources in `Data/config/` and `Data/fares/`.
import Foundation

/// Constants shared by the `config` writer (``ConfigArtifactWriter``) and reader
/// (``MappedConfig``).
public enum ConfigFormat {
    /// The first four payload bytes, `CNFG`.
    public static let payloadMagic: [UInt8] = Array("CNFG".utf8)
    /// The payload's `u32` revision slot. While the format is the draft 0 it counts draft
    /// layouts (1: magic, revision, JSON bytes, extension tail); readers reject any other value.
    /// It becomes `1` of format 1 at the freeze.
    public static let payloadRevision: UInt32 = 1
}

/// A malformed or incompatible `config` artifact.
public enum ConfigFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    case badPayloadMagic
    case unsupportedPayloadRevision(UInt32)
    case unsupportedFormatVersion(UInt16)
    /// The JSON bytes are not UTF-8 JSON of the document's shape: a required key is missing, a
    /// value has the wrong type or an enum value is unknown.
    case undecodableDocument(String)
    /// The document decodes but breaks an intrinsic rule (``ConfigValidation/structuralIssues(_:)``).
    case invalidDocument([String])

    public var description: String {
        switch self {
        case .badPayloadMagic: "config payload does not start with CNFG"
        case .unsupportedPayloadRevision(let revision): "config payload revision \(revision) is not supported"
        case .unsupportedFormatVersion(let version): "config format \(version) is not supported"
        case .undecodableDocument(let message): "config JSON does not decode: \(message)"
        case .invalidDocument(let issues): "config document is invalid: " + issues.joined(separator: "; ")
        }
    }
}
