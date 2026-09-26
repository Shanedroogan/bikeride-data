import BRCore
import Foundation

/// A scratch directory removed when the value is no longer needed.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("brdata-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Seeded bytes that compress moderately, like real artifact payloads.
func sampleBytes(count: Int, seed: UInt64) -> Data {
    var rng = SplitMix64(seed: seed)
    var bytes = [UInt8](repeating: 0, count: count)
    var index = 0
    while index < count {
        let value = rng.next()
        let run = Int(value & 0x7) + 1
        for _ in 0..<min(run, count - index) {
            bytes[index] = UInt8(truncatingIfNeeded: value >> 8)
            index += 1
        }
    }
    return Data(bytes)
}
