import Foundation

// Locale-independent, bit-exact decimal float parser. Direct port of
// `ufbxi_parse_double` / `ufbxi_parse_inf_nan` / `ufbxi_parse_int64`
// (ufbx.c:1349-1846). Produces correctly-rounded (round-half-to-even) IEEE-754
// results identical to ufbx on every input, including the MSVC legacy
// `1.#INF`/`1.#IND`/`1.#NAN` spellings that real ASCII FBX exporters emit.
//
// Internal API (used by the ASCII tokenizer):
//   FloatParse.parseDouble(bytes:maxLength:flags:) -> (value, consumed)
//   FloatParse.parseDouble(_ slice:flags:)         -> (value, consumed)
//   FloatParse.parseInt64(_ slice:)                -> (value, consumed)?  (nil = no digits/overrun)
// `consumed` is the number of bytes consumed (0 if no numeric prefix); mirrors
// ufbx's `end - str`. For the `.asBinary32` (ACCURATE_F32) variant the returned
// Double equals a representable Float exactly, so `Float(value)` is lossless.

enum FloatParse {

    struct Flags: OptionSet {
        let rawValue: UInt32
        static let allowFastPath = Flags(rawValue: 0x1)
        static let asBinary32    = Flags(rawValue: 0x2)
    }

    // MARK: Tables

    // ufbx: 5^0 .. 5^27 (largest power of 5 that fits in 64 bits with headroom).
    private static let pow5Tab: [UInt64] = [
        0x1, 0x5, 0x19, 0x7d, 0x271, 0xc35, 0x3d09, 0x1312d, 0x5f5e1,
        0x1dcd65, 0x9502f9, 0x2e90edd, 0xe8d4a51, 0x48c27395, 0x16bcc41e9, 0x71afd498d,
        0x2386f26fc1, 0xb1a2bc2ec5, 0x3782dace9d9, 0x1158e460913d, 0x56bc75e2d631, 0x1b1ae4d6e2ef5,
        0x878678326eac9, 0x2a5a058fc295ed, 0xd3c21bcecceda1, 0x422ca8b0a00a425, 0x14adf4b7320334b9, 0x6765c793fa10079d,
    ]

    // ufbx: 1e0 .. 1e22, the exactly-representable powers of ten (fast path).
    private static let pow10Tab: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
        1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    // MARK: Bigint (fixed-capacity, little-limb-endian; port of ufbxi_bigint)

    private struct BigInt {
        var limbs: [UInt32]
        var length: Int
        init(capacity: Int) {
            limbs = [UInt32](repeating: 0, count: capacity)
            length = 0
        }
    }

    private static func bigintMad(_ b: inout BigInt, _ multiplicand: UInt64, _ addend: UInt64) {
        let mLo = multiplicand & 0xFFFFFFFF
        let mHi = multiplicand >> 32
        var carry = addend
        var i = 0
        while i < b.length {
            let limb = UInt64(b.limbs[i])
            let lo = limb &* mLo &+ (carry & 0xFFFFFFFF)
            let hi = limb &* mHi
            b.limbs[i] = UInt32(truncatingIfNeeded: lo)
            carry = (carry >> 32) &+ (lo >> 32) &+ hi
            i += 1
        }
        while carry != 0 {
            b.limbs[b.length] = UInt32(truncatingIfNeeded: carry)
            b.length += 1
            carry >>= 32
        }
    }

    private static func bigintMulPow5(_ b: inout BigInt, _ power: UInt32) {
        var p = power
        while p > 27 { bigintMad(&b, pow5Tab[27], 0); p -= 27 }
        bigintMad(&b, pow5Tab[Int(p)], 0)
    }

    private static func bigintShiftLeft(_ b: inout BigInt, _ amount: UInt32) {
        let words = Int(amount / 32)
        let bits = amount % 32
        let oldLength = b.length
        let bitsDown = UInt32(31) &- bits // == 32 - bits - 1
        let topCarry = (((b.limbs[oldLength - 1] >> 1) >> bitsDown) != 0) ? 1 : 0
        b.length = oldLength + words + topCarry
        b.limbs[oldLength] = 0
        var i = oldLength
        while i >= 1 {
            b.limbs[i + words] = (b.limbs[i] << bits) | ((b.limbs[i - 1] >> 1) >> bitsDown)
            i -= 1
        }
        b.limbs[words] = b.limbs[0] << bits
        var k = 0
        while k < words { b.limbs[k] = 0; k += 1 }
    }

    // Knuth Algorithm D long division. Returns true if the remainder is nonzero.
    private static func bigintDiv(_ q: inout BigInt, _ u: inout BigInt, _ v: inout BigInt) -> Bool {
        let n = v.length
        let m = u.length - n
        let vHi = UInt64(v.limbs[v.length - 1])
        u.limbs[n + m] = 0
        q.length = 0
        var j = m - 1
        while j >= 0 {
            let uHi = (UInt64(u.limbs[n + j]) << 32) | UInt64(u.limbs[n + j - 1])
            var qhat = uHi / vHi
            var rhat = uHi % vHi
            while (qhat >> 32) != 0 || qhat &* UInt64(v.limbs[n - 2]) > ((rhat << 32) | UInt64(u.limbs[j + n - 2])) {
                qhat -= 1
                rhat += vHi
                if (rhat >> 32) != 0 { break }
            }
            var carry: UInt32 = 0
            var i = 0
            while i < n {
                let p = qhat &* UInt64(v.limbs[i])
                let t = UInt64(u.limbs[i + j]) &- UInt64(carry) &- UInt64(UInt32(truncatingIfNeeded: p))
                u.limbs[i + j] = UInt32(truncatingIfNeeded: t)
                carry = UInt32(truncatingIfNeeded: (p >> 32) &- (t >> 32))
                i += 1
            }
            let t2 = UInt64(u.limbs[j + n]) &- UInt64(carry)
            u.limbs[j + n] = UInt32(truncatingIfNeeded: t2)
            if (t2 >> 32) != 0 {
                qhat -= 1
                var carry2: UInt64 = 0
                var i2 = 0
                while i2 < n {
                    let t = UInt64(u.limbs[i2 + j]) &+ UInt64(v.limbs[i2]) &+ carry2
                    u.limbs[i2 + j] = UInt32(truncatingIfNeeded: t)
                    carry2 = t >> 32
                    i2 += 1
                }
                u.limbs[j + n] = u.limbs[j + n] &+ UInt32(truncatingIfNeeded: carry2)
            }
            q.limbs[j] = UInt32(truncatingIfNeeded: qhat)
            if qhat != 0 && q.length == 0 {
                q.length = j + 1
            }
            j -= 1
        }
        var i = 0
        while i < n {
            if u.limbs[i] != 0 { return true }
            i += 1
        }
        return false
    }

    private static func bigintTopLimb(_ b: BigInt, _ index: Int) -> UInt32 {
        return index < b.length ? b.limbs[b.length - 1 - index] : 0
    }

    private static func bigintExtractHigh(_ b: BigInt, _ exponent: inout Int32, _ tail: inout Bool) -> UInt64 {
        var result: UInt64 = 0
        let limbCount = 2 // 64 / 32
        for i in 0..<limbCount {
            result = (result << 32) | UInt64(bigintTopLimb(b, i))
        }
        let shift = UInt32(result.leadingZeroBitCount)
        result <<= shift
        let lo = bigintTopLimb(b, limbCount)
        if shift > 0 {
            result |= UInt64(lo) >> (32 - shift)
        }
        tail = tail || UInt32(truncatingIfNeeded: UInt64(lo) << UInt64(shift & 63)) != 0
        var i = limbCount + 1
        while i < b.length {
            tail = tail || bigintTopLimb(b, i) != 0
            i += 1
        }
        exponent += Int32(b.length * 32 - Int(shift) - 1)
        return result
    }

    private static func shiftRightRound(_ value: UInt64, _ shift: UInt32, _ tail: Bool) -> UInt64 {
        if shift == 0 { return value }
        if shift > 64 { return 0 }
        let result = value >> (shift - 1)
        let tailMask = (UInt64(1) << (shift - 1)) &- 1
        let rOdd = (result & 0x2) != 0
        let rRound = (result & 0x1) != 0
        let rTail = tail || (value & tailMask) != 0
        let roundBit: UInt64 = (rRound && (rOdd || rTail)) ? 1 : 0
        return (result >> 1) &+ roundBit
    }

    // MARK: inf/nan

    private static func scanIgnorecase(_ p: UnsafePointer<UInt8>, _ pi: Int, _ end: Int, _ fmt: StaticString) -> Bool {
        var fi = 0
        var i = pi
        let fbytes = fmt
        return fbytes.withUTF8Buffer { fb -> Bool in
            while fi < fb.count {
                if i >= end { return false }
                if (p[i] | 0x20) != fb[fi] { return false }
                fi += 1
                i += 1
            }
            return true
        }
    }

    // Returns (bits, consumed) or nil if not a special form.
    private static func parseInfNan(_ p: UnsafePointer<UInt8>, _ maxLength: Int) -> (UInt64, Int)? {
        var negative = false
        var i = 0
        let end = maxLength
        if i != end && (p[i] == 0x2B || p[i] == 0x2D) { // + -
            negative = p[i] == 0x2D
            i += 1
        }
        var topBits: UInt32 = 0
        if end - i >= 3 && (p[i] >= 0x30 && p[i] <= 0x39) && p[i + 1] == 0x2E && p[i + 2] == 0x23 {
            // ufbx: legacy MSVC "1.#INF" / "1.#IND" / "1.#NAN"
            i += 3
            if scanIgnorecase(p, i, end, "inf") {
                i += 3
                topBits = 0x7ff0
            } else if scanIgnorecase(p, i, end, "nan") || scanIgnorecase(p, i, end, "ind") {
                i += 3
                topBits = 0x7ff8
            } else {
                return nil
            }
            while i != end && p[i] >= 0x30 && p[i] <= 0x39 { i += 1 }
        } else {
            if scanIgnorecase(p, i, end, "nan") {
                i += 3
                topBits = 0x7ff8
                if i != end && p[i] == 0x28 { // (
                    i += 1
                    while i != end && p[i] != 0x29 { // )
                        let c = p[i]
                        let alnum = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
                        if !alnum { return nil }
                        i += 1
                    }
                    if i == end { return nil }
                    i += 1
                }
            } else if scanIgnorecase(p, i, end, "inf") {
                i += scanIgnorecase(p, i + 3, end, "inity") ? 8 : 3
                topBits = 0x7ff0
            }
        }
        topBits |= negative ? 0x8000 : 0
        let bits = UInt64(topBits) << 48
        return (bits, i)
    }

    // MARK: Main parser

    private static let infinityBits: UInt64 = 0x7ff0_0000_0000_0000

    static func parseDouble(bytes p: UnsafePointer<UInt8>, maxLength: Int, flags: Flags) -> (value: Double, consumed: Int) {
        let maxLimbs = 14

        var bigMantissa = BigInt(capacity: 42)
        var bigQuotient = BigInt(capacity: 42)
        var decExponent: Int32 = 0
        var hasDot: Int32 = 0
        var negative = false
        var tail = false
        var digitsValid = true
        var digits: UInt64 = 0
        var numDigits: UInt32 = 0

        let end = maxLength
        var i = 0
        if i != end && (p[i] == 0x2B || p[i] == 0x2D) {
            negative = p[i] == 0x2D
            i += 1
        }
        while i != end {
            let c = p[i]
            if c >= 0x30 && c <= 0x39 {
                if bigMantissa.length < maxLimbs {
                    digits = digits &* 10 &+ UInt64(c - 0x30)
                    numDigits += 1
                    if numDigits >= 18 {
                        bigintMad(&bigMantissa, pow5Tab[Int(numDigits)] << numDigits, digits)
                        digits = 0
                        numDigits = 0
                        digitsValid = false
                    }
                    decExponent -= hasDot
                } else {
                    decExponent += 1 - hasDot
                }
                i += 1
            } else if c == 0x2E && hasDot == 0 { // .
                hasDot = 1
                i += 1
            } else {
                break
            }
        }
        if i != end && (p[i] == 0x65 || p[i] == 0x45) { // e E
            i += 1
            var expNegative = false
            if i != end && (p[i] == 0x2B || p[i] == 0x2D) {
                expNegative = p[i] == 0x2D
                i += 1
            }
            var exp: Int32 = 0
            while i != end {
                let c = p[i]
                if c >= 0x30 && c <= 0x39 {
                    i += 1
                    exp = exp * 10 + Int32(c - 0x30)
                    if exp >= 10000 { break }
                } else {
                    break
                }
            }
            decExponent += expNegative ? -exp : exp
        }

        if i != end {
            let c = p[i]
            if c == 0x23 || c == 0x69 || c == 0x49 || c == 0x6E || c == 0x4E { // # i I n N
                if let (bits, consumed) = parseInfNan(p, maxLength) {
                    return (Double(bitPattern: bits), consumed)
                }
            }
        }

        let consumed = i

        // ufbx: fast path — both 10^k and the integer are exactly representable.
        if flags.contains(.allowFastPath) && bigMantissa.length == 0
            && decExponent >= -22 && decExponent <= 22 && (digits >> 53) == 0 {
            var value: Double
            if decExponent < 0 {
                value = Double(digits) / pow10Tab[Int(-decExponent)]
            } else {
                value = Double(digits) * pow10Tab[Int(decExponent)]
            }
            return (negative ? -value : value, consumed)
        }

        if bigMantissa.length == 0 {
            bigMantissa.limbs[0] = UInt32(truncatingIfNeeded: digits)
            bigMantissa.limbs[1] = UInt32(truncatingIfNeeded: digits >> 32)
            bigMantissa.length = (digits >> 32) != 0 ? 2 : (digits != 0 ? 1 : 0)
            if bigMantissa.length == 0 { return (negative ? -0.0 : 0.0, consumed) }
        } else {
            bigintMad(&bigMantissa, pow5Tab[Int(numDigits)] << numDigits, digits)
        }

        var encSignShift: UInt32 = 63
        var encMantissaBits: UInt32 = 53
        var encMaxExponent: Int32 = 1023
        if flags.contains(.asBinary32) {
            encSignShift = 31
            encMantissaBits = 24
            encMaxExponent = 127
        }

        var exponent: Int32 = 0
        if decExponent < 0 {
            if decExponent + Int32(bigMantissa.length) * 10 <= -325 { return (negative ? -0.0 : 0.0, consumed) }

            var bigDivisor = BigInt(capacity: 42)
            var pow5 = UInt32(-decExponent)
            let initialPow5 = pow5 <= 27 ? pow5 : 27
            let pow5Value = pow5Tab[Int(initialPow5)]
            pow5 -= initialPow5
            exponent += decExponent

            if pow5 == 0 && digitsValid && (digits >> 63) == 0 {
                let divisorZeros = UInt32(pow5Value.leadingZeroBitCount)
                let mantissaZeros = UInt64(digits.leadingZeroBitCount) - 1
                let divisorBits = pow5Value << divisorZeros
                let mantissaBits = digits << mantissaZeros
                bigDivisor.limbs[0] = UInt32(truncatingIfNeeded: divisorBits)
                bigDivisor.limbs[1] = UInt32(truncatingIfNeeded: divisorBits >> 32)
                bigDivisor.length = 2
                bigMantissa.limbs[0] = 0
                bigMantissa.limbs[1] = 0
                bigMantissa.limbs[2] = UInt32(truncatingIfNeeded: mantissaBits)
                bigMantissa.limbs[3] = UInt32(truncatingIfNeeded: mantissaBits >> 32)
                bigMantissa.length = 4
                exponent += Int32(divisorZeros) - Int32(mantissaZeros) - 64
            } else {
                bigDivisor.limbs[0] = UInt32(truncatingIfNeeded: pow5Value)
                bigDivisor.limbs[1] = UInt32(truncatingIfNeeded: pow5Value >> 32)
                bigDivisor.length = (pow5Value >> 32) != 0 ? 2 : 1
                if pow5 > 0 {
                    bigintMulPow5(&bigDivisor, pow5)
                }

                var divisorZeros = UInt32(bigDivisor.limbs[bigDivisor.length - 1].leadingZeroBitCount)
                if bigDivisor.length == 1 { divisorZeros += 32 }
                bigintShiftLeft(&bigDivisor, divisorZeros)
                let divisorBits = UInt32(bigDivisor.length) * 32

                let mantissaZeros = UInt32(bigMantissa.limbs[bigMantissa.length - 1].leadingZeroBitCount)
                let mantissaBits = UInt32(bigMantissa.length) * 32 - mantissaZeros
                let mantissaMinBits = divisorBits + encMantissaBits + 2
                var mantissaShift = mantissaBits < mantissaMinBits ? mantissaMinBits - mantissaBits : 0
                // ufbx: align mantissa off a limb boundary so division can skip the first digit.
                mantissaShift += (((mantissaShift &- mantissaZeros) & 31) == 0) ? 1 : 0
                if mantissaShift > 0 {
                    bigintShiftLeft(&bigMantissa, mantissaShift)
                }
                exponent += Int32(divisorZeros) - Int32(mantissaShift)
            }

            tail = bigintDiv(&bigQuotient, &bigMantissa, &bigDivisor)
            bigMantissa = bigQuotient
        } else if decExponent > 0 {
            if decExponent + Int32(bigMantissa.length - 1) * 9 >= 310 {
                return (negative ? -Double.infinity : Double.infinity, consumed)
            }
            exponent += decExponent
            bigintMulPow5(&bigMantissa, UInt32(decExponent))
        }

        var mantissa = bigintExtractHigh(bigMantissa, &exponent, &tail)
        let signBit = (negative ? UInt64(1) : 0) << encSignShift

        var mantissaShift = 64 - encMantissaBits
        if exponent > encMaxExponent {
            return (negative ? -Double.infinity : Double.infinity, consumed)
        } else if exponent <= -encMaxExponent {
            mantissaShift += UInt32(-encMaxExponent + 1 - exponent)
            exponent = -encMaxExponent + 1
        }

        mantissa = shiftRightRound(mantissa, mantissaShift, tail)
        if mantissa == 0 { return (negative ? -0.0 : 0.0, consumed) }

        var bits = mantissa
        bits = bits &+ (UInt64(exponent + encMaxExponent - 1) << (encMantissaBits - 1))
        bits |= signBit

        if flags.contains(.asBinary32) {
            let bitsLo = UInt32(truncatingIfNeeded: bits)
            return (Double(Float(bitPattern: bitsLo)), consumed)
        } else {
            return (Double(bitPattern: bits), consumed)
        }
    }

    // MARK: Convenience wrappers

    static func parseDouble(_ slice: ArraySlice<UInt8>, flags: Flags = .allowFastPath) -> (value: Double, consumed: Int) {
        return slice.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return (0.0, 0) }
            return parseDouble(bytes: base, maxLength: buf.count, flags: flags)
        }
    }

    static func parseDouble(_ bytes: [UInt8], flags: Flags = .allowFastPath) -> (value: Double, consumed: Int) {
        return parseDouble(bytes[...], flags: flags)
    }

    // MARK: Integer parsing (port of ufbxi_parse_int64)

    // Returns (value, consumed) or nil if there were no digits or the run
    // reached the 30-char cap (mirrors ufbx returning a NULL end pointer).
    static func parseInt64(bytes p: UnsafePointer<UInt8>, maxLength: Int) -> (value: Int64, consumed: Int)? {
        var absVal: UInt64 = 0
        let negative = maxLength > 0 && p[0] == 0x2D
        let positive = maxLength > 0 && p[0] == 0x2B
        let initLen = (negative || positive) ? 1 : 0
        var len = initLen
        while len < 30 {
            if len >= maxLength { break }
            let c = p[len]
            if !(c >= 0x30 && c <= 0x39) { break }
            absVal = 10 &* absVal &+ UInt64(c - 0x30)
            len += 1
        }
        if len == 30 || len == initLen { return nil }
        let value = negative ? Int64(bitPattern: 0 &- absVal) : Int64(bitPattern: absVal)
        return (value, len)
    }

    static func parseInt64(_ slice: ArraySlice<UInt8>) -> (value: Int64, consumed: Int)? {
        return slice.withUnsafeBufferPointer { buf -> (value: Int64, consumed: Int)? in
            guard let base = buf.baseAddress else { return nil }
            return parseInt64(bytes: base, maxLength: buf.count)
        }
    }
}
