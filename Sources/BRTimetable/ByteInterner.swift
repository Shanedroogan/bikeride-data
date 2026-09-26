/// Interns byte strings into dense `UInt32` ids, storing every string once in a single arena.
///
/// Used by the GTFS compiler for ids read from CSV (no `String` per field) and as the string pool
/// of a timetable payload. Hashing is FNV-1a with a fixed seed, so ids are assigned in insertion
/// order and identical inputs give identical output on every platform (unlike `Dictionary`,
/// whose iteration order is seeded per process).
public struct ByteInterner: Sendable {
    public private(set) var arena: [UInt8] = []
    /// `starts[id]..<starts[id + 1]` is string `id` in ``arena``.
    public private(set) var starts: [UInt32] = [0]
    private var slots: [Int32]
    private var hashes: [UInt32] = []
    private var mask: Int

    public init(capacity: Int = 16) {
        var size = 16
        while size < capacity * 2 { size <<= 1 }
        slots = [Int32](repeating: -1, count: size)
        mask = size - 1
    }

    public var count: Int { starts.count - 1 }

    /// The id of `bytes`, adding it if new.
    @discardableResult
    public mutating func intern(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        let hash = Self.hash(bytes)
        if let existing = find(bytes, hash: hash) { return existing }
        let id = UInt32(count)
        arena.append(contentsOf: bytes)
        precondition(arena.count <= Int(UInt32.max), "ByteInterner arena exceeds 4 GiB")
        starts.append(UInt32(arena.count))
        hashes.append(hash)
        if count * 2 > slots.count { grow() } else { insertSlot(id: id, hash: hash) }
        return id
    }

    @discardableResult
    public mutating func intern(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.withUnsafeBufferPointer { intern($0) }
    }

    @discardableResult
    public mutating func intern(_ string: String) -> UInt32 {
        var copy = string
        return copy.withUTF8 { intern($0) }
    }

    public func lookup(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
        find(bytes, hash: Self.hash(bytes))
    }

    public func lookup(_ bytes: ArraySlice<UInt8>) -> UInt32? {
        bytes.withUnsafeBufferPointer { lookup($0) }
    }

    public func lookup(_ string: String) -> UInt32? {
        var copy = string
        return copy.withUTF8 { lookup($0) }
    }

    public func bytes(_ id: UInt32) -> ArraySlice<UInt8> {
        arena[Int(starts[Int(id)])..<Int(starts[Int(id) + 1])]
    }

    public func string(_ id: UInt32) -> String {
        String(decoding: bytes(id), as: UTF8.self)
    }

    public func length(_ id: UInt32) -> Int {
        Int(starts[Int(id) + 1] - starts[Int(id)])
    }

    // MARK: - Table

    @inline(__always)
    static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return UInt32(truncatingIfNeeded: h ^ (h >> 32))
    }

    private func find(_ bytes: UnsafeBufferPointer<UInt8>, hash: UInt32) -> UInt32? {
        var slot = Int(hash) & mask
        return arena.withUnsafeBufferPointer { arena in
            while true {
                let id = slots[slot]
                if id < 0 { return nil }
                if hashes[Int(id)] == hash {
                    let start = Int(starts[Int(id)]), end = Int(starts[Int(id) + 1])
                    if end - start == bytes.count,
                       bytes.count == 0 || memoryEqual(arena.baseAddress! + start, bytes.baseAddress!, bytes.count)
                    {
                        return UInt32(id)
                    }
                }
                slot = (slot + 1) & mask
            }
        }
    }

    private mutating func insertSlot(id: UInt32, hash: UInt32) {
        var slot = Int(hash) & mask
        while slots[slot] >= 0 { slot = (slot + 1) & mask }
        slots[slot] = Int32(id)
    }

    private mutating func grow() {
        let size = slots.count * 2
        slots = [Int32](repeating: -1, count: size)
        mask = size - 1
        for id in 0..<count {
            insertSlot(id: UInt32(id), hash: hashes[id])
        }
    }
}

@inline(__always)
func memoryEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
    var index = 0
    while index + 8 <= count {
        let x = UnsafeRawPointer(a + index).loadUnaligned(as: UInt64.self)
        let y = UnsafeRawPointer(b + index).loadUnaligned(as: UInt64.self)
        if x != y { return false }
        index += 8
    }
    while index < count {
        if a[index] != b[index] { return false }
        index += 1
    }
    return true
}

/// Lexicographic byte order, as used by the sorted id indexes.
@inline(__always)
func compareBytes(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
    let n = min(a.count, b.count)
    var index = 0
    while index < n {
        let x = a[index], y = b[index]
        if x != y { return x < y ? -1 : 1 }
        index += 1
    }
    return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
}
