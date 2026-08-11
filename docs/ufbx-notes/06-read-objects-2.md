# Reading parsed data, part 2: materials, textures, deformers, animation curves, poses, connections

## Purpose

This slice of `ufbxi_read_object` (the big per-FBX-node-type dispatcher) covers the "leaf" element
readers that turn a parsed DOM node into a typed `ufbx_*` element: skin deformers/clusters, blend
channels, animation curves (including the full KeyTime/KeyValueFloat/KeyAttrFlags/KeyAttrDataFloat/
KeyAttrRefCount decode and tangent-mode math), materials, textures (file/layered), videos, anim
stacks, bind poses, shader binding tables, selection sets/nodes, characters/constraints (data only),
audio clips, and the generic `Model`/`NodeAttribute`/`Geometry`/`Deformer`/... dispatch table itself
(`ufbxi_read_object`, `ufbxi_read_objects`). It also covers reading the raw `C` (Connections) block
into a flat list of pending src/dst/prop links. Crucially, **most of these readers only extract raw
values into the generic `ufbx_props` bag plus a handful of directly-stored fields** — the "smart"
derived data (material FBX/PBR maps, camera FOV, light color*intensity, texture UV transforms, skin
cluster `geometry_to_bone`, node/attribute connection graphs) is computed by a much later finalize
pass outside this span (`ufbxi_update_material` ~23344, `ufbxi_update_light` ~23044, camera FOV calc
~23200-23250, `ufbxi_pre_finalize_scene` ~18116 onward). This span is the "raw ingestion" layer that
those passes consume.

## Key data structures

- **`ufbxi_element_info`** (ufbx.c:6322-6327) — transient struct threaded through every `ufbxi_read_*`
  function: `fbx_id` (64-bit id, or synthesized for pre-7000 files), `name`, `props` (already-parsed
  property bag), `dom_node` (retained DOM pointer if DOM retention enabled).
- **`ufbxi_tmp_connection`** (6316-6320) — one row of the `C:` connections block before ids are
  resolved to element pointers: `src`, `dst` (fbx ids), `src_prop`/`dst_prop` (empty string unless an
  `OP`/`PO`/`PP` connection). All connections (explicit file ones plus every synthetic one ufbx
  manufactures, e.g. `ufbxi_connect_oo`/`connect_op`/`connect_pp`) accumulate into `uc->tmp_connections`
  as this one flat type — OO/OP/PO/PP are distinguished purely by which of `src_prop`/`dst_prop` are
  non-empty, there's no explicit type tag carried past this point.
- **`ufbxi_tmp_anim_stack`** (6396-6406ish, hash-mapped by name) — used to de-duplicate `AnimationStack`
  elements found by name across the 6x00 "Take" pass and the object pass (see final section).
- **`ufbxi_tmp_bone_pose`** (6329-6332) — `{ bone_fbx_id, bone_to_world }`; poses store bone bindings
  by FBX id (bypassing the connection system, see Quirks) and are converted to real `ufbx_bone_pose`
  (with resolved `ufbx_node*`) later.
- **`ufbxi_tmp_mesh_texture`** / **`ufbxi_mesh_extra`** (6334-6344) — carries legacy pre-7000 mesh-embedded
  `LayerElementTexture`/`LayerElementXxxTextures` face-texture-index arrays, attached to the mesh via
  `ufbxi_push_element_extra` for a later pass to turn into material texture connections.
  `ufbxi_texture_extra` (6346-6358) carries a `LayeredTexture`'s parallel `Alphas`/`BlendModes` arrays.
- **`ufbxi_key_flags`** enum (14088-14104) — bitmask decoded from each keyframe's `KeyAttrFlags` int32:
  interpolation mode bits (constant/linear/cubic), tangent mode bits (auto/TCB/user/broken), a
  constant-next bit (shares its value 0x100 with `TANGENT_AUTO` — they're mutually exclusive because
  they only apply under different interpolation bits), clamp/clamp-progressive/time-independent bits,
  and weighted/velocity bits for the right tangent and the *next* key's left tangent. See Format
  details for the full bit table.
- **`ufbx_keyframe`** (ufbx.h:3203-3209) — `time` (seconds, double), `value` (real), `interpolation`
  (enum: CONSTANT_PREV/CONSTANT_NEXT/LINEAR/CUBIC), `left`/`right` tangents (`ufbx_tangent{dx,dy}`,
  already converted to absolute dx/dy deltas, not slope+weight — see control flow). The header
  documents the cubic Bezier convention explicitly (comment above the struct, ufbx.h:3193-3200).
- **`ufbx_anim_curve`** (ufbx.h:3213-3236) — `keyframes` list, `pre_extrapolation`/`post_extrapolation`
  (`ufbx_extrapolation{mode, repeat_count}`), `min_value`/`max_value` (from keys), `min_time`/`max_time`
  (NOTE: these two are *not* set by `ufbxi_read_animation_curve` in this span — only `min_value`/
  `max_value` are; min/max_time must be filled elsewhere, likely the finalize pass).
- **`ufbx_skin_deformer`** (ufbx.h:1982-2008) — `skinning_method` enum (LINEAR/RIGID/DUAL_QUATERNION/
  BLENDED_DQ_LINEAR, mapped from the `SkinningType` string "Rigid"/"Linear"/"DualQuaternion"/"Blend"),
  `clusters` list (filled later from OO connections), per-vertex `vertices`/`weights` compacted lists
  (filled later — this span only fills the *raw* `dq_vertices`/`dq_weights`/`num_dq_weights` straight
  from the `Indexes`/`BlendWeights` arrays used for dual-quaternion blend weight override).
- **`ufbx_skin_cluster`** (ufbx.h:2011-2046) — `bone_node` (resolved later via OO connection to a
  `LimbNode`), `mesh_node_to_bone` and `bind_to_world` (this span, straight from the `Transform`/
  `TransformLink` 4x4 arrays via `ufbxi_read_transform_matrix`), `geometry_to_bone`/`geometry_to_world`/
  `geometry_to_world_transform` (computed later), `vertices`/`weights` raw parallel arrays straight from
  `Indexes`/`Weights`.
- **`ufbx_blend_deformer`** (2050-2060) — just `channels` list (populated via OO connections later).
- **`ufbx_blend_channel`** (2078-2095) — `weight` (set from evaluated `DeformPercent`-derived props
  later), `keyframes` (`ufbx_blend_keyframe{shape, target_weight, effective_weight}`, list built later
  from OO connections between channel and shape plus the channel's `FullWeights` array — this span only
  stashes the raw `FullWeights` real array into a side table `uc->tmp_full_weights` for the later pass
  to consume per-channel in order), `target_shape` (resolved later).
- **`ufbx_blend_shape`** (2098-...) — `num_offsets`, `offset_vertices` (indices into
  `ufbx_mesh.vertices[]`), `position_offsets` (`ufbx_vec3` list), `normal_offsets` (optional). Built by
  `ufbxi_read_shape` (13010-13075, technically just above this span's start but topically part of this
  subsystem — chased into because blend channels reference it).
- **`ufbx_material`** (ufbx.h:2638-2671) — this span sets only `shading_model_name` (from `ShadingModel`
  string prop, or empty) and `shader_prop_prefix` (initialized empty here, filled later for prefixed
  shader props like `"3dsMax|Parameters|"`). Everything else (`fbx` FBX-map struct, `pbr` PBR-map
  struct, `features`, `shader_type`, `shader`, `textures` list) is derived later from the raw `props`
  bag that `ufbxi_read_properties` (called from `ufbxi_read_object`) already populated.
- **`ufbx_texture`** (2890-2959) — this span sets `type` (`UFBX_TEXTURE_FILE` or `UFBX_TEXTURE_LAYERED`),
  `filename`/`absolute_filename`/`relative_filename` (+ raw non-UTF8 `blob` variants) straight from
  `FileName`/`Filename`/`RelativeFileName`/`RelativeFilename` props (note FBX's own inconsistent
  capitalization, both spellings are probed). `video`, `file_index`, `has_file`, `layers`, `shader`,
  `file_textures`, `uv_set`, `wrap_u/v`, `has_uv_transform`/`uv_transform`/`texture_to_uv`/`uv_to_texture`
  are all resolved later.
- **`ufbx_video`** (2962-2994) — filenames like texture, plus `content` blob read via
  `ufbxi_read_embedded_blob` from a child `Content` node (base64/binary embedded file bytes).
- **`ufbxi_texture_extra`** — layered texture's parallel `blend_modes`/`alphas` raw int32/real arrays
  (from `BlendModes`/`Alphas` children), consumed later to build `ufbx_texture.layers`.
- **`ufbx_shader_binding`** / **`ufbx_shader_prop_binding`** (ufbx.h:3017-3030) — `BindingTable` object:
  a list of `{shader_prop, material_prop}` pairs built from child `Entry` nodes with 4 string values
  `(src, src_type, dst, dst_type)`; an entry only counts if one side's type tag is
  `"FbxPropertyEntry"` and the other `"FbxSemanticEntry"` (either order), and the resulting list is
  sorted by `shader_prop` (stable sort, `ufbxi_sort_shader_prop_bindings`, 14689-14695).
- **`ufbx_pose`** / **`ufbx_bone_pose`** (ufbx.h:3444-3475) — `is_bind_pose` (from sub_type ==
  `"BindPose"`), `bone_poses` list of `{bone_node, bone_to_world, bone_to_parent}`; this span only
  fills a *temporary* parallel array of `{bone_fbx_id, bone_to_world}` (bones referenced by FBX id or
  by string name pre-7000, see Quirks) which is reinterpreted in place as `ufbx_bone_pose*` via a
  documented HACK (14681-14684) — `bone_node`/`bone_to_parent` are filled by a later pass once ids
  resolve to nodes.
- **`ufbx_selection_set`** / **`ufbx_selection_node`** (ufbx.h:3260-3292) — selection node stores
  `include_node` (from `IsTheNodeInSet`) plus raw `vertices`/`edges`/`faces` uint32 index lists pulled
  straight from `VertexIndexArray`/`EdgeIndexArray`/`PolygonIndexArray` (no bounds validation against
  the target mesh happens here — deferred, and the header promises indices are valid once resolved).
- **`ufbx_constraint_type`** table (14805-14812) — 6 known constraint type-name strings ("Aim",
  "Parent-Child", "Position From Positions", "Rotation From Rotations", "Scale From Scales",
  "Single Chain IK") mapped to the `ufbx_constraint_type` enum; everything else (targets, weights,
  per-axis flags) is populated by a much later pass — this reader only stores the raw `type_name`
  string and the resolved `type` enum (14814-14835). `Character` constraints get their own no-op
  reader (`ufbx_character`, 14773-14783) — described in source as having "extremely cursed all-caps
  data", not handled.
- **`ufbxi_key_flags`**, `ufbxi_solve_auto_tangent*`, `ufbxi_solve_tcb` — pure math helpers for deriving
  cubic tangent slopes from FBX's packed keyframe attribute encoding; see Control flow.

## Control flow / algorithms

### Top-level object dispatch

1. **`ufbxi_read_objects`** (15101-15121) loops calling `ufbxi_parse_toplevel_child` to pull each
   top-level child of the `Objects` node, then `ufbxi_read_object` per node, until none remain. Each
   iteration pushes a deferred "current element id" slot used for warning attribution.
   `ufbxi_read_objects_threaded` (15129-15234) is the same thing parallelized across
   `UFBX_THREAD_GROUP_COUNT` worker batches — out of v1 scope (no threading) but shows objects are
   independently parseable/order-insensitive except for shared string pool and template lookups.

2. **`ufbxi_read_object`** (14947-15099) is the dispatcher, called once per top-level child of
   `Objects`:
   - `GlobalSettings` is special-cased first (15952-15955) → `ufbxi_read_global_settings` (14941-14945)
     just reads its properties into `uc->scene.settings.props` (no struct fields set here — settings
     like axes/units/frame-rate are derived from props later, out of this span).
   - Object identity: version ≥ 7000 nodes have values `(L id, s "Type::Name", s subtype)` (or
     `"Name\x00\x01Type"` order in binary — see Format details for the ASCII/binary difference);
     version < 7000 synthesizes a 64-bit id by hashing/pointer-interning the `type_and_name` string via
     `ufbxi_synthetic_id_from_string` (12250-12258, just reinterprets small pointers as ids, or hashes
     larger ones through a map) since pre-7000 FBX only has Type::Name identity, no numeric ids.
   - `sub_type` gets its `"Fbx"` prefix stripped if present (14974-14978), then re-interned into the
     string pool (subtype strings are used as O(1) pointer-equality keys throughout, see Quirks).
   - `type_and_name` is split into `type_str`/`info.name` via `ufbxi_split_type_and_name` (12271-12305):
     ASCII uses `"Type::Name"` order with `"::"` separator; binary uses `"Name\x00\x01Type"` order with
     a literal NUL+SOH separator. If no separator found, the whole string is the name and type is
     empty.
   - `ufbxi_read_properties` reads the node's `Properties60`/`Properties70` child block into
     `info.props` (this function itself lives in the previous span's territory, not re-derived here).
   - `info.props.defaults = ufbxi_find_template(...)` (12195-12218) looks up a per-type[,subtype]
     template properties block (from the file's `Definitions` section) to use as property fallback
     defaults; `Material`/`Model`/`AnimationStack`/`AnimationLayer` templates match regardless of
     subtype, everything else must match subtype exactly.
   - Then a big `if/else if` chain keyed on `node->name` (`"Model"`, `"NodeAttribute"`, `"Geometry"`,
     `"Deformer"`, `"Material"`, `"Texture"`, `"LayeredTexture"`, `"Video"`, `"AnimationStack"`,
     `"AnimationLayer"`, `"AnimationCurveNode"`, `"AnimationCurve"`, `"Pose"`, `"Implementation"`,
     `"BindingTable"`, `"Collection"` (only `SelectionSet` subtype handled), `"CollectionExclusive"`
     (only `DisplayLayer` subtype), `"SelectionNode"`, `"Constraint"` (Character vs generic),
     `"SceneInfo"`, `"Cache"`, `"ObjectMetaData"`, `"AudioLayer"`, `"Audio"`), each branching again on
     `sub_type` where relevant, falling through to `ufbxi_read_unknown` for anything unrecognized
     (12637-12653: stores raw type/sub_type/super_type strings into an `ufbx_unknown` element rather
     than dropping the data — a "capture everything" fallback). Simple leaf types with no custom
     parsing logic (Light, Camera, LimbNode/Limb/Root→Bone, Null/Marker→Empty, LodGroup,
     CameraStereo/CameraSwitcher, BlendShape deformer, VertexCacheDeformer, AnimationLayer,
     AnimationCurveNode→`ufbx_anim_value`, Implementation→`ufbx_shader`, Cache file, ObjectMetaData,
     AudioLayer) go through the generic **`ufbxi_read_element`** (12629-12635) which just allocates a
     zeroed struct of the right size/type via `ufbxi_push_element_size` — all of their meaningful
     fields are populated by later per-type "update" passes reading straight from `props`.

3. **Pre-7000 attribute splitting — `ufbxi_read_synthetic_attribute`** (14837-14939): pre-7000 FBX
   attaches geometry/light/camera/etc. data directly on the `Model` node rather than as a separate
   linked `NodeAttribute`; ufbx synthesizes a second element to keep the post-7000 node/attribute
   split uniform. Steps: detect legacy meshes with no sub_type by sniffing for `Vertices`+
   `PolygonVertexIndex` children (14841-14847); early-out for plain `Model`/empty sub_type (nothing to
   split); derive a name/id for the attribute from `NodeAttributeName` if unique (14859-14871,
   falling back to a synthetic id derived from the node's own id otherwise); record the node↔attribute
   link in `uc->fbx_attr_map` via `ufbxi_insert_fbx_attr` (used later to redirect property connections
   that historically pointed at "the node" but should resolve against whichever of node/attribute
   actually owns that property); **partition properties**: user-defined properties and non-"node"
   properties get moved from the node's prop list into the attribute's prop list in-place
   (14877-14894, single left-compaction pass using `ufbxi_is_node_property_name` to decide ownership);
   dispatch on `sub_type` to the same per-type readers as the post-7000 path (Mesh, Light, Camera,
   Bone, Empty, NurbsCurve/Surface, Line, TrimNurbsSurface, Boundary, CameraStereo/Switcher,
   FK/IKEffector, LodGroup, else Unknown); finally connects the new attribute element to the node via
   `ufbxi_connect_oo`.

### Skin / cluster reading

- **`ufbxi_read_skin`** (13992-14022): maps `SkinningType` string to `ufbx_skinning_method` (only 4
  known strings recognized, default is `UFBX_SKINNING_METHOD_LINEAR` i.e. enum value 0 if the prop is
  absent/unrecognized); if both `Indexes` (int array) and `BlendWeights` (real array) children exist,
  stores them directly as `dq_vertices`/`dq_weights` truncated to the shorter of the two lengths
  (`ufbxi_min_sz`) — no error even in strict mode if the sizes differ (comment flags this is
  intentionally lenient, TODO to make strict mode reject it).
- **`ufbxi_read_skin_cluster`** (14024-14052): `Indexes`/`Weights` arrays → `vertices`/`weights` (here
  sizes *must* match, `ufbxi_check(indices->size == weights->size)`); `Transform`/`TransformLink`
  arrays (each must have ≥16 reals) → `mesh_node_to_bone`/`bind_to_world` via
  `ufbxi_read_transform_matrix` (13957-13963: takes a 16-float column-major-ish FBX matrix array and
  picks out columns 0,1,2 (rotation/scale basis) and column 3 (translation) into an `ufbx_matrix`,
  discarding the 4th row since FBX matrices are stored as 4x4 but always affine).

### Blend channel reading

- **`ufbxi_read_blend_channel`** (14054-14086): reads the `FullWeights` real array (one weight per
  in-between shape/keyframe) into a temp `ufbx_real_list` and pushes it onto `uc->tmp_full_weights`
  (a side-channel array kept in lockstep with the channel's OO-connected shapes, resolved to
  `ufbx_blend_keyframe.target_weight` later). Then a Blender-specific quirk: if the channel has no
  properties yet and a literal `DeformPercent` *child node* exists (Blender exports this as a plain
  value, not a property, even though animation curves connect to the `"DeformPercent"` *property*
  name), synthesizes a single `UFBX_PROP_NUMBER` property named `DeformPercent` with default 100.0,
  overwritten by the child's value if present, so downstream animation-curve-to-property binding still
  finds a property to bind to (14067-14083).

### Animation curve reading — the core of this span

**`ufbxi_read_animation_curve`** (14257-14532):

1. Reads `Pre_Extrapolation`/`Post_Extrapolation` child blocks unconditionally via
   `ufbxi_read_extrapolation` (14227-14255): looks for a `Type` int32 char code (`'A'`→REPEAT_RELATIVE,
   `'C'`→CONSTANT, `'K'`→SLOPE, `'M'`→MIRROR, `'R'`→REPEAT, default CONSTANT if child/type missing) and
   a `Repetition` int32 (negative → -1 meaning infinite, default -1 if absent).
2. If `uc->opts.ignore_animation`, stop here (extrapolation is still read even so).
3. Fetches five parallel arrays that must all exist: `KeyTime` (`'l'`, int64 ktime ticks),
   `KeyValueFloat` (`'r'`, real), `KeyAttrFlags` (`'i'`, int32 bitmask per *run*),
   `KeyAttrDataFloat` (`'?'` — wildcard type, see Format details on why), `KeyAttrRefCount`
   (`'i'`, int32 run-length counts). Invariants checked: `times->size == values->size`;
   `attr_flags->size == refs->size`; `attrs->size == refs->size * 4` (4 floats of attribute data per
   distinct flags run).
4. Allocates `num_keys = times->size` keyframes. Walks all five arrays in lockstep with a run-length
   decoder: a `refs_left` counter (from the current `KeyAttrRefCount` entry) is decremented once per
   key; when it hits zero, the flag/attr/ref pointers advance to the next run (14520-14526). This is
   how the per-key tangent flags/data are actually shared across runs of identical keys (FBX RLE-encodes
   them since many keys in a row often share tangent settings).
5. Per key `i`, tracks a rolling `prev_time`/`next_time` window (times converted from raw ticks to
   seconds by dividing by `uc->ktime_sec_double`, see Format details for the two possible KTime epoch
   values) and updates the curve's running `min_value`/`max_value`.
6. Reads the 32-bit flags word for this key, then unpacks the 4 floats of `KeyAttrDataFloat` for this
   run: `p_attr[0]` = right-tangent slope (or TCB tension), `p_attr[1]` = *next* key's left-tangent
   slope (or TCB continuity), `p_attr[2]` = auto-tangent bias (or TCB bias); if the run is weighted
   (`WEIGHTED_RIGHT`/`WEIGHTED_NEXT_LEFT` bits set), `p_attr[2]`'s raw 32 bits are **reinterpreted as
   two packed 16-bit unsigned fixed-point weights** (`packed_weights & 0xffff` = right weight,
   `packed_weights >> 16` = next-left weight, each in units of `0.0001`) rather than as a float value —
   this is a deliberate bit-level reinterpretation via `memcpy` (14343-14344), not a numeric
   conversion. A commented-out (`#if 0`) block shows the same packed-fixed-point trick would apply to
   velocity data in `p_attr[3]` if ufbx supported it (14356-14372, explicitly disabled — see Quirks).
7. Interpolation-mode-specific tangent derivation (this is the algorithmic heart):
   - **Constant** (`INTERPOLATION_CONSTANT` bit set): `CONSTANT_NEXT` bit (which reuses bit 0x100,
     shared with `TANGENT_AUTO` — safe because they're only interpreted under mutually exclusive
     top-level interpolation bits) picks `UFBX_INTERPOLATION_CONSTANT_NEXT` vs `_PREV`; slopes forced
     to 0, weights forced to the default 1/3 (14374-14387).
   - **Cubic** (`INTERPOLATION_CUBIC` bit): three sub-modes based on tangent-mode bits:
     - **TCB** (Tension/Continuity/Bias, `TANGENT_TCB`): computes raw left/right secant slopes from
       neighboring values/times (falling back to "edge" mode — factor 1.0 instead of 0.5 in the TCB
       blend — if there's no valid neighbor on that side, 14393-14406), then blends them through
       `ufbxi_solve_tcb` (14215-14225) using the classic Kochanek–Bartels basis weights
       `d00,d01,10,d11` computed from `(tension, continuity, bias)` taken directly from
       `p_attr[0..2]`. Next-key's left tangent info is intentionally zeroed here with a `TODO` comment
       (14410-14413) — i.e. TCB tangents are always recomputed independently per key from raw values,
       never propagated key-to-key like auto tangents are.
     - **User** (`TANGENT_USER`): tangent slopes come directly from the packed `slope_right`/
       `next_slope_left` floats already read; if `TANGENT_BROKEN` is *not* set (unified tangents) there
       is a `// TODO: ??? slope_left = slope_right` left unimplemented — i.e. **ufbx currently does not
       unify left/right user tangents even when the file says they should be unified**; broken
       tangents are handled correctly as independent slopes (14414-14423). Flag this for the Swift
       port as a known-incomplete area to preserve bug-for-bug or fix deliberately.
     - **Auto** (default, no TCB/User bit — "Auto Break" bit 0x800 also falls into this branch with a
       `// TODO` noting it's not distinguished, 14425): calls `ufbxi_solve_auto_tangent` /
       `_left` / `_right` (14106-14213) depending on whether both/one/neither neighbor exists. The
       three-argument-window function implements FBX's auto-tangent algorithm: base slope is the
       neighbor-to-neighbor secant (time-independent slope); if not `TIME_INDEPENDENT`, blends in the
       local left/right secants weighted by relative position between neighbors, then applies an
       "auto bias" S-curve blend toward whichever neighbor's secant `auto_bias`'s sign points at, with
       an additional large-bias (`|auto_bias| > 500`) escape hatch that adds a `((|bias|-500)/100)^2 *
       40` absolute offset in the bias's direction (14125-14139, unexplained magic constants reverse
       engineered from MotionBuilder/Maya output — treat as a black-box formula to port verbatim).
       `CLAMP` zeroes the tangent if the value is within `key_clamp_threshold` of either neighbor
       (an option, `uc->opts.key_clamp_threshold`). `CLAMP_PROGRESSIVE` re-clamps the *solved* slope's
       magnitude so the resulting tangent doesn't overshoot past either neighbor's value within the
       weighted time window (14144-14164) — this is Maya/MotionBuilder's anti-overshoot clamp for auto
       tangents, applied after the bias blend. When both slopes are (near-)equal (`|slope_left +
       slope_right| <= 0.0001`) a single shared call handles both sides at once (matching key
       symmetric auto-tangent case); otherwise left and right are each solved independently by
       negating the "other side" bias hint (14428-14442, the sign flip on `slope_right`/`-slope_left`
       passed as the `auto_bias` parameter is intentional and mirrors FBX's actual per-side bias
       encoding).
   - **Linear/unknown** (else branch, 14474-14493): weights forced to 1/3, slope computed as the plain
     secant to the next key (or 0 if degenerate/at-the-end).
8. Converts slope+weight into absolute tangent deltas: `left.dx = weight_left * (time - prev_time)`,
   `left.dy = left.dx * slope_left` (zero if this is the first key or `prev_time`/`key.time` coincide);
   same pattern mirrored for `right` against `next_time` (14497-14513). This is the final
   weight-into-delta conversion that produces the `ufbx_tangent{dx,dy}` stored on the keyframe —
   consumers (evaluation code, out of scope here) just do a cubic Bezier through
   `(time,value)→(time+right.dx,value+right.dy)→(nextTime-nextLeft.dx,nextValue-nextLeft.dy)→
   (nextTime,nextValue)`.
9. Rolls `slope_left`/`weight_left` forward to the *next* key's `next_slope_left`/`next_weight_left`
   before advancing (this is how tangent info flows from one key's right side into the next key's left
   side — each key only truly owns its own "right" tangent computation; "left" is inherited from the
   previous iteration's computed `next_slope_left`).

### Material / texture / video readers (thin, see struct notes above for what's deferred)

- **`ufbxi_read_material`** (14534-14546): only `shading_model_name` + empty `shader_prop_prefix`.
- **`ufbxi_read_texture`** (14548-14570): `type = UFBX_TEXTURE_FILE`; probes both `FileName`/`Filename`
  and `RelativeFileName`/`RelativeFilename` spellings for both UTF-8 (`"S"`) and raw-blob (`"b"`)
  variants — 8 `ufbxi_ignore` probes total, all optional (a texture with no filename at all is legal,
  e.g. procedural/shader textures).
- **`ufbxi_read_layered_texture`** (14572-14599): `type = UFBX_TEXTURE_LAYERED`; stashes raw
  `Alphas`/`BlendModes` arrays into a `ufbxi_texture_extra` side-table (via
  `ufbxi_push_element_extra`) for a later pass to zip together with the OO-connected child textures
  into `ufbx_texture.layers`.
- **`ufbxi_read_video`** (14601-14624): filenames like texture (no raw-blob probing here, only `"S"`
  and `"b"` on the file/relative names, same 8 probes pattern), plus `ufbxi_read_embedded_blob` on a
  child `Content` node.
- **`ufbxi_read_embedded_blob`** (11764-11796, chased into): the `Content` node stores either nothing
  (external file only), a single binary-string chunk (fast path, only when *not* parsed from ASCII —
  binary FBX content is one contiguous byte-string value), or (always for ASCII, or if binary content
  was split into multiple string values) multiple parts concatenated into one freshly allocated
  buffer. ASCII embedded content is base64-decoded elsewhere before reaching this function (out of
  span) and can arrive pre-split into chunks because ASCII string literals have line-length limits.

### Anim stack / pose / binding table / selection / constraint readers

- **`ufbxi_read_anim_stack`** (14626-14643): de-duplicates by *name* using a `uc->anim_stack_map` hash
  map (`ufbxi_tmp_anim_stack`) — because pre-7000 "Take" blocks (parsed elsewhere, end of this file
  region and beyond, see final section) and post-7000 `AnimationStack` objects can both describe the
  same stack by name, and ufbx wants exactly one `ufbx_anim_stack` element per name.
- **`ufbxi_read_pose`** (14645-14687): only handles `PoseNode` children; bone identity is read either
  as a `Node` string (pre-7000, hashed via `ufbxi_synthetic_id_from_string`) or a `Node` int64 fbx id
  (post-7000, validated via `ufbxi_validate_fbx_id`) — **note this bypasses the normal OO connection
  system entirely**, poses reference bones directly by id/name rather than via a `C:` connections
  block entry (flagged with a `(!?)` comment at 14657, see Quirks). Requires a `Matrix` real array
  (≥16 elements) per bone node; builds a temp array of `{bone_fbx_id, bone_to_world}` on `uc->tmp_stack`,
  then transports it into the final `pose->bone_poses` list by reinterpreting the temp struct pointer
  as `ufbx_bone_pose*` (explicitly documented as a "HACK", relies on `ufbxi_tmp_bone_pose` and the
  first two fields of `ufbx_bone_pose` being layout-compatible enough for the *next* pass to safely
  overwrite `bone_node`/fix up `bone_to_parent` in place).
- **`ufbxi_read_binding_table`** (14698-14735): iterates `Entry` children, each a 4-string tuple
  `(src, src_type, dst, dst_type)`; only keeps entries where one side's type is
  `"FbxPropertyEntry"` and the other `"FbxSemanticEntry"` (constant strings `ufbxi_FbxPropertyEntry`/
  `ufbxi_FbxSemanticEntry`), storing `material_prop` = whichever side was the property entry and
  `shader_prop` = whichever was the semantic entry, regardless of which literal order the file used;
  result sorted by `shader_prop`.
- **`ufbxi_read_selection_set`** (14737-14745) — no-op body beyond allocating the element; its `nodes`
  list is populated later from OO connections to `SelectionNode` children.
- **`ufbxi_read_selection_node`** (14756-14771) — `include_node` from `IsTheNodeInSet` int flag;
  `vertices`/`edges`/`faces` raw uint32 arrays via a small helper `ufbxi_find_uint32_list`
  (14747-14754) that just wraps `ufbxi_find_array(...,'i')`.
- **`ufbxi_read_character`** (14773-14783) / **`ufbxi_read_constraint`** (14814-14835): constraint
  reads `Type` string prop, matches it against a 6-entry table (14805-14812) of known constraint
  type-name strings to set the `ufbx_constraint_type` enum (falls back to `UFBX_CONSTRAINT_UNKNOWN` —
  actually the zero-value default — if unmatched); everything else about constraints (targets, axis
  flags, aim/IK specifics) is TODO / handled by later passes not in this file region at all based on
  available evidence. Both explicitly flag "cursed all-caps data" they don't attempt to parse
  (Character objects apparently store internal state in oddly-named all-caps custom properties).
- **`ufbxi_read_audio_clip`** (14785-14798): filenames unset (bug or intentional minimalism — only
  `content` via `ufbxi_read_embedded_blob` is actually read; `filename`/`absolute_filename`/
  `relative_filename` are initialized to empty and never probed from `FileName`/`RelativeFileName`
  props here, unlike texture/video. Worth flagging as a possible ufbx gap rather than a deliberate
  design — port faithfully but note the asymmetry.)

### Connections block — `ufbxi_read_connections` (15236-15310)

Reads every top-level child of the `Connections` node (each one row of the `C:` array). Two id
schemes based on `uc->version`:
- **< 7000**: node value 0 is a type char (`OO`/`OP`/`PO`/`PP`), followed by 2-4 more values that are
  always `Type::Name`-style strings (never numeric ids) hashed into synthetic 64-bit ids via
  `ufbxi_synthetic_id_from_string`. Format strings per type: OO=`"_cc"`, OP=`"_ccs"`, PO=`"_csc"`,
  PP=`"_cscs"` (leading `_` skips the already-consumed type value at index 0). Property-name strings
  (`src_prop`/`dst_prop`) get re-interned into the string pool since they come from raw parsed string
  values (14268-14273 style pattern, here at 15268-15273).
- **≥ 7000**: value 0 is a type char, remaining values are `L` (int64) ids directly, format strings
  OO=`"_LL"`, OP=`"_LLS"`, PO=`"_LSL"`, PP=`"_LSLS"`; both ids are validated/normalized via
  `ufbxi_validate_fbx_id` (handles the "pointer id" numeric space collision, see Format details).
- Unrecognized connection type chars are silently skipped (a `// TODO: Strict mode?` marks this as a
  known permissiveness gap).
- Every parsed connection (from file OR synthesized internally via `ufbxi_connect_oo`/`_op`/`_pp`,
  12419-12449) is appended to the same flat `uc->tmp_connections` growable array as a
  `ufbxi_tmp_connection` — **this span does not resolve ids to element pointers or build any
  adjacency lists**; that happens in `ufbxi_pre_finalize_scene` (~18116 onward) and later finalize
  passes, which look up each id via `ufbxi_find_fbx_id` (a hash map from fbx id → element_id built
  incrementally as elements are pushed, `ufbxi_insert_fbx_id`/`ufbxi_find_fbx_id`, 12307-12334) and
  branch on element-type pairs to build every one of: node parent/child tree, node→attribute links,
  mesh→skin/material/deformer links, skin→cluster links, cluster→bone-node links, blend
  deformer→channel→shape links, anim-stack→layer→curve-node→curve links, property animation bindings,
  texture→material-property bindings, etc. That resolution logic is **out of this span** and should
  be treated as belonging to whichever subsystem covers scene finalization/graph building.

## Format details

- **KTime unit constant** (set in `ufbxi_read_header_extension`, ufbx.c:11981-12033, feeds directly
  into this span's `key->time = p_time[i] / uc->ktime_sec_double`): `uc->ktime_sec = 46186158000` for
  "v7" KTime units (FBX < 8000, or ≥8000 with `TCDefinition == 127`), else `141120000` for the older
  pre-7000-style unit when `FBXHeaderVersion >= 1004` and a `TCDefinition` other than 127 is present.
  This is the divisor turning raw `KeyTime` int64 ticks into seconds. Get this wrong and **all**
  animation timing silently desyncs.
- **`KeyAttrFlags` bit layout** (14088-14104), values are bit OR'd together:
  - `0x2` CONSTANT, `0x4` LINEAR, `0x8` CUBIC — interpolation mode (mutually exclusive, top nibble-ish).
  - `0x100` TANGENT_AUTO (cubic) **or** CONSTANT_NEXT (constant) — same bit reused, disambiguated by
    which of CONSTANT/CUBIC is set.
  - `0x200` TANGENT_TCB, `0x400` TANGENT_USER, `0x800` TANGENT_BROKEN (cubic only; TANGENT_BROKEN
    modifies TANGENT_USER's behavior, doesn't stand alone).
  - `0x1000` CLAMP, `0x2000` TIME_INDEPENDENT, `0x4000` CLAMP_PROGRESSIVE — auto-tangent modifiers.
  - `0x1000000` WEIGHTED_RIGHT, `0x2000000` WEIGHTED_NEXT_LEFT — this key's right / next key's left
    tangent has an explicit weight (not the default 1/3) packed into the attribute data.
  - `0x10000000` VELOCITY_RIGHT, `0x20000000` VELOCITY_NEXT_LEFT — velocity data present; **read but
    never applied** (dead code behind `#if 0`, 14356-14372 and 14464-14471), because ufbx determined
    empirically that MotionBuilder already bakes velocity into the auto-bias computation and applying
    it again double-counts it (comment at 14459-14463).
- **`KeyAttrDataFloat` layout**: 4 × 32-bit float per RLE run, meaning depends on interpolation +
  weighted bits: `[0]` = right slope (or TCB tension), `[1]` = next-key left slope (or TCB continuity),
  `[2]` = auto-tangent bias (or TCB bias) **or**, if either WEIGHTED bit is set, its 32 raw bits are
  reinterpreted as two packed `uint16` fixed-point weights (`value/10000.0`, low 16 bits = right
  weight, high 16 bits = next-left weight) — a value is never simultaneously a bias float and a
  packed-weight pair, the WEIGHTED bits gate which interpretation applies. `[3]` = packed velocities,
  same fixed-point scheme, currently unused. **Read with wildcard array type code `'?'`** (bypasses
  the normal `ufbx_real`/'f'/'d' type check that `KeyValueFloat`/`KeyTime` get) because these four
  floats are always 32-bit regardless of whether the file's "real" precision or the ASCII-inferred
  numeric type would otherwise map to `double` — the raw bytes are reinterpreted as `float*`
  unconditionally after fetching.
- **`KeyAttrRefCount`**: int32 array, same length as `KeyAttrFlags`; each entry says how many
  consecutive keys share that flags/attr-data slot (standard FBX run-length compression of repeated
  tangent settings across a curve).
- **`Extrapolation` mode char codes** (`Type` int32 in the `Pre_Extrapolation`/`Post_Extrapolation`
  child): `'A'`→REPEAT_RELATIVE, `'C'`→CONSTANT, `'K'`→SLOPE, `'M'`→MIRROR, `'R'`→REPEAT.
  `Repetition` int32 gives repeat count, negative meaning infinite (-1 sentinel).
- **`SkinningType` strings**: `"Rigid"`, `"Linear"`, `"DualQuaternion"`, `"Blend"` map 1:1 to the 4
  `ufbx_skinning_method` enum values; unrecognized/missing stays `UFBX_SKINNING_METHOD_LINEAR` (0).
- **Type::Name encoding** differs by format: ASCII uses literal `"Type::Name"` with `"::"` separator
  and **name comes after** the separator; binary uses `"Name\x00\x01Type"` with a literal
  `\x00\x01` 2-byte separator and **name comes before** it (12271-12305). Also, sub-type strings with
  a leading `"Fbx"` (3 bytes) have that prefix stripped for both formats (14974-14978) — e.g. binary
  files can spell subtypes `"FbxMesh"` while ASCII uses bare `"Mesh"`, both normalize to `"Mesh"`.
- **Constraint type-name strings → enum** table at 14805-14812: exact strings are
  `"Aim"`, `"Parent-Child"`, `"Position From Positions"`, `"Rotation From Rotations"`,
  `"Scale From Scales"`, `"Single Chain IK"` (note the spaces and mixed casing — must match exactly,
  `strcmp`, not case-insensitive).
- **Connections format codes per version** (15236-15310): pre-7000 uses `c`/`s`/`_` scanf-like format
  chars over Type::Name strings; ≥7000 uses `L` (int64) ids. Type char values are always the literal
  2-letter ASCII codes `"OO"`, `"OP"`, `"PO"`, `"PP"` (object-object, object-property, property-object,
  property-property).
- **Synthetic/pointer id space** (12220-12268): ids ≥ `UFBXI_POINTER_ID_START`
  (`0x8000000000000000`) are reserved for "pointer-derived" ids that need de-duplication through
  `ufbxi_synthetic_id_from_ptr_id`'s hash map; ids further ≥ `UFBXI_SYNTHETIC_ID_START` (pointer start
  + `0x4000000000000000`, or +`0x100` under `UFBX_REGRESSION` builds for easier fuzzing/testing) are
  pure incrementing counters from `ufbxi_push_synthetic_id`. Real FBX file ids (parsed `L` values) are
  assumed to never collide with this reserved high range in practice, but `ufbxi_validate_fbx_id`
  defensively remaps any incoming id that does land ≥ `UFBXI_POINTER_ID_START` through the same
  interning map so it can't collide with an internally-synthesized id.

## Quirks & edge cases

- **Auto tangent "unify" TODO left unimplemented** (14420-14422): FBX's "unified" (non-broken) user
  tangent mode is supposed to force `slope_left = slope_right`, but ufbx's code has this as a
  commented-out TODO and does *not* do it — broken and "unified" user tangents currently behave
  identically (independent slopes). Port faithfully (bug-compatible) unless deliberately fixing;
  document the deviation either way.
- **TCB tangents never propagate next-left info** (14410-14413): unlike auto tangents (which roll
  `next_slope_left` forward into the next key's left tangent), TCB explicitly zeroes
  `next_slope_left`/`next_weight_left` each time — every key's TCB tangent is derived fresh from its
  immediate neighbors' raw values, never inherited.
- **Velocity data parsed but deliberately never applied** (14356-14372, 14459-14471): both blocks are
  `#if 0`-disabled with a comment explaining MotionBuilder appears to already bake velocity into the
  auto-bias math, so reapplying it double-counts. If a Swift port ever wants to support this it needs
  fresh empirical verification, not just enabling the dead code.
- **`CONSTANT_NEXT` bit aliasing with `TANGENT_AUTO`** (both `0x100`): safe only because interpretation
  branches first on `INTERPOLATION_CONSTANT` vs `INTERPOLATION_CUBIC`, which are mutually exclusive —
  a port using a flags `OptionSet` must preserve this "reinterpret same bit under different top-level
  mode" behavior rather than giving them distinct enum cases naively.
- **Poses reference bones by raw FBX id/name, bypassing the connection graph entirely**
  (14657, explicit `(!?)` comment) — this is a documented FBX-format oddity: `PoseNode.Node` holds a
  bone identifier directly instead of the bone being connected to the pose via a `C:` OO/OP entry like
  everything else in the format. A Swift port's pose reader must special-case this rather than
  expecting connection-graph resolution to handle it.
- **Blender's `DeformPercent` exported as a child value, not a property** (14067-14083,
  13077-13137 in the related pre-7000 synthetic blend shape path): animations still target the
  `"DeformPercent"` *property* name by convention, so ufbx synthesizes a matching property on the
  channel even though the exporter never wrote one, keeping the animation-curve-to-property binding
  path uniform regardless of exporter.
- **Legacy pre-7000 texture-in-geometry**: `LayerElementTexture` / `LayerElementXxxTextures` /
  `LayerElementXxx_Textures` nodes appear *inside mesh geometry* in old FBX (6.x) rather than as
  separate connected `Texture` objects with named property connections — flagged in the code itself
  as "What?!" (ufbx.c:13675, just above this span's start but directly related — the actual per-mesh
  texture assignment logic is `ufbxi_read_mesh`'s territory in the previous span, this span only
  covers the resulting extra-data plumbing (`ufbxi_tmp_mesh_texture`/`ufbxi_mesh_extra`) that a later
  pass turns into modern-style material texture connections).
- **Skin `Indexes`/`BlendWeights` length mismatch tolerated** (14012-14019, comment
  `// TODO strict: ufbxi_check(indices->size == weights->size)`): silently truncates to the shorter
  array rather than failing, even in strict mode — inconsistent with `ufbxi_read_skin_cluster`'s
  stricter `Indexes`/`Weights` handling one function below it, which *does* require exact size match.
- **`ufbxi_read_audio_clip` never reads filename properties** (14785-14798) — likely an oversight
  relative to `ufbxi_read_texture`/`ufbxi_read_video`'s parallel structure (both of which probe
  `FileName`/`Filename`/`RelativeFileName`/`RelativeFilename`); flag during port, consider filing
  upstream or matching video's behavior deliberately if product needs audio clip paths.
- **Property split during synthetic attribute creation is index-shuffle-in-place** (14877-14894): the
  loop partitions `info->props.props` array by moving attribute-owned entries out to `tmp_stack` while
  left-compacting the remaining node-owned entries in the original array — a subtle in-place partition,
  not a stable copy; a Swift port doing this with `Array` should just filter into two new arrays
  instead (no correctness reason to mimic the in-place trick).
- **Ascii vs binary embedded content**: binary Content blocks are a single opaque byte string
  (fast-pathed, zero-copy `content = parts[0]`); ASCII Content blocks are always treated as
  potentially multi-chunk and copied/concatenated (11774, `!uc->from_ascii` gates the fast path) —
  actual base64 decoding of ASCII content happens in a different (parsing) subsystem before this
  function runs; this function only concatenates already-decoded byte chunks.
- **Deferred connection resolution is one flat array covering *both* file connections and every
  internally synthesized connection** (`ufbxi_connect_oo`/`_op`/`_pp`) — order matters for later
  passes only in the sense that they iterate the whole array; there is no dependency on file
  connections being processed before/after synthetic ones within this span.
- **`ufbx_anim_curve.min_time`/`max_time` are not set by `ufbxi_read_animation_curve`** despite the
  struct having these fields (ufbx.h:3234-3235) — only `min_value`/`max_value` are computed in this
  function; a Swift port should double check whichever later pass (out of this span) is responsible
  and make sure the equivalent Swift function actually gets called, since it's easy to assume this
  reader is "complete" when porting curve-by-curve.

## Port guidance

**Port faithfully (these are exactly the "crown jewel" bug-compatible bits):**
- The entire keyframe tangent decode in `ufbxi_read_animation_curve`, including: the RLE run-length
  decode over `KeyAttrFlags`/`KeyAttrDataFloat`/`KeyAttrRefCount`; the exact bit-packed weight decode
  (`& 0xffff`, `>> 16`, `* 0.0001`); the auto-tangent formula (`ufbxi_solve_auto_tangent*`) including
  the large-bias magic-constant escape hatch; the TCB Kochanek-Bartels basis math
  (`ufbxi_solve_tcb`); the slope→dx/dy conversion order. Any deviation changes animation playback
  subtly and is very hard to catch without a reference-diff test against real FBX exports (Maya,
  MotionBuilder, Blender, 3ds Max all hit different code paths here).
- KTime-to-seconds divisor selection logic (the two epoch constants + `TCDefinition`/version gating).
- Type::Name splitting asymmetry between ASCII/binary, and the `"Fbx"` subtype-prefix stripping.
- The pose-bypasses-connections special case, and the Blender `DeformPercent` synthesis quirk.
- The known-incomplete "unify user tangents" TODO and the disabled velocity code — port them as
  documented gaps (leave a `// TODO` marker matching ufbx's), don't silently "fix" them without
  flagging the behavioral change to the wider porting effort, since evaluation-code parity depends on
  matching ufbx's actual (imperfect) behavior for now.

**Replace with Swift idioms:**
- `ufbxi_key_flags` bitmask → a small Swift `OptionSet` (or, better, decode it immediately into a
  clean Swift enum `{interpolation: .constant(next: Bool)|.linear|.cubic(tangentMode: .auto(...)|
  .tcb(...)|.user(broken: Bool))}` at parse time) rather than carrying the raw C bitmask around; keep
  the *derivation logic* (which bits are checked when) faithful even as the representation changes.
- `ufbxi_tmp_connection`/flat connections array + later "find_fbx_id then branch on element type
  pairs" resolution → this whole design exists in C because ufbx parses in a single streaming pass
  with an arena allocator and can't easily build a typed graph incrementally. In Swift, since this
  port scope's whole DOM will already be materialized (Swift's `Data`/reference-type nodes), consider
  resolving connections into a typed adjacency structure (e.g. `[FBXID: [Connection]]`) as they're
  read, or immediately after the full connections block is parsed but before object dispatch, rather
  than keeping ufbx's exact multi-pass "tmp arrays + later giant resolution switch" shape. This is a
  legitimate architecture simplification — just make sure every semantic case ufbx's later resolution
  handles (out of this span, ~18100+) gets carried over.
- `ufbxi_push_element_extra` "extra data bag" pattern (mesh legacy textures, layered texture
  alphas/blend-modes) → just use proper optional fields on the corresponding Swift types instead of a
  side-table keyed by element id.
- Synthetic FBX-id generation for pre-7000 files (pointer-interning tricks, `UFBXI_POINTER_ID_START`
  etc.) → replace with any stable hashable key scheme in Swift (e.g. hash the `Type::Name` string
  directly into a `UInt64` or just key dictionaries by the `String` itself) — the elaborate
  pointer-vs-hash-map split in C exists purely for arena-allocator performance and has no bearing on
  correctness.
- The pose "HACK: transport tmp struct through the real struct pointer" (14681-14684) → just use a
  proper `[TempBonePose]` array in Swift and map it to real poses in a clean second pass.

**Skip per v1 scope:**
- Character/constraint solving beyond data passthrough (already true of ufbx itself here — TODO'd
  and "cursed all-caps" left unparsed) — expose `type`/`typeName` and leave targets/weights/axis-flags
  as later work or omit entirely per the stated scope ("data passthrough only").
- Threaded object parsing (`ufbxi_read_objects_threaded`) — the port scope has no threading
  requirement; single-pass sequential dispatch is sufficient and much simpler in Swift (structured
  concurrency, if wanted later, would look nothing like this batching scheme anyway).
- Shader-texture-as-shader-graph parsing (`ufbx_shader_texture`, 3ds Max node-graph-in-texture
  emulation) is referenced by the `ufbx_texture` struct but not populated anywhere in this span — it
  belongs to whatever later subsystem builds `ufbx_material.shader`/`ufbx_texture.shader`; treat as
  out of this span's responsibility, confirm with whichever notes file covers materials
  finalization/PBR mapping whether it's in v1 scope (PBR mapping tables are explicitly called out as
  "stretch" in the port scope, so `ufbx_shader_texture` most likely falls under that same stretch
  goal).

**Cross-subsystem dependencies (name them explicitly):**
- **FEEDS the finalize/graph-building stage** (out of this span, starts ~ufbx.c:18100
  `ufbxi_pre_finalize_scene`, materials/lights/cameras "update" functions ~22300-23900): everything
  this span reads raw (props, filenames, raw index/weight arrays, connection list) is *consumed* by
  that stage to build the real node tree, resolve skin cluster bone nodes, compute material FBX/PBR
  maps and shader classification, compute camera FOV/light color*intensity, resolve texture UV
  transforms and layered-texture layers, and turn blend channel `tmp_full_weights` + OO connections
  into `ufbx_blend_keyframe` lists. **Whoever writes the Swift equivalent of this span must produce
  data shapes that the finalize-stage port can consume equivalently** — coordinate closely with
  whichever notes file(s) cover scene finalization / transform evaluation / material PBR mapping.
- **DEPENDS ON property reading** (`ufbxi_read_properties`, `ufbxi_get_prop_type`, prop flag decoding
  at 11798+) and **DOM node retention** (`ufbxi_get_dom_node`), both from an earlier span — this span
  assumes `info.props` already exists and is fully decoded by the time any `ufbxi_read_*` function
  here runs.
- **DEPENDS ON the low-level array/value parser** (`ufbxi_find_array`/`ufbxi_get_array`,
  `ufbxi_normalize_array_type`, ufbx.c:7686-7867) for the exact semantics of type codes `'r'`
  (real, resolves to `'f'`/`'d'` depending on `ufbx_real` width), `'b'` (bool), `'i'`/`'l'` (int32/64),
  `'?'` (wildcard/no check) used throughout this span's `ufbxi_find_val*`/`ufbxi_find_array` calls.
- **DEPENDS ON mesh reading** (`ufbxi_read_mesh`, `ufbxi_read_vertex_element`, previous span) for the
  legacy pre-7000 mesh-embedded-texture quirk plumbing (`ufbxi_tmp_mesh_texture`) to make sense — this
  span only carries the data forward.
- **FEEDS pre-7000 "Take" animation reading** (starts immediately after this span, ufbx.c:15312
  onward, `// -- Pre-7000 "Take" based animation`) via the shared `uc->anim_stack_map` — the Take
  reader (next subsystem) looks up/creates the same `ufbx_anim_stack` elements this span's
  `ufbxi_read_anim_stack` creates, keyed by name, so stacks aren't duplicated when a file has both a
  legacy Take block and (redundantly) modern AnimationStack objects.
