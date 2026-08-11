// Shared FBX transform-chain builder and accumulation/mirror helpers. Ports
// `ufbxi_get_transform` (ufbx.c:22836) and the transform accumulation helpers
// (ufbx.c:22628-22755).
//
// This is the SINGLE source for the full pivot chain: both `SceneFinalizer`
// (static `node.localTransform`) and `AnimEval` (`evaluateTransform`) call it, so
// `evaluateTransform` of a non-animated node is guaranteed byte-identical to
// `node.localTransform`. Previously this code was duplicated byte-for-byte across
// those two files, an invariant that could silently drift if one copy was edited
// without the other (see the api/medium review finding this resolves).

import Foundation

enum TransformChain {

    // ufbx: `ufbxi_get_transform` (ufbx.c:22836). The full FBX pivot chain
    //   M = T·Roff·Rp·Rpre·R·Rpost⁻¹·Rp⁻¹·Soff·Sp·S·Sp⁻¹
    // built by left-multiplying each op. PostRotation is INVERTED; Pre/PostRotation
    // are ALWAYS applied in XYZ order regardless of the node's rotation_order.
    static func getTransform(_ props: FBXProps, _ order: FBXRotationOrder,
                             _ node: FBXNode, _ translationScale: FBXVec3?) -> FBXTransform {
        let scalePivot = props.findVec3("ScalingPivot", .zero)
        let rotPivot = props.findVec3("RotationPivot", .zero)
        let scaleOffset = props.findVec3("ScalingOffset", .zero)
        let rotOffset = props.findVec3("RotationOffset", .zero)
        var translation = props.findVec3("Lcl Translation", .zero)
        let rotation = props.findVec3("Lcl Rotation", .zero)
        let scaling = props.findVec3("Lcl Scaling", .one)
        let preRotation = props.findVec3("PreRotation", .zero)
        let postRotation = props.findVec3("PostRotation", .zero)

        if let ts = translationScale { translation = translation * ts }

        var t = FBXTransform.identity

        if node.hasAdjustTransform {
            mulRotateQuat(&t, node.adjustPostRotation)
            mulScaleReal(&t, node.adjustPostScale)
        }

        subTranslate(&t, scalePivot)
        mulScale(&t, scaling)
        addTranslate(&t, scalePivot)

        addTranslate(&t, scaleOffset)

        subTranslate(&t, rotPivot)
        if node.useRotationSpace {
            mulInvRotate(&t, postRotation, .xyz)
            mulRotate(&t, rotation, order)
            mulRotate(&t, preRotation, .xyz)
        } else {
            mulRotate(&t, rotation, .xyz)
        }
        addTranslate(&t, rotPivot)

        addTranslate(&t, rotOffset)
        addTranslate(&t, translation)

        if node.hasAdjustTransform {
            addTranslate(&t, node.adjustPreTranslation)
            mulRotateQuat(&t, node.adjustPreRotation)
            mulScaleReal(&t, node.adjustPreScale)
            t.translation = t.translation * node.adjustTranslationScale
        }

        if node.adjustMirrorAxis != .none {
            mirrorTranslation(&t.translation, node.adjustMirrorAxis)
            mirrorRotation(&t.rotation, node.adjustMirrorAxis)
        }

        return t
    }

    // MARK: - Accumulation helpers (ufbx.c:22628-22741)

    // Each op left-multiplies `t` (composed on the outside of what `t` holds).
    static func addTranslate(_ t: inout FBXTransform, _ v: FBXVec3) { t.translation = t.translation + v }
    static func subTranslate(_ t: inout FBXTransform, _ v: FBXVec3) { t.translation = t.translation - v }

    static func mulScale(_ t: inout FBXTransform, _ v: FBXVec3) {
        t.translation = t.translation * v
        t.scale = t.scale * v
    }
    static func mulScaleReal(_ t: inout FBXTransform, _ v: Double) {
        t.translation = t.translation * v
        t.scale = t.scale * v
    }

    static func mulRotate(_ t: inout FBXTransform, _ v: FBXVec3, _ order: FBXRotationOrder) {
        if isVec3Zero(v) { return }
        let q = FBXQuat(euler: v, order: order)
        applyRotation(&t, q)
    }
    static func mulRotateQuat(_ t: inout FBXTransform, _ q: FBXQuat) {
        if isQuatIdentity(q) { return }
        applyRotation(&t, q)
    }
    // ufbx: PostRotation is applied inverted (conjugate = inverse for unit quats).
    static func mulInvRotate(_ t: inout FBXTransform, _ v: FBXVec3, _ order: FBXRotationOrder) {
        if isVec3Zero(v) { return }
        let e = FBXQuat(euler: v, order: order)
        applyRotation(&t, FBXQuat(x: -e.x, y: -e.y, z: -e.z, w: e.w))
    }
    static func applyRotation(_ t: inout FBXTransform, _ q: FBXQuat) {
        // ufbx: the `w != 1` guard is a micro-opt to avoid an identity quat-mul.
        t.rotation = t.rotation.w != 1.0 ? q * t.rotation : q
        if !isVec3Zero(t.translation) {
            t.translation = q.rotate(t.translation)
        }
    }

    // MARK: - Mirror helpers (ufbx.c:22745-22755, 23497-23521)

    static func mirrorTranslation(_ v: inout FBXVec3, _ axis: FBXMirrorAxis) {
        negateComponent(&v, axis.rawValue - 1)
    }
    static func mirrorRotation(_ q: inout FBXQuat, _ axis: FBXMirrorAxis) {
        let a = axis.rawValue
        negateQuatComponent(&q, a % 3)
        negateQuatComponent(&q, (a + 1) % 3)
    }
    static func mirrorMatrix(_ m: inout FBXMatrix, _ axis: FBXMirrorAxis) {
        guard axis != .none else { return }
        let ax = axis.rawValue - 1
        // src: negate whole column `ax`
        switch ax {
        case 0: m.cols.0 = -m.cols.0
        case 1: m.cols.1 = -m.cols.1
        default: m.cols.2 = -m.cols.2
        }
        // dst: negate component `ax` of every column
        negateComponent(&m.cols.0, ax)
        negateComponent(&m.cols.1, ax)
        negateComponent(&m.cols.2, ax)
        negateComponent(&m.cols.3, ax)
    }
    static func negateComponent(_ v: inout FBXVec3, _ i: Int) {
        switch i {
        case 0: v.x = -v.x
        case 1: v.y = -v.y
        default: v.z = -v.z
        }
    }
    static func negateQuatComponent(_ q: inout FBXQuat, _ i: Int) {
        switch i {
        case 0: q.x = -q.x
        case 1: q.y = -q.y
        default: q.z = -q.z
        }
    }

    static func isVec3Zero(_ v: FBXVec3) -> Bool { v.x == 0 && v.y == 0 && v.z == 0 }
    static func isQuatIdentity(_ q: FBXQuat) -> Bool { q.x == 0 && q.y == 0 && q.z == 0 && q.w == 1 }
}
