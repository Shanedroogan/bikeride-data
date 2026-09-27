import BRData
import Foundation

/// The `config` artifact, opened: header, payload checks, the decoded ``ConfigDocument``.
///
/// Opening checks, in order: the kind, the formatVersion, `CNFG`, the payload revision, the JSON
/// bytes, the extension tail (ids ascending, nothing after it), the JSON decode, then
/// ``ConfigValidation/structuralIssues(_:)``. The decode ignores keys it doesn't know at any
/// depth (a key added within the format is optional, with its default documented next to it),
/// reads `null` as absent, and rejects an unknown enum value, a missing required key or a value
/// of the wrong type. Opening costs well under a millisecond: the document is about 20 KB.
public struct MappedConfig: Sendable {
    /// The raw artifact's file name inside a data directory such as `build/data`.
    public static let fileName = "config.bin"

    public let header: ArtifactHeader
    /// The document's JSON bytes as stored.
    public let json: Data
    public let document: ConfigDocument
    /// The payload's extension tail. No config extension ids are defined; readers skip any.
    public let extensions: ExtensionTable

    /// Opens `config.bin` in a data directory, e.g. `build/data`.
    public static func load(fromDataDirectory directory: URL) throws -> MappedConfig {
        try MappedConfig(contentsOf: directory.appendingPathComponent(fileName))
    }

    public init(contentsOf url: URL) throws {
        try self.init(artifact: MappedArtifact(contentsOf: url, expecting: .config))
    }

    public init(fileBytes: Data) throws {
        try self.init(artifact: MappedArtifact(fileBytes: fileBytes, expecting: .config))
    }

    public init(artifact: MappedArtifact) throws {
        guard artifact.kind == .config else {
            throw DataFormatError.kindMismatch(expected: .config, found: artifact.kind)
        }
        guard ArtifactKind.config.supportedFormatVersions.contains(artifact.header.formatVersion) else {
            throw ConfigFormatError.unsupportedFormatVersion(artifact.header.formatVersion)
        }
        header = artifact.header
        var reader = artifact.payloadReader()
        guard try reader.readBytes(count: ConfigFormat.payloadMagic.count).elementsEqual(ConfigFormat.payloadMagic) else {
            throw ConfigFormatError.badPayloadMagic
        }
        let revision = try reader.read(UInt32.self)
        guard revision == ConfigFormat.payloadRevision else { throw ConfigFormatError.unsupportedPayloadRevision(revision) }
        let bytes = try reader.readArray(of: UInt8.self)
        // Copied out: the payload may be a mapping, and the document is small.
        json = Data(bytes.toArray())
        let tail = try reader.readExtensions()
        extensions = ExtensionTable(sections: tail.sections.mapValues { Data($0) })
        document = try Self.decode(json)
    }

    /// Decodes and validates document JSON (the reader's rules).
    public static func decode(_ json: Data) throws -> ConfigDocument {
        let document: ConfigDocument
        do {
            document = try JSONDecoder().decode(ConfigDocument.self, from: json)
        } catch let error as DecodingError {
            throw ConfigFormatError.undecodableDocument(Self.describe(error))
        } catch {
            throw ConfigFormatError.undecodableDocument("\(error)")
        }
        let issues = ConfigValidation.structuralIssues(document)
        guard issues.isEmpty else { throw ConfigFormatError.invalidDocument(issues) }
        return document
    }

    /// A one-line decoding error: the coding path, then what went wrong.
    public static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return "$" + keys
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context)): missing key '\(key.stringValue)'"
        case .typeMismatch(let type, let context):
            return "\(path(context)): expected \(type): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "\(path(context)): missing \(type) value"
        case .dataCorrupted(let context):
            let underlying = (context.underlyingError as? NSError).flatMap { $0.userInfo[NSDebugDescriptionErrorKey] as? String }
            return "\(path(context)): \(context.debugDescription)" + (underlying.map { " (\($0))" } ?? "")
        @unknown default:
            return "\(error)"
        }
    }
}
