import Foundation

/// The optional sections at the end of a fixed-layout payload (streets, stations): how a frozen
/// format gains fields without a formatVersion bump. Layout, after the payload's last fixed array:
///
///     u32 count
///     count × { u32 id, array<u8> bytes }    // ids strictly ascending
///
/// and nothing after it. Readers skip ids they don't know; each kind's section in
/// `docs/formats.md` lists its ids and what a reader assumes when one is absent. The bytes of
/// each entry start 8-aligned (``BinaryWriter/append(array:)``), so a reader over them can view
/// arrays in place.
public struct ExtensionTable: Sendable, Equatable {
    /// Sections by id, as slices of the payload.
    public let sections: [UInt32: Data]

    public init(sections: [UInt32: Data] = [:]) {
        self.sections = sections
    }

    public static let empty = ExtensionTable()

    public var ids: [UInt32] { sections.keys.sorted() }

    public subscript(id: UInt32) -> Data? { sections[id] }
}

extension BinaryWriter {
    /// Writes the extension tail; pass `[]` for a payload with no extensions. Ids must be
    /// strictly ascending.
    public mutating func appendExtensions(_ entries: [(id: UInt32, bytes: [UInt8])]) {
        precondition(zip(entries, entries.dropFirst()).allSatisfy { $0.id < $1.id }, "extension ids must be strictly ascending")
        append(UInt32(entries.count))
        for entry in entries {
            append(entry.id)
            append(array: entry.bytes)
        }
    }
}

extension BinaryReader {
    /// Reads the extension tail written by ``BinaryWriter/appendExtensions(_:)`` and requires
    /// that nothing follows it.
    public mutating func readExtensions() throws -> ExtensionTable {
        let count = Int(try read(UInt32.self))
        var sections: [UInt32: Data] = [:]
        var previous: UInt32?
        for _ in 0..<count {
            let idOffset = offset
            let id = try read(UInt32.self)
            if let previous, id <= previous { throw DataFormatError.extensionIDsNotAscending(offset: idOffset) }
            previous = id
            let bytes = try readArray(of: UInt8.self)
            let start = data.startIndex + offset - bytes.count
            sections[id] = data[start..<start + bytes.count]
        }
        guard isAtEnd else { throw DataFormatError.trailingBytes(remaining) }
        return ExtensionTable(sections: sections)
    }
}
