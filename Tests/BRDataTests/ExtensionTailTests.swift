import BRData
import Foundation
import Testing

@Suite struct ExtensionTailTests {
    private func tail(_ entries: [(id: UInt32, bytes: [UInt8])], prefix: Int = 3) -> Data {
        var writer = BinaryWriter()
        writer.append(bytes: Array(repeating: 0xAA, count: prefix)) // a fixed payload before the tail
        writer.appendExtensions(entries)
        return writer.data
    }

    @Test func roundTripsSectionsByID() throws {
        let data = tail([(id: 2, bytes: [1, 2, 3]), (id: 7, bytes: []), (id: 40, bytes: Array(0..<20))])
        var reader = BinaryReader(data)
        try reader.skip(3)
        let table = try reader.readExtensions()
        #expect(table.ids == [2, 7, 40])
        #expect(table[2].map(Array.init) == [1, 2, 3])
        #expect(table[7].map(Array.init) == [])
        #expect(table[40].map(Array.init) == Array(0..<20))
        #expect(table[3] == nil)
        #expect(reader.isAtEnd)
    }

    @Test func anEmptyTailIsFourBytes() throws {
        let data = tail([], prefix: 0)
        #expect(data.count == 4)
        var reader = BinaryReader(data)
        #expect(try reader.readExtensions() == .empty)
    }

    /// Entry bytes start 8-aligned, so a reader over one can view arrays in place.
    @Test func entryBytesAreEightAlignedAndReadable() throws {
        var inner = BinaryWriter()
        inner.append(array: [UInt32(10), 20, 30])
        let data = tail([(id: 1, bytes: Array(inner.data))], prefix: 5)
        var reader = BinaryReader(data)
        try reader.skip(5)
        let section = try #require(try reader.readExtensions()[1])
        #expect((section.startIndex - data.startIndex) % 8 == 0)
        var sub = BinaryReader(section)
        #expect(try sub.readArray(of: UInt32.self).toArray() == [10, 20, 30])
    }

    @Test func rejectsIDsThatAreNotStrictlyAscending() {
        for ids: [UInt32] in [[5, 5], [9, 3]] {
            var writer = BinaryWriter()
            writer.append(UInt32(ids.count))
            for id in ids {
                writer.append(id)
                writer.append(array: [UInt8(1)])
            }
            var reader = BinaryReader(writer.data)
            #expect(throws: DataFormatError.self) { try reader.readExtensions() }
        }
    }

    @Test func rejectsBytesAfterTheTail() {
        var data = tail([(id: 1, bytes: [9])], prefix: 0)
        data.append(0)
        var reader = BinaryReader(data)
        #expect(throws: DataFormatError.trailingBytes(1)) { try reader.readExtensions() }
    }

    @Test func rejectsATruncatedTail() {
        let data = tail([(id: 1, bytes: [1, 2, 3, 4])], prefix: 0).dropLast(2)
        var reader = BinaryReader(Data(data))
        #expect(throws: DataFormatError.self) { try reader.readExtensions() }
    }
}
