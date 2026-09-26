/// SplitMix64 (Steele, Lea & Flood 2014): a tiny seeded generator whose output is the same on
/// every platform and Swift version, for reproducible tests, fixtures and simulations.
/// Not cryptographically secure.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform double in `[0, 1)` built from the top 53 bits. Unlike `Double.random(in:using:)`,
    /// its mapping from raw output is fixed by this file.
    public mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// A uniform integer in `0..<bound` via multiply-shift. Negligibly biased for small bounds.
    public mutating func nextInt(below bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return Int(next().multipliedFullWidth(by: UInt64(bound)).high)
    }
}
