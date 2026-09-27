import BRCore
import BRFlows
import Testing

@Suite struct HalfFloatTests {
    /// Values any IEEE binary16 implementation agrees on; checked on every host (no `Float16`).
    @Test func encodesKnownValues() {
        let cases: [(Double, UInt16)] = [
            (0, 0x0000), (-0.0, 0x8000), (1, 0x3C00), (0.5, 0x3800), (2, 0x4000), (-2, 0xC000),
            (0.1, 0x2E66), (1.0 / 3.0, 0x3555), (24.5, 0x4E20), (189, 0x59E8),
            (65_504, 0x7BFF), (65_519.99, 0x7BFF), (65_520, 0x7C00), (1e10, 0x7C00), (-1e10, 0xFC00),
            (.infinity, 0x7C00), (-.infinity, 0xFC00),
            (0x1p-14, 0x0400), (0x1p-24, 0x0001), (0x1p-25, 0x0000), (0x1.8p-25, 0x0001), (0x1.8p-24, 0x0002),
            (0x1p-26, 0x0000), (1e-300, 0x0000), (Double.leastNonzeroMagnitude, 0x0000),
            // Ties to even: 1 + 2^-11 lies halfway between 1 and 1 + 2^-10.
            (1 + 0x1p-11, 0x3C00), (1 + 3 * 0x1p-11, 0x3C02), (2048 + 1, 0x6800), (2048 + 3, 0x6802),
        ]
        for (value, bits) in cases {
            #expect(HalfFloat.bits(from: value) == bits, "\(value)")
        }
        #expect(HalfFloat.bits(from: .nan) & 0x7C00 == 0x7C00 && HalfFloat.bits(from: .nan) & 0x3FF != 0)
        #expect(HalfFloat.double(fromBits: 0x7BFF) == 65_504)
        #expect(HalfFloat.double(fromBits: 0x0001) == 0x1p-24)
        #expect(HalfFloat.double(fromBits: 0x03FF) == 1023 * 0x1p-24)
        #expect(HalfFloat.double(fromBits: 0x7C00) == .infinity && HalfFloat.double(fromBits: 0xFC00) == -.infinity)
        #expect(HalfFloat.double(fromBits: 0x7E00).isNaN && HalfFloat.float(fromBits: 0x7C01).isNaN)
        #expect(HalfFloat.double(fromBits: 0x8000).sign == .minus && HalfFloat.double(fromBits: 0x8000) == 0)
    }

    /// Every non-NaN pattern survives decode → encode; decoding to `Float` and to `Double` agree.
    @Test func everyPatternRoundTrips() {
        for raw in 0...0xFFFF {
            let bits = UInt16(raw)
            let value = HalfFloat.double(fromBits: bits)
            #expect(Double(HalfFloat.float(fromBits: bits)).bitPattern == value.bitPattern || value.isNaN)
            if value.isNaN { continue }
            #expect(HalfFloat.bits(from: value) == bits)
        }
    }

    @Test func nonNegativeBitPatternsOrderLikeValues() {
        var previous = -1.0
        for raw in 0..<0x7C00 {
            let value = HalfFloat.double(fromBits: UInt16(raw))
            #expect(value > previous)
            previous = value
            #expect(HalfFloat.isFiniteNonNegative(UInt16(raw)))
        }
        #expect(!HalfFloat.isFiniteNonNegative(0x7C00) && !HalfFloat.isFiniteNonNegative(0x7E00) && !HalfFloat.isFiniteNonNegative(0x8000))
    }

    #if !(os(macOS) && arch(x86_64))
    /// The bit decoder equals the platform's `Float16` for all 65,536 patterns.
    @Test func decoderMatchesFloat16ForEveryPattern() {
        for raw in 0...0xFFFF {
            let bits = UInt16(raw)
            let reference = Float(Float16(bitPattern: bits))
            let mine = HalfFloat.float(fromBits: bits)
            if reference.isNaN {
                #expect(mine.isNaN)
            } else {
                #expect(mine.bitPattern == reference.bitPattern, "0x\(String(raw, radix: 16))")
                #expect(HalfFloat.double(fromBits: bits) == Double(Float16(bitPattern: bits)))
            }
        }
    }

    /// The bit encoder equals `Float16(_: Double)` on every midpoint between neighboring halves
    /// (the ties), just either side of it, and on seeded values across the whole range.
    @Test func encoderMatchesFloat16() {
        for raw in 0..<0x7BFF {
            let low = HalfFloat.double(fromBits: UInt16(raw)), high = HalfFloat.double(fromBits: UInt16(raw + 1))
            let middle = (low + high) / 2 // exact in Double
            for value in [middle, middle.nextDown, middle.nextUp, -middle] {
                #expect(HalfFloat.bits(from: value) == Float16(value).bitPattern, "\(value)")
            }
        }
        var rng = SplitMix64(seed: 0x464C_4F57)
        for _ in 0..<200_000 {
            let exponent = Int(rng.next() % 48) - 30 // 2^-30 … 2^17: subnormals through overflow
            let fraction = Double(rng.next() >> 11) * 0x1p-53
            let value = (1 + fraction) * Double(sign: .plus, exponent: exponent, significand: 1)
            #expect(HalfFloat.bits(from: value) == Float16(value).bitPattern, "\(value)")
        }
    }
    #endif
}
