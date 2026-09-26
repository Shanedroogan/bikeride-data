import Foundation

/// One immutable data set: the mapped artifacts every engine component reads from.
///
/// ## Thread safety
/// `@unchecked Sendable` is sound because:
/// - every stored property is a `let`, fixed in `init` and never mutated;
/// - the artifact bytes are read-only file mappings; and
/// - a data set's files are never rewritten in place. Updates decode into a new
///   `data/v<setId>/` directory and the store swaps in a new handle, so bytes a handle has
///   mapped cannot change underneath concurrent readers.
///
/// Every stored property is also checkably `Sendable`. The conformance is unchecked because the
/// typed artifact views over a handle's mappings (`MappedStations`, `Timetable`, `MappedLinks`)
/// cache raw base pointers into them (`UnsafeRawPointer` is not `Sendable`); the reasoning above
/// is what makes sharing those views across isolation domains correct.
public final class DatasetHandle: @unchecked Sendable {
    public let setID: String
    public let artifacts: [ArtifactKind: MappedArtifact]

    public init(setID: String, artifacts: [ArtifactKind: MappedArtifact]) {
        self.setID = setID
        self.artifacts = artifacts
    }

    /// Maps each file, checking that its header kind matches its key.
    public convenience init(setID: String, files: [ArtifactKind: URL]) throws {
        var artifacts: [ArtifactKind: MappedArtifact] = [:]
        for (kind, url) in files {
            artifacts[kind] = try MappedArtifact(contentsOf: url, expecting: kind)
        }
        self.init(setID: setID, artifacts: artifacts)
    }

    public subscript(kind: ArtifactKind) -> MappedArtifact? {
        artifacts[kind]
    }

    public func require(_ kind: ArtifactKind) throws -> MappedArtifact {
        guard let artifact = artifacts[kind] else { throw DatasetError.missingArtifact(kind) }
        return artifact
    }
}

public enum DatasetError: Error, Equatable, Sendable {
    case missingArtifact(ArtifactKind)
}
