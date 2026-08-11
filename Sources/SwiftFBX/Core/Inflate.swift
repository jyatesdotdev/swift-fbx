import Foundation

// Pure-Swift DEFLATE / zlib decompressor. Port of `ufbx_inflate` (ufbx.c:1849-3280),
// simplified per the notes: the streaming read_fn/chunk/progress/cancellation
// machinery is dropped (input is always a single in-memory buffer) and ufbx's
// two-level fast+long+sorted Huffman tables are collapsed into a single canonical
// per-symbol lookup table — exactly equivalent on all inputs, per-symbol table
// lookup (no linear scans). Behavior matches ufbx: zlib CMF/FLG validation,
// stored/fixed/dynamic blocks, length/distance decode with overlapping-match
// byte-by-byte copy for short distances, output capacity limit, Adler-32 verify.
//
// API:
//   Inflate.inflate(_ input:into:) throws -> Int
// `output` must already have `output.count == capacity` (the known decompressed
// size); the function writes the produced bytes into it and returns their count.
enum Inflate {

    // MARK: RFC 1951 length/distance tables

    // Length codes 257..285 (index = symbol - 257).
    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    // Distance codes 0..29.
    private static let distBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    private static let distExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    // ufbx: RFC 1951 code-length-alphabet transmission order.
    private static let codeLengthPermutation: [Int] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    // MARK: Huffman table (single-level canonical decode)

    struct HuffTable {
        var table: [UInt32] // entry = (codeLength << 16) | symbol; codeLength 0 == invalid slot
        var mask: UInt32    // (1 << maxBits) - 1
        var maxBits: Int    // 0 == empty tree
    }

    private static func reverseBits(_ value: UInt32, _ count: Int) -> UInt32 {
        var x = value
        var r: UInt32 = 0
        var i = 0
        while i < count { r = (r << 1) | (x & 1); x >>= 1; i += 1 }
        return r
    }

    // Builds a canonical Huffman table, validating over/under-subscription like
    // ufbx (single-symbol trees allowed to be incomplete, per RFC 1951).
    static func buildTable(_ lengths: [UInt8], count: Int) throws -> HuffTable {
        var blCount = [Int](repeating: 0, count: 16)
        var maxBits = 0
        var nonzero = 0
        var i = 0
        while i < count {
            let l = Int(lengths[i])
            if l > 0 {
                if l > 15 { throw FBXError(.badDeflate, "code length > 15") }
                blCount[l] += 1
                nonzero += 1
                if l > maxBits { maxBits = l }
            }
            i += 1
        }
        if maxBits == 0 {
            return HuffTable(table: [], mask: 0, maxBits: 0)
        }

        // Over/under-subscription check (Kraft inequality).
        var left = 1
        var bits = 1
        while bits <= maxBits {
            left <<= 1
            left -= blCount[bits]
            if left < 0 { throw FBXError(.badDeflate, "over-subscribed huffman tree") }
            bits += 1
        }
        // left > 0 == incomplete: only legal for the single-code tree.
        if left > 0 && nonzero > 1 {
            throw FBXError(.badDeflate, "incomplete huffman tree")
        }

        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        bits = 1
        while bits <= maxBits {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
            bits += 1
        }

        let size = 1 << maxBits
        var table = [UInt32](repeating: 0, count: size)
        i = 0
        while i < count {
            let l = Int(lengths[i])
            if l != 0 {
                let c = nextCode[l]
                nextCode[l] += 1
                let rev = Int(reverseBits(UInt32(c), l))
                let entry = (UInt32(l) << 16) | UInt32(i)
                let step = 1 << l
                var idx = rev
                while idx < size {
                    table[idx] = entry
                    idx += step
                }
            }
            i += 1
        }
        return HuffTable(table: table, mask: UInt32(size - 1), maxBits: maxBits)
    }

    // MARK: Static (fixed) Huffman trees, built once and reused.

    private struct StaticTrees { let lit: HuffTable; let dist: HuffTable }
    private static let staticTrees: StaticTrees = {
        var litLen = [UInt8](repeating: 0, count: 288)
        for i in 0..<144 { litLen[i] = 8 }
        for i in 144..<256 { litLen[i] = 9 }
        for i in 256..<280 { litLen[i] = 7 }
        for i in 280..<288 { litLen[i] = 8 }
        let distLen = [UInt8](repeating: 5, count: 32)
        // Fixed code lengths are always valid.
        return StaticTrees(lit: try! buildTable(litLen, count: 288),
                           dist: try! buildTable(distLen, count: 32))
    }()

    // MARK: Bit reader (LSB-first over one contiguous buffer)

    private struct BitReader {
        let buf: UnsafePointer<UInt8>
        let end: Int
        var pos: Int = 0
        var bits: UInt64 = 0
        var count: Int = 0

        mutating func refill() {
            while count <= 56 && pos < end {
                bits |= UInt64(buf[pos]) << UInt64(count)
                count += 8
                pos += 1
            }
        }

        mutating func getBits(_ n: Int) throws -> UInt32 {
            if n == 0 { return 0 }
            if count < n {
                refill()
                if count < n { throw FBXError(.badDeflate, "unexpected end of stream") }
            }
            let v = UInt32(truncatingIfNeeded: bits & ((UInt64(1) << UInt64(n)) - 1))
            bits >>= UInt64(n)
            count -= n
            return v
        }

        mutating func decode(_ t: HuffTable) throws -> Int {
            if t.maxBits == 0 { throw FBXError(.badDeflate, "decode from empty tree") }
            refill()
            let idx = Int(bits & UInt64(t.mask))
            let entry = t.table[idx]
            let len = Int(entry >> 16)
            if len == 0 || len > count { throw FBXError(.badDeflate, "invalid huffman code") }
            bits >>= UInt64(len)
            count -= len
            return Int(entry & 0xFFFF)
        }

        mutating func alignToByte() {
            let drop = count & 7
            bits >>= UInt64(drop)
            count -= drop
        }

        // Assumes byte alignment (count is a multiple of 8).
        mutating func readByte() throws -> UInt8 {
            if count >= 8 {
                let b = UInt8(truncatingIfNeeded: bits)
                bits >>= 8
                count -= 8
                return b
            }
            if pos < end {
                let b = buf[pos]
                pos += 1
                return b
            }
            throw FBXError(.badDeflate, "unexpected end of stream")
        }
    }

    // MARK: Adler-32

    static func adler32(_ data: ArraySlice<UInt8>) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let mod: UInt32 = 65521
        data.withUnsafeBufferPointer { buf in
            var i = 0
            let n = buf.count
            while i < n {
                let chunkEnd = min(i + 5552, n)
                while i < chunkEnd {
                    a &+= UInt32(buf[i])
                    b &+= a
                    i += 1
                }
                a %= mod
                b %= mod
            }
        }
        return (b << 16) | a
    }

    // MARK: Entry point

    static func inflate(_ input: ArraySlice<UInt8>, into output: inout [UInt8],
                        noHeader: Bool = false, noChecksum: Bool = false) throws -> Int {
        let capacity = output.count
        return try input.withUnsafeBufferPointer { inBuf -> Int in
            guard let base = inBuf.baseAddress else {
                throw FBXError(.badDeflate, "empty input")
            }
            var reader = BitReader(buf: base, end: inBuf.count)

            if !noHeader {
                let cmf = try Int(reader.readByte())
                let flg = try Int(reader.readByte())
                // ufbx: CMF&0xF==8 (DEFLATE), CINFO<=7, FDICT==0, header checksum %31==0.
                if (cmf & 0xF) != 8 { throw FBXError(.badDeflate, "bad zlib method") }
                if (cmf >> 4) > 7 { throw FBXError(.badDeflate, "bad zlib window size") }
                if (flg & 0x20) != 0 { throw FBXError(.badDeflate, "preset dictionary unsupported") }
                if ((cmf << 8 | flg) % 31) != 0 { throw FBXError(.badDeflate, "bad zlib header checksum") }
            }

            var outPos = 0
            try output.withUnsafeMutableBufferPointer { outBuf in
                var bfinal: UInt32 = 0
                repeat {
                    bfinal = try reader.getBits(1)
                    let btype = try reader.getBits(2)
                    switch btype {
                    case 0:
                        // Stored / uncompressed.
                        reader.alignToByte()
                        let len = Int(try reader.getBits(16))
                        let nlen = Int(try reader.getBits(16))
                        if len != (~nlen & 0xFFFF) { throw FBXError(.badDeflate, "bad stored block length") }
                        if outPos + len > capacity { throw FBXError(.badDeflate, "output overflow") }
                        var k = 0
                        while k < len {
                            outBuf[outPos] = try reader.readByte()
                            outPos += 1
                            k += 1
                        }
                    case 1:
                        outPos = try inflateBlock(&reader, staticTrees.lit, staticTrees.dist,
                                                  outBuf, outPos, capacity)
                    case 2:
                        let (lit, dist) = try buildDynamicTrees(&reader)
                        outPos = try inflateBlock(&reader, lit, dist, outBuf, outPos, capacity)
                    default:
                        throw FBXError(.badDeflate, "reserved block type")
                    }
                } while bfinal == 0
            }

            // Trailing Adler-32 (big-endian), after byte alignment.
            reader.alignToByte()
            if !noChecksum {
                let b0 = try UInt32(reader.readByte())
                let b1 = try UInt32(reader.readByte())
                let b2 = try UInt32(reader.readByte())
                let b3 = try UInt32(reader.readByte())
                let stored = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
                let computed = adler32(output[0..<outPos])
                if stored != computed { throw FBXError(.badDeflate, "adler-32 checksum mismatch") }
            }

            return outPos
        }
    }

    // MARK: Dynamic Huffman header

    private static func buildDynamicTrees(_ reader: inout BitReader) throws -> (HuffTable, HuffTable) {
        let hlit = Int(try reader.getBits(5)) + 257
        let hdist = Int(try reader.getBits(5)) + 1
        let hclen = Int(try reader.getBits(4)) + 4

        var clen = [UInt8](repeating: 0, count: 19)
        var i = 0
        while i < hclen {
            clen[codeLengthPermutation[i]] = UInt8(try reader.getBits(3))
            i += 1
        }
        let clTree = try buildTable(clen, count: 19)

        let total = hlit + hdist
        var lengths = [UInt8](repeating: 0, count: total)
        var idx = 0
        while idx < total {
            let sym = try reader.decode(clTree)
            if sym < 16 {
                lengths[idx] = UInt8(sym)
                idx += 1
            } else if sym == 16 {
                if idx == 0 { throw FBXError(.badDeflate, "repeat with no previous length") }
                let rep = Int(try reader.getBits(2)) + 3
                if idx + rep > total { throw FBXError(.badDeflate, "code length repeat overflow") }
                let prev = lengths[idx - 1]
                var r = 0
                while r < rep { lengths[idx] = prev; idx += 1; r += 1 }
            } else if sym == 17 {
                let rep = Int(try reader.getBits(3)) + 3
                if idx + rep > total { throw FBXError(.badDeflate, "code length repeat overflow") }
                var r = 0
                while r < rep { lengths[idx] = 0; idx += 1; r += 1 }
            } else if sym == 18 {
                let rep = Int(try reader.getBits(7)) + 11
                if idx + rep > total { throw FBXError(.badDeflate, "code length repeat overflow") }
                var r = 0
                while r < rep { lengths[idx] = 0; idx += 1; r += 1 }
            } else {
                throw FBXError(.badDeflate, "bad code length symbol")
            }
        }

        let lit = try buildTable(Array(lengths[0..<hlit]), count: hlit)
        let dist = try buildTable(Array(lengths[hlit..<total]), count: hdist)
        return (lit, dist)
    }

    // MARK: Block decode

    private static func inflateBlock(_ reader: inout BitReader, _ litTree: HuffTable, _ distTree: HuffTable,
                                     _ out: UnsafeMutableBufferPointer<UInt8>, _ startPos: Int, _ capacity: Int) throws -> Int {
        var outPos = startPos
        while true {
            let sym = try reader.decode(litTree)
            if sym < 256 {
                if outPos >= capacity { throw FBXError(.badDeflate, "output overflow") }
                out[outPos] = UInt8(sym)
                outPos += 1
            } else if sym == 256 {
                return outPos // end of block
            } else {
                if sym > 285 { throw FBXError(.badDeflate, "bad length symbol") }
                let li = sym - 257
                let length = lengthBase[li] + Int(try reader.getBits(lengthExtra[li]))
                let dsym = try reader.decode(distTree)
                if dsym > 29 { throw FBXError(.badDeflate, "bad distance symbol") }
                let distance = distBase[dsym] + Int(try reader.getBits(distExtra[dsym]))
                if distance > outPos { throw FBXError(.badDeflate, "distance too far back") }
                if outPos + length > capacity { throw FBXError(.badDeflate, "output overflow") }
                // ufbx: byte-by-byte copy handles overlapping matches (distance < length) correctly.
                var src = outPos - distance
                var n = length
                while n > 0 {
                    out[outPos] = out[src]
                    outPos += 1
                    src += 1
                    n -= 1
                }
            }
        }
    }
}
