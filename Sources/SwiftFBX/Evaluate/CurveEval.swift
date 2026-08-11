// Animation-curve evaluation: the low-level cubic bezier time solver, the
// single-curve keyframe interpolation, and out-of-range extrapolation. Ports
// `ufbxi_find_cubic_bezier_t` (ufbx.c:25014), `ufbx_evaluate_curve_flags`
// (ufbx.c:30832), `ufbxi_extrapolate_curve` (ufbx.c:25977) and the anim-value
// evaluators `ufbx_evaluate_anim_value_real/vec3_flags` (ufbx.c:30926/30937).
// These are numeric-exact ports (notes 11): divergence produces subtly wrong
// animation. Tangents are stored as (dx,dy) derivatives, converted to bezier
// control points inline.

import Foundation

extension FBXAnimCurve {

    // ufbx: extrapolation repeat/mirror math runs in KTime ticks. `ktime_second`
    // lives on `ufbx_scene.metadata` in ufbx but is not modeled on our
    // `FBXMetadata` (not dumped); v1 supports FBX 6100–7700, whose KTime unit is
    // always 46186158000 ticks/second (ufbx.c:ElementReader uses this for all
    // files < 8000). See DEVIATIONS in the port report.
    static let ktimeSecond: Double = 46_186_158_000.0

    /// Ports `ufbx_evaluate_curve` (ufbx.c:30827). Evaluates the curve at `time`,
    /// returning `default` for an empty curve.
    public func evaluate(time: Double, default defaultValue: Double) -> Double {
        evaluateCurve(time: time, default: defaultValue, noExtrapolation: false)
    }

    // ufbx: `ufbx_evaluate_curve_flags` (ufbx.c:30832). `noExtrapolation` mirrors
    // `UFBX_EVALUATE_FLAG_NO_EXTRAPOLATION` (set on the extrapolation recursion).
    func evaluateCurve(time: Double, default defaultValue: Double, noExtrapolation: Bool) -> Double {
        let keys = keyframes
        let count = keys.count
        if count <= 1 {
            return count == 1 ? keys[0].value : defaultValue
        }

        if !noExtrapolation {
            if time < minTime || time > maxTime {
                return extrapolateCurve(realTime: time)
            }
        }

        // ufbx: hybrid search — binary-halve while the span is ≥ 8, then reset
        // `end` to the full count and linear-scan for the first key past `time`.
        var begin = 0
        var end = count
        while end - begin >= 8 {
            let mid = (begin + end) >> 1
            if keys[mid].time <= time { begin = mid + 1 } else { end = mid }
        }

        end = count
        while begin < end {
            let next = keys[begin]
            if next.time <= time { begin += 1; continue }

            // First keyframe (query at/precedes first in-range key).
            if begin == 0 { return next.value }

            let prev = keys[begin - 1]

            // Exact keyframe short-circuit (avoids the divide).
            if prev.time == time { return prev.value }

            let rcpDelta = 1.0 / (next.time - prev.time)
            let t = (time - prev.time) * rcpDelta

            switch prev.interpolation {
            case .constantPrev:
                return prev.value
            case .constantNext:
                return next.value
            case .linear:
                return prev.value * (1.0 - t) + next.value * t
            case .cubic:
                // ufbx: normalized x of the two interior control points; the left
                // tangent is measured backward from `next` (ufbx.c:30888).
                let x1 = prev.right.dx * rcpDelta
                let x2 = 1.0 - next.left.dx * rcpDelta
                let tb = FBXAnimCurve.findCubicBezierT(x1, x2, t)

                let t2 = tb * tb, t3 = t2 * tb
                let u = 1.0 - tb, u2 = u * u, u3 = u2 * u

                // Tangents are derivatives, so control value = value ± dy.
                let y0 = prev.value
                let y3 = next.value
                let y1 = y0 + prev.right.dy
                let y2 = y3 - next.left.dy

                return u3 * y0 + 3.0 * (u2 * tb * y1 + u * t2 * y2) + t3 * y3
            }
        }

        // Last keyframe.
        return keys[count - 1].value
    }

    // ufbx: `ufbxi_find_cubic_bezier_t` (ufbx.c:25014). Solves the x-bezier for
    // the parameter `t` such that x(t) == x0, given the interior control x's
    // `p1,p2`. Pure Newton-Raphson: 3 unrolled iterations, an eps check, then up
    // to 4 more blocks of 2 iterations — NO bisection fallback. Port faithfully.
    static func findCubicBezierT(_ p1: Double, _ p2: Double, _ x0: Double) -> Double {
        let p1_3 = p1 * 3.0, p2_3 = p2 * 3.0
        let a = p1_3 - p2_3 + 1.0
        let b = p2_3 - p1_3 - p1_3
        let c = p1_3

        let a_3 = 3.0 * a, b_2 = 2.0 * b
        var t = x0
        var x1 = 0.0, t2 = 0.0, t3 = 0.0

        t2 = t * t; t3 = t2 * t; x1 = a * t3 + b * t2 + c * t - x0
        t -= x1 / (a_3 * t2 + b_2 * t + c)

        t2 = t * t; t3 = t2 * t; x1 = a * t3 + b * t2 + c * t - x0
        t -= x1 / (a_3 * t2 + b_2 * t + c)

        t2 = t * t; t3 = t2 * t; x1 = a * t3 + b * t2 + c * t - x0
        t -= x1 / (a_3 * t2 + b_2 * t + c)

        // 4 ULP from 1.0.
        let eps = 8.881784197001252e-16
        if abs(x1) <= eps { return t }

        for _ in 0..<4 {
            t2 = t * t; t3 = t2 * t; x1 = a * t3 + b * t2 + c * t - x0
            t -= x1 / (a_3 * t2 + b_2 * t + c)

            t2 = t * t; t3 = t2 * t; x1 = a * t3 + b * t2 + c * t - x0
            t -= x1 / (a_3 * t2 + b_2 * t + c)

            if abs(x1) <= eps { return t }
        }

        return t
    }

    // ufbx: `ufbxi_extrapolate_curve` (ufbx.c:25977). Called only when `time` is
    // outside [min_time, max_time] and extrapolation is enabled. Recurses once
    // into `evaluateCurve` with `noExtrapolation` for the REPEAT/MIRROR modes.
    private func extrapolateCurve(realTime: Double) -> Double {
        let keys = keyframes
        let pre = realTime < minTime
        let key: FBXKeyframe
        let ext: FBXExtrapolation
        if pre {
            key = keys[0]
            ext = preExtrapolation
        } else {
            key = keys[keys.count - 1]
            ext = postExtrapolation
        }

        switch ext.mode {
        case .constant:
            return key.value
        case .slope:
            // Linear extrapolation along the boundary tangent (right if pre).
            let tangent = pre ? key.right : key.left
            return key.value + tangent.dy * ((realTime - key.time) / tangent.dx)
        default:
            break
        }

        // repeat_count == 0 is treated as a constant hold.
        if ext.repeatCount == 0 { return key.value }

        // ufbx: all math in KTime ticks to be frame-perfect.
        let scale = FBXAnimCurve.ktimeSecond
        let minTick = (minTime * scale).rounded(.toNearestOrEven)
        let maxTick = (maxTime * scale).rounded(.toNearestOrEven)
        let timeTick = realTime * scale

        let delta = pre ? minTick - timeTick : timeTick - maxTick
        let duration = maxTick - minTick

        // Require at least one KTime unit.
        if !(duration >= 1.0) { return key.value }

        let rep = delta / duration
        var repN = rep.rounded(.down)
        var repD = delta - repN * duration

        if ext.repeatCount > 0 && repN >= Double(ext.repeatCount) {
            // Clamp to the repeat count to handle mirroring / hold at the extreme.
            repN = Double(ext.repeatCount - 1)
            repD = duration
        }

        if ext.mode == .mirror {
            let repParity = repN * 0.5 - (repN * 0.5).rounded(.down)
            if repParity <= 0.25 {
                repD = duration - repD
            }
        }

        if pre { repD = duration - repD }
        let newTime = (minTick + repD) / scale

        var value = evaluateCurve(time: newTime, default: key.value, noExtrapolation: true)

        if ext.mode == .repeatRelative {
            var valDelta = keys[keys.count - 1].value - keys[0].value
            if pre { valDelta = -valDelta }
            value += valDelta * (repN + 1.0)
        }

        return value
    }
}

// MARK: - Anim value evaluation

// ufbx: `ufbx_evaluate_anim_value_real_flags` (ufbx.c:30926). NULL → 0; seeds
// from `default_value.x`, overwritten by curves[0] if present.
func evaluateAnimValueReal(_ value: FBXAnimValue?, time: Double, noExtrapolation: Bool = false) -> Double {
    guard let value = value else { return 0.0 }
    var res = value.defaultValue.x
    if let c = value.curve(0) {
        res = c.evaluateCurve(time: time, default: res, noExtrapolation: noExtrapolation)
    }
    return res
}

// ufbx: `ufbx_evaluate_anim_value_vec3_flags` (ufbx.c:30937). NULL → zero-vec;
// seeds each component from `default_value`, replacing x/y/z from curves[0/1/2]
// when the corresponding curve is present.
func evaluateAnimValueVec3(_ value: FBXAnimValue?, time: Double, noExtrapolation: Bool = false) -> FBXVec3 {
    guard let value = value else { return .zero }
    var res = value.defaultValue
    if let c = value.curve(0) { res.x = c.evaluateCurve(time: time, default: res.x, noExtrapolation: noExtrapolation) }
    if let c = value.curve(1) { res.y = c.evaluateCurve(time: time, default: res.y, noExtrapolation: noExtrapolation) }
    if let c = value.curve(2) { res.z = c.evaluateCurve(time: time, default: res.z, noExtrapolation: noExtrapolation) }
    return res
}
