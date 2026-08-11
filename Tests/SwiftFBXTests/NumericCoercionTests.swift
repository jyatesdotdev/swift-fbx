import XCTest
@testable import SwiftFBX

/// Regression guard for the numeric-coercion boundary that previously TRAPPED:
/// `f64ToI64` used a `<= Double(Int64.max)` guard, but `Double(Int64.max)` rounds
/// up to exactly 2^63, so a value of exactly 2^63 passed the guard and then
/// crashed in `Int64(2^63)`. Every numeric accessor eagerly computes this pair,
/// so a single malformed 'D'/'F' scalar of 2^63 crashed the whole loader/eval.
final class NumericCoercionTests: XCTestCase {

    private let twoPow63 = 9223372036854775808.0            // 2^63, == -Int64.min
    // Largest double strictly below 2^63 (2^63 - 1024); exactly Int64-representable.
    private let justBelow = 9223372036854774784.0

    // MARK: - f64ToI64 saturation (the fix)

    func testF64ToI64SaturatesAtPositiveBoundaryWithoutTrapping() {
        XCTAssertEqual(FBXValue.f64ToI64(twoPow63), .max)
        XCTAssertEqual(FBXValue.f64ToI64(twoPow63 * 2), .max)
        XCTAssertEqual(FBXValue.f64ToI64(1e300), .max)
    }

    func testF64ToI64SaturatesAtNegativeBoundary() {
        // -2^63 == Int64.min and is exactly representable, so it must map there.
        XCTAssertEqual(FBXValue.f64ToI64(-twoPow63), .min)
        XCTAssertEqual(FBXValue.f64ToI64(-1e300), .min)
    }

    func testF64ToI64PassesThroughInRangeValues() {
        XCTAssertEqual(FBXValue.f64ToI64(0.0), 0)
        XCTAssertEqual(FBXValue.f64ToI64(-0.0), 0)
        XCTAssertEqual(FBXValue.f64ToI64(42.0), 42)
        XCTAssertEqual(FBXValue.f64ToI64(-42.0), -42)
        XCTAssertEqual(FBXValue.f64ToI64(justBelow), 9223372036854774784)
    }

    // MARK: - Scalar accessors must not trap on a 2^63 value

    func testDoubleScalarAccessorsSurviveTwoPow63() {
        let v = FBXValue.double(twoPow63)
        XCTAssertEqual(v.asInt64, .max)
        XCTAssertEqual(v.asDouble, twoPow63)
        XCTAssertEqual(v.asBool, true)
        XCTAssertEqual(v.asInt32, Int32(truncatingIfNeeded: Int64.max))
        XCTAssertEqual(v.asFloat, Float(twoPow63))
    }

    func testFloatScalarAccessorSurvivesTwoPow63() {
        // 0x5F000000 is exactly 2^63 as an IEEE-754 float.
        let v = FBXValue.float(Float(bitPattern: 0x5F00_0000))
        XCTAssertEqual(v.asInt64, .max)
        XCTAssertEqual(v.asDouble, twoPow63)
    }

    // MARK: - Array coercion must not trap on a 2^63 element

    func testDoubleArrayInt64CoercionSaturates() {
        let arr = FBXArrayValue.double([twoPow63, -twoPow63, 1.0])
        XCTAssertEqual(arr.asInt64Array(), [.max, .min, 1])
    }

    func testFloatArrayInt64CoercionSaturates() {
        let arr = FBXArrayValue.float([Float(bitPattern: 0x5F00_0000), 2.0])
        XCTAssertEqual(arr.asInt64Array(), [.max, 2])
    }

    func testDoubleArrayInt32CoercionSaturates() {
        // f64_to_i32 already saturates (Double(Int32.max) is exact) — confirm the
        // shared boundary path stays consistent.
        let arr = FBXArrayValue.double([twoPow63, -twoPow63])
        XCTAssertEqual(arr.asInt32Array(), [.max, .min])
    }
}
