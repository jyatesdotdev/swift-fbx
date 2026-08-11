# Scene Processing Part 2 — Element linking, materials/textures, animation wiring, mesh partitioning

Span: `ufbx.c` lines 20400–22626 (plus cited helpers earlier in the file). This is the second
half of the *finalize* stage. By the time this code runs, elements exist (typed, offset into the
element buffer) and raw connections have been parsed but not yet resolved. This subsystem turns the
flat connection graph into typed cross-references on each element, resolves filenames, partitions
meshes by material, and wires up the animation graph.

## Purpose
Take the parsed element list + connection graph and produce the fully linked `ufbx_scene`:
attach deformers to meshes and clusters to bone nodes, wire blend channels/shapes, build per-face
material assignment and `ufbx_mesh_part` partitions, connect textures to material properties
(file/layered/shader-graph), bind anim curve nodes to element properties, compute stack/layer time
ranges and blend modes, link bind poses, resolve texture/audio/cache filenames and dedup file
content, and impose deterministic sort orders on every derived list. The controlling function is
`ufbxi_finalize_scene()` (20400 region proper starts at 21641); most of the span is either its body
or helpers it calls.

## Key data structures

### `ufbx_mesh_part` (per-material or per-face-group partition of a mesh)
- `index` — partition index (0-based, assigned in usage-order sweep).
- `num_faces`, `num_triangles`, `num_empty_faces`, `num_point_faces`, `num_line_faces` — face
  statistics. CRITICAL LAYOUT INVARIANT: `num_empty_faces`, `num_point_faces`, `num_line_faces` are
  three consecutive `size_t` fields (static-asserted at 13253-13254). `ufbxi_mesh_part_add_face`
  (13255) indexes `(&part->num_empty_faces)[num_indices]` for faces with <3 indices — i.e.
  num_indices 0→empty, 1→point, 2→line. Port this as an explicit switch, not pointer arithmetic.
- `face_indices` (`uint32_t` list) — indices *into the mesh's face array* of the faces in this part.

### `ufbx_mesh.material_part_usage_order` (`uint32_t` list)
Permutation of part indices giving a deterministic draw/iteration order. Sorted so parts that
actually contain faces come first, ordered by the first face index they touch (see
`ufbxi_material_part_usage_less`, 21548). This is a *modified-order guarantee* consumers rely on.

### `ufbxi_tmp_material_texture` (temporary, legacy LayerElement texture patching)
`{ int32_t material_id; int32_t texture_id; ufbx_string prop_name; }`. Sorted by
(material_id, texture_id, prop_name) — comparator `ufbxi_cmp_tmp_material_texture_less` (18620).
A sentinel entry with material_id=-1/texture_id=-1 is appended so the flush loop needs no epilogue.

### `ufbx_material_texture` (final texture binding on a material)
`{ ufbx_texture *texture; ufbx_string material_prop; ufbx_string shader_prop; }`. `material_prop`
is the FBX property name the texture is connected to (e.g. "DiffuseColor"); `shader_prop` starts
equal to it and is later overwritten from shader `prop_bindings`. Sorted by `material_prop`
(`ufbxi_material_texture_less`, 19308) so binary search works in the shader-prop patch pass.

### `ufbx_shader_texture` / `ufbx_shader_texture_input`
Represents a procedural/OSL/3ds-Max shader graph masquerading as a texture. `inputs` is a list of
`{ name, prop, value_*, texture, texture_prop, texture_enabled, texture_enabled_prop,
texture_output_index }`. `prop_prefix` is the interned compound-property prefix under which the
graph's parameters live. `main_texture` / `main_texture_output_index` point to the resolved output.

### `ufbx_texture_file` + `ufbxi_texture_file_entry`
De-duplicated physical files. Keyed by absolute filename pointer (raw blob data pointer), or
relative filename pointer+1 (HACK to keep overlapping abs/rel distinct — 20763). `file_index` on a
texture points into `scene.texture_files`; `UFBX_NO_INDEX` if none.

### `ufbxi_anim_imp` / `ufbx_anim`
`ufbx_anim` bundles `layers` (list of `ufbx_anim_layer*`). `ufbxi_push_anim` (21629) builds one per
stack, one per layer (single-layer), and one empty scene-level fallback.

### `ufbx_anim_prop` (animated property record inside a layer)
`{ ufbx_anim_value *anim_value; ufbx_element *element; ufbx_string prop_name; uint32_t _internal_key; }`.
Layer keeps a sorted array + a bitmask acceleration structure (`_element_id_bitmask`,
`_min_element_id`, `_max_element_id`) for fast "is this element animated in this layer" tests.

### `ufbx_anim_value`
Has `default_value` (vec3), `curves[3]` (X/Y/Z `ufbx_anim_curve*`). Component index derived from
the connection's dst property name (X/d|X→0, Y/d|Y→1, Z/d|Z→2).

## Control flow / algorithms

`ufbxi_finalize_scene()` (21641) runs top to bottom; port in this exact order because later steps
read fields written earlier.

1. **Element buffer materialization (21643-21718).** Copy element bytes out of `tmp_elements` into
   result buffer, build `scene.elements[]` from stored per-element offsets, patch `node->scale_helper`
   pointers via `ufbxi_node_extra.scale_helper_id`. Build `elements_by_type[]` and `elements_by_name[]`
   (name array carries `_internal_key = ufbxi_get_name_key`, then sorted via `ufbxi_sort_name_elements`).

2. **Connection resolution (21682-21684).** `ufbxi_resolve_connections`, `ufbxi_add_connections_to_elements`,
   `ufbxi_linearize_nodes` (defined earlier, outside this span but called here). After this every
   element has `connections_src` / `connections_dst` sorted lists.

3. **Node setup (21723-21785).** For each node: increment parent `children.count` (children.data is
   set to the first child's slot — relies on nodes being contiguous/linearized), record
   `geometry_transform_helper`, force root children to `INHERIT_MODE_NORMAL` under
   TRANSFORM_ROOT+PRESERVE (21736), set `inherit_scale_node` per inherit mode (COMPONENTWISE_SCALE→parent,
   IGNORE_PARENT_SCALE→parent's inherit_scale_node — chained, 21743-21747). Then gather node attributes
   from dst connections whose src type is in [FIRST_ATTRIB, LAST_ATTRIB]: first becomes `node->attrib`
   /`attrib_type`, extras spill to `all_attribs` list; shorthand pointers mesh/light/camera/bone set by
   switch (21768). Fetch node `materials` via `ufbxi_fetch_dst_elements`.

4. **Pose linking (21788-21824).** `pose->bone_poses.data` is transiently an array of
   `ufbxi_tmp_bone_pose {bone_fbx_id, bone_to_world}` (HACK reuse of the pointer). Resolve each fbx_id
   to a NODE element, filter out non-nodes, build real `ufbx_bone_pose`. For bind poses: set
   `node->bind_pose` if unset, and back-fill each connected `ufbx_skin_cluster.bind_to_world` when it
   was all-zero (21817). Sort bone poses by `bone_node->typed_id` (`ufbxi_sort_bone_poses`).

5. **Attribute instances (21829-21834).** For each attribute-type element, fetch its `instances`
   (NODE elements pointing at it) via `ufbxi_fetch_src_elements` (ignore_duplicates=true).

6. **Skin clusters + deformers (21838-21953).**
   - `search_node = uc->version < 7000` — pre-7000 deformers connect through the node, not the mesh,
     so deformer fetches must walk to the node (this flag threads through many `fetch` calls).
   - Each cluster: `bone_node` = dst NODE element.
   - Each skin: fetch `clusters` (SKIN_CLUSTER). If `!connect_broken_elements`, drop clusters with no
     `bone_node` by in-place compaction (21848-21858). Sum `num_weights` (overflow-checked).
   - Determine `num_vertices` = max over connected meshes' `num_vertices` (walks src connections;
     resolves NODE→geometry_transform_helper→mesh, 21870-21885). Pads to largest mesh.
   - Build `skin->vertices` (one `ufbx_skin_vertex` per vertex) and `skin->weights`. Counting pass →
     prefix-sum offsets (`weight_begin`) → scatter pass. `retain_all = !clean_skin_weights`; when
     cleaning, weights ≤ 0 are dropped. `dq_weight` default = 1.0 for DUAL_QUATERNION else 0.0, then
     overwritten from `dq_vertices`/`dq_weights`. `max_weights_per_vertex` recorded. Sort each
     vertex's weight run by descending weight (`ufbxi_sort_skin_weights`, stable, 19345).

7. **Blend deformers/channels (21955-22022).** blend deformer → `channels` (BLEND_CHANNEL). Cache
   deformer → `channel` name + `file`. cache_file → filenames + format (clamp CacheFileType to
   [0, UFBX_CACHE_FILE_FORMAT_MC]). Blend channels: `full_weights` array was accumulated during parse
   (one `ufbx_real_list` per channel, asserted count == blend_channels.count, 21984).
   `ufbxi_fetch_blend_keyframes` (19221) makes one keyframe per connected BLEND_SHAPE.
   `target_weight` default 1.0; if per-index full weight exists it is `full_weights[i]/100`
   (non-Blender) — Blender path (22000) instead divides the whole array by 100 once and assigns it as
   `shape->offset_weights`. Sort keyframes by ascending `target_weight` (19365); `target_shape` =
   last (highest weight) keyframe's shape.

8. **Procedural index buffers + per-mesh finalize (22024-22155).** Allocate shared `zero_indices`
   (all 0) and `consecutive_indices` (0,1,2,...) of sizes `max_zero_indices`/`max_consecutive_indices`.
   `ufbxi_patch_index_pointer` (19285) rewrites sentinel pointers
   (`ufbxi_sentinel_index_zero`/`_consecutive`) on every attribute's index array to these shared
   buffers. Per mesh:
   - Patch all attribute index pointers (positions, normals, colors, crease, face_material,
     face_group, skinned_*, per-uv-set uv/tangent/bitangent, per-color-set color).
   - Generate normals if missing and `generate_missing_normals` (`ufbxi_generate_normals`, 20364:
     builds topology, computes normal mapping + values, sets unique_per_vertex when count==num_vertices,
     shares result into skinned_normal).
   - Assign uv_sets[0]/color_sets[0] as canonical `vertex_uv`/`vertex_color`/tangent/bitangent.
   - Fetch `materials` (`ufbxi_fetch_mesh_materials`, 19175 — dst MATERIAL connections; stops at first
     node level that yields any; search_node walk otherwise).
   - **Material→instance patching (22083-22099):** if an instancing node has fewer materials than the
     mesh, extend its list by appending the mesh's materials for the missing tail.
   - **Mesh parts (22101-22133):** if `retain_mesh_parts`, allocate `max(materials.count,1)` parts.
     - `materials.count <= 1`: part[0] gets whole-mesh stats and `face_indices = consecutive_indices`,
       `material_part_usage_order = zero_indices` (count 1). `face_material` = zero_indices (count
       num_faces) if exactly 1 material, else NULL/empty.
     - `materials.count > 1`: call `ufbxi_finalize_mesh_material` (21561, see below).
   - Fetch deformers: `skin_deformers`, `blend_deformers`, `cache_deformers` (each type), plus
     combined `all_deformers` (`ufbxi_fetch_deformers`, 19199).
   - Ensure `vertex_position.exists` unless `allow_missing_vertex_position` (requires num_indices==0).
   - Track `scene.metadata.max_face_triangles`.

9. **`ufbxi_finalize_mesh_material` (21561).** Given >1 material and allocated parts:
   - For each face: read `face_material[i]`; clamp out-of-range to 0 (rewrites the array!). Add face
     to `parts[mat_ix]` via `ufbxi_mesh_part_add_face`.
   - Allocate each part's `face_indices` (size num_faces), reset per-part `num_faces` counter to 0,
     assign `part->index`.
   - Second face sweep fills `face_indices` (guard `mat_ix < num_parts`).
   - Build `material_part_usage_order` = identity then unstable-sort by
     `ufbxi_material_part_usage_less` (21548): empty parts sort *after* non-empty (comparing counts),
     ties broken by part index; non-empty compared by first face index. (Unstable sort is fine because
     the comparator is a total order via the index tie-break.)

10. **Remaining element wiring (22157-22598).**
    - stereo cameras → left/right (by LeftCamera/RightCamera props).
    - nurbs curves/surfaces → `ufbxi_finalize_nurbs_basis` (20268: computes wrap points from topology,
      t_min/t_max, spans, validity by monotone knots) + surface material.
    - **anim stacks (22176):** fetch `layers`; build `stack->anim`.
    - **anim layers (22183-22261):** fetch `anim_values`; build single-layer `anim`. Then build
      `anim_props`: for each anim_value, for each of its *src* connections with empty src_prop and
      non-empty dst_prop, push an `ufbx_anim_prop {anim_value, element=conn->dst, prop_name=dst_prop,
      key}`; track min/max element_id and set `_element_id_bitmask`. BlendMode enum→(blended,additive):
      0 Additive→(t,t), 1 Override→(f,f), 2 Override Passthrough→(t,f), default (f,f) (22218). Weight =
      Weight prop /100 clamped [0,1] with >0.99999→1 (22239); `weight_is_animated` from prop flag.
      `compose_rotation`/`compose_scale` from Rotation/ScaleAccumulationMode==0. Append a zeroed
      sentinel anim_prop, then sort by `ufbxi_cmp_anim_prop_less` (19294): element ptr, then key, then
      prop_name.
    - **anim values (22263-22290):** default_value from X/Y/Z (and d|X etc.) props. For each dst
      connection from an ANIM_CURVE with empty src_prop, derive component index from dst_prop name
      (pointer-compared against interned `ufbxi_Y`/`ufbxi_d_Y`/`ufbxi_Z`/`ufbxi_d_Z`), set
      `curves[index]`, and override that component's default from the property's real value.
    - **anim curves (22292-22298):** min_time/max_time = first/last keyframe time.
    - **shaders (22300-22314):** fetch bindings; RenderAPI string → shader type (Arnold/OSL/ShaderFX).
    - **materials (22316-22362):** `shader` = src SHADER; shading_model_name lambert/phong →
      FBX_LAMBERT/FBX_PHONG; shader overrides type. Blender PBR heuristic (22329). 3ds-Max ClassID
      pairs (classid_a/classid_b) select physical/OpenPBR/glTF/PBR-metal-rough/PBR-spec-gloss shader
      types and set `shader_prop_prefix` (22335-22357). Then fetch `textures`
      (`ufbxi_fetch_textures`, 19151 — dst TEXTURE connections, empty src_prop; material_prop=shader_prop=dst_prop).
    - **legacy LayerElement texture patch (22364-22466):** for meshes with an `ufbxi_mesh_extra`
      texture array. Builds `ufbxi_tmp_material_texture` records from either `all_same` textures
      (assign to every material) or per-face texture/material pairs (dedup consecutive equal
      material+texture). Append sentinel, sort, then flush per-material runs into `mat->textures`
      *only if the material has no textures yet* (22438). Within a material dedup consecutive equal
      (texture_id, prop_name).
    - `ufbxi_resolve_file_content` (21490): resolve video/audio filenames + dedup embedded content
      by absolute filename (sorted, lower-bound lookup, 21452-21528).
    - **textures (22470-22508):** uv_set from UVSet prop; `video` = dst VIDEO (content copied);
      `ufbxi_finalize_shader_texture` (20537, see below); resolve filenames;
      LAYERED textures fetch `layers` (`ufbxi_fetch_texture_layers`, 19241 — alpha from Texture alpha
      default 1.0, blend_mode from BlendMode) and patch per-layer alpha/blend from mesh_extra arrays
      (blend mode clamped < UFBX_BLEND_OVERLAY, 22500); `ufbxi_insert_texture_file` dedups file.
    - `ufbxi_propagate_main_textures` (20692) + `ufbxi_pop_texture_files`.
    - **material second pass (22514-22537):** sort `textures` by material_prop; `ufbxi_fetch_maps`
      (20124) builds fbx/pbr/features maps via mapping tables (PBR tables = stretch scope). Patch
      `shader_prop` names from shader `prop_bindings` via binary search (22528).
    - display layers→nodes, selection sets→nodes, selection nodes→target node/mesh (+validate
      vertices/edges/faces indices, 22559), constraints (props from *both* src & dst connections via
      `ufbxi_add_constraint_prop`, 20244; pre-7000 inconsistency, 22572), audio layers→clips, lod
      groups (`ufbxi_finalize_lod_group`, 20314).
    - `ufbxi_fetch_file_textures` (20876): populate each texture's `file_textures[]` via an explicit
      stack-based DFS with 3-state marking (INITIAL/STARTED/FINISHED) to handle cyclic shader graphs,
      deduplicating dependencies with `ufbxi_deduplicate_textures` (20838, sort-by-pointer then restore
      original order).
    - Scene-level empty `anim` fallback if no layers (22601).
    - Set `ktime_second`, `bone_prop_size_unit` (version/exporter-dependent, 22608), and
      `bone_prop_limb_length_relative`.

### `ufbxi_finalize_shader_texture` (20537)
Detects whether a texture is really a shader graph: 3ds-Max ClassIDa/b combine to a 64-bit id;
MaxTexture string or classid select SELECT_OUTPUT / OSL / UNKNOWN types. Extracts shader name/source
props, finds the compound `prop_prefix` (`ufbxi_shader_texture_find_prefix`, 20429 — searches
suffixes " Parameters/Connections", shader name, "3dsMax|parameters"; pre-7000 has no compound props
so it looks before the last `|`). Iterates props under the prefix building `inputs`, recognizing
`_map`/`.shader` (→texture_prop) and `.connected`/`Enabled` (→texture_enabled_prop) modifiers.
`ufbxi_file_shaders` table (20487) maps known image shaders (ai_image, OSLBitmap*, UberBitmap*) to a
filename input, promoting the shader back to a FILE texture. `ufbxi_update_shader_texture` (20496)
re-resolves input props/values/textures and SELECT_OUTPUT main texture.

### `ufbxi_modify_geometry` (21165) / `ufbxi_postprocess_scene` (21334)
Applies scale, mirror axis, winding flip, and geometry-transform baking to meshes/blend
shapes/curves/surfaces (helpers `ufbxi_mirror_vec3_list` 21018, `ufbxi_scale_vec3_list` 21033,
`ufbxi_transform_vec3_list` 21049, `ufbxi_flip_winding` 21109). Not part of `finalize_scene` but in
this span and part of the same pipeline. Winding flip (21109) reverses index order per face keeping
the first vertex, remaps edges through an index_mapping table, and shares/duplicates consecutive
index buffers carefully. Resets Geometric* props to identity unless PRESERVE handling (21310).

## Format details
- Version thresholds: `search_node = version < 7000` (21836) — pre-7000 deformers/materials/textures
  connect via the node; post-7000 via the attribute. Constraint props are on both connection
  directions pre-7000 (6100 uses "PO" connections). `bone_prop_size_unit`: version<6000→1.0,
  Blender-binary→33.0, Blender-ASCII→1.0, else 100/3 (≈33.333) (22608). `bone_prop_limb_length_relative`
  = false only for Blender-ASCII.
- `ortho_size_unit` (postprocess 21351): 1/geometry_scale for Blender-binary else 30.0.
- BlendMode enum for anim layers: 0 Additive, 1 Override, 2 Override Passthrough.
- CacheFileType clamped to [0, UFBX_CACHE_FILE_FORMAT_MC].
- Layered-texture blend mode clamped to < UFBX_BLEND_OVERLAY when patched from mesh extra (22500);
  in `ufbxi_fetch_texture_layers` it's read via find_enum bounded to UFBX_BLEND_OVERLAY.
- Blend weight full-weights divided by 100 (percent→ratio).
- Layer weight = Weight/100 clamped [0,1], >0.99999 snaps to 1.0.
- 3ds-Max shader ClassID pairs (material, 22337-22356) and shader_texture classids (20548-20551):
  keep these exact 32/64-bit constants; cite lines rather than reproduce.
- `ufbxi_file_shaders` table at 20487 (5 entries) — cite, don't inline.
- `ufbxi_constraint_props` table at 20231 (10 entries mapping FBX prop names → constraint roles).
- Texture-file dedup key HACK: relative filename pointer offset by +1 (20769) to avoid colliding with
  an equal absolute filename.

## Quirks & edge cases
- **face_material clamping mutates the mesh** (21579, 21604): out-of-range material index rewritten to
  0 in `face_material.data`. Port must clamp both in the counting AND the fill sweep.
- **Mesh-part fast path for ≤1 material** uses *shared* `consecutive_indices`/`zero_indices` buffers
  (22108-22130) — never mutate these per-mesh. Only >1 material allocates real per-part arrays.
- **Empty/point/line face counting** via consecutive-field pointer indexing (13263). Reproduce with a
  switch on num_indices (0/1/2).
- **usage-order sort** places empty parts last, ties by index; enables stable "draw non-empty first".
- **Duplicate connection warnings** (19058/19096): ignore_duplicates path uses `tmp_element_flag[]`
  set/clear guard and emits UFBX_WARNING_DUPLICATE_CONNECTION. Flags must be cleared afterward.
- **Skin cluster bind_to_world back-fill from bind pose** only when currently all-zero (21817).
- **Skin vertices padded to the largest instanced mesh** (21883), not the deformer's own vertex count.
- **clean_skin_weights** drops zero/negative weights; DQ weight default depends on skinning method.
- **Weights sorted descending** per vertex (stable) — consumers assume weight[0] is dominant.
- **Blender full-weights path** (22000): divides the entire shared array in place exactly once (i==0),
  optionally duplicating it first if `retain_dom`; assigns to `shape->offset_weights`. Non-Blender
  divides each keyframe target individually.
- **Legacy texture flush only fills materials that have no textures** (22438); otherwise the pushed
  temp material_textures are popped/discarded (22444).
- **Material texture shader_prop patch** relies on `textures` being sorted by material_prop and uses
  lower-bound + forward scan while pointers match (22528) — pointer-equality of interned strings.
- **Shader-texture prop_prefix may be empty** → shader is abandoned (kept but unused, "leaked" into
  result buffer, 20617). Also, if a known file-shader matches, texture is demoted back to FILE.
- **main-texture propagation needs 2^(N-1) passes** approximated by shifting the shader count mask
  (20694); then cyclic main textures are broken (set to NULL, 20716) and material texture refs are
  redirected to resolved main textures (20742).
- **file_textures DFS** uses tmp_parse buffer reuse and 3-state marking to survive cyclic shader
  graphs; single-dependency shortcut copies the pointer instead of allocating (20939).
- **anim_value component index** derived by pointer comparison against interned name atoms, and both
  plain (X) and d|X forms are checked; default value overridden per component (22267-22287).
- **anim layer sentinel prop** (zeroed, 22252) appended so iteration needs no bounds check; count
  excludes it.
- **Node children.data points at the first child's slot in the linearized node pointer array**
  (21727) — depends on `ufbxi_linearize_nodes` having laid children contiguously.
- **Constraint props scanned in both directions** for pre-7000 compatibility (22572).
- NURBS basis validity requires monotonically non-decreasing knots (20302).

## Port guidance
- **Faithfully port:** all the linking/sorting logic and the exact sort comparators (they define
  ufbx's deterministic output that tests depend on). Reproduce mesh-part statistics, usage-order sort,
  skin weight prefix-sum + descending sort, blend keyframe ordering, anim_prop ordering, material
  texture material_prop ordering, and the file-texture DFS dedup. Reproduce all version/exporter
  constant tables (cite lines). Reproduce the clamps/snaps (layer weight, blend mode, cache type,
  face_material) exactly.
- **Swift idioms:** replace `tmp_stack` push/push_pop with building `[T]` arrays; replace
  `tmp_element_flag` guard with a `Set<ElementId>` or `Bool` array. Replace the consecutive/zero
  shared index sentinel buffers with an enum indirection (`enum IndexSource { case zero; case
  consecutive; case explicit([UInt32]) }`) or lazily materialize — but preserve the "≤1 material uses
  shared buffer" semantics so behavior (and identity of `face_material`) matches. Use throwing funcs
  in place of `ufbxi_check`. Model `ufbx_mesh_part`'s empty/point/line counters as named fields and a
  `switch` in add-face rather than the pointer-index hack. Model anim_value `curves[3]` as a fixed
  3-tuple or small array indexed by component enum.
- **Stretch/skip per scope:** PBR mapping tables (`ufbxi_fetch_maps` pbr side, glossiness remaps) are
  stretch — port the FBX (non-PBR) map fetch first. Cache deformers/files and NURBS finalize are OUT
  of v1 (geometry caches, NURBS tessellation) — you still need the data-model passthrough but can skip
  the format/tessellation logic. Constraint solving is OUT (data passthrough only) — keep
  `ufbxi_add_constraint_prop` role assignment. Audio clips/layers, stereo cameras, LOD groups,
  display/selection layers are low priority; wire the pointers if the DOM exposes them.
- **Cross-subsystem dependencies:**
  - DEPENDS ON (upstream, earlier in file / other subsystems): `ufbxi_resolve_connections`,
    `ufbxi_add_connections_to_elements`, `ufbxi_linearize_nodes`, the element-buffer/offset scheme,
    `ufbxi_get_element_extra` (mesh/texture/node extras carrying LayerElement textures, layered-texture
    alphas/blend modes, scale_helper ids, blend full_weights), `ufbxi_find_*_connections`,
    interned name atoms (`ufbxi_X`, `ufbxi_d_Y`, `ufbxi_BlendMode`, etc.), the prop system
    (`ufbx_find_*`), and mesh reading (num_faces/num_*_faces, sentinel index pointers).
  - FEEDS (downstream): `ufbxi_update_scene`/transform evaluation (needs inherit_scale_node,
    geometry transforms, node attribs), animation evaluation (needs anim_props sorted arrays + layer
    bitmask, anim_value curves/defaults, stack/layer anim bundles), mesh consumers (material_parts,
    material_part_usage_order, face_material), skin/blend evaluation (skin vertices/weights, blend
    keyframes/target_shape/offset_weights), and material/texture query APIs (fbx/pbr maps,
    file_textures, texture_files).
