import XCTest
@testable import SwiftFBX

final class MathTests: XCTestCase {
    let tol = 1e-9

    func assertVecEqual(_ a: FBXVec3, _ b: FBXVec3, _ msg: String = "", accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "\(msg) x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "\(msg) y", file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, "\(msg) z", file: file, line: line)
    }

    func assertQuatEqual(_ a: FBXQuat, _ b: FBXQuat, accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.w, b.w, accuracy: accuracy, file: file, line: line)
    }

    func assertMatrixEqual(_ a: FBXMatrix, _ b: FBXMatrix, accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        assertVecEqual(a.cols.0, b.cols.0, "col0", accuracy: accuracy, file: file, line: line)
        assertVecEqual(a.cols.1, b.cols.1, "col1", accuracy: accuracy, file: file, line: line)
        assertVecEqual(a.cols.2, b.cols.2, "col2", accuracy: accuracy, file: file, line: line)
        assertVecEqual(a.cols.3, b.cols.3, "col3", accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Vector basics

    func testVecZeroAndOne() {
        XCTAssertEqual(FBXVec3.zero, FBXVec3(0, 0, 0))
        XCTAssertEqual(FBXVec3.one, FBXVec3(1, 1, 1))
        XCTAssertEqual(FBXVec2.zero, FBXVec2(0, 0))
        XCTAssertEqual(FBXVec4.zero, FBXVec4(0, 0, 0, 0))
    }

    func testVecArithmetic() {
        let a = FBXVec3(1, 2, 3)
        let b = FBXVec3(4, 5, 6)
        XCTAssertEqual(a + b, FBXVec3(5, 7, 9))
        XCTAssertEqual(b - a, FBXVec3(3, 3, 3))
        XCTAssertEqual(a * 2.0, FBXVec3(2, 4, 6))
        XCTAssertEqual(a * b, FBXVec3(4, 10, 18))
        XCTAssertEqual(a.dot(b), 32)
        XCTAssertEqual(a.cross(b), FBXVec3(2 * 6 - 3 * 5, 3 * 4 - 1 * 6, 1 * 5 - 2 * 4))
    }

    func testVecNormalize() {
        let v = FBXVec3(3, 4, 0)
        let n = v.normalized()
        XCTAssertEqual(n.length, 1.0, accuracy: 1e-12)
        XCTAssertEqual(FBXVec3.zero.normalized(), .zero)
    }

    // MARK: - Quaternion basics

    func testQuatIdentity() {
        let id = FBXQuat.identity
        XCTAssertEqual(id, FBXQuat(x: 0, y: 0, z: 0, w: 1))
        let v = FBXVec3(1, 2, 3)
        assertVecEqual(id.rotate(v), v)
    }

    func testQuatMultiplyIdentity() {
        let q = FBXQuat(euler: FBXVec3(10, 20, 30), order: .xyz)
        assertQuatEqual(q * .identity, q)
        assertQuatEqual(.identity * q, q)
    }

    func testQuatNormalize() {
        let q = FBXQuat(x: 2, y: 0, z: 0, w: 0)
        let n = q.normalized()
        XCTAssertEqual(n.dot(n), 1.0, accuracy: 1e-12)
        XCTAssertEqual(FBXQuat(x: 0, y: 0, z: 0, w: 0).normalized(), .identity)
    }

    func testQuatDot() {
        let a = FBXQuat(x: 1, y: 0, z: 0, w: 0)
        let b = FBXQuat(x: 0, y: 1, z: 0, w: 0)
        XCTAssertEqual(a.dot(b), 0)
        XCTAssertEqual(a.dot(a), 1)
    }

    // MARK: - Slerp

    func testSlerpEndpoints() {
        let a = FBXQuat(euler: FBXVec3(0, 0, 0), order: .xyz)
        let b = FBXQuat(euler: FBXVec3(0, 90, 0), order: .xyz)
        assertQuatEqual(FBXQuat.slerp(a, b, 0.0), a)
        assertQuatEqual(FBXQuat.slerp(a, b, 1.0), b)
    }

    func testSlerpMidpointIsUnitAndBetween() {
        let a = FBXQuat.identity
        let b = FBXQuat(euler: FBXVec3(0, 90, 0), order: .xyz)
        let mid = FBXQuat.slerp(a, b, 0.5)
        XCTAssertEqual(mid.dot(mid), 1.0, accuracy: 1e-9)
        // Halfway to a 90 degree yaw should itself be a ~45 degree yaw.
        let euler = mid.toEuler(order: .xyz)
        XCTAssertEqual(euler.y, 45.0, accuracy: 1e-6)
    }

    func testSlerpSameQuatReturnsSame() {
        let a = FBXQuat(euler: FBXVec3(12, 34, 56), order: .zyx)
        assertQuatEqual(FBXQuat.slerp(a, a, 0.5), a)
    }

    // MARK: - Euler <-> quat round trips

    func testEulerRoundTripAllOrders() {
        let orders: [FBXRotationOrder] = [.xyz, .xzy, .yzx, .yxz, .zxy, .zyx]
        let angleSets: [FBXVec3] = [
            FBXVec3(0, 0, 0),
            FBXVec3(30, 0, 0),
            FBXVec3(0, 45, 0),
            FBXVec3(0, 0, 60),
            FBXVec3(15, -25, 35),
            FBXVec3(-40, 50, -60),
            FBXVec3(89, 10, -10),
            FBXVec3(-89, -10, 10),
            FBXVec3(179, 5, -5),
        ]
        for order in orders {
            for angles in angleSets {
                let q = FBXQuat(euler: angles, order: order)
                let back = q.toEuler(order: order)
                let q2 = FBXQuat(euler: back, order: order)
                // Euler angles are ambiguous (gimbal lock, +/-360 wraps), so
                // compare the RESULTING quaternion (up to sign) rather than
                // the raw angles.
                let same = abs(q.dot(q2)) > 1.0 - 1e-6
                XCTAssertTrue(same, "order \(order) angles \(angles) -> \(back) mismatched quat dot \(q.dot(q2))")
            }
        }
    }

    func testEulerSphericIsIdentity() {
        let q = FBXQuat(euler: FBXVec3(45, 45, 45), order: .spheric)
        XCTAssertEqual(q, .identity)
        XCTAssertEqual(q.toEuler(order: .spheric), FBXVec3.zero)
    }

    func testEulerToQuatKnownAngle() {
        // 90 degree rotation about X should be a quaternion with w = cos(45deg).
        let q = FBXQuat(euler: FBXVec3(90, 0, 0), order: .xyz)
        XCTAssertEqual(q.w, cos(Double.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(q.x, sin(Double.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(q.y, 0, accuracy: 1e-9)
        XCTAssertEqual(q.z, 0, accuracy: 1e-9)
    }

    // MARK: - Matrix

    func testMatrixIdentity() {
        let m = FBXMatrix.identity
        assertVecEqual(m.transformPoint(FBXVec3(1, 2, 3)), FBXVec3(1, 2, 3))
        assertVecEqual(m.transformDirection(FBXVec3(1, 2, 3)), FBXVec3(1, 2, 3))
        XCTAssertEqual(m.determinant, 1.0, accuracy: 1e-12)
    }

    func testMatrixMultiplyIdentity() {
        let t = FBXTransform(translation: FBXVec3(1, 2, 3), rotation: FBXQuat(euler: FBXVec3(10, 20, 30), order: .xyz), scale: FBXVec3(1, 2, 0.5))
        let m = t.toMatrix()
        assertMatrixEqual(m * .identity, m)
        assertMatrixEqual(.identity * m, m)
    }

    func testMatrixInvertTimesComposeIsIdentity() {
        let transforms: [FBXTransform] = [
            .identity,
            FBXTransform(translation: FBXVec3(1, 2, 3), rotation: .identity, scale: .one),
            FBXTransform(translation: .zero, rotation: FBXQuat(euler: FBXVec3(30, 45, 60), order: .xyz), scale: .one),
            FBXTransform(translation: FBXVec3(5, -3, 2), rotation: FBXQuat(euler: FBXVec3(15, -25, 35), order: .zyx), scale: FBXVec3(2, 3, 4)),
            FBXTransform(translation: FBXVec3(-1, 0.5, 2), rotation: FBXQuat(euler: FBXVec3(-89, 10, 170), order: .yxz), scale: FBXVec3(0.1, 0.2, 0.3)),
        ]
        for t in transforms {
            let m = t.toMatrix()
            let inv = m.inverted()
            let product = inv * m
            assertMatrixEqual(product, .identity, accuracy: 1e-6)
            let product2 = m * inv
            assertMatrixEqual(product2, .identity, accuracy: 1e-6)
        }
    }

    func testMatrixInvertSingularIsZero() {
        // Zero-scale matrix is singular (det == 0).
        let t = FBXTransform(translation: .zero, rotation: .identity, scale: FBXVec3(0, 1, 1))
        let m = t.toMatrix()
        let inv = m.inverted()
        assertMatrixEqual(inv, FBXMatrix(cols: (.zero, .zero, .zero, .zero)))
    }

    func testMatrixDeterminantNegativeForMirror() {
        let t = FBXTransform(translation: .zero, rotation: .identity, scale: FBXVec3(-1, 1, 1))
        let m = t.toMatrix()
        XCTAssertLessThan(m.determinant, 0)
    }

    // MARK: - Transform <-> matrix round trip

    func testTransformMatrixRoundTrip() {
        let transforms: [FBXTransform] = [
            .identity,
            FBXTransform(translation: FBXVec3(1, 2, 3), rotation: .identity, scale: .one),
            FBXTransform(translation: .zero, rotation: FBXQuat(euler: FBXVec3(30, 45, 60), order: .xyz), scale: .one),
            FBXTransform(translation: FBXVec3(5, -3, 2), rotation: FBXQuat(euler: FBXVec3(15, -25, 35), order: .zyx), scale: FBXVec3(2, 3, 4)),
            FBXTransform(translation: FBXVec3(-1, 0.5, 2), rotation: FBXQuat(euler: FBXVec3(-89, 10, 170), order: .yxz), scale: FBXVec3(1, 1, 1)),
        ]
        for t in transforms {
            let m = t.toMatrix()
            let t2 = m.toTransform()
            let m2 = t2.toMatrix()
            // Rotation/scale can flip sign pairs (quat double-cover, axis
            // sign under negative determinant); compare via the resulting
            // matrix rather than the raw transform fields.
            assertMatrixEqual(m, m2, accuracy: 1e-6)
            assertVecEqual(t.translation, t2.translation)
        }
    }

    func testTransformMatrixRoundTripNegativeScale() {
        let t = FBXTransform(translation: FBXVec3(1, -2, 3), rotation: FBXQuat(euler: FBXVec3(20, -40, 60), order: .xzy), scale: FBXVec3(-1, 1, 1))
        let m = t.toMatrix()
        let t2 = m.toTransform()
        let m2 = t2.toMatrix()
        assertMatrixEqual(m, m2, accuracy: 1e-6)
    }

    func testUnscaledTransform() {
        let t = FBXTransform(translation: FBXVec3(1, 2, 3), rotation: FBXQuat(euler: FBXVec3(10, 20, 30), order: .xyz), scale: FBXVec3(2, 3, 4))
        XCTAssertEqual(t.unscaled.scale, .one)
        XCTAssertEqual(t.unscaled.translation, t.translation)
        assertQuatEqual(t.unscaled.rotation, t.rotation)
    }

    // MARK: - FBXRotationOrder / FBXInterpolation / FBXTangent plumbing

    func testRotationOrderRawValues() {
        XCTAssertEqual(FBXRotationOrder.xyz.rawValue, 0)
        XCTAssertEqual(FBXRotationOrder.xzy.rawValue, 1)
        XCTAssertEqual(FBXRotationOrder.yzx.rawValue, 2)
        XCTAssertEqual(FBXRotationOrder.yxz.rawValue, 3)
        XCTAssertEqual(FBXRotationOrder.zxy.rawValue, 4)
        XCTAssertEqual(FBXRotationOrder.zyx.rawValue, 5)
        XCTAssertEqual(FBXRotationOrder.spheric.rawValue, 6)
    }

    func testInterpolationRawValues() {
        XCTAssertEqual(FBXInterpolation.constantPrev.rawValue, 0)
        XCTAssertEqual(FBXInterpolation.constantNext.rawValue, 1)
        XCTAssertEqual(FBXInterpolation.linear.rawValue, 2)
        XCTAssertEqual(FBXInterpolation.cubic.rawValue, 3)
    }

    func testTangentDefaults() {
        let tangent = FBXTangent()
        XCTAssertEqual(tangent.dx, 0)
        XCTAssertEqual(tangent.dy, 0)
        let t2 = FBXTangent(dx: 1.5, dy: -2.5)
        XCTAssertEqual(t2.dx, 1.5)
        XCTAssertEqual(t2.dy, -2.5)
    }
}
