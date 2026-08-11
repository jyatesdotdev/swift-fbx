import XCTest
@testable import SwiftFBX

final class DataReaderTests: XCTestCase {
    // MARK: - Little-endian scalars

    func testReadUInt8() throws {
        var r = DataReader([0x42])
        XCTAssertEqual(try r.readUInt8(), 0x42)
        XCTAssertEqual(r.position, 1)
    }

    func testReadUInt16LE() throws {
        var r = DataReader([0x01, 0x02])
        XCTAssertEqual(try r.readUInt16(), 0x0201)
    }

    func testReadUInt32LE() throws {
        var r = DataReader([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(try r.readUInt32(), 0x04030201)
    }

    func testReadUInt64LE() throws {
        var r = DataReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        XCTAssertEqual(try r.readUInt64(), 0x0807060504030201)
    }

    func testReadInt8Negative() throws {
        var r = DataReader([0xFF])
        XCTAssertEqual(try r.readInt8(), -1)
    }

    func testReadInt16Negative() throws {
        var r = DataReader([0xFF, 0xFF])
        XCTAssertEqual(try r.readInt16(), -1)
    }

    func testReadInt32Negative() throws {
        var r = DataReader([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(try r.readInt32(), -1)
    }

    func testReadInt64Negative() throws {
        var r = DataReader([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(try r.readInt64(), -1)
    }

    // MARK: - Big-endian scalars

    func testReadUInt16BE() throws {
        var r = DataReader([0x01, 0x02], bigEndian: true)
        XCTAssertEqual(try r.readUInt16(), 0x0102)
    }

    func testReadUInt32BE() throws {
        var r = DataReader([0x01, 0x02, 0x03, 0x04], bigEndian: true)
        XCTAssertEqual(try r.readUInt32(), 0x01020304)
    }

    func testReadUInt64BE() throws {
        var r = DataReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08], bigEndian: true)
        XCTAssertEqual(try r.readUInt64(), 0x0102030405060708)
    }

    func testReadInt32BENegative() throws {
        var r = DataReader([0xFF, 0xFF, 0xFF, 0xFE], bigEndian: true)
        XCTAssertEqual(try r.readInt32(), -2)
    }

    // MARK: - Floats via bit pattern

    func testReadFloatLE() throws {
        // 1.0f = 0x3F800000
        var r = DataReader([0x00, 0x00, 0x80, 0x3F])
        XCTAssertEqual(try r.readFloat(), 1.0)
    }

    func testReadFloatBE() throws {
        var r = DataReader([0x3F, 0x80, 0x00, 0x00], bigEndian: true)
        XCTAssertEqual(try r.readFloat(), 1.0)
    }

    func testReadDoubleLE() throws {
        // 1.0 = 0x3FF0000000000000
        var r = DataReader([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F])
        XCTAssertEqual(try r.readDouble(), 1.0)
    }

    func testReadDoubleBE() throws {
        var r = DataReader([0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], bigEndian: true)
        XCTAssertEqual(try r.readDouble(), 1.0)
    }

    func testFloatBitPatternRoundTrip() throws {
        let value: Float = -3.14159
        var bytes = [UInt8](repeating: 0, count: 4)
        let bits = value.bitPattern
        for i in 0..<4 {
            bytes[i] = UInt8((bits >> (8 * i)) & 0xFF)
        }
        var r = DataReader(bytes)
        XCTAssertEqual(try r.readFloat(), value)
    }

    func testDoubleBitPatternRoundTrip() throws {
        let value: Double = 2.718281828459045
        var bytes = [UInt8](repeating: 0, count: 8)
        let bits = value.bitPattern
        for i in 0..<8 {
            bytes[i] = UInt8((bits >> (8 * i)) & 0xFF)
        }
        var r = DataReader(bytes)
        XCTAssertEqual(try r.readDouble(), value)
    }

    // MARK: - Sequential reads / cursor position

    func testSequentialReadsAdvancePosition() throws {
        var r = DataReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        XCTAssertEqual(try r.readUInt8(), 0x01)
        XCTAssertEqual(try r.readUInt16(), 0x0302)
        XCTAssertEqual(try r.readUInt8(), 0x04)
        XCTAssertEqual(r.position, 4)
        XCTAssertEqual(r.remaining, 2)
    }

    // MARK: - Byte slices

    func testReadBytes() throws {
        var r = DataReader([0x01, 0x02, 0x03, 0x04, 0x05])
        let slice = try r.readBytes(3)
        XCTAssertEqual(Array(slice), [0x01, 0x02, 0x03])
        XCTAssertEqual(r.position, 3)
        XCTAssertEqual(r.remaining, 2)
    }

    func testReadBytesZeroLength() throws {
        var r = DataReader([0x01, 0x02])
        let slice = try r.readBytes(0)
        XCTAssertEqual(slice.count, 0)
        XCTAssertEqual(r.position, 0)
    }

    func testPeekBytesDoesNotAdvance() throws {
        let r = DataReader([0x01, 0x02, 0x03])
        let slice = try r.peekBytes(2)
        XCTAssertEqual(Array(slice), [0x01, 0x02])
        XCTAssertEqual(r.position, 0)
    }

    func testPeekByte() {
        var r = DataReader([0x01, 0x02])
        XCTAssertEqual(r.peekByte(), 0x01)
        r.position = 2
        XCTAssertNil(r.peekByte())
    }

    // MARK: - Skip

    func testSkip() throws {
        var r = DataReader([0x01, 0x02, 0x03, 0x04])
        try r.skip(2)
        XCTAssertEqual(r.position, 2)
        XCTAssertEqual(try r.readUInt8(), 0x03)
    }

    func testSkipPastEndThrows() {
        var r = DataReader([0x01])
        XCTAssertThrowsError(try r.skip(5)) { error in
            XCTAssertEqual((error as? FBXError)?.code, .truncatedFile)
        }
    }

    // MARK: - Bounds errors

    func testReadUInt8PastEndThrows() {
        var r = DataReader([])
        XCTAssertThrowsError(try r.readUInt8()) { error in
            XCTAssertEqual((error as? FBXError)?.code, .truncatedFile)
        }
    }

    func testReadUInt32TruncatedThrows() {
        var r = DataReader([0x01, 0x02])
        XCTAssertThrowsError(try r.readUInt32()) { error in
            XCTAssertEqual((error as? FBXError)?.code, .truncatedFile)
        }
        // Cursor should not have moved past the checked failure.
        XCTAssertEqual(r.position, 0)
    }

    func testReadInt64TruncatedThrows() {
        var r = DataReader([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try r.readInt64()) { error in
            XCTAssertEqual((error as? FBXError)?.code, .truncatedFile)
        }
    }

    func testReadBytesPastEndThrows() {
        var r = DataReader([0x01, 0x02])
        XCTAssertThrowsError(try r.readBytes(10)) { error in
            XCTAssertEqual((error as? FBXError)?.code, .truncatedFile)
        }
    }

    func testIsAtEnd() throws {
        var r = DataReader([0x01])
        XCTAssertFalse(r.isAtEnd)
        _ = try r.readUInt8()
        XCTAssertTrue(r.isAtEnd)
    }

    // MARK: - Non-throwing helpers

    func testTryReadHelpersReturnNilPastEnd() {
        var r = DataReader([0x01])
        XCTAssertEqual(r.tryReadUInt8(), 0x01)
        XCTAssertNil(r.tryReadUInt8())
        XCTAssertNil(r.tryReadUInt32())
        XCTAssertNil(r.tryReadFloat())
    }

    func testTryReadBytesReturnsNilPastEnd() {
        var r = DataReader([0x01, 0x02])
        XCTAssertNil(r.tryReadBytes(10))
        XCTAssertEqual(r.position, 0)
    }

    func testSkipClamped() {
        var r = DataReader([0x01, 0x02])
        r.skipClamped(100)
        XCTAssertEqual(r.position, 2)
        XCTAssertTrue(r.isAtEnd)
        r.skipClamped(-100)
        XCTAssertEqual(r.position, 0)
    }

    // MARK: - Data initializer

    func testInitFromData() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var r = DataReader(data)
        XCTAssertEqual(try r.readUInt32(), 0x04030201)
    }

    // MARK: - Endianness flip mid-stream

    func testBigEndianFlagCanChangeAtRuntime() throws {
        var r = DataReader([0x01, 0x02, 0x00, 0x00, 0x01, 0x02])
        XCTAssertEqual(try r.readUInt16(), 0x0201) // little-endian
        try r.skip(2)
        r.bigEndian = true
        XCTAssertEqual(try r.readUInt16(), 0x0102) // big-endian
    }
}
