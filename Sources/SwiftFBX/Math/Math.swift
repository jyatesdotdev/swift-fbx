// Math primitives shared across SwiftFBX: vectors, quaternion, 3x4 affine
// matrix, TRS transform, euler conversion. Ports `ufbx_vec2/3/4`,
// `ufbx_quat`, `ufbx_matrix`, `ufbx_transform` and the free functions in
// ufbx.c around lines 22626-22770 (transform-chain helpers), 30341-30346
// (identity constants) and 31492-31926 (quat/matrix math), matching
// ufbx's `ufbx_real == double` build exactly (DESIGN.md: Double everywhere).
//
// `FBXRotationOrder`, `FBXInterpolation` and `FBXTangent` also live here
// (not in Scene/Animation.swift) per the wave-2 task assignment: they are
// needed by both the Math layer (euler<->quat) and the animation/scene
// layers, and Math.swift is built first, so this is the agreed shared home.

import Foundation

// MARK: - Rotation order / interpolation (shared enums)

/// Mirrors `ufbx_rotation_order` (ufbx.h:341). NOTE: the name is the
/// axis-*application* order, not the multiplication order — e.g. XYZ means
/// the composed matrix is `Z*Y*X`. Raw values match the ufbx ordinals
/// because `find_enum`-style clamping and table indexing rely on them.
public enum FBXRotationOrder: Int, Sendable, CaseIterable {
    case xyz = 0
    case xzy = 1
    case yzx = 2
    case yxz = 3
    case zxy = 4
    case zyx = 5
    case spheric = 6
}

/// Mirrors `ufbx_interpolation` (ufbx.h:3153). Raw values match ufbx.
public enum FBXInterpolation: Int, Sendable {
    case constantPrev = 0
    case constantNext = 1
    case linear = 2
    case cubic = 3
}

/// Mirrors `ufbx_tangent` (ufbx.h:3186): a keyframe tangent expressed as a
/// slope (rise `dy` over run `dx`), not a control point. `dx` is in seconds.
public struct FBXTangent: Sendable, Equatable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double = 0, dy: Double = 0) {
        self.dx = dx
        self.dy = dy
    }
}

// MARK: - Vectors

/// Mirrors `ufbx_vec2` (ufbx.h:298).
public struct FBXVec2: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double = 0, _ y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = FBXVec2()

    public static func + (a: FBXVec2, b: FBXVec2) -> FBXVec2 { FBXVec2(a.x + b.x, a.y + b.y) }
    public static func - (a: FBXVec2, b: FBXVec2) -> FBXVec2 { FBXVec2(a.x - b.x, a.y - b.y) }
    public static prefix func - (a: FBXVec2) -> FBXVec2 { FBXVec2(-a.x, -a.y) }
    public static func * (a: FBXVec2, s: Double) -> FBXVec2 { FBXVec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: FBXVec2) -> FBXVec2 { a * s }
}

/// Mirrors `ufbx_vec3` (ufbx.h:308).
public struct FBXVec3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = FBXVec3()
    public static let one = FBXVec3(1, 1, 1)

    public static func + (a: FBXVec3, b: FBXVec3) -> FBXVec3 { FBXVec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: FBXVec3, b: FBXVec3) -> FBXVec3 { FBXVec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: FBXVec3) -> FBXVec3 { FBXVec3(-a.x, -a.y, -a.z) }
    public static func * (a: FBXVec3, s: Double) -> FBXVec3 { FBXVec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: FBXVec3) -> FBXVec3 { a * s }
    /// Componentwise product (ufbxi_mul_scale's vector*vector, ufbx.c:22641).
    public static func * (a: FBXVec3, b: FBXVec3) -> FBXVec3 { FBXVec3(a.x * b.x, a.y * b.y, a.z * b.z) }

    public func dot(_ b: FBXVec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: FBXVec3) -> FBXVec3 {
        FBXVec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public func normalized() -> FBXVec3 {
        let len = length
        guard len > fbxEpsilon else { return .zero }
        return self * (1.0 / len)
    }
}

/// Mirrors `ufbx_vec4` (ufbx.h:318).
public struct FBXVec4: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0, _ w: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let zero = FBXVec4()

    public static func + (a: FBXVec4, b: FBXVec4) -> FBXVec4 { FBXVec4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w) }
    public static func - (a: FBXVec4, b: FBXVec4) -> FBXVec4 { FBXVec4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w) }
    public static func * (a: FBXVec4, s: Double) -> FBXVec4 { FBXVec4(a.x * s, a.y * s, a.z * s, a.w * s) }
}

/// `UFBX_EPSILON` for the `ufbx_real == double` build (ufbx.c:70).
let fbxEpsilon: Double = 1.4916681462400413e-154

private let fbxDegToRad: Double = Double.pi / 180.0
private let fbxRadToDeg: Double = 180.0 / Double.pi

// MARK: - Quaternion

/// Mirrors `ufbx_quat` (ufbx.h:328). Identity = `{0,0,0,1}`.
public struct FBXQuat: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0, w: Double = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = FBXQuat()

    /// Hamilton product, matches `ufbxi_mul_quat`/`ufbx_quat_mul` (ufbx.c:22660, 31492).
    public static func * (a: FBXQuat, b: FBXQuat) -> FBXQuat {
        FBXQuat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    public func dot(_ b: FBXQuat) -> Double { x * b.x + y * b.y + z * b.z + w * b.w }

    /// Matches `ufbx_quat_normalize` (ufbx.c:31507): returns identity for a
    /// zero-norm quaternion rather than NaN.
    public func normalized() -> FBXQuat {
        let norm = dot(self)
        if norm == 0.0 { return .identity }
        let n = norm.squareRoot()
        return FBXQuat(x: x / n, y: y / n, z: z / n, w: w / n)
    }

    /// Matches `ufbx_quat_rotate_vec3` (ufbx.c:31554).
    public func rotate(_ v: FBXVec3) -> FBXVec3 {
        let xy = x * v.y - y * v.x
        let xz = x * v.z - z * v.x
        let yz = y * v.z - z * v.y
        return FBXVec3(
            2.0 * (w * yz + y * xy + z * xz) + v.x,
            2.0 * (-x * xy - w * xz + z * yz) + v.y,
            2.0 * (-x * xz - y * yz + w * xy) + v.z
        )
    }

    /// Matches `ufbx_quat_slerp` (ufbx.c:31527).
    public static func slerp(_ a: FBXQuat, _ b: FBXQuat, _ t: Double) -> FBXQuat {
        var b = b
        var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
        if dot < 0.0 {
            dot = -dot
            b.x = -b.x; b.y = -b.y; b.z = -b.z; b.w = -b.w
        }
        let omega = acos(min(max(dot, 0.0), 1.0))
        // ufbx: FLT_MIN-based near-zero-angle guard, kept as a literal even
        // in the double build to match ufbx.c:31535 exactly.
        if omega <= 1.175494351e-38 { return a }
        let rcpSo = 1.0 / sin(omega)
        let af = sin((1.0 - t) * omega) * rcpSo
        let bf = sin(t * omega) * rcpSo
        let rx = af * a.x + bf * b.x
        let ry = af * a.y + bf * b.y
        let rz = af * a.z + bf * b.z
        let rw = af * a.w + bf * b.w
        let rcpLen = 1.0 / (rx * rx + ry * ry + rz * rz + rw * rw).squareRoot()
        return FBXQuat(x: rx * rcpLen, y: ry * rcpLen, z: rz * rcpLen, w: rw * rcpLen)
    }

    /// Matches `ufbx_euler_to_quat` (ufbx.c:31566): degrees in, per-order
    /// closed-form quaternion. SPHERIC (and any unknown order) falls through
    /// to the identity quaternion, matching ufbx's `default:` case.
    public init(euler v: FBXVec3, order: FBXRotationOrder) {
        let vx = v.x * (fbxDegToRad * 0.5)
        let vy = v.y * (fbxDegToRad * 0.5)
        let vz = v.z * (fbxDegToRad * 0.5)
        let cx = cos(vx), sx = sin(vx)
        let cy = cos(vy), sy = sin(vy)
        let cz = cos(vz), sz = sin(vz)

        switch order {
        case .xyz:
            self.init(x: -cx*sy*sz + cy*cz*sx, y: cx*cz*sy + cy*sx*sz, z: cx*cy*sz - cz*sx*sy, w: cx*cy*cz + sx*sy*sz)
        case .xzy:
            self.init(x: cx*sy*sz + cy*cz*sx, y: cx*cz*sy + cy*sx*sz, z: cx*cy*sz - cz*sx*sy, w: cx*cy*cz - sx*sy*sz)
        case .yzx:
            self.init(x: -cx*sy*sz + cy*cz*sx, y: cx*cz*sy - cy*sx*sz, z: cx*cy*sz + cz*sx*sy, w: cx*cy*cz + sx*sy*sz)
        case .yxz:
            self.init(x: -cx*sy*sz + cy*cz*sx, y: cx*cz*sy + cy*sx*sz, z: cx*cy*sz + cz*sx*sy, w: cx*cy*cz - sx*sy*sz)
        case .zxy:
            self.init(x: cx*sy*sz + cy*cz*sx, y: cx*cz*sy - cy*sx*sz, z: cx*cy*sz - cz*sx*sy, w: cx*cy*cz + sx*sy*sz)
        case .zyx:
            self.init(x: cx*sy*sz + cy*cz*sx, y: cx*cz*sy - cy*sx*sz, z: cx*cy*sz + cz*sx*sy, w: cx*cy*cz - sx*sy*sz)
        case .spheric:
            self = .identity
        }
    }

    /// Matches `ufbx_quat_to_euler` (ufbx.c:31622): closed-form per-order
    /// extraction with a gimbal-lock branch, output in degrees. Unknown
    /// order (there is none besides SPHERIC, handled by the `default:` case
    /// in ufbx) returns zero, matching ufbx.
    public func toEuler(order: FBXRotationOrder) -> FBXVec3 {
        // ufbx: double-build epsilon (ufbx.c:31628); float build would use 0.9999999.
        let eps = 0.999999999
        let qx = x, qy = y, qz = z, qw = w
        var vx = 0.0, vy = 0.0, vz = 0.0
        var t = 0.0

        switch order {
        case .xyz:
            t = 2.0 * (qw*qy - qx*qz)
            if abs(t) < eps {
                vy = asin(t)
                vz = atan2(2.0*(qw*qz + qx*qy), 2.0*(qw*qw + qx*qx) - 1.0)
                vx = -atan2(-2.0*(qw*qx + qy*qz), 2.0*(qw*qw + qz*qz) - 1.0)
            } else {
                vy = copysign(Double.pi * 0.5, t)
                vz = atan2(-2.0*t*(qw*qx - qy*qz), t*(2.0*qw*qy + 2.0*qx*qz))
                vx = 0.0
            }
        case .xzy:
            t = 2.0 * (qw*qz + qx*qy)
            if abs(t) < eps {
                vz = asin(t)
                vy = atan2(2.0*(qw*qy - qx*qz), 2.0*(qw*qw + qx*qx) - 1.0)
                vx = -atan2(-2.0*(qw*qx - qy*qz), 2.0*(qw*qw + qy*qy) - 1.0)
            } else {
                vz = copysign(Double.pi * 0.5, t)
                vy = atan2(2.0*t*(qw*qx + qy*qz), -t*(2.0*qx*qy - 2.0*qw*qz))
                vx = 0.0
            }
        case .yzx:
            t = 2.0 * (qw*qz - qx*qy)
            if abs(t) < eps {
                vz = asin(t)
                vx = atan2(2.0*(qw*qx + qy*qz), 2.0*(qw*qw + qy*qy) - 1.0)
                vy = -atan2(-2.0*(qw*qy + qx*qz), 2.0*(qw*qw + qx*qx) - 1.0)
            } else {
                vz = copysign(Double.pi * 0.5, t)
                vx = atan2(-2.0*t*(qw*qy - qx*qz), t*(2.0*qw*qz + 2.0*qx*qy))
                vy = 0.0
            }
        case .yxz:
            t = 2.0 * (qw*qx + qy*qz)
            if abs(t) < eps {
                vx = asin(t)
                vz = atan2(2.0*(qw*qz - qx*qy), 2.0*(qw*qw + qy*qy) - 1.0)
                vy = -atan2(-2.0*(qw*qy - qx*qz), 2.0*(qw*qw + qz*qz) - 1.0)
            } else {
                vx = copysign(Double.pi * 0.5, t)
                vz = atan2(2.0*t*(qw*qy + qx*qz), -t*(2.0*qy*qz - 2.0*qw*qx))
                vy = 0.0
            }
        case .zxy:
            t = 2.0 * (qw*qx - qy*qz)
            if abs(t) < eps {
                vx = asin(t)
                vy = atan2(2.0*(qw*qy + qx*qz), 2.0*(qw*qw + qz*qz) - 1.0)
                vz = -atan2(-2.0*(qw*qz + qx*qy), 2.0*(qw*qw + qy*qy) - 1.0)
            } else {
                vx = copysign(Double.pi * 0.5, t)
                vy = atan2(-2.0*t*(qw*qz - qx*qy), t*(2.0*qw*qx + 2.0*qy*qz))
                vz = 0.0
            }
        case .zyx:
            t = 2.0 * (qw*qy + qx*qz)
            if abs(t) < eps {
                vy = asin(t)
                vx = atan2(2.0*(qw*qx - qy*qz), 2.0*(qw*qw + qz*qz) - 1.0)
                vz = -atan2(-2.0*(qw*qz - qx*qy), 2.0*(qw*qw + qx*qx) - 1.0)
            } else {
                vy = copysign(Double.pi * 0.5, t)
                vx = atan2(2.0*t*(qw*qz + qx*qy), -t*(2.0*qx*qz - 2.0*qw*qy))
                vz = 0.0
            }
        case .spheric:
            vx = 0.0; vy = 0.0; vz = 0.0
        }

        return FBXVec3(vx * fbxRadToDeg, vy * fbxRadToDeg, vz * fbxRadToDeg)
    }
}

// MARK: - Transform (TRS)

/// Mirrors `ufbx_transform` (ufbx.h:357). Rotation is a quaternion, not
/// euler angles. Identity = `{{0,0,0},{0,0,0,1},{1,1,1}}`.
public struct FBXTransform: Sendable, Equatable {
    public var translation: FBXVec3
    public var rotation: FBXQuat
    public var scale: FBXVec3

    public init(translation: FBXVec3 = .zero, rotation: FBXQuat = .identity, scale: FBXVec3 = .one) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = FBXTransform()

    /// Same transform with `scale` forced to 1, for callers that need
    /// `ufbxi_unscaled_transform_to_matrix` semantics (ufbx.c:15818): the
    /// world-matrix chain used for skinning/scale-helper bookkeeping.
    public var unscaled: FBXTransform { FBXTransform(translation: translation, rotation: rotation, scale: .one) }

    /// Matches `ufbx_transform_to_matrix` (ufbx.c:31828): the `2*scale`
    /// factoring below is load-bearing (quaternion-to-rotation-matrix
    /// derivation folds a factor of 2 into the scale multiply), not a bug.
    public func toMatrix() -> FBXMatrix {
        let q = rotation
        let sx = 2.0 * scale.x, sy = 2.0 * scale.y, sz = 2.0 * scale.z
        let xx = q.x*q.x, xy = q.x*q.y, xz = q.x*q.z, xw = q.x*q.w
        let yy = q.y*q.y, yz = q.y*q.z, yw = q.y*q.w
        let zz = q.z*q.z, zw = q.z*q.w

        return FBXMatrix(
            m00: sx * (-yy - zz + 0.5), m10: sx * (xy + zw), m20: sx * (-yw + xz),
            m01: sy * (-zw + xy), m11: sy * (-xx - zz + 0.5), m21: sy * (xw + yz),
            m02: sz * (xz + yw), m12: sz * (-xw + yz), m22: sz * (-xx - yy + 0.5),
            m03: translation.x, m13: translation.y, m23: translation.z
        )
    }
}

// MARK: - Matrix (3x4 affine)

/// Mirrors `ufbx_matrix` (ufbx.h:367): a 4x3 affine matrix, column-major.
/// `cols.0..2` are the X/Y/Z basis vectors, `cols.3` is the translation.
/// There is no bottom row; it is implicitly `[0 0 0 1]`.
public struct FBXMatrix: Sendable, Equatable {
    public var cols: (FBXVec3, FBXVec3, FBXVec3, FBXVec3)

    public init(cols: (FBXVec3, FBXVec3, FBXVec3, FBXVec3) = (FBXVec3(1, 0, 0), FBXVec3(0, 1, 0), FBXVec3(0, 0, 1), .zero)) {
        self.cols = cols
    }

    public init(
        m00: Double, m10: Double, m20: Double,
        m01: Double, m11: Double, m21: Double,
        m02: Double, m12: Double, m22: Double,
        m03: Double, m13: Double, m23: Double
    ) {
        cols = (FBXVec3(m00, m10, m20), FBXVec3(m01, m11, m21), FBXVec3(m02, m12, m22), FBXVec3(m03, m13, m23))
    }

    public static let identity = FBXMatrix()

    public static func == (a: FBXMatrix, b: FBXMatrix) -> Bool {
        a.cols.0 == b.cols.0 && a.cols.1 == b.cols.1 && a.cols.2 == b.cols.2 && a.cols.3 == b.cols.3
    }

    // Row/column component accessors mirroring ufbx's `m<row><col>` naming,
    // used to keep the ported formulas below textually close to ufbx.c.
    @inlinable public var m00: Double { cols.0.x }
    @inlinable public var m10: Double { cols.0.y }
    @inlinable public var m20: Double { cols.0.z }
    @inlinable public var m01: Double { cols.1.x }
    @inlinable public var m11: Double { cols.1.y }
    @inlinable public var m21: Double { cols.1.z }
    @inlinable public var m02: Double { cols.2.x }
    @inlinable public var m12: Double { cols.2.y }
    @inlinable public var m22: Double { cols.2.z }
    @inlinable public var m03: Double { cols.3.x }
    @inlinable public var m13: Double { cols.3.y }
    @inlinable public var m23: Double { cols.3.z }

    /// Matches `ufbx_matrix_mul` (ufbx.c:31723): `a * b`, i.e. transforms a
    /// point by `b` first, then by `a`.
    public static func * (a: FBXMatrix, b: FBXMatrix) -> FBXMatrix {
        FBXMatrix(
            m00: a.m00*b.m00 + a.m01*b.m10 + a.m02*b.m20,
            m10: a.m10*b.m00 + a.m11*b.m10 + a.m12*b.m20,
            m20: a.m20*b.m00 + a.m21*b.m10 + a.m22*b.m20,
            m01: a.m00*b.m01 + a.m01*b.m11 + a.m02*b.m21,
            m11: a.m10*b.m01 + a.m11*b.m11 + a.m12*b.m21,
            m21: a.m20*b.m01 + a.m21*b.m11 + a.m22*b.m21,
            m02: a.m00*b.m02 + a.m01*b.m12 + a.m02*b.m22,
            m12: a.m10*b.m02 + a.m11*b.m12 + a.m12*b.m22,
            m22: a.m20*b.m02 + a.m21*b.m12 + a.m22*b.m22,
            m03: a.m00*b.m03 + a.m01*b.m13 + a.m02*b.m23 + a.m03,
            m13: a.m10*b.m03 + a.m11*b.m13 + a.m12*b.m23 + a.m13,
            m23: a.m20*b.m03 + a.m21*b.m13 + a.m22*b.m23 + a.m23
        )
    }

    /// Matches `ufbx_matrix_determinant` (ufbx.c:31749).
    public var determinant: Double {
        -m02*m11*m20 + m01*m12*m20 + m02*m10*m21
            - m00*m12*m21 - m01*m10*m22 + m00*m11*m22
    }

    /// Matches `ufbx_matrix_invert` (ufbx.c:31756).
    /// ufbx: near-singular matrices (`|det| <= UFBX_EPSILON`) invert to the
    /// **all-zero** matrix (not identity) — downstream muls then silently
    /// produce zero matrices rather than erroring.
    public func inverted() -> FBXMatrix {
        let det = determinant
        guard abs(det) > fbxEpsilon else {
            return FBXMatrix(cols: (.zero, .zero, .zero, .zero))
        }
        let rcpDet = 1.0 / det
        let r00 = (-m12*m21 + m11*m22) * rcpDet
        let r10 = (m12*m20 - m10*m22) * rcpDet
        let r20 = (-m11*m20 + m10*m21) * rcpDet
        let r01 = (m02*m21 - m01*m22) * rcpDet
        let r11 = (-m02*m20 + m00*m22) * rcpDet
        let r21 = (m01*m20 - m00*m21) * rcpDet
        let r02 = (-m02*m11 + m01*m12) * rcpDet
        let r12 = (m02*m10 - m00*m12) * rcpDet
        let r22 = (-m01*m10 + m00*m11) * rcpDet
        let r03 = (m03*m12*m21 - m02*m13*m21 - m03*m11*m22 + m01*m13*m22 + m02*m11*m23 - m01*m12*m23) * rcpDet
        let r13 = (m02*m13*m20 - m03*m12*m20 + m03*m10*m22 - m00*m13*m22 - m02*m10*m23 + m00*m12*m23) * rcpDet
        let r23 = (m03*m11*m20 - m01*m13*m20 - m03*m10*m21 + m00*m13*m21 + m01*m10*m23 - m00*m11*m23) * rcpDet
        return FBXMatrix(
            m00: r00, m10: r10, m20: r20,
            m01: r01, m11: r11, m21: r21,
            m02: r02, m12: r12, m22: r22,
            m03: r03, m13: r13, m23: r23
        )
    }

    /// Matches `ufbx_transform_position` (ufbx.c:31804): applies rotation,
    /// scale AND translation.
    public func transformPoint(_ v: FBXVec3) -> FBXVec3 {
        FBXVec3(
            m00*v.x + m01*v.y + m02*v.z + m03,
            m10*v.x + m11*v.y + m12*v.z + m13,
            m20*v.x + m21*v.y + m22*v.z + m23
        )
    }

    /// Matches `ufbx_transform_direction` (ufbx.c:31816): applies rotation
    /// and scale only, no translation.
    public func transformDirection(_ v: FBXVec3) -> FBXVec3 {
        FBXVec3(
            m00*v.x + m01*v.y + m02*v.z,
            m10*v.x + m11*v.y + m12*v.z,
            m20*v.x + m21*v.y + m22*v.z
        )
    }

    /// Matches `ufbx_matrix_to_transform` (ufbx.c:31854): a polar-ish
    /// decomposition — column lengths give scale, a negative determinant
    /// flips exactly one nonzero-scale axis, and the quaternion is extracted
    /// from the largest-trace branch of the rotation matrix.
    public func toTransform() -> FBXTransform {
        let det = determinant

        var t = FBXTransform()
        t.translation = cols.3
        t.scale = FBXVec3(cols.0.length, cols.1.length, cols.2.length)

        var signX = 1.0, signY = 1.0, signZ = 1.0
        if det < 0.0 {
            if t.scale.x > 0.0 { signX = -1.0 }
            else if t.scale.y > 0.0 { signY = -1.0 }
            else if t.scale.z > 0.0 { signZ = -1.0 }
        }

        let x = cols.0 * (t.scale.x > 0.0 ? signX / t.scale.x : 0.0)
        let y = cols.1 * (t.scale.y > 0.0 ? signY / t.scale.y : 0.0)
        let z = cols.2 * (t.scale.z > 0.0 ? signZ / t.scale.z : 0.0)
        let trace = x.x + y.y + z.z

        if trace > 0.0 {
            let a = Swift.max(0.0, trace + 1.0).squareRoot()
            let b = a != 0.0 ? 0.5 / a : 0.0
            t.rotation = FBXQuat(x: (y.z - z.y) * b, y: (z.x - x.z) * b, z: (x.y - y.x) * b, w: 0.5 * a)
        } else if x.x > y.y && x.x > z.z {
            let a = Swift.max(0.0, 1.0 + x.x - y.y - z.z).squareRoot()
            let b = a != 0.0 ? 0.5 / a : 0.0
            t.rotation = FBXQuat(x: 0.5 * a, y: (y.x + x.y) * b, z: (z.x + x.z) * b, w: (y.z - z.y) * b)
        } else if y.y > z.z {
            let a = Swift.max(0.0, 1.0 - x.x + y.y - z.z).squareRoot()
            let b = a != 0.0 ? 0.5 / a : 0.0
            t.rotation = FBXQuat(x: (y.x + x.y) * b, y: 0.5 * a, z: (z.y + y.z) * b, w: (z.x - x.z) * b)
        } else {
            let a = Swift.max(0.0, 1.0 - x.x - y.y + z.z).squareRoot()
            let b = a != 0.0 ? 0.5 / a : 0.0
            t.rotation = FBXQuat(x: (z.x + x.z) * b, y: (z.y + y.z) * b, z: 0.5 * a, w: (x.y - y.x) * b)
        }

        let len = t.rotation.x*t.rotation.x + t.rotation.y*t.rotation.y + t.rotation.z*t.rotation.z + t.rotation.w*t.rotation.w
        if abs(len - 1.0) > fbxEpsilon {
            if abs(len) <= fbxEpsilon {
                t.rotation = .identity
            } else {
                // ufbx: divides by `len` (not `sqrt(len)`) here — a literal
                // port of ufbx.c:31914-31917's (apparent) normalization quirk.
                t.rotation.x /= len
                t.rotation.y /= len
                t.rotation.z /= len
                t.rotation.w /= len
            }
        }

        t.scale.x *= signX
        t.scale.y *= signY
        t.scale.z *= signZ

        return t
    }
}
