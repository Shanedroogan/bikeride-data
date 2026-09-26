/// A binary min-heap of (key, node) pairs packed into one `UInt64` (key in the high half), so
/// ordering is a single integer compare and equal keys pop in node order.
///
/// There is no decrease-key: searches push a new entry and skip stale ones when popped.
struct PackedMinHeap {
    private var storage: [UInt64] = []

    init(reservingCapacity capacity: Int = 0) {
        storage.reserveCapacity(capacity)
    }

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(key: UInt32, node: UInt32) {
        storage.append(UInt64(key) << 32 | UInt64(node))
        var child = storage.count - 1
        let value = storage[child]
        while child > 0 {
            let parent = (child - 1) / 2
            guard value < storage[parent] else { break }
            storage[child] = storage[parent]
            child = parent
        }
        storage[child] = value
    }

    mutating func pop() -> (key: UInt32, node: UInt32)? {
        guard let top = storage.first else { return nil }
        let last = storage.removeLast()
        if !storage.isEmpty {
            var parent = 0
            let count = storage.count
            while true {
                var child = 2 * parent + 1
                guard child < count else { break }
                if child + 1 < count && storage[child + 1] < storage[child] { child += 1 }
                guard storage[child] < last else { break }
                storage[parent] = storage[child]
                parent = child
            }
            storage[parent] = last
        }
        return (UInt32(truncatingIfNeeded: top >> 32), UInt32(truncatingIfNeeded: top))
    }
}
