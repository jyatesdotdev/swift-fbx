// FBX property system: `ufbx_prop`, `ufbx_props`, `ufbx_prop_type`,
// `ufbx_prop_flags` (ufbx.h:441-572). Properties are arbitrary key/value pairs
// with a template `defaults` chain. Lookup is a binary search by a 4-byte name
// key, falling through to `defaults` (ufbx.c:11480-11518, notes 05).

import Foundation

// MARK: - Prop type / flags

/// Mirrors `ufbx_prop_type` (ufbx.h:456). Raw values match ufbx ordinals.
public enum FBXPropType: Int, Sendable {
    case unknown = 0
    case boolean = 1
    case integer = 2
    case number = 3
    case vector = 4
    case color = 5
    case colorWithAlpha = 6
    case string = 7
    case dateTime = 8
    case translation = 9
    case rotation = 10
    case scaling = 11
    case distance = 12
    case compound = 13
    case blob = 14
    case reference = 15
}

/// Mirrors `ufbx_prop_flags` (ufbx.h:480-539). Bit positions match ufbx exactly.
public struct FBXPropFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let animatable  = FBXPropFlags(rawValue: 0x1)
    public static let userDefined = FBXPropFlags(rawValue: 0x2)
    public static let hidden      = FBXPropFlags(rawValue: 0x4)
    public static let lockX       = FBXPropFlags(rawValue: 0x10)
    public static let lockY       = FBXPropFlags(rawValue: 0x20)
    public static let lockZ       = FBXPropFlags(rawValue: 0x40)
    public static let lockW       = FBXPropFlags(rawValue: 0x80)
    public static let muteX       = FBXPropFlags(rawValue: 0x100)
    public static let muteY       = FBXPropFlags(rawValue: 0x200)
    public static let muteZ       = FBXPropFlags(rawValue: 0x400)
    public static let muteW       = FBXPropFlags(rawValue: 0x800)
    public static let synthetic   = FBXPropFlags(rawValue: 0x1000)
    public static let animated    = FBXPropFlags(rawValue: 0x2000)
    public static let notFound    = FBXPropFlags(rawValue: 0x4000)
    public static let connected   = FBXPropFlags(rawValue: 0x8000)
    public static let noValue     = FBXPropFlags(rawValue: 0x10000)
    public static let overridden  = FBXPropFlags(rawValue: 0x20000)
    public static let valueReal   = FBXPropFlags(rawValue: 0x100000)
    public static let valueVec2   = FBXPropFlags(rawValue: 0x200000)
    public static let valueVec3   = FBXPropFlags(rawValue: 0x400000)
    public static let valueVec4   = FBXPropFlags(rawValue: 0x800000)
    public static let valueInt    = FBXPropFlags(rawValue: 0x1000000)
    public static let valueStr    = FBXPropFlags(rawValue: 0x2000000)
    public static let valueBlob   = FBXPropFlags(rawValue: 0x4000000)
}

// MARK: - Prop

/// Mirrors `ufbx_prop` (ufbx.h:542-560). All value slots are always populated
/// regardless of `type`, so callers never switch on `type` to read a value.
/// `valueVec4` holds up to four reals; components beyond the property's arity
/// are zero. `valueReal`/`valueVec2`/`valueVec3` alias into it.
public struct FBXProp: Sendable {
    public var name: String
    public var type: FBXPropType
    public var flags: FBXPropFlags
    public var valueString: String
    public var valueBlob: Data
    public var valueInt: Int64
    public var valueVec4: FBXVec4

    public init(
        name: String,
        type: FBXPropType = .unknown,
        flags: FBXPropFlags = [],
        valueString: String = "",
        valueBlob: Data = Data(),
        valueInt: Int64 = 0,
        valueVec4: FBXVec4 = .init()
    ) {
        self.name = name
        self.type = type
        self.flags = flags
        self.valueString = valueString
        self.valueBlob = valueBlob
        self.valueInt = valueInt
        self.valueVec4 = valueVec4
    }

    public var valueReal: Double { valueVec4.x }
    public var valueVec2: FBXVec2 { FBXVec2(valueVec4.x, valueVec4.y) }
    public var valueVec3: FBXVec3 { FBXVec3(valueVec4.x, valueVec4.y, valueVec4.z) }
    public var valueBool: Bool { valueInt != 0 }

    /// The `_internal_key`: first four bytes of the (UTF-8) name packed
    /// big-endian, matching `ufbxi_get_name_key` (ufbx.c:11609-11622). Used as
    /// the primary sort/search key so `FBXProps.find` can binary-search.
    public var internalKey: UInt32 { FBXProp.nameKey(name) }

    public static func nameKey(_ name: String) -> UInt32 {
        var key: UInt32 = 0
        var i = 0
        for b in name.utf8 {
            if i >= 4 { break }
            key = (key << 8) | UInt32(b)
            i += 1
        }
        // Pad remaining slots with zero bytes (ufbx handles len < 4 the same way).
        while i < 4 { key <<= 8; i += 1 }
        return key
    }

    /// Total order matching `ufbxi_prop_less` (ufbx.c:11871-11876): by name key,
    /// then a byte-wise (`strcmp`) comparison of the UTF-8 name. Readers MUST
    /// sort props with this comparator for `FBXProps.find`'s binary search to hold.
    public static func less(_ a: FBXProp, _ b: FBXProp) -> Bool {
        let ka = a.internalKey, kb = b.internalKey
        if ka != kb { return ka < kb }
        return byteLess(a.name, b.name)
    }

    // ufbx: strcmp over NUL-terminated UTF-8; Swift `<` uses Unicode collation,
    // so compare raw bytes to preserve ufbx's ordering exactly.
    static func byteLess(_ a: String, _ b: String) -> Bool {
        var ia = a.utf8.makeIterator()
        var ib = b.utf8.makeIterator()
        while true {
            let ca = ia.next(), cb = ib.next()
            switch (ca, cb) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?):
                if x != y { return x < y }
            }
        }
    }
}

// MARK: - Props table

/// Mirrors `ufbx_props` (ufbx.h:567-572): a name-sorted list plus an optional
/// `defaults` chain (FBX template defaults). Frozen after load, hence
/// `@unchecked Sendable` (DESIGN freeze rule).
public final class FBXProps: @unchecked Sendable {
    /// Sorted by `FBXProp.less` (name key, then name bytes).
    public internal(set) var props: [FBXProp]
    /// Template/default chain walked on lookup miss.
    public internal(set) var defaults: FBXProps?

    public init(props: [FBXProp] = [], defaults: FBXProps? = nil) {
        self.props = props
        self.defaults = defaults
    }

    /// Chained lookup mirroring `ufbxi_find_prop_with_key` (ufbx.c:11480-11509):
    /// binary-search this table by name key, linear-scan the matching-key run
    /// for a name match (skipping `NO_VALUE` props), then fall through to
    /// `defaults`.
    public func find(_ name: String) -> FBXProp? {
        let key = FBXProp.nameKey(name)
        var table: FBXProps? = self
        while let t = table {
            let arr = t.props
            // Lower bound by key.
            var lo = 0, hi = arr.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if arr[mid].internalKey < key { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < arr.count {
                let p = arr[i]
                if p.internalKey != key { break }
                if p.name == name && !p.flags.contains(.noValue) { return p }
                i += 1
            }
            table = t.defaults
        }
        return nil
    }

    public func findReal(_ name: String, _ def: Double = 0) -> Double {
        find(name)?.valueReal ?? def
    }
    public func findVec2(_ name: String, _ def: FBXVec2 = .zero) -> FBXVec2 {
        find(name).map { FBXVec2($0.valueVec4.x, $0.valueVec4.y) } ?? def
    }
    public func findVec3(_ name: String, _ def: FBXVec3 = .zero) -> FBXVec3 {
        find(name).map { FBXVec3($0.valueVec4.x, $0.valueVec4.y, $0.valueVec4.z) } ?? def
    }
    public func findVec4(_ name: String, _ def: FBXVec4 = .init()) -> FBXVec4 {
        find(name)?.valueVec4 ?? def
    }
    public func findInt(_ name: String, _ def: Int64 = 0) -> Int64 {
        find(name)?.valueInt ?? def
    }
    public func findBool(_ name: String, _ def: Bool = false) -> Bool {
        guard let p = find(name) else { return def }
        return p.valueInt != 0
    }
    public func findString(_ name: String, _ def: String = "") -> String {
        find(name)?.valueString ?? def
    }

    /// Mirrors `ufbxi_find_enum`: read the integer value and clamp into
    /// `[0, max]`; returns `def` (unclamped) when the property is absent.
    public func findEnum(_ name: String, _ def: Int, max: Int) -> Int {
        guard let p = find(name) else { return def }
        let v = Int(p.valueInt)
        if v < 0 { return 0 }
        if v > max { return max }
        return v
    }
}
