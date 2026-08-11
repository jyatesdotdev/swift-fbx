# Public data model, part 2 (ufbx.h lines 3200-6073)

## Purpose
This span covers the back half of ufbx's public API surface: the remaining scene-graph element
types (collections, constraints, audio, poses), the `ufbx_scene` container itself and its
metadata/settings structs, the entire options taxonomy (`ufbx_load_opts`, `ufbx_evaluate_opts`,
`ufbx_anim_opts`, `ufbx_bake_opts`, tessellation/subdivision/geometry-cache opts), the error and
warning taxonomy, the animation evaluation API (curve/value/prop/transform/blend-weight/whole-scene
evaluation, baking), and the "inline API" — cheap accessor helpers (`ufbx_get_vertex_*`,
`ufbx_as_*` downcasts, panic-based `ufbx_catch_*` variants). It is the layer a Swift port's public
`SwiftFBX` module surface should be modeled after: load entry points, options, errors, and the
evaluation/query functions users call after `ufbx_load_*` returns a scene.

## Key data structures

### Remaining element types (all follow the `union { ufbx_element element; struct {...}; }` pattern
described in part 1 — `name`, `props`, `element_id`, `typed_id` common header)
- **`ufbx_anim_curve`** (h:3213): one FBX animation curve — `keyframes` list, `pre_/post_extrapolation`,
  `min_value/max_value`, `min_time/max_time` (cached bounds, used to decide extrapolation vs.
  interpolation in evaluation).
- **`ufbx_display_layer`** (h:3241): named grouping of nodes for hide/freeze in DCC UIs; `nodes`,
  `visible`, `frozen`, `ui_color`. Passthrough data only.
- **`ufbx_selection_set`** / **`ufbx_selection_node`** (h:3260/3273): named selection sets;
  a selection node targets a `ufbx_node` and/or `ufbx_mesh` and carries `vertices`/`edges`/`faces`
  index lists (guaranteed valid per `index_error_handling`). Passthrough.
- **`ufbx_character`** (h:3296): empty marker element (character rig grouping) — no fields beyond
  the common header; only exists to be linked to as a constraint target/effector container.
- **`ufbx_constraint`** (h:3354): unified representation of AIM/PARENT/POSITION/ROTATION/SCALE/
  SINGLE_CHAIN_IK constraints. Fields: `type`/`type_name`, `node` (constrained node), `targets`
  (weighted `ufbx_constraint_target` list — target node + relative weight + offset transform),
  `weight`, `active`, per-axis `constrain_translation/rotation/scale[3]` bools, `transform_offset`.
  AIM-specific: `aim_vector`, `aim_up_type` (`ufbx_constraint_aim_up_type`: SCENE/TO_NODE/ALIGN_NODE/
  VECTOR/NONE), `aim_up_node`, `aim_up_vector`. IK-specific: `ik_effector`, `ik_end_node`,
  `ik_pole_vector` (`targets` doubles as pole vectors for IK). ufbx does **not** solve constraints —
  data passthrough only (matches port scope: "character/constraint solving: data passthrough only").
- **`ufbx_audio_layer`** / **`ufbx_audio_clip`** (h:3398/3410): audio track metadata; clip carries
  `filename`/`absolute_filename`/`relative_filename` (+ raw non-UTF8 blob variants) and optional
  embedded `content` blob. Out of v1 scope (no audio playback) but trivial to model as passthrough
  structs if desired.
- **`ufbx_bone_pose`** (h:3444) / **`ufbx_pose`** (h:3461): a `ufbx_pose` is a named list of
  `ufbx_bone_pose` (bone_node + `bone_to_world` matrix + **approximated** `bone_to_parent`, since FBX
  only stores world-space bind pose matrices — ufbx derives parent-space by using the parent's
  *current* world transform, which can be wrong if parent is animated independently of the pose).
  `is_bind_pose` flags bind poses specifically.
- **`ufbx_metadata_object`** (h:3477): catch-all element for unrecognized/unmodeled FBX object types
  that still need identity in the connection graph — empty struct beyond the common header.
- **`ufbx_name_element`** (h:3488): entry in the scene's by-name index — `name`, `type`, internal
  hash key, and `element` pointer. Backs `ufbx_find_element`.

### DOM types (retained document tree, opt-in via `ufbx_load_opts.retain_dom`)
Defined earlier in the header (h:400-439, technically part-1 territory but documented here since
this span owns the evaluation/query API for it) — `ufbx_dom_node` is a generic tree mirroring the
raw FBX property-list nodes: `name`, `children` (`ufbx_dom_node*` list), `values`
(`ufbx_dom_value` list). Each `ufbx_dom_value` has a `type` (`ufbx_dom_value_type`: NUMBER, STRING,
BLOB, ARRAY_I32/I64/F32/F64/BLOB, ARRAY_IGNORED) plus `value_str`/`value_blob`/`value_int`/
`value_float` (all populated regardless of type, similar to `ufbx_prop`). Query helpers:
`ufbx_dom_find(_len)` (name lookup among children), `ufbx_dom_is_array`, `ufbx_dom_array_size`,
`ufbx_dom_as_{int32,int64,float,double,real,blob}_list` (h:5817-5824). Out of v1 scope per the
port brief ("DOM retention option" listed OUT) — skip entirely unless later requested.

### `ufbx_scene` (h:3935) — the root object
- `metadata: ufbx_metadata`, `settings: ufbx_scene_settings`, `root_node`, `anim` (default
  `ufbx_anim*` built implicitly from all layers — used when callers don't build a custom one via
  `ufbx_create_anim`).
- A big union: either accessed as named typed lists (`nodes`, `meshes`, `lights`, ... `poses`,
  `metadata_objects` — ~35 lists covering every element type) **or** as
  `elements_by_type[UFBX_ELEMENT_TYPE_COUNT]` (untyped `ufbx_element_list` per type index). This
  union trick lets ufbx iterate generically over all elements of a type without a switch. In Swift,
  model as a dictionary/array keyed by an `ElementType` enum plus typed convenience accessors —
  don't try to replicate the C union; a computed property per type backed by a single `[ElementType:
  [Element]]` store is more idiomatic and equally cheap.
- `texture_files`: deduplicated list of unique texture file references in the scene (distinct from
  `ufbx_texture` — multiple textures can share one file).
- `elements` (all elements sorted by `id`), `connections_src`/`connections_dst` (the raw FBX
  object-property connection graph, sorted for binary search — `src,src_prop` / `dst,dst_prop`),
  `elements_by_name` (sorted by name+type, backs `ufbx_find_element`).
- `dom_root`: non-null only if `retain_dom` was requested.

### `ufbx_scene_settings` (h:3901) — global scene settings/units/time
- `axes: ufbx_coordinate_axes` — **original** file axes (even if `target_axes` was requested at
  load time — the conversion is applied to the geometry/transforms, not reported back here as
  identity).
- `unit_meters`: world-unit-to-meters scale (FBX default is centimeters → `0.01`).
- `frames_per_second`: the single source of truth for animation timing — prefer this over
  `time_mode`/`time_protocol`/`snap_mode` which are just the raw FBX UI enum values (`ufbx_time_mode`
  has ~18 variants: 120/100/60/50/48/30/30_DROP/NTSC_DROP/NTSC_FULL/PAL/24/1000/FILM_FULL/CUSTOM/
  96/72/59.94 FPS — h:3854-3877). `original_axis_up`/`original_unit_meters` preserve pre-conversion
  values distinctly from `axes`/`unit_meters` semantics — check ufbx.c for exactly which field wins
  when both original and post-conversion are needed; for the Swift port, expose both a `rawAxes`/
  `rawUnitMeters` (pre-conversion) and the effective converted ones if `target_axes`/
  `target_unit_meters` were requested.
- `ambient_color`, `default_camera` (name string), `props` (raw scene-level property sheet).

### `ufbx_metadata` (h:3754) — file-load diagnostics/provenance, huge grab-bag struct
- `warnings: ufbx_warning_list` + `has_warning[UFBX_WARNING_TYPE_COUNT]` bool flag array for O(1)
  "did warning X occur" checks without scanning the list.
- `ascii`, `version` (e.g. 7400 = FBX 7.4), `file_format` (FBX/OBJ/MTL), `big_endian`.
- Safety/coverage flags: `may_contain_no_index`, `may_contain_missing_vertex_position`,
  `may_contain_broken_elements`, `is_unsafe` (set when unsafe load options were used — API index/
  bounds guarantees may not hold).
- `creator`, `filename`/`relative_root` (+ raw non-UTF8 blob twins), `exporter` (`ufbx_exporter`
  enum: UNKNOWN/FBX_SDK/BLENDER_BINARY/BLENDER_ASCII/MOTION_BUILDER/UFBX_WRITE) + `exporter_version`
  (packed via `ufbx_pack_version`, see Format details).
- `scene_props` (top-level FBX document properties), `original_application`/`latest_application`
  (`ufbx_application`: vendor/name/version strings — tracks which DCC tool(s) touched the file).
- `thumbnail: ufbx_thumbnail` (width/height/format RGB_24|RGBA_32/data blob, rows bottom-to-top).
- `geometry_ignored`/`animation_ignored`/`embedded_ignored` mirror the corresponding
  `ufbx_load_opts.ignore_*` flags for introspection.
- `max_face_triangles`: largest per-face triangle fan size across all meshes — sizing hint for
  `ufbx_triangulate_face` scratch buffers.
- Memory/alloc stats (`result_memory_used`, `temp_memory_used`, `result_allocs`, `temp_allocs`,
  `element_buffer_size`, `num_shader_textures`) — diagnostics only, skip in Swift (ARC handles this).
- `bone_prop_size_unit`/`bone_prop_limb_length_relative`, `ortho_size_unit`: unit-normalization
  factors for bone display size and camera ortho size properties (exporter-dependent semantics).
- `ktime_second`: **the** internal FBX tick resolution (1 second in KTime units) — needed for
  frame-accurate curve extrapolation math (see Control flow section).
- `original_file_path`/`raw_original_file_path`.
- Conversion bookkeeping: `space_conversion`, `geometry_transform_handling`,
  `inherit_mode_handling`, `pivot_handling`, `handedness_conversion_axis` (mirrors the load-opts
  choices actually applied), `root_rotation`/`root_scale` (the transform baked into the root node
  for axis/unit conversion, if `UFBX_SPACE_CONVERSION_TRANSFORM_ROOT` was used), `mirror_axis`
  (which axis geometry was mirrored on for handedness conversion), `geometry_scale` (amount geometry
  was scaled under `UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY`).

### Warnings — `ufbx_warning_type` (h:3533) / `ufbx_warning` (h:3597)
15 warning kinds (`MISSING_EXTERNAL_FILE`, `IMPLICIT_MTL`, `TRUNCATED_ARRAY`,
`MISSING_GEOMETRY_DATA`, `DUPLICATE_CONNECTION`, `BAD_VERTEX_W_ATTRIBUTE`,
`MISSING_POLYGON_MAPPING`, `UNSUPPORTED_VERSION`, `INDEX_CLAMPED`, `BAD_UNICODE`,
`BAD_BASE64_CONTENT`, `BAD_ELEMENT_CONNECTED_TO_ROOT`, `DUPLICATE_OBJECT_ID`,
`EMPTY_FACE_REMOVED`, `UNKNOWN_OBJ_DIRECTIVE`). `UFBX_WARNING_TYPE_FIRST_DEDUPLICATED` marks
`INDEX_CLAMPED` as the boundary: warnings before it (i.e. only the first 9 listed, index 0-8) are
recorded individually per occurrence; warnings at/after that ordinal are **deduplicated** and
`ufbx_warning.count` tallies repeat occurrences instead of pushing duplicate list entries. Each
warning carries `element_id` (or `UFBX_NO_INDEX`) linking it back to the offending element.

### Errors — `ufbx_error_type` (h:4257) / `ufbx_error` (h:4350) / `ufbx_error_frame` (h:4250)
22 error codes total: `NONE`, `UNKNOWN`, `FILE_NOT_FOUND`, `EMPTY_FILE`,
`EXTERNAL_FILE_NOT_FOUND`, `OUT_OF_MEMORY`, `MEMORY_LIMIT`, `ALLOCATION_LIMIT`, `TRUNCATED_FILE`,
`IO`, `CANCELLED`, `UNRECOGNIZED_FILE_FORMAT`, `UNINITIALIZED_OPTIONS`, `ZERO_VERTEX_SIZE`,
`TRUNCATED_VERTEX_STREAM`, `INVALID_UTF8`, `FEATURE_DISABLED`, `BAD_NURBS`, `BAD_INDEX`,
`NODE_DEPTH_LIMIT`, `THREADED_ASCII_PARSE`, `UNSAFE_OPTIONS`, `DUPLICATE_OVERRIDE`,
`UNSUPPORTED_VERSION`. `ufbx_error` bundles: `type`, human `description`, an optional stack trace
(`stack[UFBX_ERROR_STACK_MAX_DEPTH]` of `{source_line, function, description}`, only populated if
compiled with `UFBX_ENABLE_ERROR_STACK` — a debug/diagnostic feature, likely skip for Swift and
instead always capture a Swift-native stack via `Error` + one descriptive string), and `info`/
`info_length` — a short NUL-terminated extra-context string (e.g. missing filename) baked directly
into the error, formatted via `%s` with description in `ufbx_format_error` (ufbx.c:30598-30633).
This maps cleanly onto a Swift `enum FBXError: Error` with associated values per case (e.g.
`.fileNotFound(path: String)`, `.unsupportedVersion(UInt32)`, `.badIndex(context: String)`) — the
`info` string becomes the associated payload rather than a separate untyped string field.

### Progress / cancellation
`ufbx_progress` (bytes_read/bytes_total), `ufbx_progress_result` (`CONTINUE=0x100`/`CANCEL=0x200`
— note the values are chosen to not collide with 0/1/false so callback bugs are more visible),
`ufbx_progress_fn`/`ufbx_progress_cb`. Explicitly OUT of v1 scope (progress callbacks) — a Swift
port would use async/await or simply not report progress; the sentinel-value choice (0x100/0x200
rather than 0/1) is worth noting only if ever bridging to C callbacks directly.

### Inflate (DEFLATE) types — `ufbx_inflate_input` (h:4410), `ufbx_inflate_retain` (h:4446)
`ufbx_inflate_input`: `total_size`, optional initial `data`/`data_size` chunk, optional scratch
`buffer`/`buffer_size` (defaults to a 256-byte stack buffer if unset), optional streaming
`read_fn`/`read_user` (concatenated after the initial `data` chunk — i.e. mixed buffered+streaming
input), optional `progress_cb` + `progress_interval_hint` + `progress_size_before/after` (rescale
progress reporting into a sub-range of a larger operation), `no_header` (skip 2-byte zlib header),
`no_checksum` (skip trailing Adler32), `internal_fast_bits` (force a specific Huffman fast-lookup
table width — a performance tuning knob, irrelevant to a from-scratch Swift port; use whatever
lookup width fits Swift idioms). `ufbx_inflate_retain`: opaque persistent state
(`bool initialized` + `uint64_t data[1024]` = 8KB scratch) reused across incremental `ufbx_inflate()`
calls — a Swift port should NOT try to preserve this ABI; just keep a Swift struct/class holding
whatever Huffman-table/window state its own inflate implementation needs, `initialized` becomes
implicit via optional/lazy-init. The actual bit-level DEFLATE algorithm lives in ufbx.c, NOT in this
header span — port from ufbx.c's `ufbxi_inflate`/Huffman routines when implementing it (out of this
subsystem's citation scope; another subsystem doc should cover it, but note the entry point
signature here: `ufbx_inflate(dst, dst_size, const ufbx_inflate_input*, ufbx_inflate_retain*) ->
ptrdiff_t` returning decompressed byte count or negative error code, h:5409).

### Index/Unicode error-handling policies
- `ufbx_index_error_handling` (h:4451): `CLAMP` (default — clamp OOB index into valid range),
  `NO_INDEX` (recommended for tolerant loading — replace with `UFBX_NO_INDEX` sentinel, then
  `ufbx_get_vertex_TYPE()` returns zero for those), `ABORT_LOADING` (fail with `UFBX_ERROR_BAD_INDEX`),
  `UNSAFE_IGNORE` (pass through unchecked — requires `allow_unsafe`, breaks memory safety
  guarantees; **do not port this mode** — Swift arrays are always bounds-checked so "unsafe passthrough"
  has no equivalent/benefit; just always validate.).
- `ufbx_unicode_error_handling` (h:4472): `REPLACEMENT_CHARACTER` (U+FFFD, default), `UNDERSCORE`
  ('_'), `QUESTION_MARK` ('?'), `REMOVE` (drop the bad bytes), `ABORT_LOADING` (fail with
  `UFBX_ERROR_INVALID_UTF8`), `UNSAFE_IGNORE` (pass through non-UTF8 bytes — requires `allow_unsafe`;
  again skip for Swift, since `String` requires valid Unicode — map this mode to `.abortLoading`
  behavior or simply unsupported).

### Baked animation types (`ufbx_bake_anim` output — linearized keyframes for runtime playback)
- `ufbx_baked_key_flags` (h:4493): bitflags per baked keyframe — `STEP_LEFT`/`STEP_RIGHT` (this key
  represents the flat part of a step discontinuity approaching from that side), `STEP_KEY` (the
  "real" value key bordering a step), `KEYFRAME` (corresponds to an actual source keyframe, not an
  inserted resample point), `REDUCED` (kept after `maximum_sample_rate` reduction removed others).
- `ufbx_baked_vec3`/`ufbx_baked_quat` (h:4510/4518): `{time, value, flags}` — meant to be linearly
  (vec3) or spherically-linearly (quat) interpolated between adjacent samples at runtime; see
  `ufbx_evaluate_baked_vec3`/`_quat` (h:5528/5533) which do exactly that, handling the step-flag
  cases so stepped tangents don't get incorrectly slerped/lerped across the discontinuity.
- `ufbx_baked_node` (h:4527): per-node baked TRS — `typed_id`/`element_id` (maps back into the
  original `ufbx_scene`), `constant_translation/rotation/scale` (skip generating a full curve if
  static — an optimization flag the Swift port should mirror to avoid wasting memory on static
  channels), `translation_keys`/`rotation_keys`/`scale_keys`.
- `ufbx_baked_prop`/`ufbx_baked_element` (h:4553/4565): same idea for arbitrary animated element
  properties (not just node transforms) — e.g. baked `Visibility`, `DeformPercent`.
- `ufbx_baked_anim` (h:4584): top-level result — `nodes`, `elements`, playback/key time ranges,
  `metadata` (alloc stats only). This is the natural target for exporting to something like a
  runtime skeletal-animation clip format. **Baking itself is explicitly OUT of v1 scope** ("animation
  baking helpers" listed OUT) — model these types only if/when bake support is added later; v1
  should rely on direct `ufbx_evaluate_*`-equivalent evaluation at arbitrary times instead.

### `ufbx_load_opts` (h:4690) — the mega options struct for `ufbx_load_*`
Grouped by theme (all bool unless noted; all default to `false`/zero — options struct MUST be
zero-initialized, enforced via `UFBX_ERROR_UNINITIALIZED_OPTIONS` and sentinel `_begin_zero`/
`_end_zero` uint32 fields that ufbx checks are still zero, catching non-zeroed structs, h:4691/4937):
- **Allocation/threading**: `temp_allocator`, `result_allocator` (`ufbx_allocator_opts` — custom
  alloc/realloc/free + memory/allocation limits + chunking thresholds), `thread_opts`
  (`ufbx_thread_pool` interface + `num_tasks`/`memory_limit` — OUT of v1 scope per brief; Swift will
  just use structured concurrency or run single-threaded).
- **Content selection**: `ignore_geometry`, `ignore_animation`, `ignore_embedded`,
  `ignore_all_content`, `evaluate_skinning`, `evaluate_caches` (caches OUT of scope).
- **External files**: `load_external_files` (opt-in, security-sensitive — arbitrary path traversal
  risk, called out explicitly in the doc comment h:4708), `ignore_missing_external_files`,
  `open_file_cb` (custom IO), `open_main_file_with_default`, `path_separator` (defaults per-OS).
- **Robustness/validation**: `strict` (reject partially-broken files), `disable_quirks` (turn off
  exporter-specific workarounds — useful for testing "what would a naive reader see"),
  `force_single_thread_ascii_parsing` (threaded ASCII parsing is stricter about self-reported array
  sizes; irrelevant once ported to Swift's presumably-single-pass parser, but the underlying
  leniency behavior — tolerating incorrect self-reported ASCII array counts — should be preserved),
  `allow_unsafe` (gate for unsafe index/unicode handling modes), `index_error_handling`,
  `connect_broken_elements` (include otherwise-dangling elements like a `ufbx_skin_cluster` with a
  missing bone reference), `allow_nodes_out_of_root`, `allow_missing_vertex_position`,
  `allow_empty_faces`, `generate_missing_normals`, `node_depth_limit` (0 = unlimited — **the Swift
  port should default this to something finite** to avoid stack-overflow via recursive algorithms on
  malicious/corrupt input, unlike ufbx's C default).
- **IO tuning**: `file_size_estimate`, `read_buffer_size`, `filename`/`raw_filename` (base for
  resolving relative paths when not using `ufbx_load_file`), `progress_cb`/`progress_interval_hint`.
- **Geometry-transform / inherit-mode / pivot / axis handling** — the FBX-scene-graph normalization
  knobs (this is the single most important quirk area for a faithful port; see Quirks section):
  `geometry_transform_handling` (`ufbx_geometry_transform_handling`, h:3651: PRESERVE/HELPER_NODES/
  MODIFY_GEOMETRY/MODIFY_GEOMETRY_NO_FALLBACK), `inherit_mode_handling`
  (`ufbx_inherit_mode_handling`, h:3680: PRESERVE/HELPER_NODES/COMPENSATE/
  COMPENSATE_NO_FALLBACK/IGNORE), `space_conversion` (`ufbx_space_conversion`, h:3623:
  TRANSFORM_ROOT/ADJUST_TRANSFORMS/MODIFY_GEOMETRY), `pivot_handling` (`ufbx_pivot_handling`,
  h:3714: RETAIN/ADJUST_TO_PIVOT/ADJUST_TO_ROTATION_PIVOT), `pivot_handling_retain_empties`,
  `handedness_conversion_axis` (`ufbx_mirror_axis`), `handedness_conversion_retain_winding`,
  `reverse_winding`, `target_axes`/`target_unit_meters` (drive `space_conversion`),
  `target_camera_axes`/`target_light_axes` (FBX cameras point +X, lights point -Y by default — these
  let the loader re-orient them to a target convention, e.g. glTF's -Z camera forward),
  `geometry_transform_helper_name`/`scale_helper_name` (naming for synthesized helper nodes),
  `normalize_normals`/`normalize_tangents`, `use_root_transform`/`root_transform` (override),
  `key_clamp_threshold` (animation keyframe clamping — see Format details), `unicode_error_handling`,
  `retain_vertex_attrib_w`, `retain_dom`.
- **Format detection**: `file_format`, `file_format_lookahead` (default 16kB), `no_format_from_content`,
  `no_format_from_extension`.
- **.obj-specific** (all OUT of v1 scope): `obj_search_mtl_by_filename`, `obj_merge_objects`,
  `obj_merge_groups`, `obj_split_groups`, `obj_mtl_path`, `obj_mtl_data`, `obj_unit_meters`, `obj_axes`.
- **skinning/blend prep**: `skip_skin_vertices`, `skip_mesh_parts`, `clean_skin_weights`
  (removes negative/zero/NaN weights — a numerical-hygiene step worth porting faithfully, since raw
  exporter data can and does contain garbage weights), `use_blender_pbr_material` (Blender exports
  PBR materials as legacy Phong FBX materials in a deterministic pattern; enabling this reads them
  back as `UFBX_SHADER_BLENDER_PHONG` so roughness/metallic textures can be recovered — a
  Blender-specific quirk worth porting given how common Blender-exported FBX is).

### `ufbx_evaluate_opts` (h:4942) — for `ufbx_evaluate_scene`
Much smaller: allocators, `evaluate_skinning`/`evaluate_caches`, `evaluate_flags`
(`ufbx_evaluate_flags`: only `NO_EXTRAPOLATION = 0x1`, h:4678), `load_external_files`/`open_file_cb`
(needed if caches must be re-read during evaluation).

### `ufbx_anim_opts` (h:4985) — for `ufbx_create_anim` (custom animation descriptor)
Lets a caller build a `ufbx_anim*` representing an arbitrary mix of layers/overrides rather than the
scene's default: `layer_ids` (indices into `scene.anim_layers`, i.e. `typed_id`s),
`override_layer_weights` (parallel array to `layer_ids`), `prop_overrides`
(`ufbx_prop_override_desc`: `element_id` + `prop_name` + `value`/`value_str`/`value_int` — lets a
caller force a specific property value at evaluation time regardless of animation, e.g. to preview a
pose), `transform_overrides` (override a whole node's `local_transform` directly),
`ignore_connections` (ignore FBX property-to-property connections during evaluation — connections
otherwise let one property drive another). Field-init note (h:4974-4976): `ufbx_vec4 value` doubles
as scalar storage via `value.x`; `value_int` auto-derives from `value.x` **only if `value_int` is
left zero**, so callers must still zero the whole `value` vec4 even when only setting `value_int`
directly — an ABI quirk with no Swift equivalent (Swift can just use an enum with associated value
per override kind: `.real(Double)`, `.string(String)`, `.int(Int64)`).

### `ufbx_bake_opts` (h:5041) — for `ufbx_bake_anim` (OUT of v1 scope, documented for completeness)
Resample-rate controls (`resample_rate` default 30, `minimum_sample_rate` default 19.5 — avoids
double-resampling exporters that already bake at ≥19.5 fps, `maximum_sample_rate` unlimited by
default), `trim_start_time`, `bake_transform_props`/`skip_node_transforms`, `no_resample_rotation`
(rotation is interpolated in Euler space by FBX, so linear-in-quaternion resampling of already-linear
Euler keys can be subtly wrong — skipping resample avoids compounding error),
`ignore_layer_weight_animation`, `max_keyframe_segments` (default 32 — caps how many linear segments
one non-linear source keyframe can expand into), `step_handling` (`ufbx_bake_step_handling`, h:5012:
DEFAULT [~1ms], CUSTOM_DURATION, IDENTICAL_TIME, ADJACENT_DOUBLE [previous/next representable
`double`, robust to naive lerp without flag-checking, but fragile to any value modification],
IGNORE), `step_custom_duration`/`step_custom_epsilon`, `evaluate_flags`, key-reduction controls
(`key_reduction_enabled`, `key_reduction_rotation`, `key_reduction_threshold` default 1e-6,
`key_reduction_passes` default 4 — each pass can roughly halve key count).

### Tessellation / subdivision / geometry-cache options (all OUT of v1 scope)
`ufbx_tessellate_curve_opts`/`ufbx_tessellate_surface_opts` (span subdivision counts — deliberately
NOT defaulted from `ufbx_nurbs_surface.span_subdivision_u/v` to avoid unbounded blowup from a
malicious/absurd FBX file, h:5142-5145 — a security-relevant clamp worth remembering if NURBS
tessellation is ever added), `ufbx_subdivide_opts` (Catmull-Clark controls, boundary rules, normal
interpolation, source-vertex/skin-weight backmapping — both explicitly flagged O(n²) risk without a
`max_source_vertices`/`max_skin_weights` cap, h:5177/5184), `ufbx_geometry_cache_opts`/
`ufbx_geometry_cache_data_opts` (external .pc2/.mc/.xml cache loading — mirror/scale/weight/additive
blending options).

### Vertex generation & topology utility types
- `ufbx_vertex_stream` (h:4070): `{data, vertex_count, vertex_size}` — input to
  `ufbx_generate_indices()`, which deduplicates a flat (non-indexed) vertex buffer into an indexed
  one via memcmp-based dedup (padding must be zeroed by caller). Useful for the triangulation/NGON
  utility in-scope for v1.
- `ufbx_topo_edge`/`ufbx_topo_flags` (h:4050-4065): half-edge mesh representation from
  `ufbx_compute_topology` — `index`/`next`/`prev`/`twin`/`face`/`edge`, `UFBX_TOPO_NON_MANIFOLD`
  flag for edges with 3+ incident faces. Backs `ufbx_generate_normal_mapping`/`ufbx_compute_normals`
  (smoothing-group-aware normal generation) — in scope for v1 ("smoothing" is listed under meshes).
- `ufbx_curve_point`/`ufbx_surface_point` (h:4035/4041): NURBS evaluation results (position +
  derivative(s), `valid` flag) — OUT of v1 (NURBS tessellation out of scope), but `valid` pattern
  (rather than throwing) is worth noting: ufbx prefers "valid flag on a stack value" over exceptions
  throughout its C API; Swift should translate this to `Optional` or a throwing function depending
  on whether invalidity is exceptional or a normal/expected outcome.

## Control flow / algorithms

### `ufbx_evaluate_curve_flags` (ufbx.c:30832-30914) — the single most load-bearing function to port faithfully
1. `curve == NULL` or `<1` keyframe → `default_value`; exactly 1 keyframe → that keyframe's value
   (no interpolation possible).
2. If `time` outside `[min_time, max_time]` and extrapolation not suppressed by
   `UFBX_EVALUATE_FLAG_NO_EXTRAPOLATION` → delegate to `ufbxi_extrapolate_curve` (below).
3. Binary search (galloping: linear scan once remaining range < 8, else binary halve, ufbx.c:30849-
   30859) to find the first keyframe `next` with `next->time > time`.
4. If `next` is the first keyframe (`begin==0`) → return its value (time is before the first key —
   only reachable here if extrapolation was suppressed).
5. Let `prev = next - 1`. If `prev->time == time` exactly → return `prev->value` (avoids any
   division/interpolation on exact hits).
6. Compute `rcp_delta = 1/(next.time - prev.time)`, `t = (time - prev.time) * rcp_delta` (linear
   parametric position in [0,1)).
7. Switch on `prev->interpolation` (`ufbx_interpolation`, defined in part 1):
   - `CONSTANT_PREV` → `prev->value`.
   - `CONSTANT_NEXT` → `next->value`.
   - `LINEAR` → `prev.value*(1-t) + next.value*t`.
   - `CUBIC` → treat as a cubic Bezier in (time-fraction, value) space with control points derived
     from tangent slopes:
     - `x1 = prev.right.dx * rcp_delta`, `x2 = 1 - next.left.dx * rcp_delta` (the Bezier control
       points' *time* components, normalized into [0,1] parametric space using each side's tangent
       run `dx`).
     - Solve for the Bezier parameter `t` such that the Bezier curve's x-component equals the linear
       `t` computed above, via `ufbxi_find_cubic_bezier_t(x1, x2, t)` (Newton-Raphson, see below) —
       this is because FBX cubic tangents are defined as Bezier control handles in (time, value)
       space, but curves must be evaluated at a *given time*, requiring inverting x(t) first.
     - Then evaluate the cubic Bezier *value* at that solved `t`: standard De Casteljau/Bernstein
       form with `y0=prev.value`, `y3=next.value`, `y1 = y0 + prev.right.dy`, `y2 = y3 - next.left.dy`
       (control-point values derived from tangent rise `dy`), result =
       `u³y0 + 3(u²t·y1 + u·t²·y2) + t³y3` where `u=1-t`.
8. If loop exhausts without finding a `next` (time ≥ last keyframe) → return last keyframe's value.

### `ufbxi_find_cubic_bezier_t` (ufbx.c:25014-25053) — invert Bezier x(t) = x0 via Newton-Raphson
Given Bezier control x-coordinates `p1`,`p2` (with implicit endpoints 0 and 1) and target `x0`,
solves the cubic `a·t³ + b·t² + c·t - x0 = 0` for `t` where `a = 3p1-3p2+1`, `b = 3p2-6p1`,
`c = 3p1` (standard cubic Bezier-in-one-dimension coefficients with endpoints pinned at 0/1).
Unrolls 3 Newton-Raphson iterations manually (using `t=x0` as the initial guess — a good guess since
Bezier x(t)≈t for typical tangent handles), checks convergence against `eps = 8.881784197001252e-16`
(~4 ULP of 1.0), and if not yet converged runs up to 4 more iterations (2 unrolled per loop) before
giving up and returning the best `t` found. **Port this exact iteration count and epsilon** — it's
tuned to match ufbx's (and by extension, matching Autodesk FBX SDK / DCC tools') interpolation
results bit-for-bit in common cases; a generic Newton solver with different tolerances will produce
visually-similar but numerically-divergent curves versus reference FBX importers.

### `ufbxi_extrapolate_curve` (ufbx.c:25977-26041) — extrapolation before/after keyframe range
1. Determine `pre` (time < min_time) vs. post; select the boundary `key` (first or last keyframe)
   and its `ufbx_extrapolation ext` (`pre_extrapolation` or `post_extrapolation`).
2. `ext.mode == CONSTANT` → return the boundary key's value directly (hold last/first value).
3. `ext.mode == SLOPE` → linear extrapolation using the boundary tangent: pick `right` tangent if
   extrapolating backward-from-first-key (uses the tangent pointing *away* from the curve, i.e. the
   one that continues its trend), `left` if extrapolating forward-from-last-key; formula:
   `key.value + tangent.dy * (real_time - key.time) / tangent.dx`.
4. `ext.repeat_count == 0` (and mode isn't CONSTANT/SLOPE) → also just return the boundary value
   (repeat/mirror with zero repeats degenerates to constant).
5. Otherwise (REPEAT / REPEAT_RELATIVE / MIRROR modes), the curve is repeated periodically:
   - All math is done in **KTime ticks**, not seconds, using
     `scale = scene.metadata.ktime_second` (ticks per second) and `ufbx_rint` to round `min_time`/
     `max_time`/`time` to the nearest tick — this guarantees frame-exact repeat behavior rather than
     accumulating floating-point drift across many repeats. **This detail matters**: a naive
     double-precision repeat (`fmod` in seconds) will drift from ufbx's reference output over long
     animations; the Swift port must replicate the "round to integer tick, then divide back to
     seconds" pattern.
   - `delta` = ticks from the curve boundary to `time` (sign/direction depends on pre/post),
     `duration = max_time - min_time` in ticks. If `duration < 1` tick, degenerate → boundary value.
   - `rep = delta/duration`; `rep_n = floor(rep)` (which repeat cycle), `rep_d = delta - rep_n*duration`
     (position within that cycle, in ticks).
   - If `repeat_count > 0` and we've exceeded it, clamp `rep_n` to `repeat_count - 1` and
     `rep_d = duration` (freeze at the last full repeat's end, i.e. behaves like CONSTANT beyond the
     repeat limit).
   - `MIRROR` mode: on odd repeat cycles (`rep_parity = fmod(rep_n/2, 1) <= 0.25` — checks whether
     `rep_n` is even, using a fractional/epsilon-tolerant check rather than integer `% 2` because
     `rep_n` is a `double`), flip `rep_d = duration - rep_d` (play the cycle backward on alternating
     repeats — the "ping-pong" pattern).
   - If `pre`, additionally flip `rep_d = duration - rep_d` again (extrapolating backward runs the
     same logic mirrored).
   - Recurse into `ufbx_evaluate_curve_flags` at the computed in-range `new_time` with
     `UFBX_EVALUATE_FLAG_NO_EXTRAPOLATION` forced on (prevents infinite recursion — the function is
     wrapped in `ufbxi_recursive_function` with a depth guard of 3, ufbx.c:25978, presumably to catch
     runaway recursion bugs defensively, not because legitimate recursion exceeds depth 1).
   - `REPEAT_RELATIVE` additionally adds an accumulated per-repeat delta: `val_delta = last.value -
     first.value` (negated if `pre`), added scaled by `(rep_n + 1)` on top of the recursively
     evaluated in-range value — this makes each successive repeat cycle offset upward/downward by
     the curve's total value delta (e.g. for a monotonically-rising ramp curve, REPEAT_RELATIVE
     produces a sawtooth-then-climbing pattern rather than a flat repeat).

### `ufbx_evaluate_transform_flags` (ufbx.c:31062-31160) — animated local-transform composition
1. No-op guards: no `node` → identity; no `anim` → `node->local_transform` as-is (static); root node
   → its `local_transform` (root has no meaningful TRS decomposition beyond whatever conversion set).
2. Component selection: by default (no `EXPLICIT_INCLUDES`) evaluates translation+rotation+scale;
   flags can restrict to a subset, picking a smaller prop-name list (`ufbxi_transform_props_all`
   vs `_rotation`/`_scale`/`_rotation_scale`, ufbx.c:31030-31060) as an optimization — only touches
   the FBX properties actually needed (avoids evaluating e.g. `ScalingPivot` when caller only wants
   rotation).
3. **Scale-helper compensation** (only relevant when `inherit_mode_handling` produced scale-helper
   nodes, i.e. `UFBX_INHERIT_MODE_HANDLING_HELPER_NODES`/`COMPENSATE` created them for non-uniform
   inheritance): if the parent chain has componentwise-scale-inheriting nodes
   (`parent->inherit_scale_node`) and caller wants scale/translation, walk up
   `p->inherit_scale_node` while `p->scale_helper` exists, multiplying in each scale-helper's
   currently-animated `Lcl Scaling` into `scale_factor` — this reconstructs the "undo inherited
   parent scale" compensation dynamically at eval time rather than baking it once at load. If the
   parent itself has a `scale_helper` (and caller isn't ignoring it), additionally evaluate that
   helper's `Lcl Scaling`, multiply by the accumulated `scale_factor`, and pass the result as
   `translation_scale` into transform composition (affects how pivots/offsets are scaled).
4. Look up `RotationOrder` property (default `XYZ`) via `ufbxi_find_enum`.
5. Evaluate only the selected props (`ufbxi_evaluate_selected_props`) into a small stack buffer
   (max 10 entries — size of `ufbxi_transform_props_all`).
6. If translation included: call `ufbxi_get_transform` (full pivot/offset/pre/post-rotation
   composition — this is the FBX transform chain math, likely detailed in part 1's node/transform
   notes since `ufbx_node.local_transform`/pivots are part-1 structures; **cross-reference**: this
   function is the evaluation-time equivalent of whatever load-time transform-chain composition
   logic populates `ufbx_node.local_transform` — both must implement the identical pivot/offset/
   pre-post-rotation formula for consistency between static and animated transforms). Otherwise
   compose rotation-only (`ufbxi_get_rotation`) and/or scale-only (`ufbxi_get_scale`) as selected,
   defaulting unselected components to identity/zero/one.
7. If a scale-helper compensation was computed (`use_scale_factor`, set only when the *node itself*
   `is_scale_helper`), multiply it into the final `transform.scale` as well.
8. Return the composed `ufbx_transform` (translation/rotation/scale), directly comparable to/
   substitutable for `node->local_transform`.

### `ufbx_evaluate_prop_flags_len` (ufbx.c:30956-30989) — single-property animated lookup
1. Static lookup via `ufbx_find_prop_len` on the element's base props; if not found, synthesize a
   zeroed `ufbx_prop` with `UFBX_PROP_FLAG_NOT_FOUND` set (name/key preserved for identification, but
   `value_str`/`value_blob` point at empty/null so callers can safely read any field).
2. If the `anim` has any `prop_overrides` (from `ufbx_create_anim`/`ufbx_anim_opts`), short-circuit
   entirely: `ufbxi_find_prop_override` and return whatever it finds (overrides win unconditionally,
   bypassing animation curves and connections).
3. If the base prop is neither `ANIMATED` nor `CONNECTED`, return the static value as-is (no
   animation applies — cheap fast path for the overwhelming majority of static properties).
4. If `CONNECTED` and `anim` isn't ignoring connections: `ufbxi_evaluate_connected_prop` resolves a
   value driven by another element's property via an FBX connection (e.g. a texture's UV offset
   driven by another curve-node-like element) — **not detailed further here**; if implementing this
   precisely matters for v1, trace `ufbxi_evaluate_connected_prop` in a transform/connection-focused
   subsystem doc.
5. Finally `ufbxi_evaluate_props` overwrites `result` in-place with the curve-evaluated value if the
   property is `ANIMATED` (looks up the corresponding `ufbx_anim_prop`/`ufbx_anim_value` for this
   element+layer(s) combination and calls into `ufbx_evaluate_curve_flags` per curve/axis, blending
   across layers by weight — the layer-blend algorithm itself lives in `ufbxi_evaluate_props`, worth
   a dedicated look if animation-layer blending semantics need bit-exact porting).

### `ufbx_evaluate_scene` (ufbx.c:31178-31192) — whole-scene evaluation entry point
Thin wrapper: allocates an `ufbxi_eval_context`, delegates to internal `ufbxi_evaluate_scene`
(compiled out entirely if `UFBXI_FEATURE_SCENE_EVALUATION` is disabled, returning
`UFBX_ERROR_FEATURE_DISABLED`-shaped error otherwise). Semantically: produces a full parallel
`ufbx_scene*` where every animated property/transform has been evaluated at `time` and baked into
the "current" value, with `props->defaults` retained as a pointer back to the *original* static
props (so `ufbx_find_prop` on the evaluated scene still works and falls through to original values
for anything not animated). The returned scene is **not independent** — frees of the original scene
must be deferred until all evaluated scenes derived from it are freed (reference/lifetime coupling;
in Swift this is a natural fit for a class holding a strong reference to its source scene).

### `ufbx_create_anim` (ufbx.c:31194-31218) — custom `ufbx_anim` descriptor construction
Builds a `ufbxi_anim_imp` (refcounted, `custom` flag set so `ufbx_free_anim`/`ufbx_retain_anim`
actually act — the scene's implicit default `anim` is presumably non-refcounted/borrowed and these
functions no-op on it, per the `if (!anim->custom) return;` guards in `ufbx_free_anim`/
`ufbx_retain_anim`, ufbc.c:31220-31240). Internally: `ufbxi_create_anim_imp` validates/dedups
`prop_overrides` (source of `UFBX_ERROR_DUPLICATE_OVERRIDE` if the same element+prop is overridden
twice) and builds internal lookup structures for the overrides/layer list. On failure, cleans up its
temp+result allocators before returning NULL with `error` populated.

### `ufbx_format_error` (ufbx.c:30598-30633) — human-readable error rendering
Writes `"ufbx vMAJOR.MINOR.PATCH error: DESCRIPTION (INFO)\n"` (INFO parenthetical omitted if
`info_length` is 0), then one line per error-stack frame (only non-empty if compiled with
`UFBX_ENABLE_ERROR_STACK`): `"LINE:FUNCTION: DESCRIPTION\n"`, right-aligned line number in a 6-char
field. Always NUL-terminates into the caller's buffer, truncating safely if `dst_size` is too small,
returning the (possibly truncated) written length. For Swift: implement as `FBXError: CustomStringConvertible`
or `LocalizedError` — no need for the manual truncation dance since Swift `String` has no fixed-size
buffer constraint.

### Panic / `ufbx_catch_*` mechanism (ufbx.c:3384-3406, 32993-33030 for vertex getters)
Two-tier error handling: the plain `ufbx_get_vertex_TYPE()` inline functions (h:5763-5766) assume
valid input and directly index (`ufbx_assert`-guarded, i.e. UB/crash in release builds on bad input)
— fast path for trusted/already-validated data. The `ufbx_catch_get_vertex_TYPE()` variants
(ufbx.c:32993-33030) take a `ufbx_panic*` and validate bounds before indexing:
1. If `panic` is non-NULL: on failure, sets `panic->did_panic = true` + formats a message into
   `panic->message` (bounded, `UFBX_PANIC_MESSAGE_LENGTH`) and returns a zero-valued fallback (never
   traps/aborts) — this lets a caller check `panic.did_panic` after a batch of calls rather than
   per-call. Once `did_panic` is set, subsequent panics on the same `ufbx_panic` are silently
   ignored (`if (panic && panic->did_panic) return;`, ufbx.c:3386) — first failure wins, avoiding
   message-overwrite races when called in a loop.
2. If `panic` is NULL: formats the same message and calls `ufbx_panic_handler` (overridable via
   `#define ufbx_panic_handler`), whose default implementation prints to stderr and then
   `ufbx_assert(false)`s — i.e. **aborts** in debug builds (assert is typically compiled out in
   release, in which case the call silently returns garbage/zero after printing to stderr — verify
   this is acceptable for release-mode callers). Each catch function validates two things
   independently: (a) `index < indices.count` (an out-of-range vertex index into the mesh's index
   array), (b) the *resolved* value index `ix` is either `< values.count` or equals `UFBX_NO_INDEX`
   sentinel (catches corrupted/mismatched index data even when the outer index was in range).
   **Port guidance**: Swift has no direct "silent panic with sticky first-failure + fallback value"
   idiom; model the catch/plain split as: plain accessors are non-throwing subscript-style
   (`mesh.position(at:)` returning a value, trusting internal invariants established at parse time
   since the Swift loader validates eagerly per `index_error_handling`), OR if genuinely exposing
   both trust levels is valuable, use a throwing `try mesh.position(at:)` for the "catch" variant and
   a `!`-style non-throwing force-unwrap-equivalent for the "get" variant — but given Swift's safety
   model, it's likely sufficient to always validate (throwing) and skip the panic-with-fallback
   pattern entirely, since the C rationale (avoid crash-on-invalid-index in release builds while
   still being fast in the common case) doesn't map to a language where bounds are always checked
   anyway.

## Format details

- **FBX version encoding**: `ufbx_metadata.version` is a plain integer like `7400` for FBX 7.4 (major
  * 1000 + minor * 100, presumably; e.g. 7100=7.1...7700=7.7 per the port scope's binary/ASCII
  version ranges). No further encoding detail found in this span (binary header parsing lives
  outside 3200-6073).
- **Exporter version packing**: `ufbx_metadata.exporter_version` and comparisons like
  `uc->exporter_version >= ufbx_pack_version(4,12,0)` (ufbx.c:22329) imply a `ufbx_pack_version(maj,
  min,patch)` macro/function packing a 3-part version into a single comparable integer — same
  `major*1000000 + minor*1000 + patch`-style scheme as `UFBX_SOURCE_VERSION` (seen used in
  `ufbx_format_error`: `/1000000`, `/1000%1000`, `%1000`, ufbx.c:30611-30612). Port as a simple
  `(major, minor, patch)` tuple or a `Version` struct with `Comparable` conformance in Swift instead
  of replicating integer packing.
- **`ufbx_exporter` detection** (ufbx.c:12080-12130, 9600, 15851, 21351, 22329, 22610-22617):
  detected from header creator strings/version fields during parsing; distinguishes Blender's binary
  vs. ASCII FBX exporter (different quirk sets) and MotionBuilder specifically — each gets special-
  cased quirk handling at several points in the parser (property defaults, PBR material inference,
  ASCII number formatting). Exact string-matching table lives in ufbx.c outside this span's line
  range; a parsing-subsystem doc should cite it. Relevant here: this classification feeds
  `ufbx_metadata.exporter` for introspection and `use_blender_pbr_material` gating.
- **KTime**: `ufbx_metadata.ktime_second` = ticks-per-second for FBX's internal fixed-point time
  representation (classically 46,186,158,000,000 ticks/second in real FBX SDK terms, though the
  exact constant isn't in this header span — grep the parsing subsystem). Used pervasively for
  frame-exact time math (extrapolation repeat cycles, `key_clamp_threshold` behavior).
- **Warning dedup boundary**: `UFBX_WARNING_TYPE_FIRST_DEDUPLICATED = UFBX_WARNING_INDEX_CLAMPED`
  (h:3587) — ordinal-based (not a bitflag), meaning warning types are deliberately ordered so
  "always-record-individually" ones come first and "may-recur-and-should-dedup" ones follow;
  preserve this ordering semantic (or replace with an explicit per-case dedup flag in Swift, which
  is clearer than relying on enum case order).
- **Thumbnail pixel layout**: rows stored bottom-to-top (h:3748), formats `RGB_24` (3 bytes/pixel)
  or `RGBA_32` (4 bytes/pixel) — matches BMP-style bottom-up convention, a common FBX-embedded-
  thumbnail quirk carried over from Windows-era tooling.
- **Progress result sentinel values**: `UFBX_PROGRESS_CONTINUE = 0x100`, `UFBX_PROGRESS_CANCEL =
  0x200` (h:4383/4386) — deliberately not 0/1 to make an uninitialized/miscoded callback return more
  likely to be caught (an accidental `return 0;` or `return true;` from a naive callback doesn't
  silently match either sentinel). Not relevant if progress callbacks are dropped for v1.
- **`_begin_zero`/`_end_zero` sentinel fields**: every opts struct (`ufbx_load_opts`,
  `ufbx_evaluate_opts`, `ufbx_anim_opts`, `ufbx_bake_opts`, tessellate/subdivide/geometry-cache opts,
  `ufbx_open_file_opts`, `ufbx_open_memory_opts`) begins/ends with a `uint32_t` that must remain zero
  — this is how ufbx detects a non-zero-initialized (i.e. uninitialized C struct with garbage stack
  memory) options struct and raises `UFBX_ERROR_UNINITIALIZED_OPTIONS` rather than reading garbage
  option values. **Irrelevant for Swift** — Swift structs/optionals with default values make this
  entire defensive pattern unnecessary; just use a struct with sensible defaults (or a builder/
  fluent-options pattern) and no sentinel fields.
- **`ufbx_bake_opts` numeric defaults** (documented inline, not enforced by header alone — actual
  zero-means-default logic lives in ufbx.c's bake implementation, outside this span): resample_rate
  30, minimum_sample_rate 19.5, maximum_sample_rate unlimited, max_keyframe_segments 32,
  key_reduction_threshold 1e-6, key_reduction_passes 4. `ufbx_tessellate_surface_opts` span
  subdivision default 4. `ufbx_allocator_opts` huge_threshold default 1MB, max_chunk_size default
  16MB. `ufbx_thread_opts` num_tasks default 2048, memory_limit default 32MB. `ufbx_load_opts`
  file_format_lookahead default 16kB. None of these size/threading defaults matter for a from-
  scratch Swift port except the animation-baking numeric defaults (30fps/19.5fps/1e-6/4 passes) if
  baking is ever implemented — otherwise these are C-implementation memory-management tuning, safe
  to ignore.

## Quirks & edge cases

1. **Bind-pose parent-space approximation** (h:3452-3455): `ufbx_bone_pose.bone_to_parent` is *not*
   stored in the file — FBX only stores world-space bind matrices. ufbx derives parent-space by
   dividing out the parent's *current* world transform, which is only correct if the parent isn't
   independently animated relative to when the pose was captured. Port this exact
   derive-from-current-parent-world approach for compatibility, but document the caveat for API
   consumers (a stale/incorrect result is possible, not a bug to "fix").
2. **Scale-helper dynamic compensation at eval time** (ufbx.c:31095-31126): non-uniform/animated
   parent scale under certain `inherit_mode_handling` modes can't be baked once at load time — ufbx
   recomputes the compensation *every time `ufbx_evaluate_transform` is called* by walking up the
   `inherit_scale_node`/`scale_helper` chain and evaluating each helper's current `Lcl Scaling`. This
   is O(depth) per call; a Swift port evaluating transforms per-frame for many nodes should consider
   caching this per evaluation pass rather than recomputing per-node if it becomes a hot path.
3. **Prop overrides bypass everything** (ufbx.c:30975-30978): if `anim.prop_overrides.count > 0`,
   `ufbx_evaluate_prop` returns the override value **unconditionally**, even skipping the
   `ANIMATED`/`CONNECTED` checks entirely — i.e. an override always wins over both curve animation
   and property connections, with no partial-override semantics (you can't override "everything
   except connections" for a given property).
4. **`ufbx_free_anim`/`ufbx_retain_anim` no-op on the scene's implicit default anim**
   (ufbx.c:31220-31240): both check `anim->custom` first and return immediately if false. This means
   `scene->anim` (the default, non-custom anim built automatically) must **not** be passed to
   `ufbx_free_anim` expecting it to be freed — it's owned by the scene. Swift port: model "default
   scene animation" and "custom created animation" as genuinely distinct types/lifetimes (e.g. the
   scene owns and vends a non-owning reference to its default anim; `createAnim` returns an owned,
   ARC-managed object) rather than one polymorphic reference-counted type with a hidden no-op case.
5. **Recursive extrapolation depth guard** (ufbx.c:25978): `ufbxi_extrapolate_curve` is wrapped with
   `ufbxi_recursive_function(..., 3, ...)`, implying a depth-3 recursion limit even though normal
   REPEAT/MIRROR extrapolation logic only ever recurses once (computes an in-range time and calls
   `ufbx_evaluate_curve_flags` with `NO_EXTRAPOLATION` forced, which cannot re-enter extrapolation).
   This suggests defensive/paranoid guarding against a theoretical bug rather than expected deep
   recursion — a Swift port's iterative or single-recursion-level implementation is sufficient; no
   need to replicate a recursion-depth counter unless mirroring ufbx's defensive posture exactly.
6. **MIRROR extrapolation parity test uses fractional epsilon, not integer modulo** (ufbx.c:26024):
   `rep_parity = rep_n*0.5 - floor(rep_n*0.5); if (rep_parity <= 0.25) ...` — because `rep_n` is a
   `double` (derived from `floor(delta/duration)`, so should be an exact integer value in double
   representation for any reasonable inputs), this is equivalent to "is rep_n even" but written
   defensively against floating-point representation error rather than cast-to-int-and-mod. Port
   with the same tolerance-based check rather than `Int(rep_n) % 2 == 0` for maximum fidelity,
   though in practice both should agree for all realistic curve durations.
7. **`ufbx_prop_override_desc.value_int` zero-init dependency** (h:4974-4976): `value_int` is only
   auto-derived from `value.x` when `value_int == 0` — meaning if a caller wants to override with the
   literal integer `0`, they cannot rely on the auto-derivation and must set `value_int` (redundant
   with an already-zero `value.x`) explicitly, or more subtly: if a caller sets `value.x` to a
   non-zero float but leaves `value_int` at its zero-initialized default, ufbx derives `value_int`
   from it — but if a caller *does* explicitly want `value_int = 0` alongside a non-zero `value.x`
   (e.g. overriding a property that's read as both fields), there's no way to distinguish "unset,
   please derive" from "explicitly zero" in the C API. Not applicable to a well-designed Swift
   `enum`-based override (each case unambiguously carries one typed payload).
8. **Warning "count" semantics differ before/after the dedup boundary** (h:3585-3587): don't assume
   `ufbx_warning.count` is meaningful/incremented for warning types before
   `UFBX_WARNING_TYPE_FIRST_DEDUPLICATED` — those are pushed once per occurrence as separate list
   entries instead (each with `count` presumably always 1, though verify against ufbx.c's warning-
   push implementation if exact fidelity matters — not traced in this pass).
9. **`use_blender_pbr_material` version-gated** (ufbx.c:22329): only applied when
   `exporter == UFBX_EXPORTER_BLENDER_BINARY && exporter_version >= ufbx_pack_version(4,12,0)` —
   i.e. Blender's deterministic Phong-encoding-of-PBR pattern was only introduced/stable from
   Blender 4.12's FBX exporter onward (per this check); earlier Blender FBX exports won't get PBR
   reinterpretation even with the option enabled. Port this version gate exactly, not just the
   general "Blender + option enabled" condition.
10. **Panic-based catch functions validate index AND resolved-value-index separately** (ufbx.c:
    32993 etc.): even if the outer per-vertex `index` is in bounds, the catch functions still
    separately validate that the *resolved* attribute value index (after the indirection through
    `indices.data[index]`) is either in-bounds or exactly `UFBX_NO_INDEX` — protecting against
    corrupted/mismatched index buffers (e.g. a normal-index array pointing past the end of the
    values array due to a parser bug or malicious file) even when the outer vertex index itself was
    fine. A Swift port validating both layers (or just always validating in a single throwing
    accessor) preserves this safety property.

## Port guidance

**Port faithfully** (these encode exact FBX/Autodesk-compatible numerical behavior — any deviation
produces visibly different animation/interpolation vs. reference importers):
- `ufbx_evaluate_curve_flags`'s exact CUBIC branch math (Bezier control point derivation from
  tangent dx/dy, then the De Casteljau evaluation) and `ufbxi_find_cubic_bezier_t`'s Newton-Raphson
  iteration count/epsilon.
- `ufbxi_extrapolate_curve`'s tick-based (not floating-point-seconds-based) repeat-cycle math,
  including the MIRROR parity check and REPEAT_RELATIVE cumulative-delta formula.
- `ufbx_evaluate_transform_flags`'s scale-helper compensation walk (parent-chain componentwise-scale
  undo) — this is what makes `UFBX_INHERIT_MODE_HANDLING_HELPER_NODES`/`COMPENSATE` actually produce
  correct results at arbitrary animated times, not just at load time.
- `clean_skin_weights` semantics (drop negative/zero/NaN weights) and `use_blender_pbr_material`'s
  exact version gate.
- The catch/plain vertex-getter dual-validation (index in range AND resolved value-index in range or
  `NO_INDEX`) — as a single throwing accessor in Swift, but validate both layers.

**Replace with Swift idioms:**
- `ufbx_error`/`ufbx_error_type` → `enum FBXError: Error` with associated values (drop the manual
  stack-trace/`info` string buffer machinery; Swift's native error propagation + `String`
  interpolation replaces `ufbx_format_error`'s manual snprintf-based formatting).
- `ufbx_panic`/catch-vs-plain accessor duality → likely collapse to always-validating throwing
  accessors, since Swift has no equivalent to "fast unchecked path for trusted release-mode callers"
  that's meaningfully faster than a bounds-checked one at this granularity.
- `_begin_zero`/`_end_zero` sentinel-based "was this struct zero-initialized" detection → unnecessary;
  Swift struct defaults + memberwise init make `UFBX_ERROR_UNINITIALIZED_OPTIONS` a non-issue.
- `ufbx_index_error_handling`/`ufbx_unicode_error_handling`'s `UNSAFE_IGNORE` modes → drop entirely;
  Swift's `String`/`Array` bounds/encoding guarantees make "unsafe passthrough" both impossible to
  honor cleanly and unnecessary (there's no perf case for it once bounds-checking is already
  mandatory in the language).
- `ufbx_scene`'s dual union representation (typed lists + `elements_by_type[]` array) → a single
  `[ElementType: [Element]]`-style store or an `ElementType`-indexed array of `[any FBXElement]`,
  with typed convenience computed properties (`var meshes: [Mesh]`) layered on top — don't replicate
  the C union.
- `ufbx_prop_override_desc`'s shared `ufbx_vec4 value` + zero-derivation-of-`value_int` quirk →
  a Swift enum `OverrideValue { case real(Double), vec3(SIMD3<Double>), string(String), int(Int64) }`.
- Reference-counted types (`ufbx_scene`, `ufbx_mesh`, `ufbx_anim`, `ufbx_baked_anim`,
  `ufbx_line_curve`, `ufbx_geometry_cache` — see the C++11 `ufbx_type_traits`/`ufbx_shared_ptr`
  wrapper at h:5867-6002, itself a strong hint about which types have reference semantics) → Swift
  reference types (`final class`) relying on ARC instead of manual retain/free; drop
  `ufbx_retain_*`/`ufbx_free_*` entirely.

**Skip per v1 scope** (OUT):
- Everything under Tessellation/Subdivision/Geometry-cache options; `ufbx_bake_anim` and all
  `ufbx_baked_*` types (until/unless a later milestone adds baking); thread pool API
  (`ufbx_thread_pool*`, `ufbx_thread_opts`); progress callbacks (`ufbx_progress*`); custom
  allocators (`ufbx_allocator*`) — Swift uses `Data`/ARC; DOM retention (`ufbx_dom_*`,
  `retain_dom`); all `.obj`/`.mtl`-specific `ufbx_load_opts` fields; `ufbx_character`/
  `ufbx_constraint` solving logic (keep the data structures as passthrough only, per the port
  brief — no IK/aim solving).

**Cross-subsystem dependencies** (this span's types are consumed by / depend on other subagents'
regions):
- `ufbx_scene_settings.axes`/`unit_meters` + `ufbx_load_opts.target_axes`/`target_unit_meters`/
  `space_conversion`/`geometry_transform_handling`/`inherit_mode_handling`/`pivot_handling` are pure
  **options declarations** here; the actual conversion algorithms (root-transform injection, helper-
  node synthesis, pivot baking) execute during scene construction — covered by whichever subsystem
  doc owns node/transform-chain construction (likely the "node tree + full FBX transform chain"
  part of the scope). This doc only specifies the *policy* surface; implementers must consult that
  other doc for the *mechanism*.
- `ufbx_anim_curve`/keyframe/tangent evaluation here depends on `ufbx_keyframe`/`ufbx_tangent`/
  `ufbx_interpolation`/`ufbx_extrapolation` struct definitions, which live just before this span
  (likely documented in part 1, e.g. keyframe struct is at h:3203 right at this span's start —
  verify it isn't duplicated/missed by the part-1 author since 3200 is the exact boundary).
  `ufbx_anim_curve` itself (h:3213) IS in this span and is documented above.
- `ufbx_get_vertex_*`/`ufbx_catch_get_vertex_*` depend on `ufbx_vertex_real/vec2/vec3/vec4` struct
  layout (indices + values arrays) defined in part 1 (mesh layer-element section) — this span only
  covers the accessor *functions*, not the underlying struct.
- Skinning (`ufbx_get_skin_vertex_matrix`), blend shapes (`ufbx_get_blend_shape_vertex_offset`,
  `ufbx_add_blend_shape_vertex_offsets`), and NURBS evaluation functions declared here (h:5596-5646)
  operate on `ufbx_skin_deformer`/`ufbx_blend_shape`/`ufbx_nurbs_curve`/`ufbx_nurbs_surface`
  structs defined in part 1 — this span is the "verb" layer, part 1 is the "noun" layer, for those
  features.
- The whole `ufbx_evaluate_*` family depends on animation-stack/layer/value/curve construction and
  property-connection resolution (`ufbxi_evaluate_connected_prop`, `ufbxi_evaluate_props` layer-
  blending) whose *construction* (not evaluation) is presumably covered by an animation-parsing
  subsystem doc — flag for cross-check that layer-weight blending semantics are documented exactly
  once, likely here or in that other doc, not divergently in both.

## Warnings / open questions for the parent agent
- The exact FBX-version integer encoding (e.g. confirm `7400` = major*1000+minor*100, not some other
  packing) and the KTime tick-per-second constant are referenced but not defined within lines
  3200-6073 — needed from a parsing-focused subsystem doc for full fidelity.
- `ufbxi_evaluate_connected_prop` (property-to-property FBX connections during evaluation) and the
  animation-layer weight-blending algorithm inside `ufbxi_evaluate_props` were identified but not
  traced in depth — if bit-exact layer blending / connected-property evaluation matters for v1
  (likely does, since "evaluation of props and transforms at time t" is explicitly in scope), a
  follow-up pass should trace these two functions specifically.
- Exact per-warning-type `count` accumulation behavior (whether pre-dedup-boundary warnings ever get
  `count > 1`) wasn't verified against the warning-push implementation in ufbx.c.
- `ufbx_pack_version`'s definition wasn't located within this span; confirmed only via its usage
  pattern at ufbx.c:22329 and the analogous `UFBX_SOURCE_VERSION` decomposition in
  `ufbx_format_error`.
