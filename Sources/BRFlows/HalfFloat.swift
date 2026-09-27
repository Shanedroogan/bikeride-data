/// IEEE 754 binary16 ("half") values stored as their `UInt16` bit patterns, converted with integer
/// operations only.
///
/// `Float16` is unavailable on macOS x86_64, and a conversion that goes through the host's
/// floating-point unit is only as reproducible as that unit. These functions touch nothing but the
/// bits, so the `flows` builder writes identical cells on every host and every reader decodes them
/// identically. Encoding rounds to nearest, ties to even, exactly like a correctly rounded
/// `Float16(_: Double)`; decoding is exact.
public enum HalfFloat {
    public static let positiveInfinity: UInt16 = 0x7C00
    public static let quietNaN: UInt16 = 0x7E00
    /// The largest finite half, 65,504.
    public static let greatestFinite: UInt16 = 0x7BFF

    /// `value` rounded to the nearest half (ties to even). Values of magnitude 65,520 or more
    /// become infinity; NaN stays NaN; the sign is kept, including on zero.
    public static func bits(from value: Double) -> UInt16 {
        let raw = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: raw >> 48) & 0x8000
        let exponentField = Int((raw >> 52) & 0x7FF)
        let fraction = raw & 0x000F_FFFF_FFFF_FFFF
        if exponentField == 0x7FF {
            return sign | (fraction == 0 ? positiveInfinity : quietNaN)
        }
        if exponentField == 0 {
            return sign // zero, or a double subnormal (below 1e-307): rounds to zero
        }
        let exponent = exponentField - 1023
        if exponent > 15 {
            return sign | positiveInfinity
        }
        let significand = fraction | (1 << 52) // 53 bits, value = significand × 2^(exponent − 52)
        if exponent >= -14 {
            // Normal half: keep 10 fraction bits, round the 42 dropped ones. A carry out of the
            // fraction moves into the exponent field, which is exactly the next binade (and past
            // 65,504 it reaches 0x7C00, infinity).
            let kept = UInt16(truncatingIfNeeded: (significand >> 42) & 0x3FF)
            let result = UInt16((exponent + 15) << 10) | kept
            return sign | rounded(result, remainder: significand & ((1 << 42) - 1), shift: 42)
        }
        // Subnormal half: value / 2^−24 = significand × 2^(exponent − 28).
        let shift = 28 - exponent // ≥ 43
        guard shift < 64 else { return sign }
        let kept = UInt16(truncatingIfNeeded: significand >> UInt64(shift))
        return sign | rounded(kept, remainder: significand & ((1 << UInt64(shift)) - 1), shift: shift)
    }

    /// Round-to-nearest-even of `result` given the `shift` bits dropped below it.
    @inline(__always)
    private static func rounded(_ result: UInt16, remainder: UInt64, shift: Int) -> UInt16 {
        let half: UInt64 = 1 << UInt64(shift - 1)
        if remainder > half || (remainder == half && result & 1 == 1) {
            return result + 1
        }
        return result
    }

    /// The exact value of a half, as a `Double`.
    public static func double(fromBits bits: UInt16) -> Double {
        let sign = UInt64(bits & 0x8000) << 48
        let exponentField = Int((bits >> 10) & 0x1F)
        var fraction = UInt64(bits & 0x3FF)
        if exponentField == 0x1F {
            return Double(bitPattern: sign | 0x7FF0_0000_0000_0000 | (fraction << 42) | (fraction == 0 ? 0 : 1 << 51))
        }
        var exponent: Int
        if exponentField == 0 {
            if fraction == 0 { return Double(bitPattern: sign) }
            // Subnormal: normalize so the leading one becomes the implicit bit.
            exponent = -14
            while fraction & 0x400 == 0 {
                fraction <<= 1
                exponent -= 1
            }
            fraction &= 0x3FF
        } else {
            exponent = exponentField - 15
        }
        return Double(bitPattern: sign | (UInt64(exponent + 1023) << 52) | (fraction << 42))
    }

    /// The exact value of a half, as a `Float` (every half is a float).
    public static func float(fromBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponentField = Int((bits >> 10) & 0x1F)
        var fraction = UInt32(bits & 0x3FF)
        if exponentField == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (fraction << 13) | (fraction == 0 ? 0 : 1 << 22))
        }
        var exponent: Int
        if exponentField == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            exponent = -14
            while fraction & 0x400 == 0 {
                fraction <<= 1
                exponent -= 1
            }
            fraction &= 0x3FF
        } else {
            exponent = exponentField - 15
        }
        return Float(bitPattern: sign | (UInt32(exponent + 127) << 23) | (fraction << 13))
    }

    /// Finite and not negative (sign bit clear, so `-0` is rejected too).
    @inline(__always)
    public static func isFiniteNonNegative(_ bits: UInt16) -> Bool {
        bits & 0x8000 == 0 && bits & 0x7C00 != 0x7C00
    }

    /// The next half above a finite non-negative half (`bits + 1`: for non-negative halves the
    /// bit patterns are ordered like the values).
    @inline(__always)
    public static func nextUp(_ bits: UInt16) -> UInt16 {
        bits + 1
    }
}
