import Foundation

// Binary FBX record reader. Port of `ufbxi_binary_parse_node` and the
// surrounding helpers (ufbx.c:8607–9404) plus the binary header sniff from
// `ufbxi_begin_parse` (ufbx.c:11193–11240). Produces `FBXDocNode` trees whose
// arrays are already converted to the destination type `ParseState` chose, with
// the same quirks ufbx has: 13-byte vs 25-byte record headers (>= 7500 uses
// 64-bit offsets), big-endian scalar/array byte swapping, DEFLATE (encoding 1)
// array payloads, saturating float->int conversion, bool post-processing, the
// pre-7000 multivalue (concatenated-scalar) array fallback, raw-vs-sanitized
// strings per `isRawString`, and NULL-record sibling termination.
//
// The IO/threading/zero-copy/DOM-retention machinery of ufbx is dropped: we hold
// the whole file in a `DataReader` and always inflate/convert synchronously.
//
// Entry points (used by DocumentParser, wave 3):
//   - `BinaryParser.detectHeader(_:)`   → parse magic/endianness/version (a)
//   - `BinaryParser.nextTopLevelNode()` → iterate top-level nodes one by one (b)
//   - `BinaryParser.parseBinaryDocument(_:...)` → convenience full parse
struct BinaryParser {

    // ufbx: "Kaydara FBX Binary  \x00\x1a" — 22 bytes, two ASCII spaces before
    // the terminator (UFBXI_BINARY_MAGIC_SIZE, ufbx.c:9400–9402).
    static let binaryMagic: [UInt8] = Array("Kaydara FBX Binary  ".utf8) + [0x00, 0x1a]

    // ufbx: UFBXI_MAX_NODE_DEPTH (ufbx.c:52).
    static let maxNodeDepth = 32

    private var reader: DataReader
    private let version: Int
    private let context: ParseContext
    private let arrayBudget: FBXDecodedArrayBudget

    init(reader: DataReader, version: Int, context: ParseContext,
         arrayBudget: FBXDecodedArrayBudget = FBXDecodedArrayBudget(options: .init())) {
        self.reader = reader
        self.version = version
        self.context = context
        self.arrayBudget = arrayBudget
    }

    /// The cursor position after the last parsed node (absolute file offset).
    var position: Int { reader.position }

    // MARK: - Header detection (ufbxi_begin_parse, ufbx.c:11193)

    /// Detect and consume the 27-byte binary header. Returns `nil` with the
    /// cursor unmoved when the buffer does not start with the binary magic (the
    /// caller then treats the file as ASCII). On success the reader is advanced
    /// past the header and its `bigEndian` flag is set for subsequent reads.
    static func detectHeader(_ reader: inout DataReader) throws -> (version: Int, bigEndian: Bool)? {
        guard let head = try? reader.peekBytes(27) else { return nil }
        let s = head.startIndex
        for i in 0..<22 where head[s + i] != binaryMagic[i] { return nil }

        // ufbx: byte after the magic is the endianness flag (!= 0 => big-endian).
        let bigEndian = head[s + 22] != 0
        let b0 = UInt32(head[s + 23]), b1 = UInt32(head[s + 24])
        let b2 = UInt32(head[s + 25]), b3 = UInt32(head[s + 26])
        let version: UInt32 = bigEndian
            ? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            : (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
        try reader.skip(27)
        reader.bigEndian = bigEndian
        return (Int(version), bigEndian)
    }

    // MARK: - Top-level iteration

    /// Parse the next top-level node (full subtree). Returns `nil` at the
    /// terminating NULL record / end of the top-level list.
    mutating func nextTopLevelNode() throws -> FBXDocNode? {
        try parseNode(depth: 0, parentState: .root)
    }

    /// Convenience: detect the binary header then parse every top-level node into
    /// a synthetic root. Returns `nil` if the buffer is not a binary FBX.
    static func parseBinaryDocument(_ bytes: [UInt8],
                                    ignoreGeometry: Bool = false,
                                    ignoreAnimation: Bool = false,
                                    ignoreEmbedded: Bool = false,
                                    retainDom: Bool = false,
                                    retainVertexW: Bool = false,
                                    blenderFullWeights: Bool = false,
                                    arrayBudget: FBXDecodedArrayBudget = FBXDecodedArrayBudget(options: .init())) throws -> FBXDocument? {
        var reader = DataReader(bytes)
        guard let (version, bigEndian) = try detectHeader(&reader) else { return nil }
        let context = ParseContext(version: version, fromAscii: false,
                                   ignoreGeometry: ignoreGeometry,
                                   ignoreAnimation: ignoreAnimation,
                                   ignoreEmbedded: ignoreEmbedded,
                                   retainDom: retainDom,
                                   retainVertexW: retainVertexW,
                                   blenderFullWeights: blenderFullWeights)
        var parser = BinaryParser(reader: reader, version: version, context: context,
                                  arrayBudget: arrayBudget)
        let root = FBXDocNode(name: "")
        while let node = try parser.nextTopLevelNode() {
            root.children.append(node)
        }
        return FBXDocument(version: version, format: .binary, bigEndian: bigEndian, root: root)
    }

    // MARK: - Core node reader (ufbxi_binary_parse_node, ufbx.c:8964)

    /// Parse one node and its subtree. Returns `nil` for the NULL-sentinel record
    /// that terminates a sibling list (`end_offset == 0 && name_len == 0`).
    private mutating func parseNode(depth: Int, parentState: ParseState) throws -> FBXDocNode? {
        if depth >= BinaryParser.maxNodeDepth {
            throw FBXError(.nodeDepthLimit, "node depth >= \(BinaryParser.maxNodeDepth)")
        }

        // ufbx: header is 25 bytes for >= 7500 (64-bit offsets), else 13 bytes.
        // Reading each field through the endian-aware DataReader is equivalent to
        // ufbx swapping the leading 3 words together.
        let endOffset: UInt64
        let numValues64: UInt64
        let valuesLen: UInt64
        if version >= 7500 {
            endOffset = try reader.readUInt64()
            numValues64 = try reader.readUInt64()
            valuesLen = try reader.readUInt64()
        } else {
            endOffset = UInt64(try reader.readUInt32())
            numValues64 = UInt64(try reader.readUInt32())
            valuesLen = UInt64(try reader.readUInt32())
        }
        let nameLen = Int(try reader.readUInt8())

        // ufbx: NULL-sentinel terminating a node list.
        if endOffset == 0 && nameLen == 0 {
            return nil
        }

        if numValues64 > UInt64(UInt32.max) {
            throw FBXError(.corruptData, "num_values overflow")
        }
        let numValues = Int(numValues64)

        let nameBytes = try reader.readBytes(nameLen)
        let name = String(decoding: nameBytes, as: UTF8.self)

        // ufbx (ufbx.c:9027): `values_end_offset = read_offset + values_len` in
        // uint64 (C wraparound). A malformed huge `values_len` wraps here; the
        // `offset > valuesEndOffset` check below then rejects it as corrupt,
        // exactly as ufbx's `ufbxi_check(offset <= values_end_offset)` does. Use
        // `&+` so Swift does not trap on the (intentional) overflow.
        let valuesEndOffset = UInt64(reader.position) &+ valuesLen

        let node = FBXDocNode(name: name)

        if let info = ParseState.arrayInfo(parent: parentState, name: name, context: context) {
            try parseArray(node: node, info: info, numValues: numValues)
        } else {
            try parseScalarValues(node: node,
                                  count: min(numValues, 8), // UFBXI_MAX_NON_ARRAY_VALUES
                                  parentState: parentState, name: name)
        }

        // ufbx: skip to the recorded value end (tolerates truncated value lists
        // and trailing bytes after an array; overrun is a hard error).
        let offset = UInt64(reader.position)
        if offset > valuesEndOffset {
            throw FBXError(.corruptData, "value list overran node")
        }
        if offset < valuesEndOffset {
            // ufbx skips `values_end_offset - offset` bytes via `ufbxi_skip_bytes`,
            // which fails cleanly ("Truncated file") if that runs past the buffer.
            // A malformed `values_len` can make the delta exceed `Int.max`; the
            // unchecked `Int(...)` conversion here was the reported trap
            // ("Not enough bits to represent the passed value", BinaryParser:157).
            // Any delta that does not fit in `Int` is by definition past the end
            // of an in-memory file, so reject it as truncated like ufbx.
            guard let skipCount = Int(exactly: valuesEndOffset - offset) else {
                throw FBXError(.truncatedFile, "value list extends past end of file")
            }
            try reader.skip(skipCount)
        }

        // Recurse into children until end_offset or a NULL sentinel.
        let childState = ParseState.update(parent: parentState, name: name)
        while true {
            let current = UInt64(reader.position)
            if current >= endOffset {
                // ufbx: end_offset == 0 tolerated (children ran to parent end).
                if current != endOffset && endOffset != 0 {
                    throw FBXError(.corruptData, "child list overran node")
                }
                break
            }
            guard let child = try parseNode(depth: depth + 1, parentState: childState) else { break }
            node.children.append(child)
        }

        return node
    }

    // MARK: - Array branch (ufbx.c:9032–9254)

    private mutating func parseArray(node: FBXDocNode, info: ArrayInfo, numValues: Int) throws {
        // ufbx: dst storage type ('b' -> 'c'), and the retained array tag ('b'
        // kept to drive the bool post-process). 'r' resolves to Double here.
        let dstStorage = normalize(info.type, bool: .uint8)
        let arrType = normalize(info.type, bool: .bool)

        // ufbx: at least 13 bytes are always safely peekable (files end in a
        // full NULL record). `c` is the wire array tag.
        let firstByte = try reader.peekBytes(1)
        var c = firstByte[firstByte.startIndex]
        if numValues == 0 { c = 0x30 }               // '0' — empty
        if dstStorage == .ignore { c = 0x2D }         // '-' — ignore

        var arr: FBXArrayValue
        switch c {
        case 0x63, 0x62, 0x69, 0x6C, 0x66, 0x64:      // c b i l f d — typed array
            arr = try parseTypedArray(tag: c, dstStorage: dstStorage)
        case 0x2D:                                     // '-' — ignored, payload skipped by trailing skip
            node.array = .raw(Data())
            return
        case 0x30:                                     // '0' — empty
            arr = emptyArray(dstStorage: dstStorage)
        default:                                        // pre-7000 concatenated scalars
            arr = try parseMultivalueArray(dstStorage: dstStorage, size: numValues)
        }

        // ufbx: postprocess bool arrays (each stored byte -> 0/1).
        if arrType == .bool {
            arr = .bool(arr.asBoolArray())
        }
        node.array = arr
    }

    /// Post-7000 typed array: 1 tag byte + u32 size + u32 encoding + u32
    /// encoded_size + payload. Decodes and converts to `dstStorage`.
    private mutating func parseTypedArray(tag: UInt8, dstStorage: ArrayType) throws -> FBXArrayValue {
        _ = try reader.readUInt8()                          // consume tag
        let size = Int(try reader.readUInt32())
        let encoding = try reader.readUInt32()
        let encodedSize = Int(try reader.readUInt32())

        guard let srcType = normalizeSrc(tag) else {
            throw FBXError(.corruptData, "bad array source type")
        }
        // `size` and `encodedSize` are untrusted 32-bit counts from the file.
        // `elemSize * size` can be up to ~34 GB; compute it overflow-checked so a
        // crafted count cannot trap or wrap into a small (mis-sized) buffer.
        let (decodedSize, overflow) = elemSize(srcType).multipliedReportingOverflow(by: size)
        if overflow || decodedSize < 0 {
            throw FBXError(.corruptData, "array element count too large")
        }

        let destinationSize = elemSize(dstStorage).multipliedReportingOverflow(by: size)
        guard !destinationSize.overflow else {
            throw FBXError(.resourceLimit, "normalized array byte count overflow")
        }
        try arrayBudget.claim(
            elements: size,
            bytes: Swift.max(decodedSize, destinationSize.partialValue),
            context: "binary typed array"
        )

        let decoded: [UInt8]
        if encoding == 0 {
            // Encoding 0: plain bytes; encoded_size must equal decoded size.
            // `readBytes` bounds `encodedSize` against the buffer, so this branch
            // can never allocate more than the file actually contains.
            if encodedSize != decodedSize {
                throw FBXError(.corruptData, "array size mismatch")
            }
            decoded = Array(try reader.readBytes(encodedSize))
        } else if encoding == 1 {
            // Encoding 1: DEFLATE; inflated output must be exactly decodedSize.
            let compressed = try reader.readBytes(encodedSize)
            // Guard the output allocation: DEFLATE cannot expand its input by more
            // than ~1032x, so any declared `decodedSize` beyond that could never be
            // produced from `encodedSize` bytes — ufbx rejects it at the inflate
            // size check; we reject before allocating to avoid a huge zero-filled
            // buffer (OOM/timeout) on malformed input. This never rejects a valid
            // stream. (`compressed.count == encodedSize`, itself bounded by the file.)
            let maxDecoded = compressed.count.multipliedReportingOverflow(by: 1032)
            if maxDecoded.overflow || decodedSize > maxDecoded.partialValue + 64 {
                throw FBXError(.badDeflate, "declared array size exceeds max DEFLATE expansion")
            }
            var out = [UInt8](repeating: 0, count: decodedSize)
            let produced = try Inflate.inflate(compressed, into: &out)
            if produced != decodedSize {
                throw FBXError(.badDeflate, "Bad DEFLATE data")
            }
            decoded = out
        } else {
            throw FBXError(.corruptData, "Bad array encoding")
        }

        let source = try readSourceArray(decoded, srcType: srcType, size: size)
        return convert(source, to: dstStorage)
    }

    /// Pre-7000 multivalue array: a run of individually-typed scalar records
    /// concatenated into one array (ufbxi_binary_parse_multivalue_array, 8767).
    private mutating func parseMultivalueArray(dstStorage: ArrayType, size: Int) throws -> FBXArrayValue {
        // String / content arrays: each record is an 'S'/'R' (u32 len + bytes).
        if dstStorage == .content || dstStorage == .string || dstStorage == .stringSanitized {
            var blob = Data()
            for _ in 0..<size {
                let type = try reader.readUInt8()
                guard type == 0x53 || type == 0x52 else { // 'S' or 'R'
                    throw FBXError(.corruptData, "bad multivalue string type")
                }
                let len = Int(try reader.readUInt32())
                try arrayBudget.claim(elements: 1, bytes: len, context: "binary string array")
                blob.append(contentsOf: try reader.readBytes(len))
            }
            return .raw(blob)
        }

        try arrayBudget.claim(
            elements: size,
            bytesPerElement: elemSize(dstStorage),
            context: "binary multivalue array"
        )

        // `size` (== num_values) is untrusted. Each element consumes at least a
        // tag byte plus payload, so the number we can actually read is bounded by
        // the remaining bytes; cap the pre-allocation to that so a huge declared
        // count cannot reserve gigabytes before the read loop hits EOF and throws.
        let reserve = Swift.max(0, Swift.min(size, reader.remaining))

        switch dstStorage {
        case .uint8:
            var a = [UInt8](); a.reserveCapacity(reserve)
            for _ in 0..<size {
                let (i, f, isFloat) = try readMultivalueScalar()
                a.append(UInt8(truncatingIfNeeded: isFloat ? FBXValue.f64ToI64(f) : i))
            }
            return .raw(Data(a))
        case .int32:
            var a = [Int32](); a.reserveCapacity(reserve)
            for _ in 0..<size {
                let (i, f, isFloat) = try readMultivalueScalar()
                a.append(isFloat ? FBXValue.f64ToI32(f) : Int32(truncatingIfNeeded: i))
            }
            return .int32(a)
        case .int64:
            var a = [Int64](); a.reserveCapacity(reserve)
            for _ in 0..<size {
                let (i, f, isFloat) = try readMultivalueScalar()
                a.append(isFloat ? FBXValue.f64ToI64(f) : i)
            }
            return .int64(a)
        case .float:
            var a = [Float](); a.reserveCapacity(reserve)
            for _ in 0..<size {
                let (i, f, isFloat) = try readMultivalueScalar()
                a.append(isFloat ? Float(f) : Float(i))
            }
            return .float(a)
        case .double, .real:
            var a = [Double](); a.reserveCapacity(reserve)
            for _ in 0..<size {
                let (i, f, isFloat) = try readMultivalueScalar()
                a.append(isFloat ? f : Double(i))
            }
            return .double(a)
        default:
            throw FBXError(.corruptData, "bad multivalue destination type")
        }
    }

    /// Read one multivalue scalar record. Returns (intValue, floatValue, isFloat)
    /// where int-family records (C/B/Y/I/L) fill intValue and float-family (F/D)
    /// fill floatValue, matching ufbx's `m_cast_int` / `m_cast_float` split.
    private mutating func readMultivalueScalar() throws -> (Int64, Double, Bool) {
        let type = try reader.readUInt8()
        switch type {
        case 0x43, 0x42:                                    // 'C', 'B'
            return (Int64(try reader.readUInt8()), 0, false)
        case 0x59:                                          // 'Y'
            return (Int64(try reader.readInt16()), 0, false)
        case 0x49:                                          // 'I'
            return (Int64(try reader.readInt32()), 0, false)
        case 0x4C:                                          // 'L'
            return (try reader.readInt64(), 0, false)
        case 0x46:                                          // 'F'
            return (0, Double(try reader.readFloat()), true)
        case 0x44:                                          // 'D'
            return (0, try reader.readDouble(), true)
        default:
            throw FBXError(.corruptData, "Bad multivalue array type")
        }
    }

    // MARK: - Scalar branch (ufbx.c:9256–9357)

    private mutating func parseScalarValues(node: FBXDocNode, count: Int,
                                            parentState: ParseState, name: String) throws {
        var values: [FBXValue] = []
        values.reserveCapacity(Swift.min(count, reader.remaining))
        for i in 0..<count {
            let type = try reader.readUInt8()
            switch type {
            case 0x43, 0x42, 0x5A:                          // 'C','B','Z' — 1-byte unsigned
                values.append(.int32(Int32(try reader.readUInt8())))
            case 0x59:                                       // 'Y' — i16
                values.append(.int32(Int32(try reader.readInt16())))
            case 0x49:                                       // 'I' — i32
                values.append(.int32(try reader.readInt32()))
            case 0x4C:                                       // 'L' — i64
                values.append(.int64(try reader.readInt64()))
            case 0x46:                                       // 'F' — f32
                values.append(.float(try reader.readFloat()))
            case 0x44:                                       // 'D' — f64
                values.append(.double(try reader.readDouble()))
            case 0x53, 0x52:                                 // 'S','R' — string
                let len = Int(try reader.readUInt32())
                let bytes = try reader.readBytes(len)
                if len == 0 {
                    values.append(.string(""))
                } else if ParseState.isRawString(parent: parentState, name: name,
                                                 valueIndex: i, version: version) {
                    // Raw path: preserve exact bytes (may hold \x00\x01 separators).
                    values.append(.raw(Data(bytes)))
                } else {
                    values.append(.string(String(decoding: bytes, as: UTF8.self)))
                }
            case 0x63, 0x62, 0x69, 0x6C, 0x66, 0x64:        // c b i l f d — array where a scalar is expected: skip it
                _ = try reader.readUInt32()                  // size
                _ = try reader.readUInt32()                  // encoding
                let encodedSize = Int(try reader.readUInt32())
                try reader.skip(encodedSize)
            default:
                throw FBXError(.corruptData, "Bad value type \(type)")
            }
        }
        node.values = values
    }

    // MARK: - Type helpers (ufbxi_normalize_array_type / _array_type_size)

    // ufbx: 'r' -> real (Double in this port), 'b' -> requested bool storage.
    private func normalize(_ t: ArrayType, bool: ArrayType) -> ArrayType {
        switch t {
        case .real: return .double
        case .bool: return bool
        default: return t
        }
    }

    // Wire array tag -> source element type. 'b' normalizes to 'c' (byte storage).
    private func normalizeSrc(_ tag: UInt8) -> ArrayType? {
        switch tag {
        case 0x63, 0x62: return .uint8      // 'c', 'b'
        case 0x69: return .int32            // 'i'
        case 0x6C: return .int64            // 'l'
        case 0x66: return .float            // 'f'
        case 0x64: return .double           // 'd'
        default: return nil
        }
    }

    private func elemSize(_ t: ArrayType) -> Int {
        switch t {
        case .uint8, .bool: return 1
        case .int32, .float: return 4
        case .int64, .double, .real: return 8
        default: return 1
        }
    }

    /// Interpret raw (file-endian) decoded bytes as the source element type.
    private func readSourceArray(_ bytes: [UInt8], srcType: ArrayType, size: Int) throws -> FBXArrayValue {
        switch srcType {
        case .uint8:
            return .raw(Data(bytes))
        case .int32:
            var r = DataReader(bytes, bigEndian: reader.bigEndian)
            var a = [Int32](); a.reserveCapacity(size)
            for _ in 0..<size { a.append(try r.readInt32()) }
            return .int32(a)
        case .int64:
            var r = DataReader(bytes, bigEndian: reader.bigEndian)
            var a = [Int64](); a.reserveCapacity(size)
            for _ in 0..<size { a.append(try r.readInt64()) }
            return .int64(a)
        case .float:
            var r = DataReader(bytes, bigEndian: reader.bigEndian)
            var a = [Float](); a.reserveCapacity(size)
            for _ in 0..<size { a.append(try r.readFloat()) }
            return .float(a)
        case .double:
            var r = DataReader(bytes, bigEndian: reader.bigEndian)
            var a = [Double](); a.reserveCapacity(size)
            for _ in 0..<size { a.append(try r.readDouble()) }
            return .double(a)
        default:
            throw FBXError(.corruptData, "bad array source type")
        }
    }

    /// Convert a source array to the destination storage type (ufbxi_binary_convert_array).
    private func convert(_ source: FBXArrayValue, to dstStorage: ArrayType) -> FBXArrayValue {
        switch dstStorage {
        case .double, .real: return .double(source.asDoubleArray())
        case .float: return .float(source.asFloatArray())
        case .int32: return .int32(source.asInt32Array())
        case .int64: return .int64(source.asInt64Array())
        case .uint8:
            if case .raw = source { return source }
            return .raw(Data(source.asInt32Array().map { UInt8(truncatingIfNeeded: $0) }))
        default:
            return source
        }
    }

    private func emptyArray(dstStorage: ArrayType) -> FBXArrayValue {
        switch dstStorage {
        case .double, .real: return .double([])
        case .float: return .float([])
        case .int32: return .int32([])
        case .int64: return .int64([])
        default: return .raw(Data())
        }
    }
}
