import BRCore
import BRData
import Foundation

/// Serializes the `config` artifact (layout: "config" in `docs/formats.md`; reader:
/// ``MappedConfig``).
///
/// Payload: `CNFG`, the `u32` payload revision, the document as `array<u8>` of UTF-8 JSON, and an
/// empty extension tail. The JSON is canonical: `JSONEncoder` with sorted keys, unescaped
/// slashes and no whitespace, over a document whose set-like arrays are already sorted
/// (``ConfigValidation/canonicalIssues(_:)``). The wire types hold no floating point, `Set` or
/// non-String-keyed dictionary, so the bytes are the same on every platform and in every process.
public enum ConfigArtifactWriter {
    /// The canonical encoder.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The document's canonical JSON bytes.
    public static func json(_ document: ConfigDocument) throws -> Data {
        try encoder().encode(document)
    }

    /// The payload around already-encoded JSON bytes.
    public static func payload(json: Data) -> Data {
        var writer = BinaryWriter(reservingCapacity: json.count + 32)
        writer.append(bytes: ConfigFormat.payloadMagic)
        writer.append(ConfigFormat.payloadRevision)
        writer.append(array: [UInt8](json))
        writer.appendExtensions([])
        return writer.data
    }

    public static func payload(_ document: ConfigDocument) throws -> Data {
        payload(json: try json(document))
    }

    /// `config:` and the lowercase-hex SHA-256 of the JSON bytes, so equal documents get equal
    /// headers.
    public static func dataVersion(jsonSha256 hex: String) -> String {
        "config:\(hex)"
    }

    /// A complete artifact file. `config` is a root input: `builtAgainst` stays empty.
    public static func artifact(json: Data, dataVersion: String) -> Data {
        let header = ArtifactHeader(
            kind: .config, formatVersion: ArtifactKind.config.currentFormatVersion,
            dataVersion: dataVersion, builderSwiftVersion: BuildInfo.swiftVersion, builtAgainst: [:]
        )
        return header.assemble(payload: payload(json: json))
    }
}
