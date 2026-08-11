import Foundation

/// The two FBX file container formats. Mirrors ufbx's `sure_fbx`/ASCII split
/// (`ufbxi_begin_parse`, ufbx.c:11193).
public enum FBXFormat: Sendable {
    case binary
    case ascii
}

/// A node in the low-level document tree. Mirrors `ufbxi_node` (ufbx.c:6197):
/// either up to 8 scalar `values`, or a single `array` payload — never both.
///
/// Parsing (Binary/AsciiParser + ParseState) is implemented elsewhere; this
/// type only owns storage + the lenient `ufbxi_get_val_at`-style accessors
/// (ufbx.c:7711-7909).
public final class FBXDocNode: @unchecked Sendable {
    public let name: String
    public internal(set) var values: [FBXValue]
    /// Set iff this node was parsed as an array node (`value_type_mask ==
    /// UFBXI_VALUE_ARRAY`); mutually exclusive with non-empty `values`.
    public internal(set) var array: FBXArrayValue?
    public internal(set) var children: [FBXDocNode]

    public init(name: String, values: [FBXValue] = [], array: FBXArrayValue? = nil, children: [FBXDocNode] = []) {
        self.name = name
        self.values = values
        self.array = array
        self.children = children
    }

    // MARK: - Child lookup (ufbxi_find_child, ufbx.c:7713)

    /// First child named `name`, or nil. ufbx compares interned name
    /// pointers; we just compare strings (semantically identical).
    public func child(_ name: String) -> FBXDocNode? {
        for c in children where c.name == name { return c }
        return nil
    }

    /// All children named `name`, in document order.
    public func children(_ name: String) -> [FBXDocNode] {
        children.filter { $0.name == name }
    }

    /// Walks a chain of `child(_:)` lookups, e.g. `findChild(["Properties70"])`.
    public func findChild(_ path: [String]) -> FBXDocNode? {
        var node: FBXDocNode? = self
        for segment in path {
            node = node?.child(segment)
            if node == nil { return nil }
        }
        return node
    }

    // MARK: - Scalar value accessors (ufbxi_get_val_at, ufbx.c:7731)
    // nil on missing index or type mismatch (soft failure, matching ufbx's
    // 0-return convention).

    public func bool(at index: Int) -> Bool? {
        guard values.indices.contains(index) else { return nil }
        return values[index].asBool
    }

    public func int32(at index: Int) -> Int32? {
        guard values.indices.contains(index) else { return nil }
        return values[index].asInt32
    }

    public func int64(at index: Int) -> Int64? {
        guard values.indices.contains(index) else { return nil }
        return values[index].asInt64
    }

    public func float(at index: Int) -> Float? {
        guard values.indices.contains(index) else { return nil }
        return values[index].asFloat
    }

    public func double(at index: Int) -> Double? {
        guard values.indices.contains(index) else { return nil }
        return values[index].asDouble
    }

    /// Sanitized UTF-8 string (fmt 'S'/'C').
    public func string(at index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index].asString
    }

    /// Raw unsanitized bytes (fmt 's'/'c'/'b').
    public func rawString(at index: Int) -> Data? {
        guard values.indices.contains(index) else { return nil }
        return values[index].asRawData
    }

    // MARK: - Array accessors (ufbxi_get_array + ufbxi_binary_convert_array)
    // nil when the node has no array payload; otherwise the stored array is
    // converted to the requested destination type per ufbx's conversion
    // matrix (ufbx.c:8672), saturating float->int, truncating int widen/narrow.

    public func asBoolArray() -> [Bool]? {
        array?.asBoolArray()
    }

    public func asInt32Array() -> [Int32]? {
        array?.asInt32Array()
    }

    public func asInt64Array() -> [Int64]? {
        array?.asInt64Array()
    }

    public func asFloatArray() -> [Float]? {
        array?.asFloatArray()
    }

    public func asDoubleArray() -> [Double]? {
        array?.asDoubleArray()
    }

    public func asRawData() -> Data? {
        array?.asRawData
    }
}

/// The parsed low-level document: a synthetic root holding all top-level FBX
/// nodes (Header, Definitions, Objects, Connections, Takes, ...), plus format
/// metadata detected during parsing.
public final class FBXDocument: @unchecked Sendable {
    /// e.g. 7500; 6100 for legacy ASCII FBX 6.1.
    public let version: Int
    public let format: FBXFormat
    public let bigEndian: Bool
    public internal(set) var root: FBXDocNode

    /// Internal: parsing (BinaryParser/AsciiParser/DocumentParser) constructs
    /// this. `parse(data:options:)` is added by DocumentParser.swift.
    init(version: Int, format: FBXFormat, bigEndian: Bool, root: FBXDocNode = FBXDocNode(name: "")) {
        self.version = version
        self.format = format
        self.bigEndian = bigEndian
        self.root = root
    }
}
