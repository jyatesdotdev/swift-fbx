import Foundation

// Streaming lexer for text-form FBX files (ASCII 6100-7700). Direct port of the
// `ufbxi_ascii_*` tokenizer (ufbx.c:9404-9908). ufbx's buffered/streaming IO
// layer (`ufbxi_ascii_refill`/`_yield`, retained buffers, progress callbacks,
// span capture, thread pool) is collapsed: the whole file is in memory as a
// `[UInt8]`, so `peek`/`next` are plain index reads and the fast comma-array
// readers / deferred span machinery are dropped — the token-by-token grammar in
// AsciiParser reproduces the identical result for in-memory data (notes 03).

// ufbx: token category codes (ufbx.c:9406-9411). Punctuation tokens carry their
// literal byte as `type`; none of the punctuation bytes collide with these.
enum AsciiTokenKind {
    static let end: UInt8 = 0            // '\0'
    static let name: UInt8 = 0x4E        // 'N'
    static let bareWord: UInt8 = 0x42    // 'B'
    static let int: UInt8 = 0x49         // 'I'
    static let float: UInt8 = 0x46       // 'F'
    static let string: UInt8 = 0x53      // 'S'
}

/// One lexer token. Mirrors `ufbxi_ascii_token` (ufbx.c:6248-6272). For NAME the
/// identifier bytes are in `data`; for STRING/BARE_WORD the (unescaped) contents;
/// for INT/FLOAT the parsed value lives in `i64`/`f64` (`data` holds the raw
/// digits, without ufbx's trailing NUL terminator).
struct AsciiToken {
    var type: UInt8 = AsciiTokenKind.end
    var data: [UInt8] = []
    var i64: Int64 = 0
    var f64: Double = 0
    // ufbx: preserved so the value path can reconstruct `-0.0` from an int token.
    var negative: Bool = false
}

final class AsciiTokenizer {
    private let bytes: [UInt8]
    private var src: Int
    private let end: Int

    /// Lookahead token (`ua->token`) and the just-consumed token (`ua->prev_token`).
    var current = AsciiToken()
    var previous = AsciiToken()

    // ufbx: lexer state fields on `ufbxi_ascii`/`ufbxi_context` consumed downstream.
    private var readFirstComment = false
    var foundVersion = false
    var version = 0
    var parseAsF32 = false
    var isBlenderAscii = false

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.src = 0
        self.end = bytes.count
    }

    // MARK: - Byte cursor (ufbxi_ascii_peek/_next collapsed to index reads)

    @inline(__always) private func peekByte() -> UInt8 {
        src < end ? bytes[src] : 0
    }

    @inline(__always) private func nextByte() -> UInt8 {
        if src < end { src += 1 }
        return src < end ? bytes[src] : 0
    }

    // MARK: - Character classes

    @inline(__always) private func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
    }
    @inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) private func isAlpha(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
    // ufbx: bare words may contain '-', '(', ')' (ufbx.c:9755-9756).
    @inline(__always) private func isBareChar(_ c: UInt8) -> Bool {
        isAlpha(c) || isDigit(c) || c == 0x5F || c == 0x2D || c == 0x28 || c == 0x29
    }
    // [0-9-+.eE]
    @inline(__always) private func isNumChar(_ c: UInt8) -> Bool {
        isDigit(c) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45
    }
    // ufbx: trailing "nan-like" run [A-Za-z0-9#()] (ufbx.c:9781).
    @inline(__always) private func isNanChar(_ c: UInt8) -> Bool {
        isAlpha(c) || isDigit(c) || c == 0x23 || c == 0x28 || c == 0x29
    }

    // MARK: - Version magic comment (ufbxi_ascii_parse_version, ufbx.c:9497)

    private static let versionFmt: [UInt8] = Array(" FBX ?.?.?".utf8)
    private static let blenderPrefix: [UInt8] = Array(" Created by Blender".utf8)

    private func parseVersion() -> UInt32 {
        var digits: [UInt8] = [0, 0, 0]
        var numDigits = 0
        var c = nextByte()
        var ix = 0
        let fmt = AsciiTokenizer.versionFmt
        while numDigits < 3 {
            let ref = fmt[ix]; ix += 1
            if ref == 0x3F {                 // '?' — one decimal digit
                if !isDigit(c) { return 0 }
                digits[numDigits] = c - 0x30
                numDigits += 1
                c = nextByte()
            } else if ref == 0x20 {          // ' ' — skip spaces/tabs
                while c == 0x20 || c == 0x09 { c = nextByte() }
            } else {                         // literal
                if c != ref { return 0 }
                c = nextByte()
            }
        }
        return 1000 &* UInt32(digits[0]) &+ 100 &* UInt32(digits[1]) &+ 10 &* UInt32(digits[2])
    }

    // MARK: - Whitespace & comments (ufbxi_ascii_skip_whitespace, ufbx.c:9552)

    private func skipWhitespace() -> UInt8 {
        var c = peekByte()
        while true {
            while isSpace(c) { c = nextByte() }
            if c == 0x3B {                   // ';' line comment
                var readMagic = false
                if !readFirstComment {
                    readFirstComment = true
                    let v = parseVersion()
                    if v != 0 {
                        version = Int(v)
                        foundVersion = true
                        readMagic = true
                    }
                }
                c = nextByte()
                while c != 0x0A && c != 0 { c = nextByte() }
                c = nextByte()
                // ufbx: if we just read the magic and the next line is also a
                // comment, sniff " Created by Blender" (Blender-6100 fixups).
                if readMagic && c == 0x3B {
                    var line: [UInt8] = []
                    c = nextByte()
                    while c != 0x0A && c != 0 {
                        if line.count < 32 { line.append(c) }
                        c = nextByte()
                    }
                    if line.count >= 19 && Array(line[0..<19]) == AsciiTokenizer.blenderPrefix {
                        isBlenderAscii = true
                    }
                }
            } else {
                break
            }
        }
        return c
    }

    // MARK: - skip_until (ufbxi_ascii_skip_until, ufbx.c:9639)

    /// Advance `src` forward to the next byte `dst` (left positioned AT it).
    /// Throws on EOF, mirroring ufbx's `ufbxi_check(c != '\0')`.
    func skipUntil(_ dst: UInt8) throws {
        while src < end && bytes[src] != dst { src += 1 }
        if src >= end { throw FBXError(.truncatedFile, "Unterminated ASCII array/string") }
    }

    // MARK: - try_ignore_string (ufbxi_ascii_try_ignore_string, ufbx.c:9710)

    /// If the next token is a `"`-string, install it as `current` (a STRING with
    /// its body skipped, not interned) and return true. Used to drop an embedded
    /// `Content` value after a leading comma when the array is ignored.
    func tryIgnoreString() throws -> Bool {
        let c = skipWhitespace()
        if c == 0x22 {                       // '"'
            previous = current
            _ = nextByte()                   // skip opening quote
            try skipUntil(0x22)
            _ = nextByte()                   // skip closing quote
            current = AsciiToken(type: AsciiTokenKind.string)
            return true
        }
        return false
    }

    // MARK: - The tokenizer (ufbxi_ascii_next_token, ufbx.c:9738)

    /// Parse the next token into `current`; the old `current` becomes `previous`.
    func nextToken() throws {
        previous = current
        var token = AsciiToken()
        var c = skipWhitespace()

        if isAlpha(c) || c == 0x5F {
            // Bare word / name
            token.type = AsciiTokenKind.bareWord
            while isBareChar(c) {
                token.data.append(c)
                c = nextByte()
            }
            c = skipWhitespace()
            if c == 0x3A {                   // ':' — retype to NAME
                token.type = AsciiTokenKind.name
                _ = nextByte()
            }
        } else if isDigit(c) || c == 0x2D || c == 0x2B || c == 0x2E {
            // Number
            token.type = AsciiTokenKind.int
            token.negative = (c == 0x2D)
            while isNumChar(c) {
                if c == 0x2E || c == 0x65 || c == 0x45 { token.type = AsciiTokenKind.float }
                token.data.append(c)
                c = nextByte()
            }
            var nanLike = false
            while isNanChar(c) {
                nanLike = true
                token.data.append(c)
                c = nextByte()
            }
            if nanLike { token.type = AsciiTokenKind.float }

            if token.type == AsciiTokenKind.int {
                guard let (v, consumed) = FloatParse.parseInt64(token.data[...]),
                      consumed == token.data.count else {
                    throw FBXError(.asciiSyntax, "Bad integer literal")
                }
                token.i64 = v
            } else {
                let flags: FloatParse.Flags = parseAsF32 ? .asBinary32 : .allowFastPath
                let (v, consumed) = FloatParse.parseDouble(token.data[...], flags: flags)
                guard consumed == token.data.count else {
                    throw FBXError(.asciiSyntax, "Bad float literal")
                }
                token.f64 = v
            }
        } else if c == 0x22 {
            // Quoted string
            token.type = AsciiTokenKind.string
            c = nextByte()
            while c != 0x22 {
                if c == 0x26 {               // '&' XML-like escape
                    c = try appendEscape(&token, first: c)
                    continue
                }
                if c == 0 { throw FBXError(.asciiSyntax, "Unterminated string") }
                token.data.append(c)
                c = nextByte()
            }
            let next = nextByte()            // skip closing quote
            // ufbx: legacy names with spaces, e.g. `"Transport Tool Settings":`.
            if next == 0x3A {
                token.type = AsciiTokenKind.name
                _ = nextByte()
            }
        } else {
            // Single-character punctuation token
            token.type = c
            _ = nextByte()
        }

        current = token
    }

    // ufbx: `&quot;`->`"`, `&cr;`->`\r`, `&lf;`->`\n`; any other `&...` is emitted
    // literally char-by-char (there is deliberately no `&amp;`) (ufbx.c:9827-9871).
    private func appendEscape(_ token: inout AsciiToken, first: UInt8) throws -> UInt8 {
        var c = nextByte()                   // char after '&'
        let entity: [UInt8]
        let replacement: UInt8
        switch c {
        case 0x71: entity = [0x26, 0x71, 0x75, 0x6F, 0x74, 0x3B]; replacement = 0x22 // "&quot;" -> '"'
        case 0x63: entity = [0x26, 0x63, 0x72, 0x3B];             replacement = 0x0D // "&cr;"  -> '\r'
        case 0x6C: entity = [0x26, 0x6C, 0x66, 0x3B];             replacement = 0x0A // "&lf;"  -> '\n'
        default:   entity = [0x26];                               replacement = 0x26 // '&' -> '&'
        }
        var step = 1
        while step < entity.count {
            if c != entity[step] { break }
            c = nextByte()
            step += 1
        }
        if step == entity.count {
            token.data.append(replacement)
        } else {
            for i in 0..<step { token.data.append(entity[i]) }
        }
        return c
    }
}
