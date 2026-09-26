import BRData
import Foundation
import Testing

@Suite struct BinaryFormatTests {
    @Test func roundTripsEveryPrimitive() throws {
        var writer = BinaryWriter()
        writer.append(UInt8(0xAB))
        writer.append(UInt16(0xBEEF))
        writer.append(UInt32(0xDEAD_BEEF))
        writer.append(UInt64(0x0123_4567_89AB_CDEF))
        writer.append(Int32(-123_456))
        writer.append(Float(3.25))
        writer.append(Double.pi)
        writer.append(bytes: [1, 2, 3])
        writer.append(string: "Jay St–MetroTech 🚲")
        writer.append(string: "")

        var reader = BinaryReader(writer.data)
        #expect(try reader.read(UInt8.self) == 0xAB)
        #expect(try reader.read(UInt16.self) == 0xBEEF)
        #expect(try reader.read(UInt32.self) == 0xDEAD_BEEF)
        #expect(try reader.read(UInt64.self) == 0x0123_4567_89AB_CDEF)
        #expect(try reader.read(Int32.self) == -123_456)
        #expect(try reader.read(Float.self) == 3.25)
        #expect(try reader.read(Double.self) == .pi)
        #expect(try reader.readBytes(count: 3) == Data([1, 2, 3]))
        #expect(try reader.readString() == "Jay St–MetroTech 🚲")
        #expect(try reader.readString() == "")
        #expect(reader.isAtEnd)
    }

    @Test func writesLittleEndian() {
        var writer = BinaryWriter()
        writer.append(UInt32(0x0403_0201))
        writer.append(Int16(-2))
        writer.append(string: "hi")
        #expect(Array(writer.data) == [1, 2, 3, 4, 0xFE, 0xFF, 2, 0, 0, 0, 0x68, 0x69])
    }

    @Test func alignsTypedArraysToEightBytes() throws {
        var writer = BinaryWriter()
        writer.append(UInt8(7))
        writer.append(array: [UInt16(1), 2, 3])
        writer.append(array: [Int32(-1), 5])
        writer.append(array: [Double]())
        writer.append(array: [Float(1.5), 2.5])
        writer.append(array: [UInt64.max])
        #expect(writer.count % 8 == 0)

        var reader = BinaryReader(writer.data)
        #expect(try reader.read(UInt8.self) == 7)
        let u16 = try reader.readArray(of: UInt16.self)
        #expect(Array(u16) == [1, 2, 3])
        #expect(reader.offset == 8 + 8 + 6)
        #expect(try reader.readArray(of: Int32.self).toArray() == [-1, 5])
        #expect(try reader.readArray(of: Double.self).isEmpty)
        #expect(try reader.readArray(of: Float.self).toArray() == [1.5, 2.5])
        #expect(try reader.readArray(of: UInt64.self).toArray() == [.max])
        #expect(reader.isAtEnd)

        // The padding the writer inserted is exactly what the layout promises.
        #expect(Array(writer.data[1..<8]) == [0, 0, 0, 0, 0, 0, 0])
    }

    @Test func typedViewsAreZeroCopyOverAlignedStorage() throws {
        var writer = BinaryWriter()
        writer.append(array: (0..<1000).map { UInt32($0 * 3) })
        let data = writer.data
        var reader = BinaryReader(data)
        let view = try reader.readArray(of: UInt32.self)
        let sum = view.withUnsafeBufferPointer { buffer -> Int in
            let base = data.withUnsafeBytes { $0.baseAddress! }
            #expect(UnsafeRawPointer(buffer.baseAddress!) == base + 8)
            return buffer.reduce(0) { $0 + Int($1) }
        }
        #expect(sum == 3 * 999 * 1000 / 2)
        #expect(view[999] == 2997)
    }

    @Test func throwsInsteadOfReadingPastTheEnd() {
        var reader = BinaryReader(Data([1, 2, 3]))
        #expect(throws: DataFormatError.outOfBounds(offset: 0, needed: 4, available: 3)) { try reader.read(UInt32.self) }
        #expect(throws: DataFormatError.self) { try reader.readBytes(count: 4) }
        #expect(throws: DataFormatError.self) { try reader.skip(-1) }
        #expect(throws: DataFormatError.self) { try reader.seek(to: 4) }
        #expect(reader.offset == 0)

        var writer = BinaryWriter()
        writer.append(UInt32(100))
        writer.append(bytes: [0x61, 0x62])
        var truncatedString = BinaryReader(writer.data)
        #expect(throws: DataFormatError.outOfBounds(offset: 4, needed: 100, available: 2)) { try truncatedString.readString() }
    }

    @Test func rejectsImpossibleArrayCounts() {
        var huge = BinaryWriter()
        huge.append(UInt64.max)
        var overflow = BinaryReader(huge.data)
        #expect(throws: DataFormatError.countOverflow(offset: 0)) { try overflow.readArray(of: UInt32.self) }

        var tooMany = BinaryWriter()
        tooMany.append(UInt64(10))
        tooMany.append(UInt32(1))
        var short = BinaryReader(tooMany.data)
        #expect(throws: DataFormatError.outOfBounds(offset: 8, needed: 40, available: 4)) { try short.readArray(of: UInt32.self) }
    }

    @Test func rejectsNonZeroPaddingAndInvalidUTF8() {
        var padded = BinaryReader(Data([1, 0, 0, 9, 0, 0, 0, 0]))
        _ = try? padded.read(UInt8.self)
        #expect(throws: DataFormatError.nonZeroPadding(offset: 1)) { try padded.align(to: 8) }

        var writer = BinaryWriter()
        writer.append(UInt32(2))
        writer.append(bytes: [0xC3, 0x28])
        var invalid = BinaryReader(writer.data)
        #expect(throws: DataFormatError.invalidUTF8(offset: 4)) { try invalid.readString() }
    }

    @Test func readsSlicesWithNonZeroStartIndex() throws {
        var writer = BinaryWriter()
        writer.append(UInt64(0))
        writer.append(UInt32(42))
        let slice = writer.data[8...]
        var reader = BinaryReader(slice)
        #expect(try reader.read(UInt32.self) == 42)
    }

    @Test func overwritesInPlace() {
        var writer = BinaryWriter()
        writer.append(UInt32(0))
        writer.append(UInt8(9))
        writer.overwrite(UInt32(0xAABB_CCDD), at: 0)
        #expect(Array(writer.data) == [0xDD, 0xCC, 0xBB, 0xAA, 9])
    }
}
