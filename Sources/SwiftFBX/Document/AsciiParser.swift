import Foundation

// ASCII FBX grammar driver: turns the AsciiTokenizer stream into the same
// `FBXDocNode` tree the binary parser produces. Direct port of
// `ufbxi_ascii_parse_node` + the ASCII entry path of `ufbxi_begin_parse`
// (ufbx.c:10285-10694, 11193-11276) with the streaming/threading machinery
// removed (notes 03). Shares node classification with the binary parser via
// `ParseState` and number parsing via `FloatParse`.
//
// Entry API (mirrors BinaryParser.parseBinaryDocument; the DocumentParser drives
// both: detect format -> parse header/version -> iterate top-level nodes):
//   AsciiParser.parseAsciiDocument(_ bytes:...) throws -> FBXDocument
//
// Non-fatal issues discovered while parsing (bad base64 content) are collected
// on the parser instance. FBXDocument has no warnings channel, so they are
// dropped by the top-level `parse`; a Loader that needs them can call the
// instance path instead (see report).

// ufbx: UFBXI_MAX_NODE_DEPTH (ufbx.c:52).
private let maxNodeDepth = 32

final class AsciiParser {
    private let tok: AsciiTokenizer
    private let sureFbx: Bool
    private let options: ParseOptions
    private let arrayBudget: FBXDecodedArrayBudget

    // The classifier option gates (parallels BinaryParser's parameters).
    struct ParseOptions {
        var ignoreGeometry = false
        var ignoreAnimation = false
        var ignoreEmbedded = false
        var retainDom = false
        var retainVertexW = false
        var blenderFullWeights = false
    }

    /// Bad-base64 warnings collected during parse (ufbx.c:10276).
    private(set) var warnings: [FBXWarning] = []

    private init(tokenizer: AsciiTokenizer, sureFbx: Bool, options: ParseOptions,
                 arrayBudget: FBXDecodedArrayBudget) {
        self.tok = tokenizer
        self.sureFbx = sureFbx
        self.options = options
        self.arrayBudget = arrayBudget
    }

    // ufbx: version is read live by the classifier (a `FBXVersion:` node can set
    // it mid-parse when there was no magic comment), so build the context fresh.
    private func context() -> ParseContext {
        ParseContext(version: tok.version, fromAscii: true,
                     ignoreGeometry: options.ignoreGeometry,
                     ignoreAnimation: options.ignoreAnimation,
                     ignoreEmbedded: options.ignoreEmbedded,
                     retainDom: options.retainDom,
                     retainVertexW: options.retainVertexW,
                     blenderFullWeights: options.blenderFullWeights)
    }

    // MARK: - Entry point (ufbxi_begin_parse ASCII branch, ufbx.c:11218-11237)

    /// Parse an in-memory ASCII FBX file. The caller (DocumentParser) has already
    /// determined the buffer is not a binary FBX. `nil` is never returned — an
    /// ASCII sniff failure throws `.unrecognizedFileFormat`.
    static func parseAsciiDocument(_ bytes: [UInt8],
                                   ignoreGeometry: Bool = false,
                                   ignoreAnimation: Bool = false,
                                   ignoreEmbedded: Bool = false,
                                   retainDom: Bool = false,
                                   retainVertexW: Bool = false,
                                   blenderFullWeights: Bool = false,
                                   arrayBudget: FBXDecodedArrayBudget = FBXDecodedArrayBudget(options: .init())) throws -> FBXDocument {
        let tokenizer = AsciiTokenizer(bytes: bytes)
        // Prime the first token; the magic comment (and its version) is consumed
        // by skip_whitespace during this call.
        try tokenizer.nextToken()

        let sure: Bool
        if tokenizer.version > 0 {
            sure = true
        } else {
            // ufbx: default to 7400 when no magic comment (v1 is never `strict`).
            tokenizer.version = 7400
            sure = false
        }

        let options = ParseOptions(ignoreGeometry: ignoreGeometry,
                                   ignoreAnimation: ignoreAnimation,
                                   ignoreEmbedded: ignoreEmbedded,
                                   retainDom: retainDom,
                                   retainVertexW: retainVertexW,
                                   blenderFullWeights: blenderFullWeights)
        let parser = AsciiParser(tokenizer: tokenizer, sureFbx: sure, options: options,
                                 arrayBudget: arrayBudget)
        let root = FBXDocNode(name: "")
        var children: [FBXDocNode] = []
        while let node = try parser.parseNode(depth: 0, parentState: .root) {
            children.append(node)
        }
        root.children = children

        return FBXDocument(version: tokenizer.version, format: .ascii, bigEndian: false, root: root)
    }

    // MARK: - accept / expect (ufbxi_ascii_accept, ufbx.c:9898)

    @inline(__always) private func accept(_ type: UInt8) throws -> Bool {
        if tok.current.type == type {
            try tok.nextToken()
            return true
        }
        return false
    }

    private func expect(_ type: UInt8, _ message: String) throws {
        if !(try accept(type)) {
            throw FBXError(.asciiSyntax, message)
        }
    }

    // MARK: - Node grammar (ufbxi_ascii_parse_node, ufbx.c:10285)

    /// Parse one node (and, recursively, its children). Returns `nil` when the
    /// current token closes the parent's child list (`}` or end-of-file).
    func parseNode(depth: Int, parentState: ParseState) throws -> FBXDocNode? {
        if tok.current.type == 0x7D {                    // '}'
            try tok.nextToken()
            return nil
        }
        if tok.current.type == AsciiTokenKind.end {
            guard depth == 0 else { throw FBXError(.truncatedFile, "Truncated file") }
            return nil
        }

        guard depth < maxNodeDepth else { throw FBXError(.nodeDepthLimit, "Node depth limit exceeded") }

        // ufbx: ASCII content sniff — if not sure this is FBX, the first
        // top-level token must be a `Name:`.
        if !sureFbx && depth == 0 && tok.current.type != AsciiTokenKind.name {
            throw FBXError(.unrecognizedFileFormat, "Not an FBX file")
        }
        try expect(AsciiTokenKind.name, "Expected a 'Name:' token")

        let nameBytes = tok.previous.data
        guard nameBytes.count <= 0xFF else { throw FBXError(.asciiSyntax, "Node name too long") }
        let name = String(decoding: nameBytes, as: UTF8.self)

        // Array classification (resolved before any payload byte is consumed).
        let arrInfo = ParseState.arrayInfo(parent: parentState, name: name, context: context())
        var arrType: UInt8 = 0
        if let info = arrInfo {
            arrType = AsciiParser.normalizeArrayType(info.type)
            if info.flags.contains(.accurateF32) { tok.parseAsF32 = true }
        }

        // ufbx: leading-comma fields, e.g. `Content: , "base64-string"`.
        if tok.current.type == 0x2C {                    // ','
            if arrType == 0x2D {                         // '-' ignored array
                if !(try tok.tryIgnoreString()) { try tok.nextToken() }
            } else {
                try tok.nextToken()
            }
        }

        let parseState = ParseState.update(parent: parentState, name: name)

        // Accumulators.
        var values: [FBXValue] = []
        var boolArr: [Bool] = []
        var byteArr: [UInt8] = []
        var i32Arr: [Int32] = []
        var i64Arr: [Int64] = []
        var f32Arr: [Float] = []
        var f64Arr: [Double] = []
        var strArr: [[UInt8]] = []
        var arrError = false
        var numValues = 0
        var inAsciiArray = false

        valueLoop: while true {
            if try accept(AsciiTokenKind.string) {
                let t = tok.previous
                if arrType != 0 {
                    switch arrType {
                    case 0x43:                           // 'C' — base64 content
                        try decodeBase64(t.data, into: &byteArr, failed: &arrError)
                    case 0x73, 0x53:                     // 's'/'S' — string array
                        try arrayBudget.claim(
                            elements: 1,
                            bytes: t.data.count,
                            context: "ASCII string array"
                        )
                        strArr.append(t.data)
                    default:
                        numValues -= 1                   // ignore string in numeric array
                    }
                } else if numValues < 8 {
                    values.append(makeStringValue(t.data, parent: parentState, name: name, index: numValues))
                }
            } else if try accept(AsciiTokenKind.int) {
                let t = tok.previous
                let val = t.i64
                try claimNumericArrayValue(type: arrType)
                switch arrType {
                case 0:
                    // ufbx: version fallback from the `FBXVersion:` integer node.
                    if !tok.foundVersion && parseState == .fbxVersion && numValues == 0
                        && val >= 6000 && val <= 10000 {
                        tok.foundVersion = true
                        tok.version = Int(val)
                    }
                    if numValues < 8 {
                        // ufbx: `fsign = !val && negative ? -1 : 1; v->f = (double)(v->i = val) * fsign`
                        // (ufbx.c:10466-10469) — a literal `-0` keeps i=0 AND f=-0.0.
                        // `.double(-0.0)` reproduces that dual view (asInt64 == 0,
                        // asDouble == -0.0); mirrors the 'f'/'d' array cases below.
                        if val == 0 && t.negative {
                            values.append(.double(-0.0))
                        } else {
                            values.append(.int64(val))
                        }
                    }
                case 0x62: boolArr.append(val != 0)                                    // 'b'
                case 0x63: byteArr.append(UInt8(truncatingIfNeeded: val))              // 'c'
                case 0x69: i32Arr.append(Int32(truncatingIfNeeded: val))              // 'i'
                case 0x6C: i64Arr.append(val)                                          // 'l'
                case 0x66:                                                             // 'f'
                    let fsign: Float = (val == 0 && t.negative) ? -1 : 1
                    f32Arr.append(Float(val) * fsign)
                case 0x64:                                                             // 'd'
                    let dsign: Double = (val == 0 && t.negative) ? -1 : 1
                    f64Arr.append(Double(val) * dsign)
                case 0x2D: numValues -= 1                                              // '-'
                default: throw FBXError(.asciiSyntax, "Bad array dst type")
                }
            } else if try accept(AsciiTokenKind.float) {
                let val = tok.previous.f64
                try claimNumericArrayValue(type: arrType)
                switch arrType {
                case 0:
                    if numValues < 8 { values.append(.double(val)) }
                case 0x62: boolArr.append(val != 0)                                    // 'b'
                case 0x63: byteArr.append(UInt8(truncatingIfNeeded: FBXValue.f64ToI64(val))) // 'c'
                case 0x69: i32Arr.append(FBXValue.f64ToI32(val))                       // 'i'
                case 0x6C: i64Arr.append(FBXValue.f64ToI64(val))                       // 'l'
                case 0x66: f32Arr.append(Float(val))                                   // 'f'
                case 0x64: f64Arr.append(val)                                          // 'd'
                case 0x2D: numValues -= 1                                              // '-'
                default: throw FBXError(.asciiSyntax, "Bad array dst type")
                }
            } else if try accept(AsciiTokenKind.bareWord) {
                let t = tok.previous
                var val: Int64 = 0
                var valF: Double = 0
                if let first = t.data.first {
                    val = Int64(first)
                    valF = Double(val)
                    // ufbx: bare `inf`/`nan`/`infinity`/MSVC `1.#IND` words become floats.
                    if t.data.count > 1 && t.data.count < 64 {
                        let (f, consumed) = FloatParse.parseDouble(t.data[...], flags: .allowFastPath)
                        if consumed == t.data.count && (f.isInfinite || f.isNaN) {
                            val = 0
                            valF = f
                        }
                    }
                }
                try claimNumericArrayValue(type: arrType)
                switch arrType {
                case 0:
                    if numValues < 8 { values.append(.int64(val)) }
                case 0x62: boolArr.append(val != 0)                                    // 'b'
                case 0x63: byteArr.append(UInt8(truncatingIfNeeded: val))              // 'c'
                case 0x69: i32Arr.append(Int32(truncatingIfNeeded: val))              // 'i'
                case 0x6C: i64Arr.append(val)                                          // 'l'
                case 0x66: f32Arr.append(Float(valF))                                  // 'f'
                case 0x64: f64Arr.append(valF)                                         // 'd'
                case 0x2D: numValues -= 1                                              // '-'
                default: throw FBXError(.asciiSyntax, "Bad array dst type")
                }
            } else if try accept(0x2A) {                 // '*' post-7000 array syntax
                guard !inAsciiArray else { throw FBXError(.asciiSyntax, "Nested ASCII array") }
                try expect(AsciiTokenKind.int, "Expected array count")
                if try accept(0x7B) {                    // '{'
                    try expect(AsciiTokenKind.name, "Expected array element name")
                    inAsciiArray = true
                    // ufbx: ignored arrays skip their whole body to '}'. The
                    // non-ignored body is parsed by the following loop iterations
                    // (threaded/deferred span parsing is out of scope, notes 03).
                    if arrType == 0x2D {                 // '-'
                        try tok.skipUntil(0x7D)
                    }
                }
                continue valueLoop                       // skip num_values++/comma
            } else {
                break valueLoop
            }

            numValues += 1
            if !(try accept(0x2C)) { break valueLoop }   // ','
        }

        if inAsciiArray {
            try expect(0x7D, "Expected '}' to close ASCII array")
        }
        tok.parseAsF32 = false

        let node = FBXDocNode(name: name)
        if arrType != 0 {
            node.array = try finalizeArray(arrType: arrType, arrError: arrError,
                                           boolArr: boolArr, byteArr: byteArr,
                                           i32Arr: i32Arr, i64Arr: i64Arr,
                                           f32Arr: f32Arr, f64Arr: f64Arr, strArr: strArr)
        } else {
            node.values = values
        }

        // Children.
        if try accept(0x7B) {                            // '{'
            var children: [FBXDocNode] = []
            while let child = try parseNode(depth: depth + 1, parentState: parseState) {
                children.append(child)
            }
            node.children = children
        }

        return node
    }

    // MARK: - Array finalization (ufbxi_ascii_parse_node, ufbx.c:10606-10662)

    private func finalizeArray(arrType: UInt8, arrError: Bool,
                               boolArr: [Bool], byteArr: [UInt8],
                               i32Arr: [Int32], i64Arr: [Int64],
                               f32Arr: [Float], f64Arr: [Double],
                               strArr: [[UInt8]]) throws -> FBXArrayValue {
        // ufbx: ignored ('-') or bad-base64 arrays materialize as size 0.
        if arrType == 0x2D { return .raw(Data()) }
        if arrError { return .raw(Data()) }

        switch arrType {
        case 0x62: return .bool(boolArr)                 // 'b'
        case 0x63: return .raw(Data(byteArr))            // 'c'
        case 0x43: return .raw(Data(byteArr))            // 'C'
        case 0x69: return .int32(i32Arr)                 // 'i'
        case 0x6C: return .int64(i64Arr)                 // 'l'
        case 0x66: return .float(f32Arr)                 // 'f'
        case 0x64: return .double(f64Arr)                // 'd'
        case 0x73, 0x53:                                 // 's'/'S' — see report DEVIATION
            let separatorBytes = Swift.max(0, strArr.count - 1)
            try arrayBudget.claim(
                elements: 0,
                bytes: separatorBytes,
                context: "ASCII string array separators"
            )
            var joined: [UInt8] = []
            for (idx, s) in strArr.enumerated() {
                if idx > 0 { joined.append(0) }
                joined.append(contentsOf: s)
            }
            return .raw(Data(joined))
        default:
            return .raw(Data())
        }
    }

    // ufbx: ufbxi_normalize_array_type(type, 'b') — 'r'->'d' (ufbx_real==double),
    // 'b' stays 'b' (ufbx.c:7686).
    private static func normalizeArrayType(_ type: ArrayType) -> UInt8 {
        switch type {
        case .real: return 0x64                          // 'd'
        case .bool: return 0x62                          // 'b'
        default: return type.rawValue
        }
    }

    /// Claims one numeric value before its typed accumulator can grow.
    private func claimNumericArrayValue(type: UInt8) throws {
        switch type {
        case 0, 0x2D: return                               // scalar / ignored array
        case 0x62, 0x63:                                  // 'b', 'c'
            try arrayBudget.claim(elements: 1, bytes: 1, context: "ASCII numeric array")
        case 0x69, 0x66:                                  // 'i', 'f'
            try arrayBudget.claim(elements: 1, bytes: 4, context: "ASCII numeric array")
        case 0x6C, 0x64:                                  // 'l', 'd'
            try arrayBudget.claim(elements: 1, bytes: 8, context: "ASCII numeric array")
        default:
            throw FBXError(.asciiSyntax, "Bad array dst type")
        }
    }

    // MARK: - String value storage (ufbxi_ascii_parse_node STRING branch)

    /// Non-array scalar string. Per DESIGN, raw-string paths (`isRawString`)
    /// preserve bytes as `Data`; everything else is UTF-8 sanitized. This is
    /// observationally identical to ufbx's `raw = !non_ascii || is_raw_string`
    /// (a pure-ASCII value round-trips the same through `.string`).
    private func makeStringValue(_ data: [UInt8], parent: ParseState, name: String, index: Int) -> FBXValue {
        if data.isEmpty { return .string("") }
        if ParseState.isRawString(parent: parent, name: name, valueIndex: index, version: tok.version) {
            return .raw(Data(data))
        }
        return .string(String(decoding: data, as: UTF8.self))
    }

    // MARK: - base64 (ufbxi_setup_base64 / ufbxi_decode_base64, ufbx.c:10224-10282)

    private static let base64Table: [UInt8] = {
        var t = [UInt8](repeating: 0x80, count: 256)
        for c in 0x41...0x5A { t[c] = UInt8(c - 0x41) }          // 'A'-'Z'
        for c in 0x61...0x7A { t[c] = UInt8(26 + (c - 0x61)) }   // 'a'-'z'
        for c in 0x30...0x39 { t[c] = UInt8(52 + (c - 0x30)) }   // '0'-'9'
        t[0x2B] = 62                                             // '+'
        t[0x2F] = 63                                             // '/'
        t[0x3D] = 0x40                                           // '='
        return t
    }()

    private func decodeBase64(_ src: [UInt8], into out: inout [UInt8],
                              failed: inout Bool) throws {
        let table = AsciiParser.base64Table
        let n = src.count
        var errorMask: UInt32 = 0
        var padError: UInt32 = 0
        let decodedBytes = (n / 4).multipliedReportingOverflow(by: 3)
        guard !decodedBytes.overflow else {
            throw FBXError(.resourceLimit, "base64 decoded byte count overflow")
        }
        try arrayBudget.claim(
            elements: decodedBytes.partialValue,
            bytes: decodedBytes.partialValue,
            context: "ASCII base64 content"
        )
        let capacity = out.count.addingReportingOverflow(decodedBytes.partialValue)
        guard !capacity.overflow else {
            throw FBXError(.resourceLimit, "base64 output capacity overflow")
        }
        out.reserveCapacity(capacity.partialValue)

        var i = 0
        while i + 4 <= n {
            let a = UInt32(table[Int(src[i + 0])])
            let b = UInt32(table[Int(src[i + 1])])
            let c = UInt32(table[Int(src[i + 2])])
            let d = UInt32(table[Int(src[i + 3])])
            padError = errorMask
            errorMask |= a | b | c | d
            out.append(UInt8(truncatingIfNeeded: (a << 2) | (b >> 4)))
            out.append(UInt8(truncatingIfNeeded: (b << 4) | (c >> 2)))
            out.append(UInt8(truncatingIfNeeded: (c << 6) | d))
            i += 4
        }

        if n >= 4 {
            var padding = 0
            if src[n - 4] == 0x3D { padding |= 0x8 }
            if src[n - 3] == 0x3D { padding |= 0x4 }
            if src[n - 2] == 0x3D { padding |= 0x2 }
            if src[n - 1] == 0x3D { padding |= 0x1 }
            if padding <= 0x1 {
                if padding == 1 && !out.isEmpty { out.removeLast(1) }
            } else if padding == 0x3 {
                out.removeLast(min(2, out.count))
            } else {
                padError |= 0x40
            }
        }

        if ((errorMask & 0x80) != 0 || (padError & 0x40) != 0 || n % 4 != 0) && !failed {
            warnings.append(FBXWarning(kind: .badBase64Content, info: "Ignored bad base64 embedded content"))
            failed = true
        }
    }
}
