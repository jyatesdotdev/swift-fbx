# Sources/SwiftFBX/Evaluate

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

Turns the parsed animation DOM (curves, anim values, layers, stacks — all
static, frozen data owned by `Scene/Animation.swift`) into concrete numbers at
an arbitrary time `t`: single-curve keyframe interpolation/extrapolation,
multi-layer property blending, and full FBX transform-chain reconstruction
from evaluated props. Nothing here mutates the scene; every entry point is a
pure function of `(anim/curve, time) -> value`.

## Files

- `CurveEval.swift` — the low-level numeric solver, all on `extension FBXAnimCurve`:
  - `evaluate(time:default:)` / `evaluateCurve(time:default:noExtrapolation:)` — ports
    `ufbx_evaluate_curve_flags` (ufbx.c:30832): hybrid binary/linear keyframe search + interpolation.
  - `static findCubicBezierT(_:_:_:)` — ports `ufbxi_find_cubic_bezier_t` (ufbx.c:25014): Newton-Raphson
    x-bezier solve.
  - `extrapolateCurve(realTime:)` — ports `ufbxi_extrapolate_curve` (ufbx.c:25977): constant/slope/
    repeat/mirror/repeat-relative extrapolation, KTime-tick-exact.
  - `static ktimeSecond` — the fixed 46186158000 ticks/second constant (v1 supports only FBX
    6100–7700, so this is a compile-time constant, not read from `scene.metadata`).
  - Free functions `evaluateAnimValueReal(_:time:noExtrapolation:)` / `evaluateAnimValueVec3(...)` —
    port `ufbx_evaluate_anim_value_real/vec3_flags` (ufbx.c:30926/30937).
- `AnimEval.swift` — layered prop + transform evaluation, on `extension FBXAnim`:
  - `evaluateProps(element:time:)` — ports `ufbx_evaluate_props` (ufbx.c:30991): full prop set for an
    element at `time`.
  - `evaluateTransform(node:time:)` — ports `ufbx_evaluate_transform` (ufbx.c:31025/31062): rebuilds
    the whole FBX transform chain via the shared `TransformChain.getTransform` (in
    `Scene/TransformChain.swift`, NOT this directory) — the same builder `SceneFinalizer` uses for
    the static `localTransform`.
  - `evaluateProp(element:name:time:noExtrapolation:)` — single-prop path, ports
    `ufbx_evaluate_prop_flags_len` (ufbx.c:30956).
  - `private evaluateSelectedProps` — ports `ufbxi_evaluate_selected_props` (ufbx.c:25926): merges a
    sorted prop-name whitelist against an element's sorted props.
  - `private applyAnimLayers` — ports `ufbxi_evaluate_props` (ufbx.c:25759): the multi-layer combiner
    loop.
  - `private combineAnimLayer` — ports `ufbxi_combine_anim_layer` (ufbx.c:25699): additive/blended/
    override math per prop, with special-cased `Lcl Rotation` (quaternion) and `Lcl Scaling`
    (log-space) handling.
  - `private evaluateConnectedProp` / `findPropConnection` — port `ufbxi_evaluate_connected_prop`
    (ufbx.c:25822) / `ufbxi_find_prop_connection` (ufbx.c:19271).
  - `private findAnimPropStart` — ports `ufbxi_find_anim_prop_start` (ufbx.c:19329): binary
    lower-bound into a layer's sorted `animProps`.
  - `private struct AnimLayerCombineCtx` — ports `ufbxi_anim_layer_combine_ctx` (ufbx.c:25681):
    carries the lazily-evaluated rotation order across the per-prop combine loop.
  - `enum AnimEval` (namespace, not a type instance) — `transformPropsAll` (byte-sorted 10-prop
    whitelist, ufbx.c:31030), `powAbs(_:_:)` (`ufbxi_pow_abs`, ufbx.c:25689), `findEnum(_:_:_:_:)`
    (`ufbxi_find_enum`, ufbx.c:11551).

## Business rules & invariants

- **Time units**: all `time:` parameters here are **seconds** (`Double`), matching `FBXKeyframe.time`.
  KTime ticks only appear internally inside `extrapolateCurve`, converted via `ktimeSecond` and
  converted back before returning — never leak ticks across a public boundary.
- **Tangents are derivatives, not control points.** `right.dy`/`left.dy` are added/subtracted from
  `value` to get the bezier control *value*; `right.dx`/`left.dx` are added/subtracted from `time` to
  get the control *x*, then normalized by `rcpDelta`. Getting the sign wrong on either silently
  produces plausible-looking but wrong curves — there is no crash to catch it.
- **The Newton-Raphson bezier solve has NO bisection fallback.** `findCubicBezierT` does exactly 3
  unrolled iterations, checks against `eps = 8.881784197001252e-16` (4 ULP near 1.0), then up to 4 more
  2-iteration blocks (11 iterations total, checked every 2), and returns whatever `t` it lands on if it
  never converges. Do not add a bisection/clamping fallback "for robustness" — ufbx doesn't have one and
  golden dumps are generated against curves that rely on exactly this iteration count.
- **Interpolation mode of the *previous* keyframe governs the whole span** to the next key — not the
  next key's mode, not an average.
- **Exact-time and first-key short-circuits are required, not optimizations you can drop**: `prev.time
  == time` returns `prev.value` directly (avoids a divide that could otherwise NaN on `rcpDelta` when
  two keys share a time), and a query at/before the first in-range key returns that key's value without
  extrapolating.
- **Layer-weight clamp uses a FLOAT literal promoted to double**: `if w > Double(Float(0.99999))` —
  this is `0.9999899864196777`, NOT the double literal `0.99999`. Do not simplify to `w > 0.99999`;
  weights in `(0.9999899864196777, 0.99999]` must snap to a pure override (weight = 1.0) exactly as
  ufbx does, or blended-layer golden cases will diverge by a hair that fails the tolerance check.
- **Layer 0 never blends** — the first layer that has an anim-prop entry for an element+prop writes the
  evaluated value directly into the result, regardless of that layer's `additive`/`blended`/override
  flags. This looks inconsistent but is exactly `ufbxi_evaluate_props` (ufbx.c:25759) behavior.
- **`Lcl Rotation` combines via quaternion slerp, not per-component euler lerp** — additive slerps `b`
  from identity by `weight` then multiplies onto `a`; blended slerps directly between `a` and `b`.
  These are two different quaternion code paths, not the same formula parameterized differently.
- **`Lcl Scaling` combines in log space via `powAbs`** (sign-preserving power: `e<=0→1`, `e>=1→v`, else
  `sign(v) * pow(|v|, e)`), never linear lerp — negative scales must blend keeping their sign.
- **Connections override animation by default** (`flags.contains(.connected) && !ignoreConnections`
  skips the layer loop for that prop) — an animated-and-connected prop's connection wins unless the
  caller's `FBXAnim.ignoreConnections` is set.
- **Connected-prop chains are cycle-guarded at exactly 1000 hops**; cyclic chains clear `.connected`
  and fall through to being treated as directly animatable rather than erroring.
- **`RotationOrder` is evaluated lazily, at most once per `combineAnimLayer` call-chain**, cached in
  `AnimLayerCombineCtx.hasRotationOrder` — only triggered for `Lcl Rotation` on a `composeRotation &&
  blended` layer. The recursive `evaluateProp` call this makes can only ever recurse into
  `RotationOrder` (never back into `Lcl Rotation`), so it is bounded to depth 1 — do not "fix" this into
  a loop that could recurse further.
- **`findEnum` returns the default UNCLAMPED** when the value is out of `[0, maxValue]` or the prop is
  absent — it does not clamp into range. `RotationOrder` out-of-range → `.xyz` default, not the nearest
  valid order.
- **`evaluateTransform` on a non-animated node must be byte-identical to `node.localTransform`** — both
  route through the same `TransformChain.getTransform` builder in `Scene/TransformChain.swift`. If you
  ever see them diverge, the bug is almost certainly a missed default value or prop-name typo in the
  whitelist merge (`evaluateSelectedProps`), not in `TransformChain` itself.
- **`PostRotation` is applied inverted; Pre/Post rotation are always XYZ order** regardless of the
  node's `RotationOrder` — only `Lcl Rotation` itself uses the node's rotation order. This is enforced
  inside `TransformChain`, not here, but `evaluateTransform`'s whitelist/order plumbing must still get
  the right `RotationOrder` value to it (see `AnimEval.findEnum(props, "RotationOrder", 0, 6)`).
- **Scale-helper / `inheritScaleNode` chain walk** in `evaluateTransform` is inert under v1's default
  load options (no helper nodes are synthesized), but is ported for fidelity — don't delete it as
  "dead code."
- **Prop ordering for the layer-combine merge loops (`applyAnimLayers`, `evaluateSelectedProps`) relies
  on props and anim-props both being pre-sorted** (by `(elementID, internalKey, name)` for anim-props,
  by name-key for element props) — these are two-cursor merges, not independent lookups; an unsorted
  input silently produces wrong/missing matches rather than crashing.

## Swift tips for this code

- `AnimLayerCombineCtx` is intentionally `private` and constructed fresh per `applyAnimLayers` call —
  do not hoist it to shared/static state; it caches per-(element,time) rotation order and must not leak
  across evaluations.
- The two-cursor prop-name matching (`FBXProp.nameKey`, `FBXProp.byteLess`) exists because ufbx compares
  *interned pointer identity* for prop names; Swift has no equivalent pointer pool, so this code falls
  back to `internalKey` prefilter + `==`/lexicographic `byteLess` on the `String`. Keep both — the key
  prefilter alone is not sufficient (hash collisions across different prop names are expected/allowed by
  design, same as ufbx's key).
- `evaluateProp`/`evaluateConnectedProp`/`combineAnimLayer` mutually recurse in a way that's easy to
  accidentally deepen when refactoring (e.g. adding a new "evaluate this related prop" call site) —
  check the recursion-bound comments before adding a new call to `evaluateProp` from inside the
  layer-combine or connected-prop paths.
- `FBXAnimCurve.evaluateCurve` and `findCubicBezierT` are `Double`-only; there is no `Float` fast path
  here, unlike some parser-layer code — do not introduce one for perf, it will not match golden output.
- `layer.scene.element(_:)` / element-id downcasts follow the arena/element-id convention from the
  parent AGENTS.md; nothing new here.

## Dependencies & boundaries

- Imports `Foundation` only. Depends on `Math/Math.swift` (`FBXQuat`, `FBXVec3`, `FBXRotationOrder`),
  `Scene/Animation.swift` (`FBXAnimCurve`, `FBXAnimValue`, `FBXAnimLayer`, `FBXAnim`, `FBXKeyframe`,
  `FBXExtrapolation`), `Scene/Properties.swift` (`FBXProp`, `FBXProps`, `FBXPropFlags`),
  `Scene/Elements.swift`/`Scene/Scene.swift` (`FBXElement`, element-id lookup), `Scene/Node.swift`
  (`FBXNode`), and `Scene/TransformChain.swift` (`TransformChain.getTransform` — shared with the
  finalizer, do not duplicate its logic here).
- Nothing in `Loader/*` or `Document/*` may depend on this directory — evaluation runs strictly after
  a scene is fully loaded and frozen (freeze rule from the parent AGENTS.md: `evaluate*` never mutates
  `element`/`node`/`layer`, it only reads and returns new value types).
- Public surface other modules rely on: `FBXAnimCurve.evaluate(time:default:)`,
  `FBXAnim.evaluateTransform(node:time:)`, `FBXAnim.evaluateProps(element:time:)` — these three are
  cited directly in DESIGN.md's "Internal contracts" and consumed by `FBXDumpCore/SceneDump.swift`.
  Keep their signatures stable.

## Testing

```
swift test --filter CurveEvalTests   # analytic keyframe/extrapolation/bezier-solve cases
swift test --filter GoldenTests      # exercises evaluateTransform via SceneDump on real anim stacks
```

- `Tests/SwiftFBXTests/CurveEvalTests.swift` covers `CurveEval.swift` directly (interpolation modes,
  extrapolation modes, bezier solve edge cases) with hand-computed expected values.
- `AnimEval.swift` (layer blending, transform reconstruction) has **no dedicated unit test file** — it
  is verified only through `GoldenTests` (`Sources/FBXDumpCore/SceneDump.swift` calls
  `stack.anim.evaluateTransform(node:time:)` while building the dump). If you change layer-blending or
  transform-eval logic, run the full golden suite, and consider adding targeted unit cases if you find
  a bug golden coverage didn't catch (multi-layer blend weight edge cases are the thinnest-covered
  area).

## Rules for the model

- Any behavior change in `CurveEval.swift` or `AnimEval.swift` must keep `GoldenTests` at 44/44 and
  `CurveEvalTests` green.
- Never "simplify" the Newton-Raphson iteration count, the float-literal weight-clamp constant, or the
  layer-0-writes-directly special case — these look like odd artifacts but are exact ufbx behavior;
  changing them changes animation output for real files.
- Consult `docs/ufbx-notes/11-anim-eval.md` (and the cited `ufbx.c` line) before changing any function
  here — this subsystem is explicitly called out in the notes as "the crown jewels; divergence produces
  subtly wrong animation," i.e. bugs here are silent, not crashes.
- If a transform-eval change is needed, check whether the fix actually belongs in
  `Scene/TransformChain.swift` instead (the shared pivot-chain builder) — don't fork/duplicate
  transform-chain logic into this directory to work around a bug that also affects static
  `localTransform`.
