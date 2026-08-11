import XCTest
@testable import SwiftFBX

final class CurveEvalTests: XCTestCase {

    // Keep constructed scenes alive: elements hold `unowned let scene`.
    private var scenes: [FBXScene] = []

    private func makeCurve(_ keys: [FBXKeyframe],
                           pre: FBXExtrapolation = .init(),
                           post: FBXExtrapolation = .init()) -> FBXAnimCurve {
        let scene = FBXScene()
        scenes.append(scene)
        let c = FBXAnimCurve(scene: scene, name: "", props: FBXProps(),
                             elementID: 0, typedID: 0, fbxID: 0)
        c.keyframes = keys
        if let f = keys.first, let l = keys.last { c.minTime = f.time; c.maxTime = l.time }
        c.preExtrapolation = pre
        c.postExtrapolation = post
        return c
    }

    private func key(_ time: Double, _ value: Double,
                     _ interp: FBXInterpolation = .linear,
                     left: FBXTangent = .init(), right: FBXTangent = .init()) -> FBXKeyframe {
        FBXKeyframe(time: time, value: value, interpolation: interp, left: left, right: right)
    }

    // MARK: - Degenerate curves

    func testEmptyCurveReturnsDefault() {
        let c = makeCurve([])
        XCTAssertEqual(c.evaluate(time: 5.0, default: 42.0), 42.0)
        XCTAssertEqual(c.evaluate(time: -3.0, default: -7.0), -7.0)
    }

    func testSingleKeyReturnsKeyValue() {
        let c = makeCurve([key(0.0, 99.0)])
        XCTAssertEqual(c.evaluate(time: -100.0, default: 0.0), 99.0)
        XCTAssertEqual(c.evaluate(time: 0.0, default: 0.0), 99.0)
        XCTAssertEqual(c.evaluate(time: 100.0, default: 0.0), 99.0)
    }

    // MARK: - Linear

    func testLinearMidpoint() {
        let c = makeCurve([key(0.0, 0.0, .linear), key(4.0, 8.0, .linear)])
        XCTAssertEqual(c.evaluate(time: 2.0, default: 0.0), 4.0, accuracy: 1e-12)
        XCTAssertEqual(c.evaluate(time: 1.0, default: 0.0), 2.0, accuracy: 1e-12)
        XCTAssertEqual(c.evaluate(time: 3.0, default: 0.0), 6.0, accuracy: 1e-12)
    }

    func testLinearExactKeyframe() {
        let c = makeCurve([key(0.0, 1.0, .linear), key(2.0, 5.0, .linear)])
        // Exact-keyframe short-circuit returns the prev key value directly.
        XCTAssertEqual(c.evaluate(time: 2.0, default: 0.0), 5.0)
        XCTAssertEqual(c.evaluate(time: 0.0, default: 0.0), 1.0)
    }

    func testLinearEndpoints() {
        let c = makeCurve([key(0.0, 3.0, .linear), key(2.0, 7.0, .linear)])
        XCTAssertEqual(c.evaluate(time: 0.0, default: 0.0), 3.0)
        XCTAssertEqual(c.evaluate(time: 2.0, default: 0.0), 7.0)
    }

    // MARK: - Constant

    func testConstantPrev() {
        let c = makeCurve([key(0.0, 3.0, .constantPrev), key(2.0, 7.0, .constantPrev)])
        XCTAssertEqual(c.evaluate(time: 0.5, default: 0.0), 3.0)
        XCTAssertEqual(c.evaluate(time: 1.9, default: 0.0), 3.0)
    }

    func testConstantNext() {
        let c = makeCurve([key(0.0, 3.0, .constantNext), key(2.0, 7.0, .constantNext)])
        XCTAssertEqual(c.evaluate(time: 0.5, default: 0.0), 7.0)
        XCTAssertEqual(c.evaluate(time: 1.9, default: 0.0), 7.0)
    }

    // MARK: - Cubic (hand-computed)

    // Even-spaced x control points (dx = 1/3 of the span each) make x(t) == t, so
    // the value bezier with control points {0,0,1,1} is exactly the smoothstep
    // 3t² - 2t³ over the span [0,1].
    func testCubicSmoothstep() {
        let third = 1.0 / 3.0
        let c = makeCurve([
            key(0.0, 0.0, .cubic, right: FBXTangent(dx: third, dy: 0.0)),
            key(1.0, 1.0, .cubic, left: FBXTangent(dx: third, dy: 0.0)),
        ])
        func smoothstep(_ t: Double) -> Double { 3.0 * t * t - 2.0 * t * t * t }
        for t in [0.1, 0.25, 0.5, 0.75, 0.9] {
            XCTAssertEqual(c.evaluate(time: t, default: 0.0), smoothstep(t), accuracy: 1e-9)
        }
        XCTAssertEqual(c.evaluate(time: 0.0, default: 0.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(c.evaluate(time: 1.0, default: 0.0), 1.0, accuracy: 1e-12)
    }

    // Non-monotone value bezier: control points {0, 1, -1, 0} → 3·u·t·(u - t).
    func testCubicNonMonotone() {
        let third = 1.0 / 3.0
        let c = makeCurve([
            key(0.0, 0.0, .cubic, right: FBXTangent(dx: third, dy: 1.0)),
            key(1.0, 0.0, .cubic, left: FBXTangent(dx: third, dy: 1.0)),
        ])
        func expected(_ t: Double) -> Double { let u = 1.0 - t; return 3.0 * u * t * (u - t) }
        for t in [0.2, 0.25, 0.4, 0.6, 0.75, 0.8] {
            XCTAssertEqual(c.evaluate(time: t, default: 0.0), expected(t), accuracy: 1e-9)
        }
        // Symmetric antisymmetry: exactly zero at the midpoint.
        XCTAssertEqual(c.evaluate(time: 0.5, default: 0.0), 0.0, accuracy: 1e-9)
    }

    // MARK: - Bezier solver

    func testFindCubicBezierTInversion() {
        // x(t) = a t³ + b t² + c t with a = 3p1-3p2+1, b = 3p2-6p1, c = 3p1.
        let p1 = 0.1, p2 = 0.9
        let a = 3.0 * p1 - 3.0 * p2 + 1.0
        let b = 3.0 * p2 - 6.0 * p1
        let c = 3.0 * p1
        for tTrue in [0.05, 0.2, 0.3, 0.5, 0.7, 0.95] {
            let x0 = a * tTrue * tTrue * tTrue + b * tTrue * tTrue + c * tTrue
            let t = FBXAnimCurve.findCubicBezierT(p1, p2, x0)
            XCTAssertEqual(t, tTrue, accuracy: 1e-9)
        }
    }

    func testFindCubicBezierTEvenSpacingIsIdentity() {
        // p1 = 1/3, p2 = 2/3 → x(t) == t, so the solver returns x0 unchanged.
        for x0 in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(FBXAnimCurve.findCubicBezierT(1.0 / 3.0, 2.0 / 3.0, x0), x0, accuracy: 1e-12)
        }
    }

    // MARK: - Extrapolation

    func testConstantExtrapolationReturnsBoundaryValue() {
        // Default extrapolation mode is CONSTANT → hold the first/last key value.
        let c = makeCurve([key(0.0, 3.0, .linear), key(2.0, 7.0, .linear)])
        XCTAssertEqual(c.evaluate(time: -5.0, default: 0.0), 3.0)   // before range
        XCTAssertEqual(c.evaluate(time: 9.0, default: 0.0), 7.0)    // after range
    }

    func testSlopeExtrapolation() {
        // SLOPE uses the boundary tangent: pre uses right, post uses left.
        let pre = FBXExtrapolation(mode: .slope, repeatCount: -1)
        let post = FBXExtrapolation(mode: .slope, repeatCount: -1)
        let c = makeCurve([
            key(0.0, 0.0, .linear, right: FBXTangent(dx: 1.0, dy: 2.0)),
            key(2.0, 4.0, .linear, left: FBXTangent(dx: 1.0, dy: 2.0)),
        ], pre: pre, post: post)
        // post: value + left.dy * ((time - key.time) / left.dx) = 4 + 2*((3-2)/1) = 6
        XCTAssertEqual(c.evaluate(time: 3.0, default: 0.0), 6.0, accuracy: 1e-12)
        // pre: value + right.dy * ((time - key.time) / right.dx) = 0 + 2*((-1-0)/1) = -2
        XCTAssertEqual(c.evaluate(time: -1.0, default: 0.0), -2.0, accuracy: 1e-12)
    }

    // MARK: - Anim value composition

    func testAnimValueVec3Composition() {
        let scene = FBXScene()
        scenes.append(scene)
        let cx = FBXAnimCurve(scene: scene, name: "", props: FBXProps(), elementID: 0, typedID: 0, fbxID: 0)
        cx.keyframes = [key(0.0, 0.0, .linear), key(2.0, 10.0, .linear)]
        cx.minTime = 0; cx.maxTime = 2
        let cz = FBXAnimCurve(scene: scene, name: "", props: FBXProps(), elementID: 1, typedID: 1, fbxID: 1)
        cz.keyframes = [key(0.0, -4.0, .linear), key(2.0, 4.0, .linear)]
        cz.minTime = 0; cz.maxTime = 2
        let value = FBXAnimValue(scene: scene, name: "", props: FBXProps(), elementID: 2, typedID: 0, fbxID: 2)
        value.defaultValue = FBXVec3(0, 5, 0)   // y has no curve → stays at default
        value.curveIDs = [0, -1, 1]
        scene.elements = [cx, cz, value]

        let v = evaluateAnimValueVec3(value, time: 1.0)
        XCTAssertEqual(v.x, 5.0, accuracy: 1e-9)    // curve x at t=0.5
        XCTAssertEqual(v.y, 5.0, accuracy: 1e-9)    // default (no curve)
        XCTAssertEqual(v.z, 0.0, accuracy: 1e-9)    // curve z at t=0.5

        // Nil anim value → zero vector.
        XCTAssertEqual(evaluateAnimValueVec3(nil, time: 1.0), .zero)
        XCTAssertEqual(evaluateAnimValueReal(nil, time: 1.0), 0.0)
    }

    // MARK: - Layered prop evaluation

    func testEvaluatePropsSingleLayer() {
        let scene = FBXScene()
        scenes.append(scene)

        let nodeProps = FBXProps(props: [
            FBXProp(name: "Lcl Translation", type: .translation, flags: [.animated],
                    valueVec4: FBXVec4(0, 0, 0, 0)),
        ])
        let node = FBXNode(scene: scene, name: "n", props: nodeProps, elementID: 0, typedID: 0, fbxID: 0)

        let value = FBXAnimValue(scene: scene, name: "", props: FBXProps(), elementID: 1, typedID: 0, fbxID: 1)
        value.defaultValue = .zero
        value.curveIDs = [2, -1, -1]

        let curve = FBXAnimCurve(scene: scene, name: "", props: FBXProps(), elementID: 2, typedID: 0, fbxID: 2)
        curve.keyframes = [key(0.0, 0.0, .linear), key(2.0, 10.0, .linear)]
        curve.minTime = 0; curve.maxTime = 2

        let layer = FBXAnimLayer(scene: scene, name: "", props: FBXProps(), elementID: 3, typedID: 0, fbxID: 3)
        layer.animProps = [FBXAnimProp(elementID: 0, propName: "Lcl Translation", animValueID: 1)]

        scene.elements = [node, value, curve, layer]

        let anim = FBXAnim(layers: [layer])
        let props = anim.evaluateProps(element: node, time: 1.0)
        let p = props.find("Lcl Translation")
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.valueVec3.x, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p!.valueVec3.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(p!.valueVec3.z, 0.0, accuracy: 1e-9)
    }

    // A node with NO animated props must evaluate to exactly its static transform.
    func testEvaluateTransformNoAnimMatchesStaticChain() {
        let scene = FBXScene()
        scenes.append(scene)

        // Props sorted by (key, name): "Lcl Scaling" precedes "Lcl Translation".
        let nodeProps = FBXProps(props: [
            FBXProp(name: "Lcl Scaling", type: .scaling, valueVec4: FBXVec4(2, 2, 2, 0)),
            FBXProp(name: "Lcl Translation", type: .translation, valueVec4: FBXVec4(1, 2, 3, 0)),
        ])
        let node = FBXNode(scene: scene, name: "n", props: nodeProps, elementID: 0, typedID: 0, fbxID: 0)
        scene.elements = [node]

        // Empty anim, no animated flags → transform comes entirely from defaults.
        let anim = FBXAnim(layers: [])
        let t = anim.evaluateTransform(node: node, time: 0.0)
        XCTAssertEqual(t.translation, FBXVec3(1, 2, 3))
        XCTAssertEqual(t.scale, FBXVec3(2, 2, 2))
        XCTAssertEqual(t.rotation, FBXQuat.identity)
    }

    // Animated blended-layer weight uses ufbx's FLOAT saturation constant
    // (0.99999f == 0.9999899864196777), not the double 0.99999. At an evaluated
    // weight of exactly 0.99999 (Weight% == 99.999) ufbx snaps to a PURE override
    // (weight 1.0, no residual lower-layer blend); a double-literal `> 0.99999`
    // guard would keep 0.99999 and blend a residual. This asserts the override.
    func testAnimatedLayerWeightSaturatesWithFloatConstant() {
        let scene = FBXScene()
        scenes.append(scene)

        // Element ids are indices into scene.elements.
        let nodeProps = FBXProps(props: [
            FBXProp(name: "Lcl Translation", type: .translation, flags: [.animated],
                    valueVec4: FBXVec4(0, 0, 0, 0)),
        ])
        let node = FBXNode(scene: scene, name: "n", props: nodeProps, elementID: 0, typedID: 0, fbxID: 0)

        // Layer 0 base value (0), layer 1 override value (100), layer 1 weight (99.999%).
        let av0 = FBXAnimValue(scene: scene, name: "", props: FBXProps(), elementID: 1, typedID: 0, fbxID: 1)
        av0.defaultValue = FBXVec3(0, 0, 0)
        let av1 = FBXAnimValue(scene: scene, name: "", props: FBXProps(), elementID: 2, typedID: 1, fbxID: 2)
        av1.defaultValue = FBXVec3(100, 0, 0)
        let avW = FBXAnimValue(scene: scene, name: "", props: FBXProps(), elementID: 3, typedID: 2, fbxID: 3)
        avW.defaultValue = FBXVec3(99.999, 0, 0)   // /100 == 0.99999 exactly

        let layer0 = FBXAnimLayer(scene: scene, name: "", props: FBXProps(), elementID: 4, typedID: 0, fbxID: 4)
        layer0.animProps = [FBXAnimProp(elementID: 0, propName: "Lcl Translation", animValueID: 1)]

        let layer1 = FBXAnimLayer(scene: scene, name: "", props: FBXProps(), elementID: 5, typedID: 1, fbxID: 5)
        layer1.blended = true
        layer1.weightIsAnimated = true
        // Sorted by element_id: the node prop (0) precedes the layer's own Weight (5).
        layer1.animProps = [
            FBXAnimProp(elementID: 0, propName: "Lcl Translation", animValueID: 2),
            FBXAnimProp(elementID: 5, propName: "Weight", animValueID: 3),
        ]

        scene.elements = [node, av0, av1, avW, layer0, layer1]

        let anim = FBXAnim(layers: [layer0, layer1])
        let props = anim.evaluateProps(element: node, time: 0.0)
        let p = props.find("Lcl Translation")
        XCTAssertNotNil(p)
        // Pure override: 100.0. The pre-fix double guard would yield 99.999.
        XCTAssertEqual(p!.valueVec3.x, 100.0, accuracy: 1e-12)
    }

    // Guards that `evaluateTransform` and the static `localTransform` builder stay
    // in lockstep: both now call the single shared `TransformChain.getTransform`,
    // so a non-animated node with a FULL pivot chain (rotation space, pre/post
    // rotation, pivots, offsets, non-XYZ order) must evaluate byte-identically to
    // the transform that builder produces. This locks the two paths together so a
    // future edit that reintroduces a private copy would fail here.
    func testEvaluateTransformNoAnimMatchesSharedPivotChain() {
        let scene = FBXScene()
        scenes.append(scene)

        let props = FBXProps(props: [
            FBXProp(name: "Lcl Translation", type: .translation, valueVec4: FBXVec4(10, 20, 30, 0)),
            FBXProp(name: "Lcl Rotation", type: .rotation, valueVec4: FBXVec4(15, 25, 35, 0)),
            FBXProp(name: "Lcl Scaling", type: .scaling, valueVec4: FBXVec4(2, 3, 4, 0)),
            FBXProp(name: "PreRotation", type: .rotation, valueVec4: FBXVec4(5, 0, 0, 0)),
            FBXProp(name: "PostRotation", type: .rotation, valueVec4: FBXVec4(0, 10, 0, 0)),
            FBXProp(name: "RotationPivot", type: .vector, valueVec4: FBXVec4(1, 1, 1, 0)),
            FBXProp(name: "ScalingPivot", type: .vector, valueVec4: FBXVec4(0.5, 0.5, 0.5, 0)),
            FBXProp(name: "RotationOffset", type: .vector, valueVec4: FBXVec4(0.2, 0, 0, 0)),
            FBXProp(name: "ScalingOffset", type: .vector, valueVec4: FBXVec4(0, 0.3, 0, 0)),
            FBXProp(name: "RotationOrder", type: .integer, valueInt: 2),   // yzx
        ].sorted(by: FBXProp.less))

        let node = FBXNode(scene: scene, name: "n", props: props, elementID: 0, typedID: 0, fbxID: 0)
        node.rotationOrder = .yzx
        node.useRotationSpace = true
        scene.elements = [node]

        // Mirror what SceneFinalizer.updateNode does to fill `localTransform`.
        node.localTransform = TransformChain.getTransform(node.props, node.rotationOrder, node, nil)

        let anim = FBXAnim(layers: [])
        let evaluated = anim.evaluateTransform(node: node, time: 0.0)
        XCTAssertEqual(evaluated, node.localTransform)
    }

    func testEvaluateTransformRootReturnsLocal() {
        let scene = FBXScene()
        scenes.append(scene)
        let node = FBXNode(scene: scene, name: "root", props: FBXProps(), elementID: 0, typedID: 0, fbxID: 0)
        node.isRoot = true
        node.localTransform = FBXTransform(translation: FBXVec3(7, 8, 9))
        scene.elements = [node]

        let anim = FBXAnim(layers: [])
        let t = anim.evaluateTransform(node: node, time: 3.0)
        XCTAssertEqual(t.translation, FBXVec3(7, 8, 9))
    }
}
