import Foundation

/// The header at the start of every artifact file. Byte layout: `docs/formats.md`.
public struct ArtifactHeader: Equatable, Sendable {
    /// `BRDA`.
    public static let magic: [UInt8] = Array("BRDA".utf8)
    /// Version of the header layout itself, independent of any payload format.
    public static let layoutVersion: UInt16 = 1
    static let fixedSize = 24
    static let headerLengthOffset = 12

    public var kind: ArtifactKind
    public var formatVersion: UInt16
    /// Identifies the inputs the payload was built from, e.g. source ETags or a UTC build stamp.
    public var dataVersion: String
    public var builderSwiftVersion: String
    /// Artifact name → rawSha256 (lowercase hex) of each input artifact this one was built against.
    public var builtAgainst: [String: String]

    public init(
        kind: ArtifactKind,
        formatVersion: UInt16,
        dataVersion: String,
        builderSwiftVersion: String,
        builtAgainst: [String: String] = [:]
    ) {
        self.kind = kind
        self.formatVersion = formatVersion
        self.dataVersion = dataVersion
        self.builderSwiftVersion = builderSwiftVersion
        self.builtAgainst = builtAgainst
    }

    /// The header bytes for a payload of `payloadLength` bytes, padded to a multiple of 8.
    /// Deterministic: `builtAgainst` is written in key order, so equal headers give equal bytes.
    public func encoded(payloadLength: Int) -> Data {
        var writer = BinaryWriter()
        writer.append(bytes: Self.magic)
        writer.append(Self.layoutVersion)
        writer.append(kind.rawValue)
        writer.append(formatVersion)
        writer.append(UInt16(0)) // reserved
        writer.append(UInt32(0)) // header length, patched below
        writer.append(UInt64(payloadLength))
        writer.append(string: dataVersion)
        writer.append(string: builderSwiftVersion)
        writer.append(UInt32(builtAgainst.count))
        for (name, sha) in builtAgainst.sorted(by: { $0.key < $1.key }) {
            writer.append(string: name)
            writer.append(string: sha)
        }
        writer.pad(toMultipleOf: 8)
        writer.overwrite(UInt32(writer.count), at: Self.headerLengthOffset)
        return writer.data
    }

    /// A complete artifact file: this header followed by `payload`.
    public func assemble(payload: Data) -> Data {
        encoded(payloadLength: payload.count) + payload
    }

    /// Parses the header at the start of `file` and returns it with the payload that follows,
    /// as a slice sharing storage with `file`. The payload must fill the rest of `file` exactly.
    public static func decode(from file: Data) throws -> (header: ArtifactHeader, payload: Data) {
        var fixed = BinaryReader(file)
        guard try fixed.readBytes(count: magic.count).elementsEqual(magic) else { throw DataFormatError.badMagic }
        let layout = try fixed.read(UInt16.self)
        guard layout == layoutVersion else { throw DataFormatError.unsupportedHeaderLayout(layout) }
        let kindCode = try fixed.read(UInt16.self)
        guard let kind = ArtifactKind(rawValue: kindCode) else { throw DataFormatError.unknownArtifactKind(kindCode) }
        let formatVersion = try fixed.read(UInt16.self)
        _ = try fixed.read(UInt16.self) // reserved
        let headerLength = try fixed.read(UInt32.self)
        let payloadLength = try fixed.read(UInt64.self)

        guard headerLength >= fixedSize, headerLength % 8 == 0, Int(headerLength) <= file.count else {
            throw DataFormatError.invalidHeaderLength(headerLength)
        }
        guard payloadLength == UInt64(file.count - Int(headerLength)) else {
            throw DataFormatError.payloadLengthMismatch(declared: payloadLength, actual: file.count - Int(headerLength))
        }

        let headerEnd = file.startIndex + Int(headerLength)
        var fields = BinaryReader(file[file.startIndex..<headerEnd])
        try fields.seek(to: fixedSize)
        let dataVersion = try fields.readString()
        let builderSwiftVersion = try fields.readString()
        let entryCount = try fields.read(UInt32.self)
        var builtAgainst: [String: String] = [:]
        for _ in 0..<entryCount {
            let name = try fields.readString()
            let sha = try fields.readString()
            guard builtAgainst.updateValue(sha, forKey: name) == nil else { throw DataFormatError.duplicateKey(name) }
        }
        try fields.align(to: 8)
        guard fields.isAtEnd else { throw DataFormatError.invalidHeaderLength(headerLength) }

        let header = ArtifactHeader(
            kind: kind,
            formatVersion: formatVersion,
            dataVersion: dataVersion,
            builderSwiftVersion: builderSwiftVersion,
            builtAgainst: builtAgainst
        )
        return (header, file[headerEnd...])
    }
}
