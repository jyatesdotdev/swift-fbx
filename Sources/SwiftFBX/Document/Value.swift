import Foundation

// Document-layer value model. Mirrors `ufbxi_value`/`ufbxi_value_array` (ufbx.c
// 6179-6197) with the lenient coercion semantics of `ufbxi_get_val_at`
// (ufbx.c 7711-7909) implemented as computed properties below rather than by
// keeping both an int and a double form on every scalar.

/// A single scalar node value. Mirrors `ufbxi_value` (NUMBER/STRING union).
public enum FBXValue: Sendable {
    case bool(Bool)
    case int32(Int32)
    case int64(Int64)
    case float(Float)
    case double(Double)
    /// UTF-8 sanitized (U+FFFD replacement for invalid sequences).
    case string(String)
    /// Raw, unsanitized bytes (isRawString paths per the parse state machine).
    case raw(Data)
}

/// A whole-node array value. Mirrors `ufbxi_value_array` after
/// `ufbxi_binary_convert_array`/`ufbxi_postprocess_bool_array` have run — i.e.
/// the destination type ufbx's `ParseState` chose at parse time.
public enum FBXArrayValue: Sendable {
    case bool([Bool])
    case int32([Int32])
    case int64([Int64])
    case float([Float])
    case double([Double])
    /// Byte / blob arrays (content, thumbnails, and any plain 'c' byte array).
    case raw(Data)
}

// MARK: - Numeric coercion (ufbxi_get_val_at NUMBER family)

extension FBXValue {
    /// ufbx: every numeric scalar is readable as *any* numeric format
    /// regardless of wire type (`ufbxi_get_val_at` fmt `I/L/F/D/R/B/Z`, all
    /// backed by the dual `.i`/`.f` storage of `ufbxi_value`). We reconstruct
    /// that dual view on demand instead of storing it eagerly.
    fileprivate var numericPair: (i: Int64, f: Double)? {
        switch self {
        case .bool(let b): return (b ? 1 : 0, b ? 1 : 0)
        case .int32(let v): return (Int64(v), Double(v))
        case .int64(let v): return (v, Double(v))
        case .float(let v):
            // ufbx: F stores .f = value, .i = f64_to_i64(.f) (saturating).
            return (FBXValue.f64ToI64(Double(v)), Double(v))
        case .double(let v):
            return (FBXValue.f64ToI64(v), v)
        case .string, .raw:
            return nil
        }
    }

    // ufbx: ufbxi_f64_to_i32 (ufbx.c:1112) — saturating, not truncating.
    static func f64ToI32(_ value: Double) -> Int32 {
        if value.magnitude <= Double(Int32.max) {
            return Int32(value)
        }
        return value >= 0 ? Int32.max : Int32.min
    }

    // ufbx: ufbxi_f64_to_i64 (ufbx.c:1121).
    //
    // Deliberately uses the EXCLUSIVE bound 2^63 rather than `<= Double(Int64.max)`:
    // `Double(Int64.max)` (= 2^63 - 1) is not exactly representable and rounds UP to
    // exactly 2^63, so a `<=` guard would admit a value of exactly 2^63 and then
    // `Int64(9223372036854775808.0)` TRAPS ("result would be greater than
    // Int64.max"). ufbx.c uses `<= (double)INT64_MAX` too, but C's out-of-range
    // float→int cast is UB (silently wraps) where Swift traps; the strict `<`
    // reproduces ufbx's *intended* saturating result without the crash. Reachable
    // from any malformed binary 'D'/'F' scalar (or coerced array element) of 2^63.
    // `f64ToI32` above is safe with `<=` only because `Double(Int32.max)` is exact.
    static func f64ToI64(_ value: Double) -> Int64 {
        if value.magnitude < 9223372036854775808.0 {   // 2^63, exclusive
            return Int64(value)
        }
        return value >= 0 ? Int64.max : Int64.min
    }

    /// fmt 'B': non-zero test on the integer form.
    public var asBool: Bool? {
        numericPair.map { $0.i != 0 }
    }

    /// fmt 'I': narrowing (truncating) cast of the int64 form, matching C's
    /// `(int32_t)node->vals[ix].i`.
    public var asInt32: Int32? {
        numericPair.map { Int32(truncatingIfNeeded: $0.i) }
    }

    /// fmt 'L'.
    public var asInt64: Int64? {
        numericPair.map { $0.i }
    }

    /// fmt 'F': narrowing cast of the double form.
    public var asFloat: Float? {
        numericPair.map { Float($0.f) }
    }

    /// fmt 'D'/'R' (ufbx_real == Double in this port).
    public var asDouble: Double? {
        numericPair.map { $0.f }
    }

    /// fmt 'S'/'C': sanitized string. Raw values are decoded leniently
    /// (`String(decoding:as:)`) per the DESIGN.md default string policy —
    /// ufbx only rejects the pathological "raw and not valid UTF-8" case,
    /// which we treat the same as any other raw payload here.
    public var asString: String? {
        switch self {
        case .string(let s): return s
        case .raw(let d): return String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    /// fmt 's'/'c'/'b': raw bytes, unsanitized.
    public var asRawData: Data? {
        switch self {
        case .raw(let d): return d
        case .string(let s): return Data(s.utf8)
        default: return nil
        }
    }
}

// MARK: - Array conversion (ufbxi_binary_convert_array, ufbx.c:8672-8760)

extension FBXArrayValue {
    public var count: Int {
        switch self {
        case .bool(let a): return a.count
        case .int32(let a): return a.count
        case .int64(let a): return a.count
        case .float(let a): return a.count
        case .double(let a): return a.count
        case .raw(let d): return d.count
        }
    }

    // Uniform "as Double" view of every element regardless of storage,
    // mirroring the src-type row of ufbx's conversion matrix (c/i/l/f/d).
    private func asDoubles() -> [Double] {
        switch self {
        case .bool(let a): return a.map { $0 ? 1 : 0 }
        case .int32(let a): return a.map(Double.init)
        case .int64(let a): return a.map(Double.init)
        case .float(let a): return a.map(Double.init)
        case .double(let a): return a
        case .raw(let d): return d.map(Double.init)
        }
    }

    /// Convert to `[Int32]` following ufbx's dst='i' rows: 'c' widens
    /// unsigned-byte→i32, 'l' truncates, 'f'/'d' saturate (`f64_to_i32`).
    public func asInt32Array() -> [Int32] {
        switch self {
        case .int32(let a): return a
        case .bool(let a): return a.map { $0 ? 1 : 0 }
        case .int64(let a): return a.map { Int32(truncatingIfNeeded: $0) }
        case .float(let a): return a.map { FBXValue.f64ToI32(Double($0)) }
        case .double(let a): return a.map { FBXValue.f64ToI32($0) }
        case .raw(let d): return d.map { Int32($0) }
        }
    }

    /// dst='l' rows: 'c' widens, 'i' widens, 'f'/'d' saturate (`f64_to_i64`).
    public func asInt64Array() -> [Int64] {
        switch self {
        case .int64(let a): return a
        case .bool(let a): return a.map { $0 ? 1 : 0 }
        case .int32(let a): return a.map(Int64.init)
        case .float(let a): return a.map { FBXValue.f64ToI64(Double($0)) }
        case .double(let a): return a.map { FBXValue.f64ToI64($0) }
        case .raw(let d): return d.map { Int64($0) }
        }
    }

    /// dst='f' rows: plain numeric casts, no saturation for float dst.
    public func asFloatArray() -> [Float] {
        switch self {
        case .float(let a): return a
        case .bool(let a): return a.map { $0 ? 1 : 0 }
        case .int32(let a): return a.map(Float.init)
        case .int64(let a): return a.map(Float.init)
        case .double(let a): return a.map(Float.init)
        case .raw(let d): return d.map { Float($0) }
        }
    }

    /// dst='d' rows.
    public func asDoubleArray() -> [Double] {
        switch self {
        case .double(let a): return a
        default: return asDoubles()
        }
    }

    /// dst='c' (bool storage): non-zero test, matching
    /// `ufbxi_postprocess_bool_array` semantics on the coerced byte value.
    public func asBoolArray() -> [Bool] {
        switch self {
        case .bool(let a): return a
        case .int32(let a): return a.map { $0 != 0 }
        case .int64(let a): return a.map { $0 != 0 }
        case .float(let a): return a.map { $0 != 0 }
        case .double(let a): return a.map { $0 != 0 }
        case .raw(let d): return d.map { $0 != 0 }
        }
    }

    /// dst='C'/blob: only meaningful when the stored form already is raw
    /// bytes; other array kinds have no byte-array equivalent in ufbx.
    public var asRawData: Data? {
        if case .raw(let d) = self { return d }
        return nil
    }
}
