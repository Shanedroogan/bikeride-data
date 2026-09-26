import Foundation

/// Builds an artifact payload. Layout rules are in `docs/formats.md`.
public struct BinaryWriter: Sendable {
    public private(set) var data = Data()

    public init(reservingCapacity capacity: Int = 0) {
        data.reserveCapacity(capacity)
    }

    public var count: Int { data.count }

    public mutating func append<T: BinaryScalar>(_ value: T) {
        withUnsafePointer(to: value) { data.append(UnsafeBufferPointer(start: $0, count: 1)) }
    }

    public mutating func append<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
        data.append(contentsOf: bytes)
    }

    /// A `UInt32` byte count followed by the UTF-8 bytes, with no terminator or padding.
    public mutating func append(string: String) {
        let utf8 = Array(string.utf8)
        append(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }

    /// Zero padding to 8-byte alignment, a `UInt64` element count, then the elements.
    /// Aligning the count keeps the elements 8-aligned, so readers can view them in place.
    public mutating func append<T: BinaryScalar>(array values: [T]) {
        pad(toMultipleOf: 8)
        append(UInt64(values.count))
        values.withUnsafeBufferPointer { data.append($0) }
    }

    public mutating func pad(toMultipleOf alignment: Int) {
        precondition(alignment > 0, "alignment must be positive")
        let remainder = data.count % alignment
        if remainder != 0 {
            data.append(contentsOf: repeatElement(0, count: alignment - remainder))
        }
    }

    /// Overwrites an already-written value, e.g. to back-patch a length or offset.
    public mutating func overwrite<T: BinaryScalar>(_ value: T, at offset: Int) {
        let size = MemoryLayout<T>.size
        precondition(offset >= 0 && offset + size <= data.count, "overwrite out of bounds")
        let start = data.startIndex + offset
        withUnsafeBytes(of: value) { data.replaceSubrange(start..<start + size, with: $0) }
    }
}
