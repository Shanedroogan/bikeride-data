import Foundation

/// An artifact file mapped into memory, with its header parsed and its payload exposed in place.
public struct MappedArtifact: Sendable {
    public let header: ArtifactHeader
    /// The bytes after the header. A slice of the mapping: indices do not start at zero, so read
    /// it through ``payloadReader()``.
    public let payload: Data

    /// Maps the file at `url`. Throws if it is not an artifact, or not of kind `expected`.
    public init(contentsOf url: URL, expecting expected: ArtifactKind? = nil) throws {
        try self.init(fileBytes: Data(contentsOf: url, options: .alwaysMapped), expecting: expected)
    }

    /// Parses artifact bytes already in memory.
    public init(fileBytes: Data, expecting expected: ArtifactKind? = nil) throws {
        (header, payload) = try ArtifactHeader.decode(from: fileBytes)
        if let expected, header.kind != expected {
            throw DataFormatError.kindMismatch(expected: expected, found: header.kind)
        }
    }

    public var kind: ArtifactKind { header.kind }

    public func payloadReader() -> BinaryReader {
        BinaryReader(payload)
    }
}
