# API layer (ufbx.c lines 30333-33204)

## Purpose

This region is the public C ABI surface (`ufbx_abi` functions): entry points that open streams/files, drive the
top-level load pipeline (`ufbx_load_memory/file/stdio/stream`), look up props/elements by name, evaluate
animated properties/transforms/curves at time `t`, do quaternion/matrix math, evaluate NURBS bases, triangulate
n-gons, and the `ufbx_as_TYPE`/`ufbx_find_*` convenience wrappers that call the `_len` variants with
`strlen`. It is the thin, mostly-mechanical shell around the real work done by internal (`ufbxi_`) functions
defined earlier in the file — most importantly `ufbxi_load`/`ufbxi_load_imp` (line 25472 / 25204), which are
*outside* this line span but define the pipeline order this subsystem's notes must document, so they are
included here by necessity.

## Key data structures

- **`ufbx_load_opts`** (ufbx.h:4690-4938) — the mega-options struct for `ufbx_load_*`. See "Format details" below
  for the full field-by-field list; it is zero-initialized by convention (`{0}` in C, all-zero check enforced —
  see Quirks) and any non-set fields get sane defaults applied in `ufbxi_load`/`ufbxi_load_imp`.
- **`ufbx_error`** (ufbx.h:4350-4368) — `type` (`ufbx_error_type` enum, ufbx.h:4257-4344), `description`
  (`ufbx_string`), a fixed-depth `stack[UFBX_ERROR_STACK_MAX_DEPTH]` of `ufbx_error_frame` (source_line, function
  name, description) only populated if compiled with `UFBX_ENABLE_ERROR_STACK`, and a fixed `info[]` buffer (e.g.
  holds the missing filename) with `info_length`.
- **`ufbx_error_type`** enum — `NONE, UNKNOWN, FILE_NOT_FOUND, EMPTY_FILE, EXTERNAL_FILE_NOT_FOUND,
  OUT_OF_MEMORY, MEMORY_LIMIT, ALLOCATION_LIMIT, TRUNCATED_FILE, IO, CANCELLED,
  UNRECOGNIZED_FILE_FORMAT, UNINITIALIZED_OPTIONS, ZERO_VERTEX_SIZE, TRUNCATED_VERTEX_STREAM, INVALID_UTF8,
  FEATURE_DISABLED, BAD_NURBS, BAD_INDEX, NODE_DEPTH_LIMIT, THREADED_ASCII_PARSE, UNSAFE_OPTIONS,
  DUPLICATE_OVERRIDE, UNSUPPORTED_VERSION` (ufbx.h:4257-4344). `UNINITIALIZED_OPTIONS` is what you get if you pass
  a non-zeroed opts struct (see `ufbxi_check_opts_ptr`, ufbx.c:30313).
- **`ufbx_props` / `ufbx_prop`** — a sorted-by-key array of properties plus a `defaults` chain pointer (props
  fall back to `props->defaults` recursively — this is how "class" default templates and per-node overrides
  compose). Lookup is a binary search keyed by a 32-bit hashed name key (`_internal_key`) with a name-equality
  tiebreak (`ufbxi_macro_lower_bound_eq`, e.g. ufbx.c:30642).
- **`ufbx_anim`** — bundles `prop_overrides` (sorted by `element_id` then prop key/name) and `ignore_connections`;
  passed to all `ufbx_evaluate_*` functions. `ufbx_evaluate_prop_flags_len` (ufbx.c:30956) short-circuits through
  overrides first, then connected-prop evaluation, then curve evaluation.
- **`ufbx_anim_layer` / `ufbx_anim_prop`** — `anim_props` is sorted by `(element ptr, prop_name)`;
  `ufbx_find_anim_prop_len`/`ufbx_find_anim_props` binary-search this to get the animated props touching one
  element (ufbx.c:30775-30812).
- **`ufbx_keyframe` / `ufbx_anim_curve`** — sorted `keyframes` array with `min_time/max_time`,
  `pre_extrapolation`/`post_extrapolation` (`ufbx_extrapolation{mode, repeat_count}`). Each keyframe carries
  `value`, `interpolation` (constant-prev/next, linear, cubic), and `left`/`right` tangents (`dx`,`dy`) used only
  for cubic segments.
- **`ufbx_transform`** (translation vec3, rotation quat, scale vec3) vs **`ufbx_matrix`** (3x4, column-major:
  `cols[0..3]`, `m00..m23`, no bottom row since affine) — `ufbx_transform_to_matrix` / `ufbx_matrix_to_transform`
  convert between them (ufbx.c:31828, 31854).
- **`ufbx_coordinate_axes`** (`right`,`up`,`front`, each a `ufbx_coordinate_axis` = one of 6 signed-axis enum
  values `POSITIVE_X..NEGATIVE_Z`, ufbx.h near 829) describes a coordinate system; `ufbx_coordinate_axes_valid`
  (ufbx.c:31478) checks all three axes are in range and collectively cover exactly the 3 physical axes (bitmask
  trick: `1u << (axis>>1)` must OR up to `0x7`).
- **`ufbx_space_conversion`** enum — `TRANSFORM_ROOT` (0, default), `ADJUST_TRANSFORMS`, `MODIFY_GEOMETRY`
  (ufbx.h:3623-3643). Governs *how* axis/unit conversion is realized in the output scene.
- **`ufbx_geometry_transform_handling`** enum — `PRESERVE` (0, default), `HELPER_NODES`, `MODIFY_GEOMETRY`,
  `MODIFY_GEOMETRY_NO_FALLBACK` (ufbx.h:3651-3677).
- **`ufbx_inherit_mode_handling`** enum — `PRESERVE` (0, default), `HELPER_NODES`, `COMPENSATE`,
  `COMPENSATE_NO_FALLBACK`, `IGNORE` (ufbx.h:3680-3711).
- **`ufbx_pivot_handling`** enum — `RETAIN` (0, default), `ADJUST_TO_PIVOT`, `ADJUST_TO_ROTATION_PIVOT`
  (ufbx.h:3714-3735).
- **`ufbx_index_error_handling`** enum — `CLAMP` (0, default), `NO_INDEX`, `ABORT_LOADING`, `UNSAFE_IGNORE`
  (requires `allow_unsafe`) (ufbx.h:4451-4470).
- **`ufbx_unicode_error_handling`** enum — `REPLACEMENT_CHARACTER` (0, default = U+FFFD), `UNDERSCORE` ('_'),
  `QUESTION_MARK` ('?'), `REMOVE`, `ABORT_LOADING`, `UNSAFE_IGNORE` (requires `allow_unsafe`) (ufbx.h:4472-4489).

## Control flow / algorithms

### Load pipeline driver (outside this span but essential — ufbx.c:25204-25625)

Every `ufbx_load_memory/file/file_len/stdio/stdio_prefix/stream/stream_prefix` (ufbx.c:30502-30576) fills a stack
`ufbxi_context uc` (zeroed), stashes the data pointer or deferred-file/stream info, and calls
`ufbxi_load(&uc, opts, error)` (ufbx.c:25472). Order:

1. **`ufbxi_load`** (25472):
   - Detect endianness of the *host* (25474-25480), init `double_parse_flags`.
   - Copy `user_opts` into `uc.opts` if given, else zero it (25484-25488) — this is where "all-zero default"
     options come from.
   - `file_size_estimate` → seeds `progress_bytes_total` (25490).
   - `ignore_all_content` implies `ignore_geometry`+`ignore_animation`+`ignore_embedded` (25494-25498).
   - Init temp/result allocators (25503-25504).
   - Apply scalar option defaults (see Format details table) — `read_buffer_size`, `file_format_lookahead`,
     `path_separator`, `progress_interval` derivation, `open_file_cb` default, `thread_opts.memory_limit`
     default (25506-25537).
   - Init string pool, several `ufbxi_map`s (fbx_id, prop_type, anim_stack name, dom_node, etc.) and temp buffers
     (25541-25580), all backed by the temp allocator.
   - Calls **`ufbxi_load_imp(&uc)`** (25601) — the actual parse+build; on return, closes the stream
     (`uc.close_fn`), frees all temp buffers (`ufbxi_free_temp`, 25412), and:
     - on success: clears `*p_error`, returns `&uc.scene_imp->scene`.
     - on failure: `ufbxi_fix_error_type` fills in the caller's `ufbx_error`; if the error is still
       `UFBX_ERROR_UNKNOWN` and the format is FBX and the version is unsupported, upgrades the error to
       `UFBX_ERROR_UNSUPPORTED_VERSION` with the version number as `info` (25616-25621); frees the result
       allocator; returns `NULL`.

2. **`ufbxi_load_imp`** (25204) — the real pipeline, in call order:
   1. If deferred load (i.e. came from `ufbx_load_file*`), open the file now via `open_file_cb`
      (default = stdio) — respects `opts.filename` fallback to derive a relative-path base (25206-25244).
   2. Optional total-size probe for progress reporting (25246-25250).
   3. Validate `path_separator` is printable ASCII (0x20-0x7e) (25252).
   4. Fix up string options that may need NUL-termination copies: `filename`, `obj_mtl_path`,
      `geometry_transform_helper_name`, `scale_helper_name` (25254-25257).
   5. Init thread pool (25259).
   6. **Unsafe-option gate**: unless `allow_unsafe`, fail if `index_error_handling ==
      UFBX_INDEX_ERROR_HANDLING_UNSAFE_IGNORE` or `unicode_error_handling ==
      UFBX_UNICODE_ERROR_HANDLING_UNSAFE_IGNORE` (25261-25266) → `UFBX_ERROR_UNSAFE_OPTIONS`. If unsafe *is*
      allowed, `scene.metadata.is_unsafe = true`.
   7. If `index_error_handling == NO_INDEX`, mark `metadata.may_contain_no_index = true` (25268-25270).
   8. `retain_mesh_parts = !ignore_geometry && !skip_mesh_parts` (25272); copy `allow_missing_vertex_position`
      and `connect_broken_elements` into metadata flags (25273-25274).
   9. `unit_scale = 1.0` initial; if `data == NULL` point at a static zero-size buffer (25278-25282).
   10. `retain_vertex_w = (retain_dom || retain_vertex_attrib_w) && !ignore_geometry` (25284).
   11. **`ufbxi_load_strings`**, **`ufbxi_load_maps`**, **`ufbxi_determine_format`** (25286-25288) — string
       interning setup, name-key maps, and file-format sniffing (FBX/OBJ/MTL) from header bytes/extension
       (details belong to the format-detection subsystem, not re-derived here).
   12. Branch on detected `format`:
       - **FBX**: `ufbxi_begin_parse` → if `version < 6000` use `ufbxi_read_legacy_root` (pre-7000 "Take" era)
         else `ufbxi_read_root`; if version unsupported, emit a *warning* (not a hard failure) via
         `UFBX_WARNING_UNSUPPORTED_VERSION`; `ufbxi_update_scene_metadata`; `ufbxi_init_file_paths`
         (25292-25303).
       - **OBJ**: `ufbxi_obj_load` then `ufbxi_update_scene_metadata` (25304-25306) — out of v1 scope.
       - **MTL**: `ufbxi_mtl_load` then `ufbxi_update_scene_metadata` (25307-25309) — out of v1 scope.
   13. If `retain_dom` and no dom root was produced, synthesize an empty one (25312-25318).
   14. **`ufbxi_pre_finalize_scene`** (25320) then free `tmp_parse` buffer (25322-25323, parsing is fully done).
   15. **`ufbxi_finalize_scene`** (25325) — builds final typed element arrays, connections, etc. (own
       subsystem).
   16. **`ufbxi_update_scene_settings`** (25327; see below) — reads axes/units/frame-rate/time-mode from scene
       props into `scene.settings`. For OBJ, `ufbxi_update_scene_settings_obj` instead (25328-25330).
   17. **Axis conversion**: if `ufbx_coordinate_axes_valid(opts.target_axes)`, call
       `ufbxi_transform_to_axes(uc, opts.target_axes)` (25333-25335; see below).
   18. **Unit conversion**: if `opts.target_unit_meters > 0`, call `ufbxi_scale_units(uc, target_unit_meters)`
       (25338-25340; see below).
   19. `ufbxi_update_adjust_transforms(uc, &uc->scene)` (25343; see below) — computes per-node "adjust"
       compensation transforms for space conversion / light / camera axis remap / inherit-mode scale
       compensation. Marked `// TODO: This could be done in evaluate as well`.
   20. `ufbxi_modify_geometry(uc)` (25345) — bakes geometry-space scale/rotation into vertex data when
       `space_conversion == MODIFY_GEOMETRY` or `geometry_transform_handling` requests geometry modification
       (own subsystem: mesh finalize).
   21. `ufbxi_postprocess_scene(uc)` (25346) — misc scene-wide fixups (own subsystem).
   22. `ufbxi_update_scene(&uc->scene, true, NULL, 0)` (25348; see below) — computes all derived per-element
       "world" data (node transforms, camera/light directions, skin clusters, blend channels, textures,
       materials, anim stacks, display layers, constraints, `ufbx_anim`) for the *default* (non-animated,
       t=0) pose. This is the function later reused by `ufbx_evaluate_scene` for baking at arbitrary time.
   23. Force `scene.anim` non-NULL even if no animation was found (25351-25353).
   24. If `load_external_files`, call `ufbxi_load_external_files` (25355-25357; geometry caches / .mtl — mostly
       out of v1 scope except .mtl external lookup, which itself is out of scope).
   25. If `evaluate_skinning`, run `ufbxi_evaluate_skinning` to populate `ufbx_mesh.skinned_vertices`
       (25360-25365) — out of v1 scope per port instructions (evaluation-of-skinning helper, not core skin
       deformer data model).
   26. Pop accumulated warnings into `scene.metadata.warnings` (`ufbxi_pop_warnings`) and resolve warning →
       element back-references (`ufbxi_resolve_warning_elements`) (25368-25369).
   27. Copy final scalar metadata: `version`, `ascii`, `big_endian`, `geometry_ignored`, `animation_ignored`,
       `embedded_ignored` (25372-25377).
   28. **Retain the scene**: push a `ufbxi_scene_imp` wrapper (refcounted, magic-tagged) as the *last* allocation
       in the result buffer, copy `uc.scene` into it, transplant the result allocator/buffers into the imp so
       the scene remains valid after `uc` is destroyed, back-patch every element's `->scene` pointer to point at
       the retained copy (25379-25405). Returns 1 (success).

### Option validation entry (`ufbxi_check_opts_ptr`, ufbx.c:30313, macro)

Every public entry that takes an `opts` pointer (`ufbx_load_memory`, `ufbx_evaluate_scene`, `ufbx_create_anim`,
`ufbx_bake_anim`, `ufbx_tessellate_*`) expands this macro first: if `opts` is non-NULL, it asserts
`opts->_begin_zero == 0 && opts->_end_zero == 0` and, in release builds where the assert is compiled out, still
checks the same condition and fails with `UFBX_ERROR_UNINITIALIZED_OPTIONS` if violated. This is how ufbx catches
callers who forgot to zero-initialize a large opts struct (stack garbage would otherwise silently misconfigure
loading). `ufbx_open_memory_ctx` (30442-30495) does the same check manually for `ufbx_open_memory_opts`.

### `ufbx_find_prop_len` (ufbx.c:30635) — property lookup semantics

1. Hash the requested name into a 32-bit `key` (`ufbxi_get_name_key`) and build a temporary `ufbx_string`.
2. Walk the `props` chain: at each level, binary-search the level's `props.data` array (sorted by key, then by
   name for collisions) via `ufbxi_macro_lower_bound_eq`; if found, return that `ufbx_prop*` immediately.
3. If not found at this level, move to `props->defaults` (the parent/template props) and repeat.
4. If the chain is exhausted, return `NULL`.

This is the standard FBX property-template inheritance: object-instance props shadow class-default props, which
shadow further defaults. `ufbx_find_real/vec3/int/bool/string/blob_len` (30652-30710) all wrap this and return a
caller-supplied default if the prop is missing. `ufbx_find_prop_concat` (30712) does the same but hashes/matches
a name built by concatenating multiple `ufbx_string` parts (used for pipe-separated compound prop names like
`"Original|ApplicationName"`).

### `ufbx_find_element_len` (ufbx.c:30730) — scene-wide named lookup

Binary-searches `scene->elements_by_name` (sorted by name then element type) for an entry matching both name and
`ufbx_element_type`. `ufbx_find_node/anim_stack/material_len` are thin casts over this. `ufbx_get_prop_element`
(30743) resolves a prop that stores an FBX object reference (as a string) back to the connected `ufbx_element*`
of a given type via `ufbxi_fetch_dst_element` (defined elsewhere — walks the connection graph).

### Curve/property evaluation call graph (evaluation entry points)

- `ufbx_evaluate_curve_flags` (30832): if the curve has ≤1 keyframe, return that value or the caller default.
  Otherwise, unless `UFBX_EVALUATE_FLAG_NO_EXTRAPOLATION` is set and `time` is outside `[min_time,max_time]`,
  delegate to `ufbxi_extrapolate_curve` (25977, see below). Else binary-search (8-wide unrolled linear scan
  fallback) for the first keyframe with `time > t`; handle before-first/exact-match fast paths; otherwise
  interpolate between `prev`/`next` per `prev->interpolation`:
  - `CONSTANT_PREV` → `prev->value`; `CONSTANT_NEXT` → `next->value`.
  - `LINEAR` → straight lerp by `t = (time-prev.time)/(next.time-prev.time)`.
  - `CUBIC` → Bezier: reparameterize `t` via `ufbxi_find_cubic_bezier_t` (25014, Newton-Raphson solve of the
    Bezier X(t)=x0 equation, 3 unrolled iterations + up to 4 more for accuracy, tolerance `8.88e-16`), then
    evaluate the cubic Bezier Y using control points derived from `prev.right`/`next.left` tangent `dy`.
- `ufbxi_extrapolate_curve` (25977, recursive — but recursion only occurs once via `ufbx_evaluate_curve_flags`
  called with `NO_EXTRAPOLATION` for the wrapped-time evaluation, so effectively depth 1): picks
  `pre_extrapolation`/`post_extrapolation` depending on which side of the curve `time` is on.
  - `CONSTANT` → boundary keyframe value.
  - `SLOPE` → linear extrapolation using the boundary tangent (`right` if before-start, `left` if after-end).
  - `repeat_count == 0` → boundary value (degenerate).
  - Otherwise (`REPEAT`/`MIRROR`/`REPEAT_RELATIVE`): converts `min_time`/`max_time`/`time` to KTime tick units
    (`scale = ktime_second`) for frame-perfect math, computes how many whole `duration`s (`rep_n`) and the
    remainder (`rep_d`) fit in the overshoot `delta`; clamps `rep_n` to `repeat_count-1` if it's a bounded
    repeat; for `MIRROR`, flips `rep_d` on odd repeats (`rep_parity`); re-enters
    `ufbx_evaluate_curve_flags` at the folded-back `new_time` with `NO_EXTRAPOLATION` forced; for
    `REPEAT_RELATIVE`, adds `(rep_n+1) * (last.value - first.value)` (signed by side) on top, i.e. the curve's
    net delta accumulates each repeat instead of mirroring/clamping.
- `ufbx_evaluate_anim_value_real/vec3_flags` (30926/30937): starts from `anim_value->default_value`, overrides
  each present component curve (`curves[0..2]`) via `ufbx_evaluate_curve_flags`.
- `ufbx_evaluate_prop_flags_len` (30956): look up the static prop on the element; if missing, synthesize a
  `NOT_FOUND`-flagged stand-in prop carrying just the name/key (so callers can still inspect `.name`). If
  `anim->prop_overrides` is non-empty, `ufbxi_find_prop_override` (25643, binary search by
  `(element_id, internal_key, strcmp(name))`) short-circuits and returns the override value verbatim (flags
  cleared of `NO_VALUE|NOT_FOUND`, `OVERRIDDEN` set) — overrides win over everything else. Otherwise, if the
  prop isn't `ANIMATED`/`CONNECTED`, return the static value as-is. If `CONNECTED` (and
  `!anim->ignore_connections`), resolve through `ufbxi_evaluate_connected_prop` (25822, elsewhere — follows an
  FBX connection to another element's animated prop). Finally `ufbxi_evaluate_props` (25759, elsewhere) applies
  curve evaluation for `ANIMATED` props across (potentially multiple stacked) anim layers, combining additively
  or blended per `ufbxi_combine_anim_layer` (25699) — this is where `Lcl Rotation` gets special-cased to slerp
  quaternions per-layer (evaluating `RotationOrder` first, recursively) rather than lerping Euler angles
  component-wise, and `Lcl Scaling` uses `pow(|v|, weight)` per axis for additive blending
  (`ufbxi_pow_abs`, 25689).
- `ufbx_evaluate_props_flags` (30996): iterates every prop on the element (via `ufbxi_prop_iter`/`ufbxi_next_prop`,
  elsewhere) that's `ANIMATED|OVERRIDDEN|CONNECTED`, copies up to `buffer_size` of them into the caller buffer,
  resolves connections same as above, then batch-evaluates via `ufbxi_evaluate_props`. Returned `ufbx_props`
  chains `defaults` back to the *original* static `element->props`, so a caller doing `ufbx_find_prop_len` on the
  result transparently falls through to statics for anything not animated.
- `ufbx_evaluate_transform_flags` (31062) — the node-transform evaluator:
  1. Fast paths: no `anim` → return `node->local_transform` as-is; `node->is_root` → same (root transform is
     handled specially, see axis-conversion quirk below).
  2. Determine which of Translation/Rotation/Scale components are requested (`INCLUDE_*` flags, default = all
     three) and pick a minimal prop-name table accordingly (`ufbxi_transform_props_all/rotation/scale/
     rotation_scale`, 31030-31060) to avoid evaluating unused props.
  3. **Scale-helper / inherit-mode compensation** (31095-31126): if translation or scale is requested and the
     parent has scale-inheritance quirks, walks up the `inherit_scale_node`/`scale_helper` chain accumulating a
     multiplicative `scale_factor` from each ancestor's evaluated `Lcl Scaling`, feeding it in as
     `translation_scale` for the position math and re-applied to the final `scale` at the end
     (`use_scale_factor`). This is how `UFBX_INHERIT_MODE_HANDLING_HELPER_NODES`/`COMPENSATE` chains stay correct
     under animation.
  4. Batch-evaluate the selected props via `ufbxi_evaluate_selected_props` (25926, elsewhere), read
     `RotationOrder` (default XYZ), then build the transform from `ufbxi_get_transform/get_rotation/get_scale`
     (elsewhere — these apply pivots/offsets/pre-post rotation per the full FBX transform chain formula) or
     identity components for unrequested parts.
- `ufbx_evaluate_blend_weight_flags` (31167): evaluates just `DeformPercent`, default = `channel->weight*100`,
  result scaled by `0.01`.

### Axis/unit/space conversion (ufbx.c:24946-25010, called from `ufbxi_load_imp`)

- **`ufbxi_transform_to_axes`** (24946): no-op if the scene's own axes aren't valid. Computes `uc->axis_matrix`
  via `ufbxi_axis_matrix(src, dst)` (23640-ish, elsewhere — builds a signed permutation matrix remapping each of
  src's right/up/front axes to dst's, flipping sign when parity differs, see line 23667-23671 above the read
  window). If the resulting matrix has negative determinant (i.e. axis remap flips handedness) and
  `opts.handedness_conversion_axis != NONE`, mirrors the matrix about that axis (`ufbxi_mirror_matrix_dst`) and
  records `uc->mirror_axis`/`scene.metadata.mirror_axis`, and flags every non-root node
  `adjust_mirror_axis = mirror_axis` so mesh/prop finalization can compensate winding elsewhere. If
  `space_conversion == TRANSFORM_ROOT` (the default), folds `axis_matrix` directly into
  `scene.root_node.local_transform`/`node_to_parent` (pre-multiplied with any existing non-identity root
  transform) — this is the "cheapest", least-invasive conversion mode; the other two modes leave the root alone
  and instead rely on `ufbxi_update_adjust_transforms`.
- **`ufbxi_scale_units`** (24983): no-op if `scene.settings.unit_meters <= 0`. Rounds both the target and the
  computed `ratio = unit_meters/target_meters` to the nearest "nice" power-of-ten-ish value via
  `ufbxi_round_if_near` (23889, snapping against the `ufbxi_pow10_targets` table 23880-23887, i.e. 1e-8..1e9) so
  that e.g. `0.999999` becomes exactly `1.0` and a no-op scale is correctly detected (`ratio == 1.0` → early
  return). Stores `uc->unit_scale = ratio`; if `TRANSFORM_ROOT`, multiplies the root's `local_transform.scale`
  and the corresponding rows of `node_to_parent` by `ratio` directly.
- **`ufbxi_update_adjust_transforms`** (23676-23804, called unconditionally after axis+unit conversion): computes
  `root_transform` from `uc->axis_matrix` (if non-zero) with `scale *= unit_scale` folded in, and separately
  computes optional **light**/**camera** re-orientation matrices if `target_light_axes`/`target_camera_axes` are
  valid — FBX's implicit conventions are lights pointing `-Y` and cameras pointing `+X`; these are remapped to
  canonical axes (`{+X,-Z,+Y}` for lights ufbx.c:23696-23700, `{+Z,+Y,-X}` for cameras ufbx.c:23712-23716) via
  `ufbxi_axis_matrix`, and the resulting rotation is stashed as `light_post_rotation`/`camera_post_rotation` plus
  a recomputed `light_direction` (inverse-transformed default `-Y`). Then, per node (23746-23803):
  - Reset `adjust_pre_rotation/post_rotation` to identity, `adjust_pre_scale/post_scale/translation_scale` to 1.
  - If `space_conversion == ADJUST_TRANSFORMS` and the node is a direct root child (`node_depth<=1`, not root
    itself): set `adjust_pre_rotation = root_transform.rotation`, `adjust_pre_scale = root_scale`, flag
    `has_adjust_transform`/`has_root_adjust_transform`.
  - If `space_conversion == MODIFY_GEOMETRY`: same pre-rotation-at-depth-1 rule, but instead of pre-scale, sets
    `adjust_translation_scale = root_scale` on *every* non-root node (so translations, not just the root, are
    rescaled — the actual vertex-geometry scaling happens later in `ufbxi_modify_geometry`).
  - **Scale-inheritance compensation**: if the parent had a root-adjust transform and this node's
    `inherit_mode == IGNORE_PARENT_SCALE`, multiply `adjust_post_scale` by `root_scale` to counteract the parent
    not otherwise propagating it. If the parent `is_scale_compensate_parent` and this node's
    *original* (pre-handling) inherit mode was `IGNORE_PARENT_SCALE`, compute a representative scalar `size`
    from the parent's `Lcl Scaling` (picks whichever axis is closest to 1.0 among y/z as a tie-break against x —
    a heuristic for "the" uniform scale component) and multiply `adjust_post_scale` by `1/size`.
  - If the node has exactly one attribute and it's a light/camera and a target axis was requested, apply the
    precomputed light/camera post-rotation and (for lights) overwrite `light->local_direction`; (for cameras)
    set `camera->projection_axes = target_camera_axes`.
  - Also unconditionally resets every `ufbx_light.local_direction` to the FBX default `(0,-1,0)` at the top of
    the function (23723-23728) before any override — i.e. light direction is always FBX-space `-Y` unless a
    target axis conversion is requested.

### `ufbxi_update_scene` (23806-23867) — full derived-state recompute

Iterates, in this fixed order, calling per-kind `ufbxi_update_*` helpers: nodes → lights → cameras → bones →
line_curves → (if `initial`) initial clusters + poses → skin_clusters → blend_channels → textures → (propagate
main textures) → materials → anim_stacks → display_layers → constraints → `ufbxi_update_anim`. This exact order
matters: e.g. node world transforms must be resolved before cameras/lights/bones read them, and clusters/skins
must be updated before materials (which may reference textures already updated). Called once at load time
(`initial=true`) and again by scene-evaluation/baking code (elsewhere) with `initial=false` and a
`transform_overrides` list for evaluating a scene at a different pose without recomputing one-time state
(initial clusters, poses).

### `ufbxi_update_scene_settings` (23903-23931)

Reads `UnitScaleFactor`/`OriginalUnitScaleFactor` props (default 1.0), axes from `UpAxis`/`UpAxisSign`,
`FrontAxis`/`FrontAxisSign`, `CoordAxis`/`CoordAxisSign`. Converts unit scale factor to meters via `* 0.01`
(FBX's default unit is cm) and snaps to the nearest power-of-ten-ish nice value (same `ufbxi_round_if_near`
table). Reads `CustomFrameRate` (default 24), `AmbientColor` (default black), `OriginalUpAxis`,
`DefaultCamera` (string prop → `settings.default_camera`), `TimeMode`/`TimeProtocol`/`SnapOnFrameMode` enums
clamped into range, and if `time_mode != CUSTOM`, overwrites `frames_per_second` from the
`ufbxi_time_mode_fps[]` lookup table (defined elsewhere — maps the standard time-mode enum, e.g. 24/30/60fps,
NTSC variants, to an exact fps value).

### NGON triangulation (`ufbx_catch_triangulate_face`, ufbx.c:32392-32475) — in v1 scope

1. `num_indices < 3` → 0 triangles.
2. Bounds-check via `ufbxi_panicf` (a "catch" function: reports through a `ufbx_panic*` instead of
   crashing/asserting, so callers can opt into graceful degradation) that the output buffer has room for
   `(n-2)*3` indices and the face's index range is in-bounds.
3. **Triangle** (`n==3`): pass through as one triangle, indices `[begin, begin+1, begin+2]`.
4. **Quad** (`n==4`): decide which diagonal to split along by comparing squared diagonal lengths
   (`dot_aa` vs `dot_bb`, the two diagonals `v2-v0` and `v3-v1`), preferring the *shorter* diagonal — unless the
   quad is non-planar/concave enough that face normals computed from each half-triangle-pair disagree
   (`dot_na`/`dot_nb < 0`, meaning one candidate split produces inverted/folded triangles), in which case the
   split is instead chosen to be whichever diagonal has consistent normals (`dot_na >= dot_nb`). This handles
   bowtie/non-convex quads correctly rather than blindly bisecting by distance.
5. **N-gon (n≥5)**: delegates to `ufbxi_triangulate_ngon` (defined at ufbx.c:28489, outside this span — an
   ear-clipping algorithm operating on a small (≤12) stack buffer when possible, else the caller's buffer). Only
   consulted here for interface contract, not re-derived.
6. Non-catching wrapper `ufbx_triangulate_face` (33165) just calls the catch variant with `panic=NULL`.

## Format details

### `ufbx_load_opts` fields and defaults (ufbx.h:4690-4938; defaults applied in `ufbxi_load`/`ufbxi_load_imp`)

Boolean/enum fields default to `false`/`0` unless noted. Zero-valued sentinels get replaced at load time as
shown.

| Field | Default / replacement | Effect |
|---|---|---|
| `temp_allocator`, `result_allocator` | system malloc via `ufbx_allocator_opts{0}` | custom allocators for scratch vs. final scene memory |
| `thread_opts` | `memory_limit` defaults to 32 MiB if 0 (ufbx.c:25535-25537) | threading tuning — out of v1 scope (Swift has no thread pool) |
| `ignore_geometry/animation/embedded` | false | skip loading that data category |
| `ignore_all_content` | false | if true, forces all three above to true (25494-25498) |
| `evaluate_skinning`, `evaluate_caches` | false | out of v1 scope |
| `load_external_files` | false | out of v1 scope (implicit external file loading) |
| `ignore_missing_external_files` | false | n/a if above unused |
| `skip_skin_vertices` | false | skip computing `ufbx_skin_deformer.vertices/weights` |
| `skip_mesh_parts` | false | skip `material_parts`/`face_group_parts`; combined with `ignore_geometry` to set `uc.retain_mesh_parts` |
| `clean_skin_weights` | false | drop negative/zero/NaN skin weights |
| `use_blender_pbr_material` | false | reinterpret Blender-exported Phong as `UFBX_SHADER_BLENDER_PHONG` |
| `disable_quirks` | false | turn off exporter-specific workarounds |
| `strict` | false | reject partially-broken files instead of tolerating |
| `force_single_thread_ascii_parsing` | false | n/a for a from-scratch Swift port (no threads) but affects strictness — see Quirks |
| `allow_unsafe` | false | gate for the two `UNSAFE_IGNORE` enum values |
| `index_error_handling` | `CLAMP` (0) | see enum above |
| `connect_broken_elements` | false | include dangling-reference elements in connection lists anyway |
| `allow_nodes_out_of_root` | false | if false, unparented nodes get force-attached under scene root |
| `allow_missing_vertex_position` | false | permit meshes without a position attribute |
| `allow_empty_faces` | false | permit zero-index faces |
| `generate_missing_normals` | false | synthesize vertex normals when absent |
| `open_main_file_with_default` | false | bypass `open_file_cb` for the main file specifically |
| `path_separator` | `'\0'` → replaced with platform separator (`UFBX_PATH_SEPARATOR`, ufbx.c:25519-25521) | relative path joining |
| `node_depth_limit` | 0 = unlimited | fail with `UFBX_ERROR_NODE_DEPTH_LIMIT` past this depth |
| `file_size_estimate` | 0 | progress-reporting hint only |
| `read_buffer_size` | 0 → 0x4000 (16 KiB); clamps up to ≥32 if smaller (25506-25511) | streaming IO chunk size |
| `filename`, `raw_filename` | empty | base path for resolving relative references; derived from each other if one is empty |
| `progress_cb`, `progress_interval_hint` | none / derived: no callback ⇒ interval=SIZE_MAX (never); hint==0 ⇒ 0x4000; hint given ⇒ used verbatim (25523-25529) | progress callback cadence — out of v1 scope |
| `open_file_cb` | none → `ufbx_default_open_file` (stdio-based) (25531-25533) | out of v1 scope (Swift uses Data/URL) but semantics matter for deferred-load driver logic |
| `geometry_transform_handling` | `PRESERVE` (0) | see enum |
| `inherit_mode_handling` | `PRESERVE` (0) | see enum |
| `space_conversion` | `TRANSFORM_ROOT` (0) | see enum |
| `pivot_handling` | `RETAIN` (0) | see enum |
| `pivot_handling_retain_empties` | false | only relevant with `ADJUST_TO_ROTATION_PIVOT` |
| `handedness_conversion_axis` | `UFBX_MIRROR_AXIS_NONE` (0) | axis to mirror when axis conversion flips handedness |
| `handedness_conversion_retain_winding` | false | keep original face winding after a handedness mirror |
| `reverse_winding` | false | force-flip winding of all faces |
| `target_axes` | all-`UNKNOWN` (invalid) → conversion skipped unless valid (`ufbx_coordinate_axes_valid`) | requested output coordinate system |
| `target_unit_meters` | 0 → unit conversion skipped (`> 0.0` gate at 25338) | requested output unit scale |
| `target_camera_axes`, `target_light_axes` | invalid by default → skipped | requested camera/light forward-axis remap |
| `geometry_transform_helper_name`, `scale_helper_name` | empty | naming for synthesized helper nodes |
| `normalize_normals`, `normalize_tangents` | false | renormalize vertex attributes post-load |
| `use_root_transform` + `root_transform` | false / identity | override the scene root's transform outright |
| `key_clamp_threshold` | 0.0 | animation keyframe clamp tolerance (specific interpolation modes) |
| `unicode_error_handling` | `REPLACEMENT_CHARACTER` (0) | see enum |
| `retain_vertex_attrib_w` | false | keep the W component of normal/tangent/bitangent (combined with `retain_dom` to set `uc.retain_vertex_w`, 25284) |
| `retain_dom` | false | build the raw `ufbx_dom_node` tree — out of v1 scope (DOM retention explicitly excluded) |
| `file_format` | `UFBX_FILE_FORMAT_UNKNOWN` (0) → auto-detect | force a format instead of sniffing |
| `file_format_lookahead` | 0 → 0x4000 (16 KiB); floors at `UFBXI_MIN_FILE_FORMAT_LOOKAHEAD` if smaller-but-nonzero (25513-25517) | how many bytes to sniff for format detection |
| `no_format_from_content` / `no_format_from_extension` | false | disable one of the two detection heuristics |
| `obj_search_mtl_by_filename`, `obj_merge_objects/groups`, `obj_split_groups`, `obj_mtl_path`, `obj_mtl_data`, `obj_unit_meters`, `obj_axes` | various | all OBJ-specific — out of v1 scope entirely |

Two `uint32_t _begin_zero`/`_end_zero` sentinel fields bookend the struct; see Quirks for their role.

### `ufbx_error_type` enum values

Full list (ufbx.h:4257-4344): `NONE, UNKNOWN, FILE_NOT_FOUND, EMPTY_FILE, EXTERNAL_FILE_NOT_FOUND,
OUT_OF_MEMORY, MEMORY_LIMIT, ALLOCATION_LIMIT, TRUNCATED_FILE, IO, CANCELLED, UNRECOGNIZED_FILE_FORMAT,
UNINITIALIZED_OPTIONS, ZERO_VERTEX_SIZE, TRUNCATED_VERTEX_STREAM, INVALID_UTF8, FEATURE_DISABLED, BAD_NURBS,
BAD_INDEX, NODE_DEPTH_LIMIT, THREADED_ASCII_PARSE, UNSAFE_OPTIONS, DUPLICATE_OVERRIDE, UNSUPPORTED_VERSION`.
These map naturally onto a Swift `enum FBXError: Error` with associated values for the ones that carry `info`
(filename, index, version number, etc.).

### `ufbx_format_error` (ufbx.c:30598-30633) — human-readable rendering

Format: `"ufbx v<major>.<minor>.<patch> error: <description> (<info>)\n"` (info clause only if
`0 < info_length < UFBX_ERROR_INFO_LENGTH`), followed by up to `UFBX_ERROR_STACK_MAX_DEPTH` lines of
`"%6u:%s: %s\n"` (source_line, function name, per-frame description) from the error stack (only populated if
compiled with `UFBX_ENABLE_ERROR_STACK`). Version numbers are decoded from a single packed
`UFBX_SOURCE_VERSION` integer as `major = v/1000000`, `minor = v/1000%1000`, `patch = v%1000`.

### Coordinate axis encoding

`ufbx_coordinate_axis` values are laid out so `axis >> 1` gives the physical axis (0=X,1=Y,2=Z) and `axis & 1`
gives the sign parity (0=positive,1=negative) — this is exploited directly in `ufbxi_axis_matrix` (permutation +
sign matrix construction, ufbx.c:23660-23673) and in `ufbx_coordinate_axes_valid`'s bitmask check (31478-31490).
Predefined axis-set constants: `ufbx_axes_right_handed_y_up`, `_right_handed_z_up`, `_left_handed_y_up`,
`_left_handed_z_up` (ufbx.c:30348-30359).

### Rotation-order table

`ufbx_euler_to_quat`/`ufbx_quat_to_euler` (31566-31721) hardcode closed-form formulas per each of the 6
`ufbx_rotation_order` permutations (`XYZ, XZY, YZX, YXZ, ZXY, ZYX`) plus the degenerate `SPHERIC` (falls through
to identity/zero in both directions — spherical/"independent of order" rotation isn't actually invertible to
Euler angles). Comments note these were code-generated by `misc/gen_rotation_order.py` /
`misc/gen_quat_to_euler.py` — port as a single generic algorithm (e.g. build the rotation matrix generically from
order permutation) rather than transcribing all 6 branches by hand, though transcribing is also acceptable and
lower-risk.

### Unit rounding table

`ufbxi_pow10_targets[]` (23880-23887): 18 entries, 1e-8 through 1e9 inclusive plus 0.0, used by
`ufbxi_round_if_near` to snap floating unit-scale ratios to "nice" powers of ten within a relative tolerance
(`~9.5e-7`, clamped to an absolute floor `~7.5e-37`) so that FBX files whose `UnitScaleFactor` is e.g.
`0.99999994` (float rounding noise) are treated as an exact match rather than triggering a needless
unit-conversion.

## Quirks & edge cases

- **Options-struct zero-guard** (`ufbxi_check_opts_ptr`, ufbx.c:30313): every opts-taking API validates two
  bookend sentinel fields (`_begin_zero`/`_end_zero`) are actually zero and fails with
  `UFBX_ERROR_UNINITIALIZED_OPTIONS` otherwise. This is ufbx's defense against C callers who `malloc` an opts
  struct without zeroing it (stack garbage in unset fields would silently corrupt behavior otherwise). A Swift
  API with `struct LoadOptions` defaults doesn't need this defense mechanically, but it signals which fields are
  "load-bearing enough to validate."
- **Deferred file loading path** (25206-25244): `ufbx_load_file*` doesn't open the file eagerly; it stores the
  filename and defers to `ufbxi_load_imp`, which decides between the *raw* `ufbx_open_file_ctx` (when
  `open_main_file_with_default` or the callback wasn't overridden) vs. a caller-supplied `open_file_cb`. This
  distinction exists so a user-supplied `open_file_cb` can still be bypassed for just the main file while still
  being used for externally-referenced files.
- **Warning vs. hard failure for unsupported FBX versions** (25299-25301, and again at load-failure time
  25616-25621): an unsupported version does *not* abort loading — ufbx tries anyway and only emits a
  `UFBX_WARNING_UNSUPPORTED_VERSION`. It only becomes a hard `UFBX_ERROR_UNSUPPORTED_VERSION` if loading fails
  for some *other* reason and the error was otherwise going to be reported as the generic `UNKNOWN` — i.e. the
  unsupported-version fact is used as a plausible root-cause explanation for an otherwise-unexplained failure,
  not as an independent gate.
- **`tmp_parse` freed mid-pipeline** (25322-25323): explicitly freed right after `ufbxi_pre_finalize_scene` and
  before `ufbxi_finalize_scene`, as a memory-pressure optimization — implies `ufbxi_finalize_scene` must not
  reference anything still living only in `tmp_parse`. Relevant if porting the memory-budget conscious structure;
  in Swift with ARC this ordering constraint disappears (dead references just get released), but it's a hint
  about *data lifetime dependencies* between the parse and finalize stages worth preserving conceptually.
  Everything else in `tmp_*` buffers is freed uniformly in `ufbxi_free_temp` (25412) after `ufbxi_load_imp`
  returns, whether success or failure.
  Everything in the **result** buffer is preserved via the refcounted `ufbxi_scene_imp` wrapper and only released
  on `ufbx_free_scene`/refcount-drop (30578-30596) — freed with `ufbxi_free_result` (25464) only on load failure.
- **Scene retention as the final allocation** (25379-25405, comment at 25379): explicit comment that the
  `ufbxi_scene_imp` push "must be the final allocation as we copy `ator_result` to `ufbxi_scene_imp`" — i.e. the
  allocator's bookkeeping state (`current_size` etc, later exposed as `metadata.result_memory_used`) is snapshotted
  at that point and any allocation afterward wouldn't be tracked correctly. Not directly relevant to a Swift
  port (no manual arena) but explains why `result_memory_used`/`result_allocs` metadata are computed exactly
  there.
- **Axis conversion default folds into the root node, not a wrapper** (`TRANSFORM_ROOT`, the default
  `space_conversion`): most callers doing straightforward "give me Y-up glTF-style output" get their conversion
  applied by mutating `scene.root_node.local_transform`/`node_to_parent` directly (24969-24980, 24994-25007) —
  i.e. a naive Swift port that ignores `space_conversion` entirely and always mutates the root will match the
  *default* behavior but silently diverge for the two alternate modes.
- **Handedness flip picks exactly one axis to mirror, not the "natural" one**: `ufbxi_transform_to_axes`
  (24951-24966) only mirrors when the *axis remap itself* produces a negative determinant, and the mirror axis is
  whatever the caller specified via `handedness_conversion_axis` — it does not auto-detect the least-disruptive
  axis. If `handedness_conversion_axis == NONE` and a flip is needed, ufbx silently leaves the scene left/right
  handed-inverted (determinant negative) with no diagnostic; only nodes get `adjust_mirror_axis` set if the axis
  actually was specified.
- **Scale-compensation heuristic picks the "most-1.0" axis, not a designated uniform axis**
  (23781-23786): when compensating for `IGNORE_PARENT_SCALE` inherit mode, ufbx doesn't assume scale is uniform
  and just take X; it evaluates X/Y/Z and picks whichever is closest to `1.0` as the representative "size" if it's
  closer than the current best — a defensive heuristic for non-uniform scale that the algorithm doesn't otherwise
  support (comment explicitly: only correct for uniform non-animated scaling; see
  `UFBX_INHERIT_MODE_HANDLING_COMPENSATE` docs, ufbx.h:3692-3696, which say as much).
- **Light direction reset happens unconditionally before the conditional override** (23723-23728 vs.
  23792-23796): every light's `local_direction` is force-reset to FBX's canonical `(0,-1,0)` at the start of
  `ufbxi_update_adjust_transforms` regardless of whether a `target_light_axes` conversion is requested, then
  conditionally overwritten only for single-attribute nodes with a valid target. A light attached to a node with
  *more than one* attribute (`all_attribs.count != 1`) never gets the post-rotation applied even if
  `target_light_axes` was requested — a documented-by-omission edge case worth a unit test.
  Same restriction applies symmetrically to cameras (`node->camera`, 23797-23801).
  Also: `has_camera_transform`/`has_light_transform` are computed once from the *scene-level* target axes and
  applied identically to every qualifying node — there's no per-light/per-camera override.
  Also: for compatibility purposes, `ufbx_get_compatible_matrix_for_normals` (30814) composes
  `node_to_world * geometry_rotation` and re-derives the normal matrix (dropping translation, correcting for
  non-uniform scale/reflection via `ufbx_matrix_for_normals`, which flips sign based on determinant sign rather
  than inverse-transposing translation) — a lower-cost approximation for the common no-shear case, not a full
  inverse-transpose.
- **Quaternion "fix antipodal"/slerp epsilon**: `ufbx_quat_slerp` (31527) treats `omega <= 1.175494351e-38`
  (FLT_MIN) as "identical enough" and returns `a` verbatim rather than doing a division-by-near-zero — this
  guards against `sin(omega)==0` blowing up, not a general small-angle optimization (no lerp fallback for small
  but nonzero angles, unlike some quaternion libraries).
- **Skin vertex matrix blends linear and dual-quaternion skinning per-vertex** (`ufbx_catch_get_skin_vertex_matrix`,
  31928-32018): `skin_vertex.dq_weight` (0=linear blend skinning, 1=fully dual-quaternion, in between = blend of
  both matrices) is a *per-vertex* interpolation weight, not a global deformer setting — each vertex can sit
  anywhere on the LBS/DQS spectrum. The DQ path also fixes antipodal quaternions relative to the *first*
  contributing bone's rotation (`first_q0`, 31952-31959) before accumulating, which is required because
  dual-quaternion blending is only valid when all contributing quaternions are in the same "hemisphere."
  If `total_weight <= 0` (a vertex bound to zero live weight, e.g. all its clusters had `bone_node == NULL`),
  returns the caller-supplied `fallback` matrix or identity — never divides by zero.
- **Blend-shape offsets are sparse and index-sorted**: `ufbx_get_blend_shape_offset_index`
  (32020-32033) binary-searches `shape->offset_vertices` (assumed sorted ascending, one entry per *affected*
  vertex only) rather than storing a dense per-vertex offset array — ports naturally to a Swift sorted-array +
  binary search, or a `Dictionary<UInt32, Int>` if random access matters more than memory.
  `ufbx_add_blend_shape_vertex_offsets` (32062-32081) additionally supports a *sparse per-offset weight*
  (`offset_weights`, may have fewer entries than `offset_vertices` — only weights up to `i < weights.count` are
  applied, remainder implicitly weight 1.0) — a subtle partial-array situation to preserve.
- **N-gon quad-split anti-degenerate heuristic** (32408-32454): note this is *not* a simple "shorter diagonal"
  rule — it's overridden whenever computed face normals from the two candidate triangle pairs disagree in sign
  (`dot_na`/`dot_nb < 0`), which catches non-planar or bowtie quads where the "shorter diagonal" choice would
  otherwise fold the quad inside-out. Any Swift reimplementation must preserve this override, not just the
  distance heuristic, or will differ from ufbx on non-planar quads (a very common real-world case: baked/animated
  meshes, terrain).
- **NURBS basis evaluation clamps `u` to `[t_min,t_max]` at the boundaries and uses modular indexing into control
  points** (`ufbx_evaluate_nurbs_basis`/`_curve`/`_surface`, 32097-32280): control point indices wrap via `%
  count`, supporting periodic/closed NURBS without special-casing the loop — the modulus is applied per control
  point access (`(base+i) % count`), not just at the ends. Out of v1 scope (NURBS tessellation excluded) but the
  *data-model* evaluation functions (`ufbx_evaluate_nurbs_curve/surface`, not tessellation) are cheap pure math
  and could be ported if NURBS pass-through data model is desired even without tessellation.
- **`ufbx_matrix_to_transform`** (31854-31926) recovers scale as **always non-negative per axis** via column
  vector lengths, then reintroduces exactly *one* sign flip (never more than one) on whichever axis has nonzero
  scale, chosen in priority order X, then Y, then Z, when the matrix's determinant is negative — this means a
  matrix produced by mirroring two axes (net-positive determinant) round-trips with a different quaternion than
  the "obvious" one, but always the same *appearance*. Rotation is recovered via a standard branch-on-largest-
  trace-diagonal-term quaternion extraction, with an explicit renormalization safety net if the extracted
  quaternion norm drifts from 1 by more than `UFBX_EPSILON`.
- **`ufbx_matrix_invert`** (31756-31782) returns an all-zero matrix (not a partial/garbage result, not `NaN`s)
  when `|det| <= UFBX_EPSILON`, i.e. singular-matrix inversion is a defined, silent no-crash failure mode —
  callers must check for this (a Swift port might prefer a `nil`-returning or throwing signature to make this
  explicit instead of a silent zero matrix).
- **Progress interval sentinel**: `progress_interval = SIZE_MAX` is used internally to mean "never call the
  progress callback" (25523-25524) — distinct from `0` which would mean "every byte." Preserve this sentinel
  semantic if porting progress reporting (currently out of v1 scope, but note for future).

## Port guidance

**Port faithfully:**
- The `ufbxi_load_imp` step ordering (parse → pre-finalize → finalize → scene-settings update → axis conversion
  → unit conversion → adjust-transforms → geometry-modify → postprocess → full scene update) — this is *the*
  loader driver contract and must be replicated exactly for correctness parity, even though several individual
  steps (OBJ/MTL, geometry cache, skinning evaluation) are out of v1 scope and can be stubbed/skipped.
- `ufbx_find_prop_len`'s defaults-chain lookup semantics (props shadow `props.defaults` recursively) — this is
  core to correct FBX property resolution (class templates + instance overrides) and used pervasively by scene
  construction, materials, and animation subsystems.
- The property/curve/transform evaluation call graph and its flag semantics (`UFBX_EVALUATE_FLAG_NO_EXTRAPOLATION`,
  `UFBX_TRANSFORM_FLAG_INCLUDE_*`) — port as a Swift enum `OptionSet` for flags, and mirror the override →
  connected-prop → curve-evaluation → layer-combine precedence exactly.
  The extrapolation math (`ufbxi_extrapolate_curve`) including the KTime-tick-perfect rounding — subtle
  frame-perfect behavior that's easy to get "almost right" but numerically different if reimplemented from
  first principles; port the tick-based approach, not a naive double-based repeat.
- Cubic Bezier tangent solving (`ufbxi_find_cubic_bezier_t`) — port the Newton-Raphson iteration count and
  epsilon as-is for keyframe-interpolation-exact output.
- Quaternion/matrix math (`ufbx_transform_to_matrix`, `ufbx_matrix_to_transform`, `ufbx_matrix_invert`,
  `ufbx_matrix_for_normals`, `ufbx_euler_to_quat`/`quat_to_euler` per rotation order) — these are pure math, port
  directly; Swift's `simd` types (`simd_quatf`/`simd_double4x4`) could replace `ufbx_matrix`/`ufbx_quat`
  representations but the *singular-matrix-returns-zero*, *sign-flip-priority*, and *rotation-order-specific
  closed forms* behaviors must be preserved for bit-for-bit-ish parity with existing FBX content expectations.
- Axis conversion / unit conversion / adjust-transform algorithms (`ufbxi_transform_to_axes`, `ufbxi_scale_units`,
  `ufbxi_update_adjust_transforms`) — explicitly in scope ("axis conversion metadata", "all pivots/offsets" in
  the transform chain). Port the three `ufbx_space_conversion` modes as distinct code paths (e.g. a Swift enum
  with the transform-application logic as a method), not just the default `TRANSFORM_ROOT` path.
- NGON triangulation (`ufbx_catch_triangulate_face`) including the quad-split heuristic and the (out-of-span)
  `ufbxi_triangulate_ngon` ear-clipping for n≥5 — explicitly listed in v1 scope as "NGON triangulation utility."
- Error type taxonomy (`ufbx_error_type`) and the two-tier error-vs-warning treatment for unsupported versions —
  map to a Swift `enum FBXLoadError: Error` with associated data for `info` (filename/index/version), and throw
  instead of returning `nil` + out-param error.

**Replace with Swift idioms:**
- `ufbx_load_opts` mega-struct with `_begin_zero`/`_end_zero` sentinels and 60+ flat fields → a Swift
  `LoadOptions` struct with sensible property defaults (no zero-guard needed; Swift structs are always
  fully-initialized) — but preserve the *default values* table above exactly, since they encode FBX-domain
  knowledge (e.g. `space_conversion` defaulting to `.transformRoot`, `unicode_error_handling` defaulting to
  replacement-character).
- Error handling: replace `ufbx_error*` out-parameter + `NULL`-return pattern with `throws`; replace
  `ufbx_format_error`'s manual snprintf-based stack rendering with `CustomStringConvertible`/`LocalizedError`
  conformance.
- Streams/allocators/thread pool (`ufbx_stream`, `ufbx_allocator_opts`, `ufbx_thread_opts`, `open_file_cb`) →
  Swift `Data`/`URL`/`FileHandle`, no custom allocator or thread-pool abstraction, per project scope notes.
- Refcounted scene wrapper (`ufbxi_scene_imp`, manual `ufbxi_retain_ref`/`release_ref`) → plain Swift reference
  type (`class Scene`) relying on ARC; no magic-number tagging needed.
- `ufbx_panic`-based "catch" functions (`ufbx_catch_*`) that report bounds violations without crashing → Swift
  `throws` functions, or just rely on Swift's built-in bounds checking / `precondition` since ufbx's whole reason
  for `panic` (avoiding UB in C on bad indices) doesn't apply the same way in memory-safe Swift — though the
  *decision of what counts as a recoverable vs. fatal condition* (e.g. `UFBX_INDEX_ERROR_HANDLING`) is still a
  meaningful design choice to port as an enum controlling loader leniency.

**Skip per v1 scope:**
- OBJ/MTL loading (`ufbxi_obj_load`, `ufbxi_mtl_load`, all `obj_*` options) — entirely out of scope.
- NURBS tessellation (`ufbx_tessellate_nurbs_curve/surface`) — but the pure-math NURBS basis/curve/surface
  *evaluation* functions (not tessellation) are cheap to keep if a data-model passthrough is wanted; not
  required.
- Geometry caches (`ufbx_load_geometry_cache*`, `.pc2/.mc/.xml`, `ufbx_read/sample_geometry_cache_*`) — out of
  scope.
- Animation baking (`ufbx_bake_anim`, `ufbx_baked_anim`/`baked_node`/`baked_element`) — out of scope (v1 wants
  curve evaluation at time t, not a baking helper), though the underlying per-key evaluation math is shared with
  in-scope curve evaluation and already covered above.
- Progress callbacks, custom allocators, threading, DOM retention (`retain_dom`, `ufbx_dom_*`) — all explicitly
  out of scope; skip `ufbx_dom_find*`/`ufbx_dom_as_*_list`/`ufbx_dom_is_array`/`ufbx_dom_array_size`.
- Subdivision (`ufbx_subdivide_mesh`) — out of scope.
- Thread pool callbacks (`ufbx_thread_pool_*`) — out of scope.
- Scene evaluation "catch" bounds-checked vertex accessors (`ufbx_catch_get_vertex_real/vec2/vec3/vec4/w_vec3`)
  are trivial wrappers; only port if a matching `ufbx_vertex_real/vec2/vec3/vec4` typed-accessor abstraction is
  built for the mesh subsystem — otherwise a Swift `Array` subscript already gives the same safety.

**Cross-subsystem dependencies (this subsystem feeds / depends on):**
- **Depends on** the format-detection, string-pool, and FBX-parsing subsystems (`ufbxi_determine_format`,
  `ufbxi_begin_parse`, `ufbxi_read_root`/`ufbxi_read_legacy_root`) for the actual document parse — this
  subsystem only orchestrates *when* they run.
- **Depends on** the scene-finalization subsystem (`ufbxi_pre_finalize_scene`, `ufbxi_finalize_scene`,
  `ufbxi_postprocess_scene`, `ufbxi_modify_geometry`) for building the typed element graph this subsystem's
  `ufbxi_update_scene`/evaluation functions then operate on.
- **Feeds** the node/transform subsystem: `ufbx_evaluate_transform_flags`'s dependency on `inherit_scale_node`/
  `scale_helper`/`is_scale_helper` fields means the node-transform-chain subsystem must set those fields up
  during finalization/`inherit_mode_handling` processing for evaluation to work correctly — these two
  subsystems are tightly coupled and should be designed together.
- **Feeds** the mesh/materials/animation subsystems via `ufbx_find_prop_*`/`ufbx_evaluate_*` — essentially every
  other subsystem's "read a property, possibly animated" need funnels through this file's functions.
- **NGON triangulation** feeds the mesh subsystem's public triangulation utility surface, but its actual ear-
  clipping core (`ufbxi_triangulate_ngon`) lives in the mesh-finalization span (ufbx.c:28489), not here — that
  subsystem's notes should be consulted for the ear-clipping algorithm itself.
