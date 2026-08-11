# Legacy (pre-7000) FBX reading: Takes animation, Version5 settings, legacy object graph

## Purpose

This subsystem handles everything specific to old-style FBX files (roughly versions 3000-6999,
including "Version 5.x"/pre-6000 files that put all data flat under the document root instead of
inside `Objects`/`Connections` sections). It covers two mostly-independent pieces: (1) **Takes**,
the pre-7000 equivalent of animation stacks/layers/curves, stored as deeply nested `Channel` nodes
holding heterogeneous `Key` arrays that must be decoded by hand into ufbx's normal
`ufbx_anim_curve`/`ufbx_keyframe` representation; and (2) **legacy object reading**
(`ufbxi_read_legacy_*`), which parses `Model`/`Material`/`Link` nodes that in old files carry
inline geometry, material props, and skin-cluster data directly (no separate `Geometry`/`Deformer`
objects, no `Connections` section — parent/child and node/attribute relationships are inferred from
`Type::Name` string pairs and a `Children` string array). The tail of the assigned range also
contains generic scene-finalization helpers (relative filename resolution, `ufbxi_finalize_mesh`)
that happen to fall in this line span but are not legacy-specific.

## Key data structures

- **`ufbxi_legacy_prop`** (ufbx.c:15938-15943): a static table entry `{ prop_name, prop_type,
  node_name, node_fmt }` describing how to translate a legacy child node (e.g. a node literally
  named `"Diffuse"` with 3 `R` values) into a `ufbx_prop` with a modern name (e.g. `DiffuseColor`)
  and `UFBX_PROP_COLOR` type. `node_fmt` is a tiny format string interpreted by
  `ufbxi_read_legacy_prop` (`L`=int64 at value index 0, `R`=one real appended to `value_real_arr`,
  `S`=string, `_`=skip a value slot). Four tables exist: `ufbxi_legacy_light_props` (15946),
  `ufbxi_legacy_camera_props` (15957), `ufbxi_legacy_bone_props` (15972),
  `ufbxi_legacy_material_props` (15977) — each **must be alphabetically sorted** per the comments
  (this ordering isn't algorithmically required by the code shown, it's a maintenance convention).
- **`ufbx_anim_curve.keyframes`** (`ufbx_keyframe_list`, ufbx.h:3213-3230): the common target
  representation both post-7000 and legacy Take parsing populate. Each `ufbx_keyframe` (ufbx.h:3203)
  has `time` (double seconds), `value` (ufbx_real), `interpolation`
  (`UFBX_INTERPOLATION_{CONSTANT_PREV,CONSTANT_NEXT,LINEAR,CUBIC}`, ufbx.h:3154-3163), and
  `left`/`right` `ufbx_tangent { dx, dy }` — cubic Bezier control-point deltas relative to the key's
  own (time, value), NOT raw slopes. The Bezier reconstruction is documented at ufbx.h:3193-3199:
  control points are `(prev.time,prev.value)`, `(prev.time+prev.right.dx, prev.value+prev.right.dy)`,
  `(next.time-next.left.dx, next.value-next.left.dy)`, `(next.time,next.value)`.
- **`ufbx_extrapolation`** (ufbx.h:3177-3183): `{ mode, repeat_count }`. `mode` is one of
  `UFBX_EXTRAPOLATION_{CONSTANT,REPEAT,MIRROR,SLOPE,REPEAT_RELATIVE}`. `repeat_count` negative means
  infinite.
- **`ufbxi_key_flags`** (ufbx.c:14085-14104, only partially in this range but used here): bit flags
  passed to the auto-tangent solver — `UFBXI_KEY_CLAMP`, `UFBXI_KEY_TIME_INDEPENDENT`,
  `UFBXI_KEY_CLAMP_PROGRESSIVE` are the three actually used by the legacy Take path (15541).
- **Take object identity**: legacy files have no numeric FBX IDs for the objects referenced inside
  a `Take`; instead each `Model`/channel target is identified by a `Type::Name` (ASCII) or
  `Name\x00\x01Type` (binary) string pair, which is turned into a stable pseudo-FBX-ID via
  `ufbxi_synthetic_id_from_string` (ufbx.c:12250, hashes/interns the pointer — same interned string
  pointer ⇒ same ID) so that `Connections`-style graph building can still work uniformly.
- **`ufbxi_tmp_anim_stack`** (ufbx.c:6406, map at 6513): used to shim `LocalTime`/`ReferenceTime`
  from a post-7000 `Take` block onto the corresponding `ufbx_anim_stack` found by name — see Quirks.

## Control flow / algorithms

### 1. `ufbxi_read_take_anim_channel` (ufbx.c:15323-15583)
Decodes one `Channel`'s `Key:` array into an `ufbx_anim_curve`. Called once per X/Y/Z (or single)
sub-channel of a property.

1. Read `Default` (`R`) into `*p_default` if present (15325) — this becomes
   `ufbx_anim_value.default_value.v[i]`.
2. Find the `Key` array (`ufbxi_find_array(node, ufbxi_Key, 'd')`, i.e. as doubles); if absent,
   return success with only the default value set (curve not created) (15328-15329).
3. Create a synthetic `ufbx_anim_curve` element and connect it to the owning `ufbx_anim_value` via
   `ufbxi_connect_op` (curve → value, property name) (15332-15335).
4. Read `Pre_Extrapolation`/`Post_Extrapolation` child nodes via `ufbxi_read_extrapolation` (15337-338;
   see Format details for codes).
5. If `opts.ignore_animation`, stop here (curve has extrapolation/name but no keys) (15340).
6. Determine `key_ver` (`KeyVer` int prop; if absent/<=0, defaulted by **document version**: <5000
   → 4003, <6000 → 4004, else → 4005) (15342-15352). This version selects which of several
   ad-hoc slope/weight encodings apply below.
7. Read `KeyCount` ('Z', i.e. size_t) → allocate `curve->keyframes` array of that length (15354-15358).
8. **The `Key` array is a flat, heterogeneous stream of doubles** — ufbx casts every raw value
   (originally i64/f64/char in the source binary) to `double` and reinterprets bytes as needed via
   `ufbxi_double_to_char` (15314-15321: valid only for values in `[0,127]`, else returns `0`). Two
   running cursors are kept: `data`/`data_end` walk the flat array; `next_time`/`next_value` are
   prefetched one key ahead so slope calculations can see the following key while processing the
   current one.
9. Prime `next_time`/`next_value` from the first 2 doubles if `num_keys>0` (15371-15375): time is
   divided by `uc->ktime_sec_double` (KTime ticks-per-second, see Format details) to get seconds.
10. Main loop `for i in 0..<num_keys` (15377-15578), each iteration:
    a. Track `curve->min_value`/`max_value` running min/max over key values (15380-15386).
    b. Consume exactly 3 doubles: `time`, `value`, `mode` char (15389-15393). `mode` is one of
       `'U'` (cUbic), `'L'` (Linear), `'C'` (Constant).
    c. **Mode `'U'` (cubic)** (15401-15511): consume 1 more double = `slope_mode` char, which
       selects a per-mode sub-decode (see Format details table for the exact byte counts/semantics
       of modes `s`/`b`, `a`, `p`, `q`, `t`, `d`). Every branch either sets explicit
       `slope_right`/`next_slope_left` floats, or sets `auto_slope = true` to defer to the
       auto-tangent solver once the next key's value is known. After the slope-mode data, a
       `num_weights`-controlled loop (0-2 iterations) reads weight-mode chars (`'n'`,`'a'`,`'l'`,
       `'r'`,`'c'`) that either accept the default weight (0.333333) or read explicit
       `weight_right`/`next_weight_left` floats (15482-15511).
    d. **Mode `'L'` (linear)**: `key->interpolation = LINEAR`, no extra data (15513-15515).
    e. **Mode `'C'` (constant)**: if `key_ver>=4004`, consume 1 more double whose char is `'n'` →
       `CONSTANT_NEXT` else `CONSTANT_PREV`; if `key_ver<4004` there's no extra byte and mode is
       always `CONSTANT_PREV` (15516-15524).
    f. Prefetch the *next* key's time/value (2 more doubles) if not last key (15530-15534) — needed
       both for linear-slope computation and auto-tangent solving of the *current* key.
    g. If `auto_slope`: call `ufbxi_solve_auto_tangent(uc, prev_time, key.time, next_time,
       key[-1].value, key.value, next_value, weight_left, weight_right, /*auto_bias*/0.0,
       UFBXI_KEY_CLAMP_PROGRESSIVE|UFBXI_KEY_TIME_INDEPENDENT)` for BOTH `slope_left` and
       `slope_right` (single symmetric slope) — but only if `i>0`; the first key's auto slope is
       forced to `0` (15536-15544, ufbx.c:14106-14167 for the solver body — see below).
    h. If `interpolation==LINEAR`: recompute `slope_right`/`next_slope_left` as the literal secant
       slope `(next_value-value)/(next_time-time)` (or 0 if `next_time<=time`) (15548-15554) —
       this overrides whatever was set in step (c)/(g), i.e. LINEAR always wins with a straight
       secant regardless of any leftover cubic scratch state (harmless since LINEAR keys don't hit
       the cubic branch, but ensures the *next* key's `left` slope, which is `next_slope_left`, is
       consistent when transitioning from a linear key into a following cubic key).
    i. Convert `(slope, weight)` → Bezier tangent deltas: `left.dx = weight_left*(time-prev_time)`,
       `left.dy = left.dx*slope_left` (only if `time>prev_time`, else zero); mirror for `right.dx/dy`
       using `next_time-time` (15557-15573). This is where the "weight" (fraction of the time
       interval, default 1/3) times "slope" (dValue/dTime) becomes an actual (dx,dy) offset.
    j. Roll `slope_left/weight_left forward = next_slope_left/next_weight_left`, `prev_time = time`
       (15575-15577) for the next iteration.
11. Assert all data consumed exactly (`data==data_end`) (15580) — a correctness check that the
    per-mode byte-counts above are exhaustive/exact.

**`ufbxi_solve_auto_tangent`** (ufbx.c:14106-14167, called from 15538 with flags
`CLAMP_PROGRESSIVE|TIME_INDEPENDENT`):
- `TIME_INDEPENDENT` set ⇒ skips the "blend toward local secants + auto_bias" logic entirely
  (14119-14140 block) and just uses `slope = (next_value-prev_value)/(next_time-prev_time)` — the
  global secant across prev→next (14116).
- `CLAMP_PROGRESSIVE` set ⇒ (14144-14164) clamps the (unsigned) slope magnitude so the resulting
  tangent line doesn't overshoot past the prev/next key's value within the weighted time window:
  computes `max_left`/`max_right` bounds from `weight_left*(time-prev_time)` /
  `weight_right*(next_time-time)` and the value deltas, clamps negative/NaN bounds to 0, and clamps
  `abs_slope` to the min of both bounds (prevents classic overshoot/ringing artifacts of naive
  Catmull-Rom-like auto tangents at extrema).
- (For reference, the two one-sided variants `ufbxi_solve_auto_tangent_left`/`_right`,
  ufbx.c:14169-14213, exist for the modern post-7000 curve reader and are NOT used by the legacy
  Take path, which always uses the symmetric two-sided solver.)

### 2. `ufbxi_read_take_prop_channel` (ufbx.c:15587-15664, recursive, depth-limited to 2 via
`ufbxi_recursive_function`)
Given a `Channel` node with `name` (e.g. `"Transform"`, `"Visibility"`, a blend-shape name, etc.):

- **`name == "Transform"`** (15591-15613): pre-7000 stores the whole local transform as a nested
  `Transform{ Channel:"T"{ Channel:"X"{Key...} ... } Channel:"R"{...} Channel:"S"{...} }` tree.
  ufbx flattens this to look like post-7000's `Lcl Translation`/`Lcl Rotation`/`Lcl Scaling`
  top-level channels: it iterates the `Transform` node's direct `Channel` children, reads each
  child's `"C"` value (the sub-channel name literal `T`/`R`/`S`), maps it to the modern property
  name string, and recurses into `ufbxi_read_take_prop_channel` treating that child as if it were a
  top-level channel with the new name. Depth is bounded because this branch cannot itself be
  entered again (comment at 15585-15586: only reachable for `T`/`R`/`S`, and `Transform` case is
  excluded on the recursive call).
- **Otherwise** (15615-15663): this is a leaf property (e.g. `Lcl Translation`, `Visibility`, a
  blend-shape channel, a light/camera prop channel):
  1. Pre-6000 blend shape channels are suffixed `" (Shape)"` in the channel name; this suffix is
     stripped and the name re-interned (15618-15624).
  2. Determine whether this node itself holds a single curve (has direct `Key` or `Default` child
     → `num_channel_nodes=1`, `channel_nodes[0]=node`) or is a compound of up to 3 sub-`Channel`s
     each with their own `C` (component letter, e.g. `X`/`Y`/`Z`) and `Key`/`Default`
     (15632-15646). Early-return success (no-op) if no channels found at all (15649).
  3. Create a synthetic `ufbx_anim_value` element, connect it to the layer (`connect_oo`, value→
     layer) and to the target object+property (`connect_op`, value→target, prop name)
     (15651-15656).
  4. For each of the (1-3) channel nodes, call `ufbxi_read_take_anim_channel` writing into
     `value->default_value.v[i]` and creating/connecting a curve per component (15658-15660).

### 3. `ufbxi_read_take_object` (ufbx.c:15666-15686)
Given a `Model` node inside a `Take`: read its `"c"`-typed value (a compact `Type::Name` pair
without separate name string — note lowercase `c` format vs `C`/`S` elsewhere), derive
`target_fbx_id` via `ufbxi_synthetic_id_from_string`, then iterate its `Channel` children (top-level
property channels like `Visibility`, `Transform`, blend shape names) invoking
`ufbxi_read_take_prop_channel` for each.

### 4. `ufbxi_read_take` (ufbx.c:15688-15749)
1. Read `LocalTime`/`ReferenceTime` (`"LL"`, two int64) if present into up to 4 synthetic integer
   props (`LocalStart`/`LocalStop`/`ReferenceStart`/`ReferenceStop`) (15694-15702).
2. Read the Take's `"C"` name.
3. **Version gate — `uc->version >= 7000`** (15709-15723): in this case the file is fundamentally
   post-7000 (Takes are legacy vestiges some exporters still emit alongside real
   stacks/layers/curves for compatibility) — ufbx does NOT build a stack/layer from this Take.
   Instead it only harvests the LocalTime/ReferenceTime into the *already-existing*
   `ufbx_anim_stack` of the same name (looked up in `uc->anim_stack_map`, a name→stack map
   populated while reading real 7000+ `AnimationStack` objects) purely as a time-range fallback,
   and returns.
4. **Pre-7000 path** (15725-15748): treat the Take as if it were a first-class animation stack:
   create a synthetic `ufbx_anim_stack` (name = Take name, props = the Local/ReferenceTime props
   from step 1) and a synthetic `ufbx_anim_layer` named `"BaseLayer"` (`ufbxi_BaseLayer`), connect
   layer→stack, then for each `Model` child node call `ufbxi_read_take_object`.

### 5. `ufbxi_read_takes` (ufbx.c:15751-15764)
Top-level loop: repeatedly calls `ufbxi_parse_toplevel_child` to walk siblings under a `Takes`
node, dispatching every child named `Take` to `ufbxi_read_take`. Invoked from both
`ufbxi_read_root` (post-3000, in case the file happens to also have Takes, 7000-line path at
15911-15913) and `ufbxi_read_legacy_root` (pre-6000 flat-root files, 16451-16452).

### 6. `ufbxi_read_legacy_settings` (ufbx.c:15766-15816)
Idempotent (`uc->read_legacy_settings` flag, 15768-15769) reader of the pre-6000 `Settings` node
(nested under top-level `Version5`, or found directly by name in flat pre-6000 files). Reads a
`FrameRate` child as either a direct double (`"D"`) or a string that must fully parse as a double
(`ufbxi_parse_double`, checking `end == str.data+str.length`) (15775-15791). If a valid fps>0 is
found, synthesizes two scene-settings props: `CustomFrameRate` (real) and `TimeMode` = 
`UFBX_TIME_MODE_CUSTOM` (int). These are merged into `uc->scene.settings.props` by allocating a new
combined array, copying new-then-existing, sorting (`ufbxi_sort_properties`) and deduplicating
(`ufbxi_deduplicate_properties`) (15794-15813) — i.e. legacy settings are prepended before existing
(likely-empty at this point) settings props, then the whole set is normalized.

### 7. `ufbxi_read_root` (ufbx.c:15844-15936) — legacy-relevant portions only
This is the main >=3000 entry point (both <7000 and >=7000 share it structurally). Legacy-specific
branches:
- 15860-15862: if `version < 7000`, calls `ufbxi_init_node_prop_names` (sets up name-lookup table
  variant for old property names) before reading Documents/root.
- 15867-15878: if `version < 7000`, root ID is derived from a fixed literal `Type::Name` string
  `"Model::Scene"` (ASCII) or `"Scene\x00\x01Model"` (binary) rather than from a `Documents` block
  (there is no `Documents` section pre-7000).
- 15911-15913: `Takes` toplevel is parsed and `ufbxi_read_takes` invoked unconditionally (no-op if
  absent) for ALL versions ≥3000 (works for both old real Takes and the 7000+ fallback-time-range
  case).
- 15915-15928: after Takes, checks for a top-level `GlobalSettings` (all versions) and then a
  top-level `Version5` block containing `Settings`, dispatching to `ufbxi_read_legacy_settings`
  pre-6000 only in practice (the block wouldn't otherwise be present).

### 8. Legacy object graph: `ufbxi_read_legacy_model` → dispatch (ufbx.c:16350-16421)
For a `<6000` (or generically pre-`Objects`/`Connections`) `Model` node found directly at document
root:
1. Split its `"s"` (string) value on `Type::Name`/`Name\x00\x01Type` via
   `ufbxi_split_type_and_name` (12271-12305; note the ASCII/binary order is *reversed* between the
   two encodings — comment at 12282 flags this as unexplained/`???`).
2. `info.fbx_id = ufbxi_synthetic_id_from_string(type_and_name)`; create the `ufbx_node` element.
3. Create a *separate* synthetic id for a possible node-attribute (`attrib_info`, always a fresh
   `ufbxi_push_synthetic_id`, unconditionally `connect_oo(attrib→node)` even if no attribute
   actually gets created — comment at 16371 "if we make unused connections it doesn't matter").
4. Look at the node's `Type` child (`"C"`): `Light`→`ufbxi_read_legacy_light`, `Camera`→
   `ufbxi_read_legacy_camera`, `LimbNode`→`ufbxi_read_legacy_limb_node`; else if the node itself has
   a `Vertices` child → `ufbxi_read_legacy_mesh`; else no attribute (`has_attrib=false`).
5. If an attribute was created, register the node→attribute mapping via `ufbxi_insert_fbx_attr` so
   downstream generic connection-forwarding logic (outside this range) treats it like a modern
   `NodeAttribute` connection (16391-16393).
6. **Children**: legacy `Model` nodes list children as a plain string array named `Children`
   (`ufbxi_find_array(node, ufbxi_Children, 's')`) — each string is itself a `Type::Name` id,
   resolved via `ufbxi_synthetic_id_from_string` and connected `child→parent` via `connect_oo`
   (16396-16404). This replaces the modern `Connections` section entirely for parent/child links.
7. **Non-Take animation channels**: `Channel` children directly on a legacy `Model` (i.e. animation
   NOT wrapped in a `Take` block at all — seen in some very old/odd files) are read via
   `ufbxi_read_take_prop_channel` against a lazily-created single implicit layer id
   (`uc->legacy_implicit_anim_layer_id`, created on first use only, "so we won't be the first
   animation stack" per comment 16412) (16406-16418). `ufbxi_read_legacy_root` later (16464-16480)
   materializes this into a real `ufbx_anim_layer` named `"(internal)"` plus a paired
   `ufbx_anim_stack`, connected layer→stack, only if any such channel was ever seen.

### 9. `ufbxi_read_legacy_mesh` (ufbx.c:16173-16331)
Reads inline polygon-mesh geometry directly off a `Model` node (no separate `Geometry` object):
1. Requires both `Vertices` and `PolygonVertexIndex` children; silently no-ops (returns success,
   not an error) if either is missing — this is how NURBS/other non-poly attribute types under
   `Model` are skipped without failing the whole parse (16176-16178).
2. Reads blend shapes via `ufbxi_read_synthetic_blend_shapes` (out of this range) and calls
   `ufbxi_patch_mesh_reals` (16183-16185) — twice, also again at the very end (16328) after
   skin/material data is attached; the "patch" step presumably fixes up float/double storage
   width consistently (defined elsewhere).
3. `Vertices` (`'r'` reals, x3 per vertex) and `PolygonVertexIndex` (`'i'` ints) become
   `mesh->vertices`/`vertex_indices` directly aliasing the raw parsed arrays (no copy) unless
   `retain_dom`, in which case the index array is duplicated because it gets mutated in place
   (16197-16224) — the last index of each polygon must be bitwise-NOT'd (FBX's classic "negate last
   vertex index of a face" convention) and ufbx auto-fixes a non-negated last index (warns if
   `opts.strict`) (16218-16223).
4. Calls the shared `ufbxi_process_indices` (out of range) to build `mesh->faces` etc. from the
   negated-index convention, same as modern files.
5. **Normals** (16229-16250): legacy files may store normals per-vertex OR per-index without an
   explicit "mapping mode" flag on the array itself (unlike modern LayerElementNormal). ufbx infers
   which by comparing count to `num_vertices` vs `num_indices`: prefers per-vertex if the counts
   match AND (doesn't also match per-index OR `version==5000`); otherwise per-index if it matches
   `num_indices`. Per-index normals use the `ufbxi_sentinel_index_consecutive` sentinel index array
   (meaning "index == position in stream", i.e. implicit identity mapping) rather than allocating a
   real index buffer (16247-16249), and bumps `uc->max_consecutive_indices` for later validation.
6. **UVs** (16252-16265): a single UV set (`GeometryUVInfo` child) parsed generically via the shared
   `ufbxi_read_vertex_element` helper (children `TextureUV`/`TextureUVVerticeIndex`), pushed as the
   sole entry of `mesh->uv_sets` with empty name.
7. **Material assignment** (16267-16291): `MaterialAssignation` (`"C"`) is either `ByPolygon`
   (per-face index array via `ufbxi_read_truncated_array`, truncated/padded to `num_faces`) or
   `AllSame` (single material index; if it's `0`, uses the `ufbxi_sentinel_index_zero` sentinel
   array instead of allocating, else fills every face with that constant index).
8. **Nested `Material`/`Link` children** (16296-16322): unlike modern files (materials/skin
   clusters are separate top-level `Objects` connected via `Connections`), legacy meshes nest their
   materials and skin-cluster ("Link") data as direct child nodes of the `Model`. Each is read via
   `ufbxi_read_legacy_material`/`ufbxi_read_legacy_link`, given a synthetic id, and connected to the
   mesh's element id (`connect_oo`). The first `Link` encountered lazily creates an implicit
   `ufbx_skin_deformer` (unnamed except reusing the mesh's name) connected mesh←deformer←clusters,
   mirroring the modern Deformer/Cluster hierarchy from flat legacy data (16305-16321).
9. Sets `skinned_is_local=true` and `skinned_position/normal = vertex_position/normal` (i.e. legacy
   meshes have no separate "bind pose local vs skinned" distinction — same as the modern default
   fallback done later in `ufbxi_finalize_mesh`, 16725-16729).

### 10. `ufbxi_read_legacy_link` (ufbx.c:16092-16121)
Reads one skin-cluster's data directly off the nested `Link` node: `Indexes`/`Weights` parallel
arrays (must have equal size) become `cluster->vertices`/`weights` (aliased, no copy); `Transform`/
`TransformLink` (each ≥16 reals) are read as 4x4 matrices via `ufbxi_read_transform_matrix` into
`mesh_node_to_bone`/`bind_to_world` respectively. Comment (16097) flags this should ideally share
code with the modern `ufbxi_read_skin_cluster` but currently duplicates the logic.

### 11. `ufbxi_read_legacy_light`/`_camera`/`_limb_node`/`_material` (16123-16171, 16074-16090)
All four are thin wrappers: push the typed element, call `ufbxi_read_legacy_props` against the
appropriate static table (see Key data structures), copy the resulting prop array into
`element->props.props`. `_limb_node` (bone) differs slightly by requiring an explicit nested
`Properties` child node to search within, rather than searching the object node directly
(16161-16164) — bones store their properties in a sub-block while lights/cameras/materials store
each prop as a same-named direct child.

### 12. `ufbxi_read_legacy_media` (ufbx.c:16333-16348)
Pre-6000 embedded/referenced texture media: iterates a `Media`→`Video` node's children, each given
a fresh synthetic id and read via the modern `ufbxi_read_video` (shared, out of range).

### 13. `ufbxi_read_legacy_root` (ufbx.c:16424-16483) — top-level entry for truly flat (<6000, no
`Objects`/`Documents` wrapper at all) files
1. Calls `ufbxi_init_node_prop_names` again (redundant-looking but harmless) (16426).
2. Creates a nameless synthetic root `ufbx_node` (16431-16436), same shape as the modern root setup
   in `ufbxi_setup_root_node`.
3. Because `ufbxi_read_header_extension` is optional/may not run, defaults
   `ktime_sec = 46186158000` (the v7-era KTime constant) upfront (16438-16440) so Take key-time
   division always has a valid divisor even in headerless files.
4. Loop over toplevel document nodes (`ufbxi_parse_legacy_toplevel`) dispatching by name:
   `FBXHeaderExtension`→header, `Media`→`ufbxi_read_legacy_media`, `Takes`→`ufbxi_read_takes`,
   `Model`→`ufbxi_read_legacy_model`, literal string `"Settings"`→`ufbxi_read_legacy_settings`
   (16442-16457). Note: unlike other node-name comparisons here which use interned pointer
   equality, the `"Settings"` check uses `strcmp` — it's presumably not pre-interned into the
   known-name table for this ultra-legacy path.
5. After the loop, retains the DOM if requested, then finalizes any implicit anim stack/layer
   accumulated from bare `Channel`s on `Model`s (see item 8 above) (16460-16482).

## Format details

- **KTime divisor** (`ktime_sec_double`): FBX's internal time integer unit ("KTime", ticks per
  second). Two possible values, both used to divide raw integer key-times into double seconds:
  - `46186158000` — the standard/"v7" unit, used whenever `version<8000`, OR when
    `FBXHeaderVersion>=1004` and `TCDefinition==127` (ufbx.c:12021-12029). This is also the
    hardcoded default in the header-less legacy path (`ufbxi_read_legacy_root`, 16439).
  - `141120000` — used for `version>=8000` files that also have `TCDefinition` set to something
    other than `127` (post-8000 KTime redefinition; largely irrelevant to this <7000-focused
    subsystem but documented here since it's the same field).
- **`KeyVer` defaults** when the node lacks an explicit `KeyVer` int (or it's ≤0) (ufbx.c:15344-15352):
  `doc version<5000 → 4003`; `<6000 → 4004`; else (this branch also covers ≥7000, though Takes with
  real key arrays are essentially unseen there) `→ 4005`.
- **Key-stream cell format**: physically a flat array of doubles (`ufbxi_find_array(node,
  ufbxi_Key, 'd')`); values that are semantically single ASCII mode-characters were originally
  packed as tiny integers and are recovered with `ufbxi_double_to_char` (ufbx.c:15314-15321): valid
  only for `0.0 <= v <= 127.0`, returned as `(char)(int)v`; anything else (e.g. a real timestamp/
  value slot that got passed to this function by mistake, which shouldn't happen given the fixed
  layout) yields `'\0'`.
- **Per-key layout**, in order, always starting with exactly 3 doubles `[time_ticks, value,
  mode_char]` (15389-15393):
  - `mode == 'L'` (Linear): 0 extra doubles.
  - `mode == 'C'` (Constant): `key_ver>=4004` → 1 extra double (char `'n'`→CONSTANT_NEXT else
    CONSTANT_PREV); `key_ver<4004` → 0 extra, always CONSTANT_PREV.
  - `mode == 'U'` (Cubic): 1 extra double = `slope_mode` char, then a slope-mode-dependent number
    of doubles, then 0-2 weight-mode entries. Slope-mode table (ufbx.c:15401-15480):
    | slope_mode | extra doubles consumed | effect |
    |---|---|---|
    | `s` or `b` | 2 (`slope_right`, `next_slope_left` as explicit floats) | explicit two-sided slope; `num_weights=0` if `key_ver==4003`, else `1` |
    | `a` | 0 | `auto_slope=true`; `num_weights=0` if `key_ver<=4004` else `1` |
    | `p` | 2 (consumed/ignored) | `auto_slope=true`; `num_weights=1` if `key_ver<=4004` else `2` |
    | `q` | 2 (consumed/ignored) | `auto_slope=true`; `num_weights=1` if `key_ver<=4004` else `2` |
    | `t` | 3 (consumed/ignored) | `auto_slope=true`; `num_weights=0` |
    | `d` | 1 (consumed/ignored) | `auto_slope=true`; `num_weights` stays default `1` |
    | anything else | — | hard parse failure (`ufbxi_fail("Unknown slope mode")`) |
    Then, `num_weights` times, one weight-mode char is read (ufbx.c:15482-15511):
    | weight_mode | extra doubles | effect |
    |---|---|---|
    | `n` | 0 | leave weights at default 0.333333 |
    | `a` | 2 | explicit `weight_right`, `next_weight_left` |
    | `l` | 1 | explicit `next_weight_left` only |
    | `r` | 1 | explicit `weight_right` only |
    | `c` | 0 | leave weights at default (comment: unknown meaning, assumed automatic) |
    | anything else | — | hard parse failure |
- **Take object name encoding**: ASCII `"Type::Name"`; binary `"Name\x00\x01Type"` — note the
  binary form has name FIRST, type SECOND (opposite of ASCII), per `ufbxi_split_type_and_name`
  (ufbx.c:12271-12305, `???` comment at 12282 acknowledging this asymmetry is unexplained/observed
  behavior, not derived from spec).
- **Root pseudo-id literal strings** (ufbx.c:15873): ASCII `"Model::Scene"`; binary
  `"Scene\x00\x01Model"` (length 12, pushed via `ufbxi_push_string_imp` with explicit length 12
  covering the embedded NUL).
- **`Take`'s `"C"` field** uses format code `"C"` (interned/cached string) for the take name, but
  `ufbxi_read_take_object`'s target uses format code `"c"` (lowercase) for the `Type::Name` pair —
  distinct interning behavior for these two conceptually similar fields (15672 vs 15705).
- **Extrapolation `Type` codes** (ufbx.c:14237-14244): `'A'`→REPEAT_RELATIVE, `'C'`→CONSTANT,
  `'K'`→SLOPE, `'M'`→MIRROR, `'R'`→REPEAT. `Repetition` int gives repeat count; negative clamped to
  `-1` (infinite).
- **Legacy prop table format codes** (`node_fmt` in `ufbxi_legacy_prop`, interpreted by
  `ufbxi_read_legacy_prop`, ufbx.c:15986-16050): `L`=one int64 value at position 0 (also fills
  `value_real` as a cast, zeroes vec slots 1-3, empty str/blob); `R`=one real at the given index
  (0-3) — if index 0, also resets `value_int`/vec slots/str/blob and sets exactly one
  `VALUE_REAL`/`VEC2`/`VEC3`/`VEC4` flag bit based on final `value_ix`; `S`=string (+ also fetches
  the raw blob view of the same node value); `_`=skip a format-string position without consuming a
  value slot (used e.g. for `FilmWidth`/`FilmHeight` sharing a 2-real `CameraAperture` node but each
  wanting only one component — see `"_R"`/`"R_"` in `ufbxi_legacy_camera_props`, ufbx.c:15965/15967).
- **Legacy mesh normal per-vertex vs per-index disambiguation** (ufbx.c:16232-16234): per-vertex
  wins if `num_normals==num_vertices` AND (`num_normals!=num_indices` OR `version==5000`); this
  means version 5000 files are hard-coded to prefer per-vertex interpretation even in the
  (presumably rare/never-actually-ambiguous) case where vertex count happens to equal index count.
- **Material assignment codes**: `MaterialAssignation` `"C"` value is either the interned literal
  `ByPolygon` or `AllSame` (ufbx.c:16271/16273).
- **FBXHeaderVersion / TCDefinition / KTime unit gate**: see Format details KTime bullet above;
  literal sentinel `TCDefinition == 127` selects the old (v7) KTime unit even at version≥8000
  (ufbx.c:12021-12029) — out of this subsystem's version range but shares the same field.

## Quirks & edge cases

- **Heterogeneous key stream reinterpreted as double**: the entire `Key` array — which in the
  original binary encoding mixed 64-bit int (time), f64/f32 (value/slope/weight), and single-byte
  chars (mode codes) — is parsed generically as an array of `'d'` (double) and then chars are
  recovered via a value-range check (`ufbxi_double_to_char`, only `[0,127]` valid). This is fragile
  by construction but appears to be the only way ufbx's generic array-of-doubles decoder can be
  reused for this heterogeneous FBX 6.x binary structure; porting to Swift must replicate the exact
  per-key layout table above rather than trying to find a cleaner schema, because the underlying
  format genuinely has these ad-hoc per-`KeyVer`/slope-mode branches.
- **Slope modes `p`, `q`, `t`, `d` are explicitly marked TODO/unsolved** in the source (15434-15477):
  ufbx doesn't claim to know their exact semantics, only that certain byte-counts have been
  empirically observed not to crash, and falls back to automatic-tangent interpolation
  (`auto_slope=true`) discarding the extra data outright. A faithful port should copy this same
  "consume N doubles, ignore them, use auto tangent" behavior rather than trying to interpret the
  discarded values, since ufbx itself doesn't interpret them.
- **`KeyVer`-dependent weight-count for slope mode `s`/`b`** (15417-15423): comment admits this
  "looks very suspicious" — empirically, `KeyVer=4002` and `4004` are followed by an `'n'` weight
  byte then next key, but `4003` has no weight byte at all directly followed by the next key. Ufbx
  hard-codes `num_weights=0` only for `key_ver==4003`.
- **Auto-slope for the very first key is forced to 0** (15542-15544) rather than calling the solver
  (which would need a "previous" key that doesn't exist) — a boundary-condition special case.
  Similarly there's no explicit handling shown for the *last* key's right-tangent when
  `next_time<=key.time` other than the general "next_time>key.time" zero-fallback at 15566-15573 —
  this covers the natural case where there's no next key by virtue of `next_time`/`next_value`
  simply retaining the previous iteration's data unmodified when `i+1>=num_keys` (the values are
  simply stale/equal to the current key's own values in that scenario since they're never updated
  after the last real prefetch) — but since `right.dx` will end up computed from
  `next_time - key.time` and if `next_time` happens to equal `key.time` from staleness, that's
  caught by the `else` branch zeroing it. Port must replicate: **don't prefetch a nonexistent next
  key** and rely on time-equality (not an explicit "is last key" flag) to zero the right tangent.
- **Linear mode always overwrites tangent even after cubic-branch computed one** (15547-15555): this
  only matters for the *following* key's left tangent (`next_slope_left`), since a key literally
  marked `'L'` never enters the `'U'` branch itself — but this recompute is what makes a
  cubic-then-linear or linear-then-cubic transition produce a consistent secant-based left tangent
  for whichever key follows a linear one.
- **`ByPolygon`/`AllSame` material index `0` sentinel optimization** (16281-16289): when all faces
  share material index `0` (the common/default single-material case), ufbx avoids allocating a
  `num_faces`-sized array at all and instead points `face_material.data` at the shared
  `ufbxi_sentinel_index_zero` constant — same trick used for normals via
  `ufbxi_sentinel_index_consecutive`. Any Swift port that walks these arrays must NOT assume
  `data` is a normally-owned/mutable buffer; these sentinels are shared singletons (out-of-range
  detail, defined elsewhere in ufbx.c, but directly relevant to interpreting legacy mesh output).
- **Non-negated last polygon index auto-fix** (16218-16223): if the last vertex index of the whole
  index buffer isn't bitwise-negated (violates FBX's "last index of each face is `~real_index`"
  convention), ufbx repairs it in place rather than failing outright, UNLESS `opts.strict` is set,
  in which case it's a hard error. This is an exporter-tolerance workaround worth replicating.
- **Post-7000 files can still contain a `Take` block** (15709-15723): these are read only for their
  `LocalTime`/`ReferenceTime` as a *fallback* time range on an already-existing (name-matched)
  `ufbx_anim_stack` — no new stack/layer/curves are created. If `stack->props.props.count` is
  already nonzero (i.e. the real `AnimationStack`'s own props already carried a time range), the
  Take's fallback values are NOT applied (guarded at 15715). Silent no-op if no matching stack name
  is found in `anim_stack_map` at all (this can legitimately happen and is not an error).
  **Dependency**: this ties into the animation-stack-building subsystem (elsewhere in ufbx.c) which
  populates `uc->anim_stack_map` — a Swift port needs that map available/populated before processing
  Takes in the ≥7000 case, or must otherwise defer this reconciliation to a post-pass.
  Order of operations note: in `ufbxi_read_root`, `ufbxi_read_takes` runs strictly AFTER `Objects`
  and `Connections` are fully read (15895-15913), i.e. after all real anim stacks already exist and
  are registered in the map for exactly this reason.
- **Implicit unnamed animation layer/stack for bare `Model.Channel` (no enclosing `Take` at all)**
  (16406-16418, 16464-16482): only created lazily on first sighting, named `"(internal)"`, and its
  fbx_id is allocated (`ufbxi_push_synthetic_id`) *before* any other stack so as to deliberately NOT
  be "the first" animation stack (comment 16412) — implying downstream code somewhere treats "first
  stack encountered" specially (e.g. as a default-selected stack for evaluation) and ufbx wants to
  avoid this synthetic housekeeping stack winning that slot. **Port implication**: the Swift port's
  default-stack-selection logic (wherever it lives) must apply the same "first REAL stack, not
  first stack by allocation order" rule, or reproduce it by simply allocating this implicit stack's
  ID after everything else / marking it as ineligible for default selection.
  Also: `ufbxi_synthetic_id_from_string` interns based on the **string pointer**, not by value/hash
  content directly for "fast" pointers (12250-12258: pointers below `UFBXI_MAXIMUM_FAST_POINTER_ID`
  are used as-is as the ID; only larger/out-of-range pointers fall back to a hashmap
  `ptr_id → synthetic id`). Any Swift port must instead use its own interned-string identity (e.g.
  a dictionary keyed by the string pool's canonical String instance, or a small integer id assigned
  at intern time) — the raw-pointer-as-ID trick doesn't translate to Swift/ARC directly.
- **Unconditional/possibly-unused node↔attribute connection** (`ufbxi_read_legacy_model`,
  16371-16372): a connection from a freshly allocated `attrib_info.fbx_id` to the node is made
  BEFORE it's known whether an attribute will actually be created for that id — deliberately
  tolerated as harmless per the inline comment, because dangling/unused connections are presumably
  filtered later by the generic connection-resolution pass (out of range). A literal port should
  either replicate this exact "reserve id, connect, maybe-populate" pattern or restructure to only
  connect once an attribute exists — the latter is cleaner in Swift and should be safe as long as
  the generic connection resolver doesn't rely on connection *count* elsewhere.
- **`"Settings"` string-compared by `strcmp` instead of interned-pointer identity**
  (`ufbxi_read_legacy_root`, 16455) — a slight inconsistency in the codebase suggesting this
  ultra-legacy toplevel name wasn't added to the standard interned-name table; irrelevant for a
  Swift port using ordinary `String` equality throughout, but worth noting there's no other
  significance to it.
- **`ufbxi_read_legacy_settings` merge is prepend-then-sort** (15794-15813): new props are memcpy'd
  BEFORE existing props in the temporary buffer, then the whole array is sorted and deduplicated —
  meaning if a duplicate prop name exists in both the new legacy set and prior `GlobalSettings`
  props, `ufbxi_deduplicate_properties`'s tie-breaking behavior (which one wins, first or last in
  sorted-then-deduped order) governs precedence; the exact rule lives in that function's
  implementation elsewhere in the file and should be checked by whichever subsystem note covers it.
- **Legacy `LimbNode` (bone) props are only read from a nested `Properties` child**, not scanned
  directly on the object node like the other three legacy prop tables (16161-16164) — if no
  `Properties` child exists, `num_props` stays `0` silently (not an error).
- **`ufbxi_read_legacy_mesh` calls `ufbxi_patch_mesh_reals` twice** — once immediately after
  creating the (still-empty) mesh element (16185) and again at the very end after all vertex/
  material/skin data is attached (16328). This double-call pattern (also seen generically in
  `ufbxi_finalize_mesh`, 16762) suggests the "patch" step is meant to be idempotent/safe to call at
  multiple points as fields get filled in; a Swift port can likely fold this into a single
  finalization step run once after full construction instead of mid-way, but should verify
  `ufbxi_patch_mesh_reals`'s definition (outside this range) doesn't have order-dependent side
  effects before doing so.

## Port guidance

- **Faithfully port, byte-for-byte logic**: the entire `ufbxi_read_take_anim_channel` decode table
  (slope modes, weight modes, `KeyVer` gating, auto-tangent solver flags) — this is exactly the kind
  of undocumented reverse-engineered exporter quirk-table this project cannot re-derive from a spec.
  Suggested Swift shape: an enum `LegacyKeySlopeMode: Character { case s, b, a, p, q, t, d }` (or
  simply switch on raw `Character`) driving a small struct-returning parse function that yields
  `(auto: Bool, explicitSlopeRight: Float?, explicitNextSlopeLeft: Float?, numWeights: Int)`, then a
  second small parser for weight-mode chars. Keep `ufbxi_solve_auto_tangent` (and the CLAMP/
  CLAMP_PROGRESSIVE/TIME_INDEPENDENT flag semantics) as a shared free function usable by both this
  legacy path and the (separate subsystem's) modern per-key auto-tangent code at ufbx.c:14257+ —
  check with whichever subsystem owns lines ~14090-14310 to avoid duplicating this solver in Swift.
- **Replace with Swift idioms**: the raw-pointer-based `ufbxi_synthetic_id_from_string`/
  `ufbxi_push_synthetic_id` scheme should become a proper Swift identity mechanism — e.g. give every
  DOM node / interned string a stable `ObjectIdentifier`-backed or explicitly-assigned integer ID at
  parse time, and use a `[String: ID]` or `[ObjectIdentifier: ID]` dictionary instead of pointer
  arithmetic. The double-cast heterogeneous key array parsing, however, should NOT be redesigned —
  keep it as a raw `[Double]` cursor exactly mirroring the C, since the underlying wire format truly
  is this shape (a Swift `enum` "cleanup" of the key stream risks subtly breaking the exact byte
  alignment the per-mode tables depend on).
- **Skip per scope**: `.obj`/`.mtl` and everything after line 16767 is explicitly out of scope
  (confirmed boundary — line 16767 is the `// -- .obj file` section header). Within this range,
  `ufbxi_finalize_mesh` (16691-16765), `ufbxi_open_file` (16654-16669), and the relative-filename
  resolution helpers (16487-16650) are generic scene/IO finalization, NOT legacy-specific; they
  belong conceptually to the mesh-construction and file-IO subsystems respectively. Per the stated
  v1 scope (custom allocators/IO abstraction OUT, Swift uses Data/URL), the `ufbxi_open_file`/
  relative-path-resolution logic can likely be skipped or radically simplified to `URL`-relative
  resolution in Swift rather than ported line-by-line — flag this for whoever owns file-IO/loading
  in the Swift port to decide.
- **Legacy object graph (`ufbxi_read_legacy_*`)**: port faithfully as a parallel/alternate code path
  gated on FBX version — a `LegacyDocumentReader` (or similar) that produces the exact same
  intermediate node/element/connection graph the modern ≥7000 path produces, so that ALL downstream
  scene-assembly logic (transform chain resolution, layer-element assembly, skin/deformer wiring,
  material prop resolution) can be fully shared and version-agnostic after this stage. This mirrors
  ufbx's own architecture (`ufbxi_read_legacy_model` funnels into the same `ufbx_node`/
  `ufbx_element` machinery as the modern reader) and should be preserved in Swift, likely via the
  same "synthetic element + connection" primitives (would need to be shared with whichever
  subsystem owns `ufbxi_push_element`/`ufbxi_connect_oo`/`ufbxi_connect_op`, ufbx.c:12352-12441ish).
- **Cross-subsystem dependencies**:
  - DEPENDS ON: the tokenizer/DOM node reader (`ufbxi_node`, `ufbxi_find_child`/`ufbxi_find_array`/
    `ufbxi_get_val1` etc.) and the generic connection graph (`ufbxi_connect_oo`/`_op`,
    `ufbxi_insert_fbx_attr`/`ufbxi_find_fbx_id`) — both presumably owned by earlier subsystem
    chunks (document/DOM parsing).
  - FEEDS: the animation-evaluation subsystem (curves/keyframes/values built here are consumed by
    `ufbx_evaluate_curve` and friends, likely documented in whichever chunk covers evaluation) and
    the scene-assembly/transform-chain subsystem (legacy `ufbx_node`/mesh/material/skin elements
    built here get finalized by the same generic per-type "finalize" passes as modern elements,
    e.g. `ufbxi_finalize_mesh` at the tail of this very range, and whatever finalizes
    `ufbx_anim_stack`/`ufbx_anim_layer`/props elsewhere).
  - The `>=7000`-Take-as-time-range-fallback behavior (15709-15723) explicitly DEPENDS ON the
    animation-stack subsystem's `anim_stack_map` being populated first — sequencing constraint to
    honor in the Swift port's pipeline (Takes fallback merge must run after AnimationStack objects
    are constructed, or be redesigned as an explicit post-pass keyed by stack name).

## Warnings / unresolved items
- Slope modes `p`, `q`, `t`, `d` are unsolved even in upstream ufbx (explicit TODOs); this note
  documents the byte-consumption behavior precisely but the *semantic* meaning of the discarded
  values (e.g. whether `t` mode's 3 doubles are actually TCB tension/continuity/bias) is unknown to
  ufbx itself — do not invent an interpretation when porting; replicate "consume and use auto-slope".
- `ufbxi_patch_mesh_reals`, `ufbxi_process_indices`, `ufbxi_read_vertex_element`,
  `ufbxi_read_truncated_array`, `ufbxi_read_synthetic_blend_shapes`, `ufbxi_sort_properties`,
  `ufbxi_deduplicate_properties`, `ufbxi_read_transform_matrix`, and the sentinel index arrays
  (`ufbxi_sentinel_index_zero`/`_consecutive`) are called from this range but defined elsewhere in
  ufbx.c outside the assigned span — flagged here for whichever subsystem note owns them; their
  exact semantics were only inferred from call-site usage, not read at their definitions.
