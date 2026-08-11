# Interpret scene & update state from properties (ufbx.c 22626–23946)

## Purpose
This subsystem turns the raw DOM (interned `ufbx_props` per element) into the final,
renderer-ready scene: it composes the full FBX **transform chain** (pivots, offsets,
pre/post rotations, euler orders) into `ufbx_transform`/`ufbx_matrix` values, walks the
node hierarchy applying **inherit modes** and **geometry transforms**, applies ufbx's
**axis/unit/handedness "adjust" conversions**, and derives per-element interpreted state
(light, camera, bone, blend channel, material maps, texture UV transform, anim stack
timing, constraints, scene settings/metadata). Everything here reads only from `props`
plus a few precomputed context fields (`axis_matrix`, `unit_scale`) and writes back into
the typed element structs. It is the last major stage of loading and is re-runnable for
re-evaluation (`ufbxi_update_scene`).

## Key data structures

- **`ufbx_transform`** (ufbx.h 357): `{ vec3 translation; quat rotation; vec3 scale; }`.
  Rotation is a **quaternion** (not euler). Identity = `{{0,0,0},{0,0,0,1},{1,1,1}}`.
  This is the primitive the whole chain accumulates into.
- **`ufbx_matrix`** (ufbx.h 367): 4×3 affine, column-major. `cols[0..2]` = X/Y/Z basis,
  `cols[3]` = translation. Accessed as `m00..m23` (m<row><col>) or `v[12]` or `cols[4]`.
  There is no bottom row; it is implicitly `[0 0 0 1]`.
- **`ufbx_rotation_order`** (ufbx.h 341): `XYZ, XZY, YZX, YXZ, ZXY, ZYX, SPHERIC` (0..6).
  NOTE the header caveat: the name is the axis-*application* order; XYZ means matrix `Z*Y*X`.
  SPHERIC falls through to identity quaternion in `ufbx_euler_to_quat` (treated as XYZ-ish
  no-op default). `RotationOrder` prop is clamped to `[0, SPHERIC]` via `find_enum`.
- **`ufbx_inherit_mode`** (ufbx.h 802): `NORMAL` (R*S*r*s), `IGNORE_PARENT_SCALE`
  (segment-scale-compensate, R*r*s), `COMPONENTWISE_SCALE` (R*r*S*s). These are ufbx's own
  enum, *not* the file's `InheritType` int (mapping done upstream).
- **`ufbx_mirror_axis`** (ufbx.h 829): `NONE=0, X=1, Y=2, Z=3`. Used for handedness flips.
- **`ufbx_space_conversion`** (ufbx.h 3623): `TRANSFORM_ROOT`, `ADJUST_TRANSFORMS`,
  `MODIFY_GEOMETRY`. Selects *how* axis/unit conversion is baked.
- **`ufbx_geometry_transform_handling`** / **`inherit_mode_handling`** / **`pivot_handling`**
  (ufbx.h 3651/3680/3714): stored to metadata here; the actual helper-node creation happens
  upstream (node-link subsystem). This span only reads the resulting node flags.
- **`ufbx_node` interpreted fields** (ufbx.h 844–996): outputs written here —
  `rotation_order`, `euler_rotation`, `local_transform`, `geometry_transform`,
  `inherit_scale`, `node_to_parent`, `node_to_world`, `unscaled_node_to_world`,
  `geometry_to_node`, `geometry_to_world`, `has_geometry_transform`, `use_rotation_space`,
  `visible`. Inputs consumed: `parent`, `inherit_mode`, `original_inherit_mode`,
  `inherit_scale_node`, `scale_helper`, `is_scale_helper`, `geometry_transform_helper`,
  `is_geometry_transform_helper`, `is_scale_compensate_parent`, `node_depth`, `is_root`,
  `typed_id`, `all_attribs`, and the **adjust_* fields** (below).
- **Node `adjust_*` fields** (ufbx.h 945–951): ufbx's private conversion compensation,
  set by `ufbxi_update_adjust_transforms`, consumed by `ufbxi_get_transform`:
  - `adjust_pre_translation` / `adjust_pre_rotation` (quat) / `adjust_pre_scale` (real):
    applied **between parent and self** (outermost, parent side).
  - `adjust_post_rotation` (quat) / `adjust_post_scale` (real): applied **in local space at
    the end** (innermost, geometry side).
  - `adjust_translation_scale` (real): multiplies the *final* translation only.
  - `adjust_mirror_axis`: mirror axis for handedness.
  - flags `has_adjust_transform`, `has_root_adjust_transform`.
- **`ufbxi_aperture_format`** (ufbx.c 23064): `{uint16 film_size_x, film_size_y}` in
  1/1000-inch fixed point. Table `ufbxi_aperture_formats[12]` (23069–23082), indexed by
  `ufbx_aperture_format` enum (CUSTOM..IMAX).
- **`ufbxi_time_mode_fps[18]`** (23634–23653): FPS per `ufbx_time_mode`. Semantic notes:
  DEFAULT/30_FPS/30_FPS_DROP=30, NTSC=29.97, PAL=25, FILM=23.976, CUSTOM=24 (overridden),
  59_94=59.94, etc.
- **`ufbxi_pow10_targets[19]`** (23880–23887): `0, 1e-8 … 1e+9`, used to snap unit scale.

## Control flow / algorithms
Call order at load time (from `ufbxi_load_imp`, 25327–25348):
`update_scene_settings` → `transform_to_axes` (upstream, computes `uc->axis_matrix`,
`uc->mirror_axis`) → `scale_units` (upstream, computes `uc->unit_scale`) →
`update_adjust_transforms` → `modify_geometry` (upstream) → `postprocess_scene` (upstream)
→ `update_scene(initial=true)`.

### Transform primitive helpers (22628–22741)
All accumulate into a `ufbx_transform t` and every op **left-multiplies** (the op is
composed on the outside of what `t` already holds). Therefore, in source order, the *first*
op becomes innermost/rightmost in the final matrix product and the *last* op becomes
outermost/leftmost.
- `ufbxi_add_translate` / `ufbxi_sub_translate` (22628/22635): `t.translation ± v`
  ≡ left-mul by pure translation `T_{±v}`.
- `ufbxi_mul_scale` (22642): `t.translation *= v` and `t.scale *= v` componentwise
  ≡ left-mul by diagonal scale. `ufbxi_mul_scale_real` (22652): scalar version.
- `ufbxi_mul_quat` (22662): standard Hamilton product `a*b` (verify signs from lines
  22665–22668; x = aw·bx+ax·bw+ay·bz−az·by, etc.).
- `ufbxi_mul_rotate(t,v,order)` (22695): `q = euler_to_quat(v,order)`; if
  `t.rotation.w != 1.0` then `t.rotation = q * t.rotation` else `t.rotation = q`; and
  `t.translation = quat_rotate(q, t.translation)`. ≡ left-mul by rotation-only `R_q`.
  Early-outs if `v` is all-zero.
- `ufbxi_mul_rotate_quat(t,q)` (22711): same but takes a quat directly (early-out on
  identity quat).
- `ufbxi_mul_inv_rotate(t,v,order)` (22726): as `mul_rotate` but negates the quat vector
  part first (conjugate = inverse for unit quats). Used for **PostRotation** (which is
  applied inverted).
- The `w != 1.0` check is a micro-opt to avoid a quat-mul against identity; port can just
  always multiply.

### `ufbxi_get_transform` — THE FBX TRANSFORM CHAIN (22836–22905)
Reads props: `ScalingPivot`(Sp), `RotationPivot`(Rp), `ScalingOffset`(Soff),
`RotationOffset`(Roff) (defaults 0), `Lcl Translation`(T, def 0), `Lcl Rotation`(R, def 0),
`Lcl Scaling`(S, def 1), `PreRotation`(Rpre, def 0), `PostRotation`(Rpost, def 0).
Optional `translation_scale` vec3 pointer scales T componentwise up front (used for nested
scale-helper inheritance).

Ops in source order (each left-mul), producing the matrix
`M = T · Roff · Rp · Rpre · R · Rpost⁻¹ · Rp⁻¹ · Soff · Sp · S · Sp⁻¹`:
1. `if translation_scale: T *= *translation_scale` (componentwise).
2. `if has_adjust_transform:` `mul_rotate_quat(adjust_post_rotation)`,
   `mul_scale_real(adjust_post_scale)`  ← innermost/local.
3. `sub_translate(Sp)` → `mul_scale(S)` → `add_translate(Sp)`  (scale about scale pivot).
4. `add_translate(Soff)`.
5. `sub_translate(Rp)`.
6. Rotation block:
   - `if use_rotation_space:` `mul_inv_rotate(Rpost, XYZ)` → `mul_rotate(R, order)` →
     `mul_rotate(Rpre, XYZ)`.  (combined rotation = `Rpre · R · Rpost⁻¹`)
   - `else:` `mul_rotate(R, XYZ)` only (Rpre/Rpost and `order` are IGNORED).
7. `add_translate(Rp)`.
8. `add_translate(Roff)`.
9. `add_translate(T)`.
10. `if has_adjust_transform:` `add_translate(adjust_pre_translation)` →
    `mul_rotate_quat(adjust_pre_rotation)` → `mul_scale_real(adjust_pre_scale)` →
    `t.translation *= adjust_translation_scale` (componentwise, translation only).
    ← outermost/parent side.
11. `if adjust_mirror_axis:` `mirror_translation(t.translation)`, `mirror_rotation(t.rotation)`.

CRITICAL exactness notes:
- **PostRotation is inverted** (`mul_inv_rotate`) — matches comment at 22852–22853.
- **PreRotation and PostRotation always use `UFBX_ROTATION_ORDER_XYZ`**, regardless of the
  node's `rotation_order`; only the main `Lcl Rotation` uses `order`.
- Pivots/offsets are pure translations; the scale-pivot bracket and rot-pivot bracket
  isolate S and R respectively.
- `use_rotation_space=false` collapses the rotation to just `R` in XYZ order and skips
  pre/post + custom order entirely (see quirks).
- Regression asserts at 22901–22902 guarantee the fast paths (`get_rotation`,`get_scale`)
  reproduce `t.rotation`/`t.scale` exactly — useful cross-check for the port's tests.

### `ufbxi_get_rotation` / `ufbxi_get_scale` fast paths (22786 / 22817)
`get_rotation` runs only the rotation-affecting ops (adjust_post_rotation, the rotation
block, adjust_pre_rotation, mirror_rotation) and returns `t.rotation`. `get_scale` runs only
adjust_post_scale, `mul_scale(S)`, adjust_pre_scale and returns `t.scale` — note **mirror
does not affect scale**. These exist for partial evaluation; a v1 port can skip them and
call the full `get_transform`, but should preserve their equivalence.

### `ufbxi_get_geometry_transform` (22758)
Reads `GeometricTranslation`(def 0), `GeometricRotation`(def 0), `GeometricScaling`(def 1).
Ops: `mul_scale(S)` → `mul_rotate(R, XYZ)` → `add_translate(T)` giving `M = T·R·S`
(no pivots; geometry rotation is **always XYZ**). Then `if has_adjust_transform:
translation *= adjust_translation_scale`; then mirror. This transform is attribute-only
(affects meshes/lights/cameras attached to the node, not children).

### `ufbxi_get_texture_transform` (22907)
UV transform: `TextureScalingPivot`, `TextureRotationPivot`, `Translation`, `Rotation`,
`Scaling`. Chain: scale about scale-pivot, rotate (XYZ) about rot-pivot, translate. If
`UVSwap != 0`: `mul_scale({-1,0,0})` then `mul_rotate({0,0,-90}, XYZ)` (see quirks — the
swap scale zeroes Y/Z components, port faithfully).

### `ufbxi_get_constraint_transform` (22938)
`Translation`, `Rotation`, `RotationOffset`, `Scaling`. Chain: `mul_scale(S)` →
`mul_rotate(Rotation, XYZ)` → `mul_rotate(RotationOffset, XYZ)` → `add_translate(T)`.
Here `RotationOffset` is treated as *euler rotation*, not a translation. (Constraints are
data-passthrough in v1 scope, but the transform is trivial.)

### `ufbxi_update_node` (22955) — hierarchy composition
1. `rotation_order = find_enum(RotationOrder, def XYZ, max SPHERIC)`;
   `euler_rotation = find_vec3(Lcl Rotation)`.
2. If **not root**:
   - `rotation_active = find_int(RotationActive, 1)`; `rotation_limit_only =
     find_int(RotationSpaceForLimitOnly, 0)`; `use_rotation_space = active && !limit_only`.
   - `transform_scale = parent->scale_helper ? &parent->scale_helper->local_transform.scale
     : NULL`.
   - `local_transform = get_transform(props, rotation_order, node, transform_scale)`.
   - If `is_scale_helper && parent && parent->inherit_scale_node` and that ancestor has a
     `scale_helper`: multiply `local_transform.scale` by the ancestor scale_helper's scale
     (nested scale-helper chaining, 22970–22978).
   - **Transform overrides** (22980–22988): binary-search `overrides[]` (sorted by
     `node_id`) for `typed_id`; if found, *replace* `local_transform` wholesale.
   - `node_to_parent = transform_to_matrix(local_transform)`;
     `geometry_transform = get_geometry_transform(props, node)`.
   Else (**root**): `geometry_transform = identity`.
3. `unscaled_node_to_parent = unscaled_transform_to_matrix(local_transform)` (scale→1).
4. `inherit_scale = local_transform.scale`.
5. **World composition** (23000–23029):
   - If `parent` and `inherit_mode == NORMAL`:
     `node_to_world = parent.node_to_world · node_to_parent`;
     `unscaled_node_to_world = parent.node_to_world · unscaled_node_to_parent`.
   - Else if `parent` (IGNORE_PARENT_SCALE **or** COMPONENTWISE_SCALE — same code path):
     copy `transform = local_transform`;
     `parent_scale = inherit_scale_node ? inherit_scale_node->inherit_scale : {1,1,1}`;
     `transform.scale *= parent_scale`; `transform.translation *= parent->inherit_scale`;
     `inherit_scale = transform.scale`;
     `node_to_world = parent.unscaled_node_to_world · transform_to_matrix(transform)`;
     `unscaled_node_to_world = parent.unscaled_node_to_world ·
     unscaled_transform_to_matrix(transform)`.
   - Else (no parent): `node_to_world = node_to_parent`,
     `unscaled_node_to_world = unscaled_node_to_parent`.
   KEY: the *only* difference between IGNORE_PARENT_SCALE and COMPONENTWISE_SCALE is the
   `inherit_scale_node` pointer (set upstream): componentwise → parent; ignore → the parent
   of the nearest componentwise-scaled ancestor. The arithmetic here is identical.
6. **Geometry-to-world** (23031–23039): if `geometry_transform` non-identity,
   `geometry_to_node = transform_to_matrix(geometry_transform)`,
   `geometry_to_world = node_to_world · geometry_to_node`, `has_geometry_transform=true`;
   else identity/passthrough.
7. `visible = find_int(Visibility, 1) != 0`.
Nodes are iterated in `scene.nodes` order, which must be parent-before-child (guaranteed by
upstream topological ordering) since each node reads `parent->node_to_world` etc.

### `ufbxi_update_adjust_transforms` (23676) — axis/unit/handedness setup
Runs BEFORE `update_scene`. Inputs: `uc->axis_matrix`, `uc->unit_scale` (from upstream
`transform_to_axes`/`scale_units`), `uc->opts`.
1. `root_transform = axis_matrix all-zero ? identity : matrix_to_transform(axis_matrix)`;
   then `root_transform.scale *= unit_scale`.
2. Compute optional **light** and **camera** post-rotations toward ufbx canonical spaces:
   light canonical axes `{+X, -Z, +Y}` (23696), camera canonical axes `{+Z, +Y, -X}`
   (23712). `ufbxi_axis_matrix(target, canonical)` → post-rotation quat; for lights also
   rotate the default `local_direction {0,-1,0}` by the inverse (23701–23707).
3. Reset every light's `local_direction` to `{0,-1,0}`.
4. Copy `space_conversion`, `geometry_transform_handling`, `inherit_mode_handling`,
   `pivot_handling`, `handedness_conversion_axis` into `scene.metadata`.
5. `root_scale = min3(root_transform.scale)`.
   - `MODIFY_GEOMETRY`: `metadata.geometry_scale = root_scale`, `metadata.root_scale = 1`.
   - else: `metadata.geometry_scale = 1`, `metadata.root_scale = root_scale`.
   - `metadata.root_rotation = root_transform.rotation`.
6. Per node, reset all adjust fields to identity, then:
   - `ADJUST_TRANSFORMS`: for depth-1 non-root nodes set `adjust_pre_rotation =
     root_transform.rotation`, `adjust_pre_scale = root_scale`, mark
     `has_adjust_transform` + `has_root_adjust_transform`.
   - `MODIFY_GEOMETRY`: for non-root nodes, depth-1 gets `adjust_pre_rotation =
     root_transform.rotation`; all non-root get `adjust_translation_scale = root_scale`,
     mark `has_adjust_transform`.
   - If `parent`: if `parent.has_root_adjust_transform && inherit_mode ==
     IGNORE_PARENT_SCALE`, `adjust_post_scale *= root_scale` (+root_adjust flag). If
     `parent.is_scale_compensate_parent && original_inherit_mode == IGNORE_PARENT_SCALE`:
     read parent `Lcl Scaling`, pick the component **closest to 1** as `size`,
     `adjust_post_scale *= 1/size` (uniform scale-compensation approximation).
   - If node has exactly one attrib (`all_attribs.count == 1`): apply
     `light_post_rotation` (+ set `light->local_direction`) or `camera_post_rotation`
     (+ set `camera->projection_axes = target_camera_axes`).
`TRANSFORM_ROOT` conversion instead bakes axis+unit into the root node's `local_transform`
upstream (`transform_to_axes` 24969–24980, `scale_units` 24994–25007); no per-node adjust.

### `ufbxi_update_initial_clusters` (23523) — skin/pose space conversion (initial only)
1. Init `cluster->geometry_to_bone = mesh_node_to_bone` for all clusters.
2. Build `world_to_units` + `translation_scale`:
   - `TRANSFORM_ROOT && mirror_axis==NONE`: `world_to_units = root_node->node_to_parent`,
     `translation_scale = 1`.
   - else: build root transform from `{rotation=root_rotation, scale=root_scale uniform,
     translation=0}`, `world_to_units = transform_to_matrix`, `translation_scale =
     geometry_scale`.
3. For every skin cluster and every pose bone: `X_to_world = world_to_units · X_to_world`,
   scale its translation column by `translation_scale`, then `mirror_matrix(mirror_axis)`.
4. Patch each cluster's `mesh_node_to_bone`: resolve the skinned node (via skin deformer,
   falling back to first mesh instance); normalize geometry-helper node to its parent
   (23588–23590). If `mesh_node_to_bone` is all-zero, compute from bind pose:
   `invert(bind_to_world) · node->node_to_world`. Else mirror it and (if geometry_scale≠1)
   scale its translation column. Finally set `geometry_to_bone`: prefer geometry-helper
   `mesh_node_to_bone · geo_node->node_to_parent`, else if `has_geometry_transform`
   `mesh_node_to_bone · node->geometry_to_node`, else `mesh_node_to_bone` (HACK noted at
   23606–23609).

### Per-element update functions
- **`ufbxi_update_skin_cluster`** (23289): `geometry_to_world = (bone_node ?
  bone_node->node_to_world : bind_to_world) · geometry_to_bone`;
  `geometry_to_world_transform = matrix_to_transform(...)`. Runs every update.
- **`ufbxi_update_light`** (23044): `intensity = find_real(Intensity,100)/100`; `color`
  (def 1); `type/decay/area_shape` via clamped enums; `inner_angle` = HotSpot then
  InnerAngle override; `outer_angle` = Cone angle → ConeAngle → OuterAngle chain;
  `cast_light` (def 1), `cast_shadows` (def 0).
- **`ufbxi_update_camera`** (23084): projection/aspect/aperture/gate enums; near/far;
  aspect (`AspectW/H` then `AspectWidth/Height`); FOV (`FieldOfView[X/Y]`); focal length;
  ortho extent = `ortho_size_unit · OrthoZoom`. Film size from aperture table (or
  `FilmWidth/Height`), squeeze (2.0 for 35MM_ANAMORPHIC else `FilmSqueezeRatio`). Aspect
  back-fill logic (23116–23131). `near/far/ortho *= geometry_scale`. Resolution per
  aspect_mode (23145–23169); gate-fit FILL/OVERSCAN resolved to horizontal/vertical by
  comparing `aspect_ratio` vs `film_ratio` (23176–23181); aperture_size/orthographic_size
  per fit (23183–23216); FOV in deg + tan per aperture_mode (23218–23245); `projection_plane`
  = fov_tan (perspective) or ortho_size.
- **`ufbxi_update_bone`** (23254): `radius = find_real(Size, unit)/unit`;
  `relative_length = bone_prop_limb_length_relative ? find_real(LimbLength,1) : 1`.
- **`ufbxi_update_line_curve`** (23266): `color` (def 1).
- **`ufbxi_update_pose`** (23271): per bone_pose `bone_to_parent =
  invert(parent_to_world) · bone_to_world`, where `parent_to_world` is the parent's own
  bone_pose `bone_to_world` if present else parent node's `node_to_world` else identity.
- **`ufbxi_update_blend_channel`** (23299): `weight = find_real(DeformPercent,0)·0.01`.
  In-between blend interpolation: zero all `effective_weight`, find split around
  `target_weight == 0` (`last_negative`), then walk keyframes toward `weight` to find the
  bracketing `prev`/`next` (with a synthetic zero key), and linearly interpolate their
  `effective_weight` (23334–23340). Handles positive and negative weight directions
  symmetrically.
- **`ufbxi_update_material`** (23344): if `props.num_animated > 0`, call `ufbxi_fetch_maps`
  (material subsystem, ufbx.c 20124) to (re)resolve shading maps.
- **`ufbxi_update_texture`** (23351): `uv_transform = get_texture_transform`; if non-identity
  set `texture_to_uv = transform_to_matrix`, `uv_to_texture = invert`; `wrap_u/wrap_v`
  enums (def repeat, clamp to `UFBX_WRAP_CLAMP`); if `texture->shader` call
  `ufbxi_update_shader_texture` (20496).
- **`ufbxi_update_anim_stack`** (23371): `time_begin/end` from `LocalStart/LocalStop` (or
  `ReferenceStart/ReferenceStop` fallback) divided by `metadata.ktime_second`; copies into
  `stack->anim->time_begin/end`.
- **`ufbxi_update_display_layer`** (23390): `visible` (Show, def 1), `frozen` (Freeze, def 1),
  `ui_color` (Color, def 0.8³).
- **`ufbxi_update_constraint`** (23416): `transform_offset = get_constraint_transform`;
  `weight = find_real(Weight,100)/100`; per-target weight via
  `"<node.name>.Weight"` prop (IK targets use /1 not /100); for PARENT constraints read
  `.Offset T/R/S` into `target->transform`; `active`; per-type `constrain_*` bool triples
  via `ufbxi_find_bool3`; AIM up-type/vectors; IK pole vector. (Constraints = passthrough in
  v1.)
- **`ufbxi_update_anim`** (23490): `scene->anim = anim_stacks[0]->anim` if any.

### Scene-level
- **`ufbxi_update_scene`** (23806): orchestrator, order: nodes → lights → cameras → bones →
  line_curves; if `initial`: `update_initial_clusters` + poses; then skin_clusters →
  blend_channels → textures → `propagate_main_textures` (20692) → materials → anim_stacks →
  display_layers → constraints → `update_anim`. Ordering is load-bearing: nodes before
  clusters/poses (need world matrices); textures before materials (maps reference textures).
- **`ufbxi_update_scene_metadata`** (23869): `original_application` / `latest_application`
  vendor/name/version from `scene_props` (`Original|…`, `LastSaved|…`).
- **`ufbxi_update_scene_settings`** (23903): axes from Up/Front/Coord axis+sign;
  `unit_meters = round_if_near(UnitScaleFactor·0.01)`; `original_unit_meters`; `fps`;
  `ambient_color`; `original_axis_up`; `default_camera`; `time_mode/time_protocol/snap_mode`
  clamped enums; if `time_mode != CUSTOM`, `fps = ufbxi_time_mode_fps[time_mode]`.
- Helpers: `ufbxi_find_axis` (23621), `ufbxi_axis_matrix` (23656),
  `ufbxi_round_if_near` (23889), `ufbxi_find_bool3` (23397), mirror matrix/vec helpers
  (22745, 23497–23521).

### Underlying math (referenced, defined outside span)
- `ufbx_euler_to_quat` (31566): degrees→half-radians, then a per-order closed-form quat
  (table 31577–31617; SPHERIC/default → identity quat). Port this table verbatim.
- `ufbx_quat_rotate_vec3` (31554): standard quat·vec (31556–31562).
- `ufbx_transform_to_matrix` (31828): quat+scale+translation → 4×3 (note the `2·scale`
  factoring, 31834–31850). `ufbxi_unscaled_transform_to_matrix` (15818): same with scale=1.
- `ufbx_matrix_mul` (31723), `ufbx_matrix_invert` (31756, returns all-zero if `|det| ≤
  EPSILON`), `ufbx_matrix_determinant` (31749), `ufbx_matrix_to_transform` (31854, polar-ish
  decomposition: lengths for scale, det<0 flips one axis, quat from trace/branch, renormalize).
- `find_*` helpers (11520–11564): `find_enum` returns default if value ∉ `[0,max]`.

## Format details
- Property names are interned constants (`ufbxi_Lcl_Translation`, `ufbxi_PreRotation`,
  `ufbxi_ScalingPivot`, `ufbxi_GeometricTranslation`, `ufbxi_RotationActive`,
  `ufbxi_UnitScaleFactor`, `ufbxi_UpAxis`, …). Compared by interned-pointer identity plus a
  4-byte key (`ufbxi_find_prop` macro, 11516). Property vec3/int/real come from
  `prop->value_vec3 / value_int / value_real`.
- Defaults (all via `find_*`): pivots/offsets/translations/rotations = 0; scalings = 1;
  `RotationActive` = 1; `RotationSpaceForLimitOnly` = 0; `Visibility` = 1; `RotationOrder` =
  XYZ; light `Intensity` = 100; light `CastLight` = 1, `CastShadows` = 0;
  camera `OrthoZoom` = 1; `DeformPercent` = 0; constraint/material/light `Weight`/`Intensity`
  100×-scaled; `UnitScaleFactor` = 1; frame rate default 24.
- `find_axis` (23621): axis int default 3 → `UNKNOWN`; sign int default 2 → positive; axis
  0/1/2 → X/Y/Z, sign>0 positive else negative.
- `axis_matrix` encoding (23656): axis enum `>>1` = axis index (0/1/2), `&1` = sign parity
  (0 positive, 1 negative). Sets `mat.cols[src>>1].v[dst>>1] = ((src^dst)&1)?-1:+1`; returns
  false (no matrix needed) when src==dst axes.
- Aperture table (23069–23082) values in 1/1000 inch; film_size = `x·0.001`.
- `time_mode_fps` (23634–23653); NTSC=29.97, PAL=25, FILM=23.976.
- `pow10_targets` (23880–23887); `round_if_near` tolerance = `|target|·9.5367e-7` with a
  `7.523e-37` absolute floor (23893–23895) — snaps unit scale to a clean power of ten.
- `MM_TO_INCH` = 0.0393700787; `DEG_TO_RAD` = π/180; camera FOV uses half-angle tangents.
- This span is essentially **version-agnostic** (operates on already-normalized props).
  Version-specific behavior (`ktime_second`, `bone_prop_size_unit`,
  `bone_prop_limb_length_relative`, `ortho_size_unit`, prop-name remapping for pre-7000, the
  `InheritType`→`inherit_mode` mapping) is set upstream in the reader/finalize subsystems.

## Quirks & edge cases
- **PostRotation inverted** and **Pre/PostRotation forced to XYZ order** independent of
  `rotation_order` (22874–22876, 22799–22801). Getting either wrong silently corrupts
  skeletal rigs.
- **`use_rotation_space` gate** (22961–22963, 22873–22879): if `RotationActive==0` OR
  `RotationSpaceForLimitOnly!=0`, the node ignores `PreRotation`, `PostRotation` AND its
  custom `rotation_order`, applying only `Lcl Rotation` in **XYZ**. Many exporters leave
  `RotationActive` unset (defaults to 1 → active).
- **Light intensity ÷ 100** (23049) — FBX (Maya/Blender) stores 100× the nominal value;
  comment flags this as a possible exporter-specific quirk with no clean fix.
- **Constraint/material `Weight` ÷ 100**, but **single-chain IK target weight ÷ 1** (23428–
  23439); IK weights are not 100×-scaled.
- **Anamorphic squeeze default 2.0** for `35MM_ANAMORPHIC` aperture format (23110).
- **Gate fit FILL/OVERSCAN** resolve to HORIZONTAL/VERTICAL by comparing aspect vs film
  ratio (opposite comparisons, 23176–23181); STRETCH is a "not sure" passthrough (23212).
- **Camera aspect back-fill** when only one of aspect_x/aspect_y is provided derives the
  other from film size ratio (23116–23131).
- **near/far/ortho `*= geometry_scale`** always (23136–23138) — TODO comment questions
  whether this should always happen.
- **UVSwap texture transform** applies `mul_scale({-1,0,0})` which multiplies Y and Z scale
  by **zero** (22928–22932). Looks suspicious but must be ported faithfully to match ufbx;
  flag for a targeted test.
- **Transform overrides replace the whole `local_transform`** after the pivot chain and
  scale-helper adjustments, via a binary search on sorted `node_id`==`typed_id` (22980–22988).
- **Scale-compensation `size` pick** (23782–23786): from parent `Lcl Scaling` choose the
  component whose `|v-1|` is smallest (treats near-1 as "the real scale"); approximation for
  non-uniform scale, only for `original_inherit_mode == IGNORE_PARENT_SCALE`.
- **Root node special-casing**: root gets identity geometry_transform and skips the
  transform chain; adjust conversions only touch depth≤1 non-root nodes.
- **`mesh_node_to_bone` all-zero sentinel** (23592) means "not specified → derive from bind
  pose". Geometry-transform-helper skinning is an explicit HACK (23606–23617).
- **`matrix_invert` returns all-zeros** for near-singular matrices (`|det| ≤ EPSILON`,
  31761) rather than erroring — downstream muls then produce zero matrices.
- **`find_enum` clamps** out-of-range enum ints back to the default (11556) — malformed
  files can't push enums out of bounds.
- **mirror_rotation flips two quat components** (`axis%3` and `(axis+1)%3`, 22754–22755);
  mirror_translation flips one; matrices mirror both a row (dst) and column (src).
- The `t.rotation.w != 1.0` fast branch in `mul_rotate`/`mul_rotate_quat` is only an
  optimization; do not treat `w==1` as "skip" beyond identity handling.
- `is_scale_helper` nested chaining multiplies in the ancestor scale-helper's scale
  (22970–22978) — needed for stacked scale helpers.

## Port guidance
- **Port faithfully (bit-for-bit math):** the entire transform chain
  (`get_transform`/`get_rotation`/`get_scale`/`get_geometry_transform`/`get_texture_transform`),
  `euler_to_quat` order table, `quat_rotate_vec3`, `transform_to_matrix`,
  `matrix_mul/invert/determinant`, `matrix_to_transform`, `axis_matrix` encoding,
  `round_if_near`, the aperture/fps/pow10 tables (reference the cited line ranges — do not
  hand-transcribe blindly; unit-test against ufbx). These are the crown jewels; subtle sign
  or order errors are invisible until a rig deforms wrong.
- **Swift shapes:**
  - `ufbx_transform` → a `struct Transform { var translation: SIMD3<Double>; var rotation:
    Quat; var scale: SIMD3<Double> }` value type; matrices as a 4×3 value struct (keep
    column-major `cols[4]` to mirror ufbx and reuse its mul/invert formulas verbatim).
  - Rotation order / inherit mode / mirror axis / space conversion / gate fit / aperture
    etc. → Swift `enum` with `Int` raw values matching ufbx ordinals (needed because
    `find_enum` and table indexing use the ordinal).
  - The accumulate-via-left-multiply helpers map cleanly to small mutating methods on
    `Transform` (`mulRotate`, `addTranslate`, `mulScale`, …); keep the exact op sequence.
  - `find_*` → generic prop lookups returning defaults; enum lookup clamps to `[0,max]`.
  - Make `ufbxi_update_*` free functions/methods that mutate the typed element; keep
    `update_scene` ordering identical.
- **Skip per v1 scope:** OBJ settings override (`update_scene_settings_obj`), geometry-cache
  code after 23946. Constraints and poses are data-passthrough — you still need
  `update_constraint`/`update_pose` to fill the fields but rendering-side solving is out.
  Shader/PBR material maps (`fetch_maps`, `update_shader_texture`) are stretch; wire the
  hooks but the mapping tables are a separate subsystem.
- **Cross-subsystem dependencies (name them):**
  - FEEDS FROM (upstream, must run first): axis/unit setup (`ufbxi_transform_to_axes`,
    `ufbxi_scale_units` — provide `axis_matrix`, `unit_scale`, `mirror_axis`); node-link/
    finalize subsystem (sets `inherit_mode`, `original_inherit_mode`, `inherit_scale_node`,
    `scale_helper`/`is_scale_helper`, `geometry_transform_helper`/`is_geometry_transform_helper`,
    `is_scale_compensate_parent`, `node_depth`, topological node order, interned prop names,
    metadata units/ktime); prop-parsing subsystem (the `ufbx_props` values).
  - FEEDS INTO: animation evaluation (re-runs `update_scene` with overrides at time t and
    reuses `get_transform`/`get_rotation`/`get_scale`); skinning/matrix APIs
    (`geometry_to_world`, cluster matrices); mesh/geometry subsystem (consumes
    `geometry_to_node`, `has_geometry_transform`, `geometry_scale`); material subsystem
    (`fetch_maps`, `propagate_main_textures`); metadata/settings consumers (axes, fps,
    unit_meters).
