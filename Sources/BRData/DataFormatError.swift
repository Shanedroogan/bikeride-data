/// A malformed or incompatible artifact. Offsets are relative to the start of the buffer being read.
public enum DataFormatError: Error, Equatable, Sendable {
    case outOfBounds(offset: Int, needed: Int, available: Int)
    case countOverflow(offset: Int)
    case invalidUTF8(offset: Int)
    case nonZeroPadding(offset: Int)
    case badMagic
    case unsupportedHeaderLayout(UInt16)
    case unknownArtifactKind(UInt16)
    case invalidHeaderLength(UInt32)
    case payloadLengthMismatch(declared: UInt64, actual: Int)
    case duplicateKey(String)
    case kindMismatch(expected: ArtifactKind, found: ArtifactKind)
}
