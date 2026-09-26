import Foundation

/// Runs many independent searches across cores, each worker with its own scratch memory.
///
/// `DispatchQueue.concurrentPerform` starts `threads` workers. Each builds one scratch value and
/// pulls item indices from a shared counter in small chunks until none are left, so slow items
/// (dense Manhattan searches) and fast ones balance out. Results must be written to disjoint
/// places (e.g. one matrix row per item) or collected per worker.
enum ParallelWork {
    /// `makeScratch` and `body` run on worker threads. They are real `@Sendable` escaping
    /// closures (heap contexts with atomic reference counts); state that holds raw pointers is
    /// passed in through ``UncheckedSendable`` by callers that keep it race-free (read-only inputs,
    /// disjoint outputs). Never hand workers a non-escaping closure through
    /// `withoutActuallyEscaping`: its context may live on the stack with non-atomic reference
    /// counts, which concurrent copies corrupt.
    static func run<Scratch>(
        items: Int,
        threads: Int,
        chunk: Int = 8,
        makeScratch: @escaping @Sendable () -> Scratch,
        body: @escaping @Sendable (_ item: Int, _ scratch: Scratch) -> Void
    ) {
        guard items > 0 else { return }
        let workers = max(1, min(threads, items))
        let counter = WorkCounter(total: items, chunk: max(1, chunk))
        if workers == 1 {
            let scratch = makeScratch()
            while let range = counter.next() { for item in range { body(item, scratch) } }
            return
        }
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let scratch = makeScratch()
            while let range = counter.next() { for item in range { body(item, scratch) } }
        }
    }
}

/// Carries a value into a `@Sendable` closure; the caller vouches for thread safety.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Hands out consecutive item ranges under a lock.
final class WorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var next_ = 0
    private let total: Int
    private let chunk: Int

    init(total: Int, chunk: Int) {
        self.total = total
        self.chunk = chunk
    }

    func next() -> Range<Int>? {
        lock.lock()
        defer { lock.unlock() }
        guard next_ < total else { return nil }
        let start = next_
        next_ = min(total, start + chunk)
        return start..<next_
    }
}

/// Collects values from concurrent workers under a lock.
final class LockedCollector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func drain() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        let result = values
        values = []
        return result
    }
}

/// A fixed-size buffer that workers fill at disjoint indices.
///
/// `@unchecked Sendable`: callers guarantee every index is written by at most one worker and read
/// only after the parallel section returns.
final class SharedBuffer<Element>: @unchecked Sendable {
    let pointer: UnsafeMutableBufferPointer<Element>

    init(count: Int, repeating value: Element) {
        pointer = .allocate(capacity: count)
        pointer.initialize(repeating: value)
    }

    deinit {
        pointer.deinitialize()
        pointer.deallocate()
    }

    func toArray() -> [Element] { Array(pointer) }
}
