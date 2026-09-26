import Foundation

/// A bounds-checked cursor over artifact bytes. Every read that would pass the end throws
/// ``DataFormatError`` instead of trapping.
///
/// Offsets and alignment are relative to the start of `data`, which callers keep 8-aligned in
/// memory (file mappings are page-aligned and artifact headers are padded to 8 bytes).
public struct BinaryReader: Sendable {
    public let data: Data
    public private(set) var offset = 0

    public init(_ data: Data) {
        self.data = data
    }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { offset == data.count }

    public mutating func read<T: BinaryScalar>(_ type: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        try require(size)
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return value
    }

    /// The next `count` bytes, as a slice sharing storage with ``data``.
    public mutating func readBytes(count: Int) throws -> Data {
        try require(count)
        let start = data.startIndex + offset
        offset += count
        return data[start..<start + count]
    }

    /// Reads the form written by ``BinaryWriter/append(string:)``.
    public mutating func readString() throws -> String {
        let length = Int(try read(UInt32.self))
        let start = offset
        let bytes = try readBytes(count: length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw DataFormatError.invalidUTF8(offset: start)
        }
        return string
    }

    /// Reads the form written by ``BinaryWriter/append(array:)`` without copying the elements.
    public mutating func readArray<T: BinaryScalar>(of type: T.Type = T.self) throws -> TypedArrayView<T> {
        try align(to: 8)
        let countOffset = offset
        let count = try read(UInt64.self)
        let stride = MemoryLayout<T>.stride
        guard count <= UInt64(Int.max / stride) else { throw DataFormatError.countOverflow(offset: countOffset) }
        let byteCount = Int(count) * stride
        try require(byteCount)
        let view = TypedArrayView<T>(storage: data, byteOffset: offset, count: Int(count))
        offset += byteCount
        return view
    }

    /// Skips zero padding up to the next multiple of `alignment`.
    public mutating func align(to alignment: Int) throws {
        precondition(alignment > 0, "alignment must be positive")
        let padding = (alignment - offset % alignment) % alignment
        let start = offset
        let bytes = try readBytes(count: padding)
        if bytes.contains(where: { $0 != 0 }) { throw DataFormatError.nonZeroPadding(offset: start) }
    }

    public mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw DataFormatError.outOfBounds(offset: newOffset, needed: 0, available: data.count)
        }
        offset = newOffset
    }

    private func require(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw DataFormatError.outOfBounds(offset: offset, needed: count, available: remaining)
        }
    }
}

/// A read-only array of scalars stored in artifact bytes. Holds no pointer; the bytes stay
/// alive because the view shares the artifact's `Data` storage.
public struct TypedArrayView<Element: BinaryScalar>: RandomAccessCollection, Sendable {
    private let storage: Data
    private let byteOffset: Int
    public let count: Int

    init(storage: Data, byteOffset: Int, count: Int) {
        self.storage = storage
        self.byteOffset = byteOffset
        self.count = count
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    /// Bounds-checked element access. Hot loops should use ``withUnsafeBufferPointer(_:)``.
    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "TypedArrayView index out of range")
        return storage.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: byteOffset + index * MemoryLayout<Element>.stride, as: Element.self)
        }
    }

    /// Calls `body` with the elements in place. The pointer must not escape `body`.
    ///
    /// Zero-copy whenever the bytes are aligned for `Element`, which holds for mapped artifacts.
    /// Storage that is not (e.g. a tiny inline `Data`) is copied to an aligned buffer first.
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        guard count > 0 else { return try body(UnsafeBufferPointer(start: nil, count: 0)) }
        let stride = MemoryLayout<Element>.stride
        return try storage.withUnsafeBytes { raw in
            let bytes = UnsafeRawBufferPointer(rebasing: raw[byteOffset..<byteOffset + count * stride])
            if Int(bitPattern: bytes.baseAddress) % MemoryLayout<Element>.alignment == 0 {
                return try bytes.withMemoryRebound(to: Element.self, body)
            }
            let copy = (0..<count).map { bytes.loadUnaligned(fromByteOffset: $0 * stride, as: Element.self) }
            return try copy.withUnsafeBufferPointer(body)
        }
    }

    public func toArray() -> [Element] {
        withUnsafeBufferPointer { Array($0) }
    }
}
