// Layered property + transform evaluation against an `FBXAnim` descriptor.
// Ports `ufbxi_evaluate_props` (ufbx.c:25759), `ufbxi_combine_anim_layer`
// (25699), `ufbxi_evaluate_connected_prop` (25822), `ufbxi_evaluate_selected_props`
// (25926), `ufbx_evaluate_props_flags` (30996), `ufbx_evaluate_prop_flags_len`
// (30956) and `ufbx_evaluate_transform_flags` (31062). The final props → transform
// step calls the shared `TransformChain.getTransform` (a port of
// `ufbxi_get_transform`, 22836) — the SAME builder `SceneFinalizer` uses for the
// static `localTransform`, so `evaluateTransform` on a non-animated node is
// byte-identical to `node.localTransform`. See DEVIATIONS in the port report.

import Foundation

// ufbx: `ufbxi_anim_layer_combine_ctx` (ufbx.c:25681). Carries the lazily
// evaluated rotation order used when blending Euler `Lcl Rotation`.
private struct AnimLayerCombineCtx {
    let element: FBXElement
    let time: Double
    var rotationOrder: FBXRotationOrder = .xyz
    var hasRotationOrder: Bool = false
}

extension FBXAnim {

    // MARK: - Public entry points

    /// Ports `ufbx_evaluate_props` (ufbx.c:30991). Collects the element's
    /// animated / connected / overridden props, evaluates them against this
    /// anim's layers at `time`, and returns them with `defaults` chained to the
    /// element's static props.
    public func evaluateProps(element: FBXElement, time: Double) -> FBXProps {
        var buffer: [FBXProp] = []
        buffer.reserveCapacity(element.props.props.count)

        // No prop-overrides are modeled in v1, so the prop iterator is simply the
        // element's own (sorted) props.
        for prop in element.props.props {
            let f = prop.flags
            if !f.contains(.animated) && !f.contains(.overridden) && !f.contains(.connected) { continue }

            var dst = prop
            if f.contains(.connected) && !ignoreConnections {
                evaluateConnectedProp(&dst, element: element, name: prop.name, time: time)
            }
            buffer.append(dst)
        }

        applyAnimLayers(element: element, time: time, props: &buffer)
        return FBXProps(props: buffer, defaults: element.props)
    }

    /// Ports `ufbx_evaluate_transform` (ufbx.c:31025 / 31062). Rebuilds the full
    /// FBX transform chain from the animated transform props. A node with no
    /// animated props yields exactly `node.localTransform`.
    public func evaluateTransform(node: FBXNode, time: Double) -> FBXTransform {
        if node.isRoot { return node.localTransform }

        // The no-flags public path always includes rotation + scale + translation,
        // so the full transform builder (not the fast paths) is always used.
        var translationScale: FBXVec3? = nil
        var scaleFactor = FBXVec3.one
        var useScaleFactor = false

        if let parent = node.parent {
            // ufbx: componentwise-scale helper chain (31098). Inert under default
            // options (no helper nodes synthesized) but ported for fidelity.
            if let inheritScaleNode = parent.inheritScaleNode {
                if node.isScaleHelper { useScaleFactor = true }
                var p: FBXNode? = inheritScaleNode
                while let pp = p, let sh = pp.scaleHelper {
                    let scale = evaluateProp(element: sh, name: "Lcl Scaling", time: time)
                    scaleFactor.x *= scale.valueVec4.x
                    scaleFactor.y *= scale.valueVec4.y
                    scaleFactor.z *= scale.valueVec4.z
                    p = pp.inheritScaleNode
                }
            }

            if let sh = parent.scaleHelper {
                var helper = evaluateProp(element: sh, name: "Lcl Scaling", time: time)
                var hv = helper.valueVec3
                if helper.flags.contains(.notFound) { hv = .one }
                hv.x *= scaleFactor.x
                hv.y *= scaleFactor.y
                hv.z *= scaleFactor.z
                helper.valueVec4 = FBXVec4(hv.x, hv.y, hv.z, helper.valueVec4.w)
                translationScale = hv
            }
        }

        let props = evaluateSelectedProps(element: node, time: time, propNames: AnimEval.transformPropsAll)
        let order = FBXRotationOrder(rawValue: AnimEval.findEnum(props, "RotationOrder", 0, 6)) ?? .xyz

        var transform = TransformChain.getTransform(props, order, node, translationScale)
        if useScaleFactor {
            transform.scale.x *= scaleFactor.x
            transform.scale.y *= scaleFactor.y
            transform.scale.z *= scaleFactor.z
        }
        return transform
    }

    // MARK: - Single prop (ufbx_evaluate_prop_flags_len, ufbx.c:30956)

    func evaluateProp(element: FBXElement, name: String, time: Double, noExtrapolation: Bool = false) -> FBXProp {
        var result: FBXProp
        if let prop = element.props.find(name) {
            result = prop
        } else {
            result = FBXProp(name: name, flags: [.notFound])
        }

        // No prop-overrides modeled: skip the override apply/return branch.
        if !result.flags.contains(.animated) && !result.flags.contains(.connected) {
            return result
        }

        if result.flags.contains(.connected) && !ignoreConnections {
            evaluateConnectedProp(&result, element: element, name: name, time: time, noExtrapolation: noExtrapolation)
        }

        var arr = [result]
        applyAnimLayers(element: element, time: time, props: &arr, noExtrapolation: noExtrapolation)
        return arr[0]
    }

    // MARK: - Selected prop merge (ufbxi_evaluate_selected_props, ufbx.c:25926)

    // Merges a SORTED whitelist of prop names against the element's sorted prop
    // list, keeping only the animated / connected / overridden ones, then runs
    // the layer combiner. `defaults` chains to the element's static props.
    private func evaluateSelectedProps(element: FBXElement, time: Double, propNames: [String],
                                       noExtrapolation: Bool = false) -> FBXProps {
        var buffer: [FBXProp] = []
        let maxProps = propNames.count
        var nameIx = 0
        var name = propNames[0]
        var key = FBXProp.nameKey(name)

        for prop in element.props.props {
            while nameIx < maxProps {
                if key > prop.internalKey { break }
                if name == prop.name {
                    if prop.flags.contains(.connected) && !ignoreConnections {
                        var dst = prop
                        evaluateConnectedProp(&dst, element: element, name: name, time: time, noExtrapolation: noExtrapolation)
                        buffer.append(dst)
                    } else if prop.flags.contains(.animated) || prop.flags.contains(.overridden) {
                        buffer.append(prop)
                    }
                    break
                } else if FBXProp.byteLess(name, prop.name) {
                    nameIx += 1
                    if nameIx < maxProps {
                        name = propNames[nameIx]
                        key = FBXProp.nameKey(name)
                    }
                } else {
                    break
                }
            }
        }

        applyAnimLayers(element: element, time: time, props: &buffer, noExtrapolation: noExtrapolation)
        return FBXProps(props: buffer, defaults: element.props)
    }

    // MARK: - Layer combiner (ufbxi_evaluate_props, ufbx.c:25759)

    private func applyAnimLayers(element: FBXElement, time: Double, props: inout [FBXProp],
                                 noExtrapolation: Bool = false) {
        var ctx = AnimLayerCombineCtx(element: element, time: time)
        let elementID = Int32(element.elementID)

        for (layerIx, layer) in layers.enumerated() {
            // ufbx uses a bloom filter (`_element_id_bitmask`) to reject layers
            // early; it is a pure optimization (identical result) not modeled here.

            var weight = layerIx < overrideLayerWeights.count ? overrideLayerWeights[layerIx] : layer.weight
            if layer.weightIsAnimated && layer.blended {
                if let wi = findAnimPropStart(layer, Int32(layer.elementID)) {
                    let av = layer.scene.element(layer.animProps[wi].animValueID) as? FBXAnimValue
                    var w = evaluateAnimValueReal(av, time: time, noExtrapolation: noExtrapolation) / 100.0
                    if w < 0.0 { w = 0.0 }
                    // ufbx: `if (weight > 0.99999f) weight = 1.0f;` (ufbx.c:25790).
                    // The constant is a FLOAT literal promoted to double
                    // (= 0.9999899864196777), NOT the double 0.99999; match it
                    // bit-for-bit so weights in (0.9999899864196777, 0.99999] snap
                    // to a pure override exactly as ufbx does.
                    if w > Double(Float(0.99999)) { w = 1.0 }
                    weight = w
                }
            }

            guard let start = findAnimPropStart(layer, elementID) else { continue }
            let aprops = layer.animProps
            let count = aprops.count
            var apropIdx = start

            for i in props.indices {
                let flags = props[i].flags
                // Don't evaluate on top of overridden props.
                if flags.contains(.overridden) { continue }
                // Connections override animation by default.
                if flags.contains(.connected) && !ignoreConnections { continue }

                let propKey = props[i].internalKey
                let propName = props[i].name

                // Skip until aprop >= prop, first by key, then by name (strcmp).
                while apropIdx < count && aprops[apropIdx].elementID == elementID
                    && FBXProp.nameKey(aprops[apropIdx].propName) < propKey {
                    apropIdx += 1
                }
                if !(apropIdx < count && aprops[apropIdx].elementID == elementID && aprops[apropIdx].propName == propName) {
                    while apropIdx < count && aprops[apropIdx].elementID == elementID
                        && FBXProp.byteLess(aprops[apropIdx].propName, propName) {
                        apropIdx += 1
                    }
                }

                if apropIdx < count && aprops[apropIdx].elementID == elementID && aprops[apropIdx].propName == propName {
                    let av = layer.scene.element(aprops[apropIdx].animValueID) as? FBXAnimValue
                    let v = evaluateAnimValueVec3(av, time: time, noExtrapolation: noExtrapolation)
                    if layerIx == 0 {
                        // First matching layer writes directly (never blends).
                        props[i].valueVec4.x = v.x
                        props[i].valueVec4.y = v.y
                        props[i].valueVec4.z = v.z
                    } else {
                        combineAnimLayer(&ctx, layer, weight, propName, &props[i], v)
                    }
                }
            }
        }

        // ufbx: derive the integer form from the evaluated real (saturating).
        for i in props.indices {
            if props[i].flags.contains(.overridden) { continue }
            props[i].valueInt = FBXValue.f64ToI64(props[i].valueReal)
        }
    }

    // ufbx: `ufbxi_combine_anim_layer` (ufbx.c:25699). Blends `value` into
    // `result` per the layer's additive / blended / override mode, with special
    // quaternion handling for `Lcl Rotation` and log-space handling for
    // `Lcl Scaling`.
    private func combineAnimLayer(_ ctx: inout AnimLayerCombineCtx, _ layer: FBXAnimLayer,
                                  _ weight: Double, _ propName: String,
                                  _ result: inout FBXProp, _ value: FBXVec3) {
        if layer.composeRotation && layer.blended && propName == "Lcl Rotation" && !ctx.hasRotationOrder {
            // Recursion-bounded: only recurses on Lcl Rotation, evaluating only
            // RotationOrder (which is never Lcl Rotation).
            let rp = evaluateProp(element: ctx.element, name: "RotationOrder", time: ctx.time)
            let ri = rp.valueInt
            if ri >= 0 && ri <= 6 {
                ctx.rotationOrder = FBXRotationOrder(rawValue: Int(ri)) ?? .xyz
            } else {
                ctx.rotationOrder = .xyz
            }
            ctx.hasRotationOrder = true
        }

        var rx = result.valueVec4.x, ry = result.valueVec4.y, rz = result.valueVec4.z

        if layer.additive {
            if layer.composeScale && propName == "Lcl Scaling" {
                rx *= AnimEval.powAbs(value.x, weight)
                ry *= AnimEval.powAbs(value.y, weight)
                rz *= AnimEval.powAbs(value.z, weight)
            } else if layer.composeRotation && propName == "Lcl Rotation" {
                let a = FBXQuat(euler: FBXVec3(rx, ry, rz), order: ctx.rotationOrder)
                var b = FBXQuat(euler: value, order: ctx.rotationOrder)
                b = FBXQuat.slerp(.identity, b, weight)
                let e = (a * b).toEuler(order: ctx.rotationOrder)
                rx = e.x; ry = e.y; rz = e.z
            } else {
                rx += value.x * weight
                ry += value.y * weight
                rz += value.z * weight
            }
        } else if layer.blended {
            let resWeight = 1.0 - weight
            if layer.composeScale && propName == "Lcl Scaling" {
                rx = AnimEval.powAbs(rx, resWeight) * AnimEval.powAbs(value.x, weight)
                ry = AnimEval.powAbs(ry, resWeight) * AnimEval.powAbs(value.y, weight)
                rz = AnimEval.powAbs(rz, resWeight) * AnimEval.powAbs(value.z, weight)
            } else if layer.composeRotation && propName == "Lcl Rotation" {
                let a = FBXQuat(euler: FBXVec3(rx, ry, rz), order: ctx.rotationOrder)
                let b = FBXQuat(euler: value, order: ctx.rotationOrder)
                let e = FBXQuat.slerp(a, b, weight).toEuler(order: ctx.rotationOrder)
                rx = e.x; ry = e.y; rz = e.z
            } else {
                rx = rx * resWeight + value.x * weight
                ry = ry * resWeight + value.y * weight
                rz = rz * resWeight + value.z * weight
            }
        } else {
            // Override layer: hard replace, ignores weight.
            rx = value.x; ry = value.y; rz = value.z
        }

        result.valueVec4.x = rx
        result.valueVec4.y = ry
        result.valueVec4.z = rz
    }

    // MARK: - Connected props (ufbxi_evaluate_connected_prop, ufbx.c:25822)

    private func evaluateConnectedProp(_ prop: inout FBXProp, element: FBXElement, name: String,
                                       time: Double, noExtrapolation: Bool = false) {
        let scene = element.scene
        guard var conn = findPropConnection(element, name) else {
            prop.flags.remove(.connected)
            return
        }

        // Follow the property-connection chain to its source (max 1000 hops).
        var i = 0
        while i < 1000 {
            guard let srcElem = scene.element(conn.srcID),
                  let next = findPropConnection(srcElem, conn.srcProp) else { break }
            conn = next
            i += 1
        }

        if let srcElem = scene.element(conn.srcID), findPropConnection(srcElem, conn.srcProp) == nil {
            // Non-cyclic terminal: evaluate the source prop and copy its value.
            let ep = evaluateProp(element: srcElem, name: conn.srcProp, time: time, noExtrapolation: noExtrapolation)
            prop.valueVec4 = ep.valueVec4
            prop.valueInt = ep.valueInt
            prop.valueString = ep.valueString
            prop.valueBlob = ep.valueBlob
        } else {
            // Cyclic / unresolved: treat as animatable.
            prop.flags.remove(.connected)
        }
    }

    // ufbx: `ufbxi_find_prop_connection` (ufbx.c:19271). First (in dst-sorted
    // order) connection targeting `element.prop` with a non-empty src prop.
    private func findPropConnection(_ element: FBXElement, _ prop: String) -> FBXConnection? {
        let scene = element.scene
        let conns = scene.connections
        let order = scene.connectionsDstOrder
        for idx in element.connectionsDst {
            let c = conns[Int(order[idx])]
            if c.dstProp == prop && !c.srcProp.isEmpty { return c }
        }
        return nil
    }

    // ufbx: `ufbxi_find_anim_prop_start` (ufbx.c:19329). Lower-bound into the
    // layer's `(element_id, key, name)`-sorted anim props for `elementID`.
    private func findAnimPropStart(_ layer: FBXAnimLayer, _ elementID: Int32) -> Int? {
        let arr = layer.animProps
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if arr[mid].elementID < elementID { lo = mid + 1 } else { hi = mid }
        }
        return (lo < arr.count && arr[lo].elementID == elementID) ? lo : nil
    }
}

// MARK: - Transform-eval helpers

// Layer-blend helpers + the transform prop whitelist used by `evaluateTransform`.
// The FBX pivot chain itself lives in the shared `TransformChain` (see that file),
// which `evaluateTransform` calls so a non-animated node's evaluated transform is
// byte-identical to its static `localTransform`.
enum AnimEval {

    // ufbx: transform prop whitelist, byte-sorted (ufbx.c:31030).
    static let transformPropsAll: [String] = [
        "Lcl Rotation",
        "Lcl Scaling",
        "Lcl Translation",
        "PostRotation",
        "PreRotation",
        "RotationOffset",
        "RotationOrder",
        "RotationPivot",
        "ScalingOffset",
        "ScalingPivot",
    ]

    // ufbx: `ufbxi_pow_abs` (ufbx.c:25689) — sign-preserving power.
    static func powAbs(_ v: Double, _ e: Double) -> Double {
        if e <= 0.0 { return 1.0 }
        if e >= 1.0 { return v }
        let sign = v < 0.0 ? -1.0 : 1.0
        return sign * pow(v * sign, e)
    }

    // ufbx: `ufbxi_find_enum` (ufbx.c:11551) — returns `def` (NOT clamped) when
    // the value is out of [0, max] or the prop is absent.
    static func findEnum(_ props: FBXProps, _ name: String, _ def: Int, _ maxValue: Int) -> Int {
        guard let p = props.find(name) else { return def }
        let v = Int(p.valueInt)
        return (v >= 0 && v <= maxValue) ? v : def
    }
}
