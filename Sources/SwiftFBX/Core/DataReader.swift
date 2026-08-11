import Foundation

/// Bounds-checked byte cursor over a `[UInt8]` buffer, used by the binary
/// document parser and the DEFLATE decoder. Scalar reads support both
/// little-endian (FBX default) and big-endian (FBX big-endian files flip
/// scalar byte order — `bigEndian` is a runtime-switchable flag, not a
/// generic parameter, since a single document parse may need to flip mid-read
/// per `FBXDocument.bigEndian`).
struct DataReader {
    let bytes: [UInt8]
    var position: Int
    var bigEndian: Bool

    init(_ bytes: [UInt8], position: Int = 0, bigEndian: Bool = false) {
        self.bytes = bytes
        self.position = position
        self.bigEndian = bigEndian
    }

    init(_ data: Data, position: Int = 0, bigEndian: Bool = false) {
        self.bytes = [UInt8](data)
        self.position = position
        self.bigEndian = bigEndian
    }

    @inlinable
    var count: Int { bytes.count }

    @inlinable
    var remaining: Int { bytes.count - position }

    @inlinable
    var isAtEnd: Bool { position >= bytes.count }

    // MARK: - Bounds checking

    @inline(__always)
    private func checkAvailable(_ n: Int) throws {
        if n < 0 || position < 0 || position > bytes.count - n {
            throw FBXError(.truncatedFile, "need \(n) bytes at \(position), have \(remaining)")
        }
    }

    // MARK: - Skip / peek

    @inline(__always)
    mutating func skip(_ n: Int) throws {
        try checkAvailable(n)
        position += n
    }

    /// Non-throwing skip clamped to the buffer end.
    @inline(__always)
    mutating func skipClamped(_ n: Int) {
        position = Swift.min(bytes.count, Swift.max(0, position + n))
    }

    @inline(__always)
    func peekByte() -> UInt8? {
        position >= 0 && position < bytes.count ? bytes[position] : nil
    }

    // MARK: - Byte slices

    @inline(__always)
    mutating func readBytes(_ n: Int) throws -> ArraySlice<UInt8> {
        try checkAvailable(n)
        let slice = bytes[position..<(position + n)]
        position += n
        return slice
    }

    @inline(__always)
    mutating func tryReadBytes(_ n: Int) -> ArraySlice<UInt8>? {
        try? readBytes(n)
    }

    /// Peeks `n` bytes without advancing the cursor.
    @inline(__always)
    func peekBytes(_ n: Int) throws -> ArraySlice<UInt8> {
        try checkAvailable(n)
        return bytes[position..<(position + n)]
    }

    // MARK: - Raw little/big-endian scalar assembly (allocation-free)

    @inline(__always)
    private func loadLE<T: FixedWidthInteger>(_: T.Type, at pos: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: bytes[pos + i]) << (8 * i)
        }
        return value
    }

    @inline(__always)
    private func loadBE<T: FixedWidthInteger>(_: T.Type, at pos: Int) -> T {
        var value: T = 0
        let size = MemoryLayout<T>.size
        for i in 0..<size {
            value |= T(truncatingIfNeeded: bytes[pos + i]) << (8 * (size - 1 - i))
        }
        return value
    }

    @inline(__always)
    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try checkAvailable(size)
        let value: T = bigEndian ? loadBE(type, at: position) : loadLE(type, at: position)
        position += size
        return value
    }

    // MARK: - Unsigned integers

    @inline(__always)
    mutating func readUInt8() throws -> UInt8 {
        try checkAvailable(1)
        defer { position += 1 }
        return bytes[position]
    }

    @inline(__always)
    mutating func readUInt16() throws -> UInt16 { try readInteger(UInt16.self) }

    @inline(__always)
    mutating func readUInt32() throws -> UInt32 { try readInteger(UInt32.self) }

    @inline(__always)
    mutating func readUInt64() throws -> UInt64 { try readInteger(UInt64.self) }

    // MARK: - Signed integers

    @inline(__always)
    mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    @inline(__always)
    mutating func readInt16() throws -> Int16 { try readInteger(Int16.self) }

    @inline(__always)
    mutating func readInt32() throws -> Int32 { try readInteger(Int32.self) }

    @inline(__always)
    mutating func readInt64() throws -> Int64 { try readInteger(Int64.self) }

    // MARK: - Floating point (bit-pattern reinterpretation)

    @inline(__always)
    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    @inline(__always)
    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    // MARK: - Non-throwing "try or nil" helpers

    @inline(__always)
    mutating func tryReadUInt8() -> UInt8? { try? readUInt8() }
    @inline(__always)
    mutating func tryReadUInt16() -> UInt16? { try? readUInt16() }
    @inline(__always)
    mutating func tryReadUInt32() -> UInt32? { try? readUInt32() }
    @inline(__always)
    mutating func tryReadUInt64() -> UInt64? { try? readUInt64() }
    @inline(__always)
    mutating func tryReadInt8() -> Int8? { try? readInt8() }
    @inline(__always)
    mutating func tryReadInt16() -> Int16? { try? readInt16() }
    @inline(__always)
    mutating func tryReadInt32() -> Int32? { try? readInt32() }
    @inline(__always)
    mutating func tryReadInt64() -> Int64? { try? readInt64() }
    @inline(__always)
    mutating func tryReadFloat() -> Float? { try? readFloat() }
    @inline(__always)
    mutating func tryReadDouble() -> Double? { try? readDouble() }
}
