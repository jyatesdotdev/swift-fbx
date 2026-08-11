import Foundation
import Testing
@testable import SwiftFBX

@Suite struct InflateTests {
    static let inflateDir = Bundle.module.url(forResource: "Resources", withExtension: nil)!
        .appendingPathComponent("inflate")

    struct Vector: Decodable {
        let name: String
        let compressed_size: Int
        let raw_size: Int
        let raw_sha256: String
    }

    static var vectors: [Vector] {
        let url = inflateDir.appendingPathComponent("vectors.json")
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode([Vector].self, from: data)
    }

    static var vectorNames: [String] { vectors.map { $0.name } }

    @Test(arguments: vectorNames)
    func roundTrip(name: String) throws {
        let vec = Self.vectors.first { $0.name == name }!
        let zlib = [UInt8](try Data(contentsOf: Self.inflateDir.appendingPathComponent("\(name).zlib")))
        let expected = [UInt8](try Data(contentsOf: Self.inflateDir.appendingPathComponent("\(name).raw")))

        #expect(expected.count == vec.raw_size)

        var output = [UInt8](repeating: 0, count: vec.raw_size)
        let produced = try Inflate.inflate(zlib[...], into: &output)

        #expect(produced == vec.raw_size)
        #expect(output == expected)
    }

    @Test func rejectsBadZlibHeader() {
        var out = [UInt8](repeating: 0, count: 4)
        // 0x00 0x00: method != 8
        #expect(throws: FBXError.self) {
            _ = try Inflate.inflate([0x00, 0x00, 0x00, 0x00][...], into: &out)
        }
    }

    @Test func rejectsBadChecksum() throws {
        // "hello" stream with the last checksum byte corrupted.
        let zlib = [UInt8](try Data(contentsOf: Self.inflateDir.appendingPathComponent("hello.zlib")))
        var corrupt = zlib
        corrupt[corrupt.count - 1] ^= 0xFF
        var out = [UInt8](repeating: 0, count: 11)
        #expect(throws: FBXError.self) {
            _ = try Inflate.inflate(corrupt[...], into: &out)
        }
    }

    @Test func detectsOutputOverflow() throws {
        let zlib = [UInt8](try Data(contentsOf: Self.inflateDir.appendingPathComponent("hello.zlib")))
        var tooSmall = [UInt8](repeating: 0, count: 5) // real output is 11 bytes
        #expect(throws: FBXError.self) {
            _ = try Inflate.inflate(zlib[...], into: &tooSmall)
        }
    }
}

@Suite struct FloatParseTests {

    private func d(_ s: String, _ flags: FloatParse.Flags = .allowFastPath) -> (Double, Int) {
        let bytes = Array(s.utf8)
        let r = FloatParse.parseDouble(bytes, flags: flags)
        return (r.value, r.consumed)
    }

    /// Assert parse bit-pattern equals Swift's own correctly-rounded parse.
    private func expectMatchesNative(_ s: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let (v, consumed) = d(s)
        let native = Double(s)!
        #expect(v.bitPattern == native.bitPattern, "\(s): got \(v) want \(native)", sourceLocation: sourceLocation)
        #expect(consumed == s.utf8.count, "\(s): consumed \(consumed)", sourceLocation: sourceLocation)
    }

    @Test func integersAndDecimals() {
        for s in ["0", "1", "123", "3.14159", "-2.5", "+7", "123456.789",
                  "0.5", "100000000", "-0.0", "0.0", "42.0"] {
            expectMatchesNative(s)
        }
    }

    @Test func negativeZero() {
        let (v, _) = d("-0.0")
        #expect(v.sign == .minus)
        #expect(v == 0.0)
    }

    @Test func scientific() {
        for s in ["1e10", "1E10", "1.5e-3", "6.022e23", "-4.4e-5",
                  "2.2250738585072014e-308", "1.7976931348623157e308"] {
            expectMatchesNative(s)
        }
    }

    @Test func subnormals() {
        // Requires the exact bigint slow-path (round-half-to-even).
        for s in ["1e-320", "4.9e-324", "5e-324", "1e-310", "2.5e-323"] {
            expectMatchesNative(s)
        }
    }

    @Test func manyDigits() {
        // >18 digit mantissa exercises bigint accumulation; >22 exponent forces slow path.
        for s in ["1234567890123456789", "123456789012345678901234567890",
                  "3.141592653589793238462643383279502884197",
                  "0.00000000000000000000001234567890123456789",
                  "9999999999999999999999999999e-40"] {
            expectMatchesNative(s)
        }
    }

    @Test func overflowUnderflow() {
        #expect(d("1e400").0 == Double.infinity)
        #expect(d("-1e400").0 == -Double.infinity)
        #expect(d("1e-400").0 == 0.0)
        #expect(d("1e-2000").0 == 0.0)
    }

    @Test func infNanStandard() {
        #expect(d("inf").0 == Double.infinity)
        #expect(d("Infinity").0 == Double.infinity)
        #expect(d("-inf").0 == -Double.infinity)
        #expect(d("nan").0.isNaN)
        #expect(d("nan(1234)").0.isNaN)
    }

    @Test func infNanMSVC() {
        #expect(d("1.#INF").0 == Double.infinity)
        #expect(d("-1.#INF").0 == -Double.infinity)
        #expect(d("1.#IND").0.isNaN)
        #expect(d("-1.#IND").0.isNaN)
        #expect(d("1.#NAN").0.isNaN)
        // consumed should cover the whole token
        #expect(d("1.#INF").1 == 6)
        #expect(d("-1.#IND").1 == 7)
    }

    @Test func consumedStopsAtNonNumeric() {
        let (v, consumed) = d("3.5,7.0")
        #expect(v == 3.5)
        #expect(consumed == 3)
    }

    @Test func accurateF32() {
        // .asBinary32 rounds through Float; result equals Float(string).
        for s in ["0.1", "3.14159", "1.5", "0.2", "16777217", "1e-40", "123.456"] {
            let (v, _) = d(s, .asBinary32)
            let nativeF = Float(s)!
            #expect(Float(v).bitPattern == nativeF.bitPattern, "\(s): got \(Float(v)) want \(nativeF)")
        }
    }

    @Test func int64Parsing() {
        func i(_ s: String) -> (Int64, Int)? { FloatParse.parseInt64(Array(s.utf8)[...]) }
        #expect(i("123")?.0 == 123)
        #expect(i("-456")?.0 == -456)
        #expect(i("+7")?.0 == 7)
        #expect(i("0")?.0 == 0)
        #expect(i("9223372036854775807")?.0 == Int64.max)
        #expect(i("abc") == nil)
        #expect(i("12x")?.1 == 2)
    }
}
