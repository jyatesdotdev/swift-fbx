# Animation & Curve Evaluation

## Purpose
This subsystem turns the loaded animation DOM (curves, anim-values, layers, stacks) into concrete
values at an arbitrary time `t`: it evaluates a single animation curve (keyframe search + interpolation
+ extrapolation), combines the 1–3 curves of an `ufbx_anim_value`, blends contributions from multiple
animation layers (override / additive / blended, with special quaternion handling for rotation and
log-space handling for scale), applies property overrides, and finally reconstructs full node
`ufbx_transform`s from the evaluated FBX transform properties. It also implements the two "produce a new
thing" APIs: `ufbx_create_anim` (custom anim descriptor with overrides) and `ufbx_evaluate_scene`
(deep-copy the scene and re-evaluate every animated element at time `t`). It spans the low-level cubic
bezier time solver (25014) through the public `ufbx_evaluate_*` API (30827–31192).

## Key data structures
(All in ufbx.h unless noted.)

- **`ufbx_tangent`** (3186): `{ float dx; float dy; }` — a keyframe tangent expressed as a *derivative*
  (rise `dy` over run `dx`), NOT a control point. `dx` is in seconds (time delta), `dy` is in value units.
- **`ufbx_keyframe`** (3203): `{ double time; ufbx_real value; ufbx_interpolation interpolation;
  ufbx_tangent left; ufbx_tangent right; }`. The `interpolation` of the **previous** key governs the
  span between it and the next key. For CUBIC, the bezier control points are:
  P0 = (time, value); P1 = (time+right.dx, value+right.dy); P2 = (next.time-next.left.dx,
  next.value-next.left.dy); P3 = (next.time, next.value).
- **`ufbx_interpolation`** (3154): CONSTANT_PREV=0, CONSTANT_NEXT=1, LINEAR=2, CUBIC=3.
- **`ufbx_extrapolation_mode`** (3165): CONSTANT=0, REPEAT=1, MIRROR=2, SLOPE=3, REPEAT_RELATIVE=4.
- **`ufbx_extrapolation`** (3177): `{ mode; int32_t repeat_count; }`. `repeat_count` negative = infinite,
  0 handled specially (falls back to constant), positive = clamp.
- **`ufbx_anim_curve`** (3213): element with `keyframes` (sorted by time), `pre_extrapolation`,
  `post_extrapolation`, `min/max_value`, `min/max_time`. Sits inside `element.scene` whose
  `metadata.ktime_second` is used by extrapolation.
- **`ufbx_anim_value`** (3141): element with `ufbx_vec3 default_value` and `ufbx_anim_curve *curves[3]`
  (any may be NULL). curves[0]→x (and the "real" scalar), [1]→y, [2]→z.
- **`ufbx_anim_prop`** (3105): `{ ufbx_element *element; uint32_t _internal_key; ufbx_string prop_name;
  ufbx_anim_value *anim_value; }`. Layers store `anim_props` sorted by `(element, prop_name)`,
  terminated by a zeroed NULL-sentinel entry.
- **`ufbx_anim_layer`** (3116): weight, `weight_is_animated`, `blended`, `additive`,
  `compose_rotation`, `compose_scale` flags; `anim_values`, `anim_props`; plus an acceleration
  structure `_min_element_id`, `_max_element_id`, `_element_id_bitmask[4]` (128-bit bloom filter over
  element ids, indexed `(id>>5)&3`, bit `id&31`).
- **`ufbx_anim`** (3064): the evaluation descriptor. `layers`, optional `override_layer_weights`
  (parallel to layers), `prop_overrides` (sorted by element_id then internal_key then name),
  `transform_overrides` (sorted by node_id), `ignore_connections`, `custom`.
- **`ufbx_prop_override`** (3038): `{ element_id; _internal_key; prop_name; vec4 value; value_str;
  int64_t value_int; }`.
- **`ufbx_transform_override`** (3051): `{ uint32_t node_id; ufbx_transform transform; }`.
- **`ufbxi_prop_iter`** (25847, ufbx.c): merge-iterator over an element's own props and the anim's
  prop-overrides for that element; yields props in key order, materializing an overridden `tmp` prop
  when an override wins.
- **`ufbxi_anim_layer_combine_ctx`** (25681, ufbx.c): `{ anim; element; time; rotation_order;
  has_rotation_order; }` — carries the lazily-evaluated rotation order used when blending Euler rotation.

## Control flow / algorithms

### 1. Cubic bezier time solve — `ufbxi_find_cubic_bezier_t(p1, p2, x0)` (25014)
Given normalized x-coordinates of the two interior bezier control points `p1,p2 ∈ [0,1]` and a target
normalized time `x0`, find bezier parameter `t` such that the x-bezier equals `x0`. Sets up the cubic
`x(t) = a·t³ + b·t² + c·t` with `a = 3p1-3p2+1`, `b = 3p2-6p1` (`= 3p2 - 3p1 - 3p1`), `c = 3p1`.
Newton-Raphson: `t -= (x(t)-x0)/x'(t)`, `x'(t) = 3a·t² + 2b·t + c`. Starts `t = x0`, unrolls exactly 3
iterations, then checks residual against `eps = 8.881784197001252e-16` (4 ULP near 1.0); if not
converged does up to 4 more blocks of 2 iterations each (checking every 2), then returns whatever `t` it
has. No bisection fallback — pure Newton. Port faithfully (double precision).

### 2. Single curve — `ufbx_evaluate_curve_flags(curve, time, default_value, flags)` (30832)
1. NULL curve → default_value. 0 keys → default_value; exactly 1 key → that key's value.
2. If `NO_EXTRAPOLATION` flag not set and `time < min_time || time > max_time`, delegate to
   `ufbxi_extrapolate_curve` (see §3).
3. **Keyframe search**: hybrid binary + linear. Binary-search halves `[begin,end)` while span ≥ 8,
   moving `begin=mid+1` when `keys[mid].time <= time` else `end=mid`. Then reset `end=count` and linear
   scan from `begin` for the first key with `time > query` — call it `next`, `prev = next-1`.
4. Edge: if that first `next` is index 0 → return `next->value` (query before/at first key inside range).
   If `prev->time == time` exactly → return `prev->value`. If the scan runs off the end → return last
   key's value.
5. Compute `rcp_delta = 1/(next.time-prev.time)`, `t = (time-prev.time)*rcp_delta` (normalized 0..1).
6. Switch on **prev->interpolation**:
   - CONSTANT_PREV → prev.value; CONSTANT_NEXT → next.value.
   - LINEAR → `prev.value*(1-t) + next.value*t`.
   - CUBIC (30888): `x1 = prev.right.dx*rcp_delta`, `x2 = 1 - next.left.dx*rcp_delta` (normalized x of
     the two interior control points). `t = ufbxi_find_cubic_bezier_t(x1,x2,t)`. Then de Casteljau /
     Bernstein evaluate the **value** bezier: `y0=prev.value`, `y3=next.value`,
     `y1=y0+prev.right.dy`, `y2=y3-next.left.dy`, result =
     `u³y0 + 3(u²t·y1 + u·t²·y2) + t³y3` with `u=1-t`. Note tangents are derivatives so the control
     *value* is `value ± dy` (right adds, left subtracts).

### 3. Extrapolation — `ufbxi_extrapolate_curve(curve, real_time, flags)` (25977)
Recursive (calls `ufbx_evaluate_curve_flags` with `NO_EXTRAPOLATION`; recursion depth 1).
- `pre = real_time < min_time`. Pick boundary `key` (first or last) and `ext` (pre/post).
- CONSTANT → key.value. SLOPE → linear extrapolate using the boundary tangent (`right` if pre else
  `left`): `key.value + tangent.dy*((real_time-key.time)/tangent.dx)`. `repeat_count==0` → key.value.
- Otherwise (REPEAT/MIRROR/REPEAT_RELATIVE): **all math in KTime ticks** using
  `scale = metadata.ktime_second`; round `min_time`,`max_time` to ticks with `ufbx_rint`. `duration =
  max-min`; if `duration < 1` tick → key.value. Compute `delta` (distance outside range), `rep_n =
  floor(delta/duration)` = number of full repeats, `rep_d = delta - rep_n*duration` = offset within a
  period. If `repeat_count>0 && rep_n >= repeat_count`, clamp `rep_n = repeat_count-1`, `rep_d =
  duration` (mirror/hold at the extreme).
  - MIRROR: parity of `rep_n` (via `rep_n*0.5 - floor(rep_n*0.5) <= 0.25`) decides whether to reflect
    `rep_d = duration - rep_d`.
  - For pre side, `rep_d = duration - rep_d` (time flows backward).
  - `new_time = (min_time + rep_d)/scale`; recursively evaluate the curve there with NO_EXTRAPOLATION.
  - REPEAT_RELATIVE: add `(lastValue-firstValue) * (rep_n+1)` (negated for pre) so repeats stack.

### 4. Anim value — `ufbx_evaluate_anim_value_real_flags` (30926) / `..._vec3_flags` (30937)
NULL → 0 / zero-vec. Start from `default_value`; for the real variant only curves[0] is used
(overwriting x). Vec3 replaces x,y,z from curves[0],[1],[2] respectively, each only if non-NULL,
seeding each with the corresponding default component.

### 5. Layer blending — `ufbxi_evaluate_props(anim, element, time, props, num_props, flags)` (25759)
This is the core multi-layer combiner. `props[]` are pre-filled with the element's current prop values
(defaults) for the props we care about. For each layer in order:
1. Skip if `ufbxi_anim_layer_might_contain_id` (25751) bloom filter says the element id is absent.
2. Determine layer `weight`: `override_layer_weights[layer_ix]` if present else `layer->weight`. If the
   layer's weight itself is animated (`weight_is_animated && blended`), find the layer-element's weight
   anim prop and evaluate it, divide by 100, clamp to `[0,1]` (>0.99999 snaps to 1).
3. `ufbxi_find_anim_prop_start(layer, element)` (19329) — lower-bound into the layer's sorted
   `anim_props` for this element; NULL → skip layer.
4. Walk `props[]`; for each: skip if already OVERRIDDEN; skip if CONNECTED and `!ignore_connections`.
   Advance `aprop` (two-phase: first by `_internal_key`, then by strcmp on name) until it matches the
   prop name (`aprop->prop_name.data == prop->name.data`, interned-pointer compare). On match evaluate
   the anim value to a vec3; **layer 0** writes it directly (`prop->value_vec3 = v`), **later layers**
   call `ufbxi_combine_anim_layer`.
5. After all layers, for every non-overridden prop set `value_int = ufbxi_f64_to_i64(value_real)`.

### 6. `ufbxi_combine_anim_layer(ctx, layer, weight, prop_name, result, value)` (25699)
- If layer is `compose_rotation && blended` and prop is `Lcl Rotation` and rotation order not yet known:
  evaluate `RotationOrder` prop via `ufbx_evaluate_prop_len` (recursion bounded — only recurses on
  rotation and only evaluates RotationOrder). Clamp result to `[XYZ, SPHERIC]`, else default XYZ. Cache.
- **additive** layer:
  - compose_scale + Lcl Scaling → multiply componentwise by `pow_abs(value, weight)` (log-space scale).
  - compose_rotation + Lcl Rotation → `a = euler_to_quat(result)`, `b = euler_to_quat(value)`,
    `b = slerp(identity, b, weight)`, `result = quat_to_euler(a * b)`.
  - else → `result += value * weight` componentwise.
- **blended** layer (`res_weight = 1-weight`):
  - compose_scale + Lcl Scaling → `result = pow_abs(result,res_weight) * pow_abs(value,weight)` (log lerp).
  - compose_rotation + Lcl Rotation → `result = quat_to_euler(slerp(a, b, weight))`.
  - else → linear lerp `result*res_weight + value*weight`.
- **neither** (override layer) → `*result = *value` (hard replace, ignores weight).
- `ufbxi_pow_abs(v,e)` (25689): sign-preserving power; `e<=0→1`, `e>=1→v`, else `sign·pow(|v|,e)`.

### 7. Property overrides & connected props
- `ufbxi_find_prop_override` (25643): binary lower-bound-eq over sorted overrides by
  `(element_id, internal_key, name)`; on hit, clears NO_VALUE/NOT_FOUND, sets OVERRIDDEN, copies
  vec4/int/str/blob into the prop.
- `ufbxi_find_element_prop_overrides` (25666): lower+upper bound to get the sub-range of overrides for
  one element_id.
- `ufbxi_prop_iter` (init 25866 / next 25916 / slow 25876): a merge of the element's own props with its
  overrides. Fast path when no overrides (just iterate props). Slow path materializes an overridden
  synthetic prop (`UFBX_PROP_UNKNOWN`, flag OVERRIDDEN) when the override key ≤ the next real prop;
  when equal, both advance (override replaces). Uses `UINT32_MAX` as sentinel key (invalid UTF-8).
- `ufbxi_evaluate_connected_prop` (25822): follows a property connection chain (`ufbxi_find_prop_connection`)
  up to 1000 hops to the source; if terminal (non-cyclic), evaluates the source prop and copies its
  value; else clears the CONNECTED flag (treat as animatable). Recursion bounded (never re-enters via a
  connected prop).

### 8. Public single/bulk prop evaluation
- `ufbx_evaluate_prop_flags_len` (30956): find the prop (or synthesize a NOT_FOUND one). If overrides
  present, apply override and return immediately. Else if neither ANIMATED nor CONNECTED, return as-is.
  Else evaluate connection then `ufbxi_evaluate_props` over the single prop.
- `ufbx_evaluate_props_flags` (30996): iterate all props via prop_iter, keep those flagged
  ANIMATED|OVERRIDDEN|CONNECTED (up to buffer_size), evaluate connections, then `ufbxi_evaluate_props`.
  Returns `ufbx_props` with `defaults` pointing at the element's static props (fallback chain).
- `ufbxi_evaluate_selected_props` (25926): like above but restricted to a **sorted** whitelist of prop
  names (used by transform evaluation). Merges the sorted name list against the sorted prop iterator.

### 9. Transform evaluation — `ufbx_evaluate_transform_flags(anim, node, time, flags)` (31062)
1. NULL guards; `node->is_root` → node.local_transform. If not EXPLICIT_INCLUDES, default to
   include rotation+scale+translation.
2. Pick the whitelist of transform prop names by component subset (31030–31060): all 10 props, or
   rotation+scale (5), or rotation-only (4), or scale-only (1); components==0 → identity.
3. Inherit-scale / scale-helper handling (only if translation or scale requested and node has a parent):
   - If parent has `inherit_scale_node` and not IGNORE_COMPONENTWISE_SCALE, walk the
     `inherit_scale_node` chain multiplying `Lcl Scaling` of each `scale_helper` into `scale_factor`.
     If `node->is_scale_helper`, mark `use_scale_factor` so the factor multiplies the final scale.
   - If parent has a `scale_helper` and not IGNORE_SCALE_HELPER, evaluate its `Lcl Scaling`
     (default 1 if not found), multiply by `scale_factor`, and use it as `translation_scale` (scales the
     translation of the child).
4. Evaluate the selected props (`ufbxi_evaluate_selected_props`), read `RotationOrder`, then build the
   transform with `ufbxi_get_transform` (full path) or the component-specific
   `ufbxi_get_rotation`/`ufbxi_get_scale` fast paths. Apply `scale_factor` at the end if `use_scale_factor`.

### 10. Transform composition — `ufbxi_get_transform` (22836)
Builds `T·Roff·Rp·Rpre·R·Rpost⁻¹·Rp⁻¹·Soff·Sp·S·Sp⁻¹` (comment at 22852). Order of operations (the
transform is accumulated so read them as pre-multiplications applied to a point):
adjust-post(rotate,scale) → sub scale_pivot → scale → add scale_pivot → add scale_offset → sub
rot_pivot → [if use_rotation_space: inv-rotate PostRotation(XYZ), rotate Lcl Rotation(order), rotate
PreRotation(XYZ); else just rotate Lcl Rotation(XYZ)] → add rot_pivot → add rot_offset → add
translation → adjust-pre(translate,rotate,scale, translation_scale) → mirror. **PostRotation is applied
inverted** (`ufbxi_mul_inv_rotate`, 22726, negates the quat vector part). `translation_scale`
pre-multiplies the Lcl Translation. `ufbxi_get_rotation` (22786) and `ufbxi_get_scale` (22817) are fast
paths that must stay bit-identical (regression assert at 22901).

### 11. Evaluated scene — `ufbxi_evaluate_imp` (26105) / `ufbx_evaluate_scene` (31178)
Deep-copies the whole scene into a fresh buffer via pointer translation (`ufbxi_translate_element`,
26070, = base-offset arithmetic on a contiguous element block). Copies element data, connections, name
table, all typed lists, then per-element-type fixes up every internal pointer. Copies the anim
(`ufbxi_translate_anim`). Then for every element with animated/overridden props, allocates a `props`
buffer and calls `ufbx_evaluate_props_flags(&anim, elem, time, ...)`, setting `defaults` to the source
element's props. Finally `ufbxi_update_scene(scene, false, transform_overrides...)` recomputes all
derived matrices/transforms, optional skinning, and retains the new scene behind a refcount that keeps
the source scene alive. Gated by `UFBXI_FEATURE_SCENE_EVALUATION`.

### 12. Custom anim — `ufbxi_create_anim_imp` (26552) / `ufbx_create_anim` (31194)
Builds a standalone `ufbx_anim` from `ufbx_anim_opts`: selects layer subset by id (bounds-checked),
copies `override_layer_weights` (must match layer count), builds `prop_overrides`: fill from descs
(cross-fill value.x↔value_int when one is zero, 26596–26600), intern prop names (sort by name first to
dedupe & match global `ufbxi_strings[]`, then re-sort by `(element_id,key,name)` for evaluation),
reject duplicates. Copies+sorts `transform_overrides` by node_id. Refcount ties to source scene.

## Format details
- **Interpolation codes**: CONSTANT_PREV=0, CONSTANT_NEXT=1, LINEAR=2, CUBIC=3 (§enum 3154). The
  *previous* keyframe's interpolation controls each span.
- **Extrapolation codes**: CONSTANT=0, REPEAT=1, MIRROR=2, SLOPE=3, REPEAT_RELATIVE=4 (3165).
  `repeat_count`: negative=infinite, 0=treated as constant hold, positive=clamped count.
- **Tangents are derivatives**, not control points: bezier control value = `value + right.dy` (outgoing)
  and `value - left.dy` (incoming); control x = `time + right.dx` and `next.time - left.dx`.
- **Newton eps** = `8.881784197001252e-16` (4 ULP near 1.0); 3 unrolled + up to 8 more iterations.
- **KTime**: extrapolation repeat math uses `metadata.ktime_second` ticks and `ufbx_rint` rounding;
  requires `duration >= 1` tick.
- **Layer weight** is a percentage (0–100) when animated; divided by 100 and clamped, with `>0.99999→1`.
- **RotationOrder** clamped to `[UFBX_ROTATION_ORDER_XYZ(0), UFBX_ROTATION_ORDER_SPHERIC]`; invalid→XYZ.
- **Evaluate flags** (4678): `NO_EXTRAPOLATION = 0x1`. **Transform flags** (5454):
  IGNORE_SCALE_HELPER=0x1, IGNORE_COMPONENTWISE_SCALE=0x2, EXPLICIT_INCLUDES=0x4,
  INCLUDE_TRANSLATION=0x10, INCLUDE_ROTATION=0x20, INCLUDE_SCALE=0x40, NO_EXTRAPOLATION=0x80.
- **Prop flags** used here (ufbx.h 483+): ANIMATED=0x2000, NOT_FOUND=0x4000, CONNECTED=0x8000,
  NO_VALUE=0x10000, OVERRIDDEN=0x20000.
- **anim_props NULL sentinel**: each layer's `anim_props` array is terminated by a zeroed entry so the
  inner search loops can run without a count check (25794 comment). Preserved on copy (26349).
- **Pre-7000 vs 7000+**: at *evaluation* level there is **no difference** — pre-7000 "Take" animation is
  parsed into the same `ufbx_anim_curve`/`ufbx_anim_value`/`ufbx_anim_layer`/`ufbx_anim_stack` structures
  during loading, so all functions here are version-agnostic. Differences live entirely in the parsing
  subsystem (Takes → curves). `ktime_second` (metadata) may differ by version and feeds extrapolation.

## Quirks & edge cases
- **Hybrid keyframe search** (30852): binary search only until span < 8, then linear — must reproduce for
  identical edge behavior; note `end` is reset to full count before the linear scan (25861).
- **Exact-time short circuit** (30872): `prev->time == time` returns prev.value directly (avoids div).
- **First-key-in-range** (30867): if the first key with `time > query` is index 0, returns its value
  (query equals/precedes first in-range key without triggering extrapolation).
- **Bezier solver has no bisection fallback** — after ≤11 Newton iterations it returns whatever it has;
  fine because tangents are near-monotonic (25041 comment "enough for most tangents").
- **CUBIC normalization** uses `rcp_delta` on tangent dx, so tangents stored in absolute time units get
  normalized to the span; `x2 = 1 - next.left.dx*rcp_delta` (left tangent measured backward from next).
- **pow_abs sign preservation** for scale blending (25689) — negative scales blend in log space keeping
  sign; `e<=0→1`, `e>=1→v` avoid pow() for the common weights.
- **Additive rotation** slerps `b` from identity by weight then multiplies (25720-25724); **blended
  rotation** slerps between `a` and `b` (25736-25740) — different quaternion math per layer type.
- **Override layer** (`!additive && !blended`) hard-replaces regardless of weight (25746).
- **Layer 0 special-cased** (25805): first matching layer writes directly, never blends — so the first
  layer effectively defines the base even if flagged blended. (TODO in source questions this per-prop.)
- **Connections override animation** by default (25791) unless `anim->ignore_connections`.
- **Connected-prop cycle guard**: max 1000 hops (25828); cyclic → clears CONNECTED flag.
- **RotationOrder evaluated lazily** and only once per combine context, only for Lcl Rotation on a
  compose_rotation+blended layer (25703) — bounded recursion.
- **Bloom filter** `_element_id_bitmask[4]` + min/max id range quickly rejects layers not touching an
  element (25751); implement or the per-element scan gets slow but result is identical.
- **PostRotation inverted** in transform build (22853 comment, 22874) — easy to get wrong.
- **use_rotation_space** flag on node decides whether pre/post rotation participate; if false only Lcl
  Rotation (in XYZ order, ignoring the RotationOrder!) is applied (22877-22878).
- **has_adjust_transform** injects axis/unit-conversion adjust rotations/scales/translation-scale into
  the transform (22861, 22886) — these come from the axis-conversion subsystem.
- **adjust_mirror_axis** mirrors translation & rotation for handedness flips (22895; helpers 22745/22751).
- **translation_scale** (scale-helper) multiplies Lcl Translation before pivots (22855).
- **weight animated clamp**: `<0→0`, `>0.99999→1` (25776-25777) — near-1 snaps to exactly 1.
- **prop_override cross-fill** in create_anim (26596): if only `value.x` set, derive `value_int`, and
  vice versa — so numeric overrides work whether user set float or int.
- **Override string interning**: names matched against global `ufbxi_strings[]` for pointer-equality
  comparisons used throughout evaluation (26612-26635); duplicates rejected (26640).
- `value_real_arr[3] = 0.0f` is zeroed when applying an override (25655) — clears the w component.
- Extrapolation `repeat_count==0` returns the boundary value (treated as no repeat, 25997).

## Port guidance
- **Port faithfully (numeric-exact)**: `ufbxi_find_cubic_bezier_t` (double precision, exact iteration
  count and eps), `ufbx_evaluate_curve_flags` interpolation + the hybrid keyframe search,
  `ufbxi_extrapolate_curve` (KTime tick math with rint), the layer-blend math in
  `ufbxi_combine_anim_layer` including `pow_abs` and the two distinct quaternion paths, and
  `ufbxi_get_transform`/`get_rotation`/`get_scale` order of operations. These are the crown jewels;
  divergence produces subtly wrong animation.
- **Swift shapes**:
  - `ufbx_interpolation` / `ufbx_extrapolation_mode` → Swift enums (Int raw). `ufbx_tangent`,
    `ufbx_keyframe` → value structs. Keep tangents as (dx,dy) derivatives; document the control-point
    conversion in a comment.
  - `ufbx_evaluate_flags` / `ufbx_transform_flag` → `OptionSet`.
  - Evaluation entry points → throwing only where allocation happens (`evaluateScene`, `createAnim`);
    the pure math (`evaluateCurve`, `evaluateAnimValue`) are non-throwing `func`s returning values.
  - Layer bloom filter: keep as a small fixed array on the layer struct; it's a pure optimization.
  - `ufbxi_prop_iter` merge iterator → a Swift `Sequence`/iterator or an inline two-cursor loop.
- **Replace with Swift idioms**: the pointer-translation deep copy in `ufbxi_evaluate_imp` is a raw-buffer
  reallocation trick; in Swift, if you retain reference-typed elements you can instead clone element
  objects and rebuild references via id maps. Consider whether v1 even needs `ufbx_evaluate_scene` — it
  is a convenience over evaluating props/transforms on demand. If provided, model it as returning a new
  immutable evaluated `Scene`.
- **Interned-name pointer comparisons** (`aprop->prop_name.data == prop->name.data`) rely on ufbx's
  string pool. In Swift, either intern prop names (enum/interned symbol) or fall back to `==` on strings
  plus the `_internal_key` prefilter; keep the key comparison for ordering.
- **Depends on / feeds other subsystems**:
  - Needs `ufbx_euler_to_quat`, `ufbx_quat_to_euler`, `ufbx_quat_slerp`, `ufbxi_mul_quat`,
    `ufbx_quat_rotate_vec3`, and the `ufbxi_mul_*`/`ufbxi_add_translate` transform primitives (math
    subsystem, ~22662).
  - Needs `metadata.ktime_second` (scene metadata/settings subsystem) for extrapolation.
  - Consumes node adjust-transform fields (`has_adjust_transform`, `adjust_*`, `use_rotation_space`,
    `adjust_mirror_axis`, scale_helper/inherit_scale_node) produced by the scene-construction / axis &
    unit conversion subsystems.
  - Consumes the parsed anim DOM (curves/values/layers/stacks/Takes) from the FBX parsing subsystem.
  - `ufbx_evaluate_scene` feeds the whole-scene update (`ufbxi_update_scene`) and skinning-evaluation
    subsystems.
- **Skip per scope (OUT)**: geometry-cache sampling inside `ufbxi_evaluate_skinning` (25055) — cache
  interpretation branches (25083-25109) are for `.pc2/.mc/.xml` caches which are out; keep only the
  blend-shape + skin path if you evaluate skinning at all. Progress callbacks, custom allocators/IO
  (25204-25625 loader plumbing) are out — that whole `ufbxi_load_imp` block fell inside the line range
  but is the loader entry, not animation.

## Warnings / unresolved
- The public `ufbx_evaluate_curve_flags` / `ufbx_evaluate_prop*` / `ufbx_evaluate_transform_flags`
  bodies live at 30827–31192, **outside** the assigned 25012–26670 span; I read them because the FOCUS
  requires them and my span only holds the helpers they call (bezier solver, extrapolation, layer
  combine, prop iter). Flagging in case another subsystem also claims 30827+.
- Lines ~25055–25625 in my span are the skinning-eval helper and the main loader entry
  (`ufbxi_load_imp`/`ufbxi_load`), not animation; documented only where relevant (skinning eval is a
  consumer at time t). Full loader belongs to the loading subsystem.
- `ufbx_bake_*` (animation baking) begins at 26670 (just past my span) and is OUT of v1 scope.
