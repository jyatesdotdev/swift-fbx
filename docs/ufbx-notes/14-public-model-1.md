# Public data model, part 1 (ufbx.h lines 1-3200)

## Purpose
This span defines the front half of ufbx's public C data model: basic math/string/list
types, the DOM (raw node-tree) types, the generic property system (`ufbx_prop`/`ufbx_props`),
the element base "class" and connection graph, `ufbx_node` and its full FBX transform chain,
mesh geometry + all vertex attribute layers, and materials/textures/shaders. It also covers
lights, cameras, bones/empties, curve/surface node attributes (NURBS, line curves — out of
v1 scope but present in the header), LOD groups, all deformer types (skin, blend shape, cache),
and the start of the animation model (`ufbx_anim`, `ufbx_anim_stack/layer/value`, keyframes,
tangents) which continues past line 3200. This is the blueprint for SwiftFBX's public types.

## Key data structures

### Basic types (ufbx.h:273-396)
- `ufbx_real` — `double` by default, `float` if `UFBX_REAL_IS_FLOAT`. Swift: pick one concrete
  `Double` (recommend `Double` for parity/precision; consider a generic or typealias).
- `ufbx_string` (282): non-owning `(data: UnsafePointer<CChar>, length: Int)`, NUL-terminated
  UTF-8. Swift: plain `String`, computed at parse/copy time — no need to preserve the raw
  pointer semantics.
- `ufbx_blob` (290): raw `(data, size)` byte view. Swift: `Data` (likely with `Data(bytesNoCopy:)`
  when zero-copy matters, otherwise a copy).
- `ufbx_vec2/vec3/vec4/quat` (298-335): union of named fields (`x,y,z,w`) and a `v[N]` array —
  a C idiom for dual access; Swift should just be a `struct` with named fields (`x,y,z`) and,
  if array access is wanted, a computed subscript, not a memory union.
- `ufbx_rotation_order` (341): enum `XYZ, XZY, YZX, YXZ, ZXY, ZYX, SPHERIC`. NOTE the doc
  comment: the name lists axes in *application* order, not multiplication order, e.g. XYZ
  order actually multiplies as `Z*Y*X`. `SPHERIC` is a legacy/unsupported mode (TODO in ufbx
  itself — "figure out what spheric rotation order is").
- `ufbx_transform` (357): explicit T/R/S with **quaternion** rotation (not Euler) — this is
  the canonical way ufbx stores/composes transforms internally.
- `ufbx_matrix` (367-380): 4x3 affine matrix (no projective row), column-major-ish layout:
  `cols[0..2]` are basis vectors, `cols[3]` is translation; also exposed as `m00..m23` named
  fields and a flat `v[12]`. Swift: a `simd_double4x3`-like custom struct, or wrap
  `simd_double3x3` + translation vector; avoid the union-of-three-views C idiom.
- List types: `UFBX_LIST_TYPE` macro (208-216) generates `struct { T *data; size_t count; }`
  for every `ufbx_X_list` (bool, uint32, real, vec2/3/4, string, and later every element-pointer
  list). This is the single most pervasive C-ism in the whole API — **every** "array" in ufbx
  is one of these non-owning slices into a bump-allocated arena owned by `ufbx_scene`. Port
  guidance: replace uniformly with Swift `Array<T>` (value semantics, ARC-managed) or, for
  index-lists into shared value arrays (a very common vertex-attribute idiom, see below),
  possibly a wrapper type when the parallel index/value relationship must be preserved
  structurally.
- `UFBX_NO_INDEX` (396): sentinel `UINT32_MAX` meaning "no such index". Appears throughout
  (`vertex_first_index`, cluster maps, texture `file_index`, etc). Swift: replace with `nil`
  in an `Int?` or `UInt32?` — do not port the sentinel value itself.

### DOM (398-439)
- `ufbx_dom_value_type` (400): tags a raw FBX property/array value: NUMBER, STRING, BLOB,
  ARRAY_I32/I64/F32/F64/ARRAY_BLOB, ARRAY_IGNORED (arrays present in the file but not retained,
  e.g. because DOM retention wasn't requested for that node — see `ufbx_load_opts`, outside
  this span).
- `ufbx_dom_node` (435): raw FBX node tree — `name`, `children` (list of node pointers),
  `values` (list of `ufbx_dom_value`, one per node's inline attributes). This is the retained
  DOM tree, a lossless mirror of the parsed file structure, orthogonal to the typed scene
  graph. **Port guidance**: entire DOM retention is OUT of v1 scope per the port brief
  ("DOM retention option" excluded) — skip implementing `ufbx_dom_node`/`ufbx_dom_value`
  fully; keep the note that `ufbx_element.dom_node` (772) is `nullable` and only populated if
  `ufbx_load_opts.retain_dom` is set elsewhere.

### Properties (441-572)
- `ufbx_prop_type` (456): UNKNOWN, BOOLEAN, INTEGER, NUMBER, VECTOR, COLOR,
  COLOR_WITH_ALPHA, STRING, DATE_TIME, TRANSLATION, ROTATION, SCALING, DISTANCE, COMPOUND,
  BLOB, REFERENCE. This is the FBX property *type tag* as read from the file's
  `P: "Name", "Type", "SubType", "Flags", value...` records (parsing itself is a different
  subsystem span). Per the doc comment (452-455) **all** data fields are populated regardless
  of declared type — `value_real` and `value_int` both hold a numeric value if type is
  INTEGER, so callers never need to switch on `type` just to read a value.
- `ufbx_prop_flags` (480-539): bitflags — `ANIMATABLE`, `USER_DEFINED`, `HIDDEN`,
  `LOCK_X/Y/Z/W`, `MUTE_X/Y/Z/W`, `SYNTHETIC` (ufbx fabricated this prop because an
  `ufbx_anim_prop` referenced it but it wasn't in the file — value may come from templated
  defaults), `ANIMATED` (has at least one curve in some layer), `NOT_FOUND` (sentinel used by
  `ufbx_evaluate_prop()`), `CONNECTED` (see `ufbx_element.connections_dst` for the actual
  link), `NO_VALUE` (value is undefined/zero), `OVERRIDDEN` (user override via
  `ufbx_anim.prop_overrides`), and `VALUE_REAL/VEC2/VEC3/VEC4/INT/STR/BLOB` — the *actual*
  value-shape flags, mutually exclusive for the numeric ones but `STR` can coexist with a
  vector flag (rare case: a string defines the unit for a vector, e.g. distance properties).
  Swift: this maps naturally onto an `OptionSet`, but consider whether a property value would
  be better modeled as a Swift `enum` with associated values keyed by the VALUE_* flags rather
  than a flags+union pair (a case for `case vector3(Double,Double,Double)`, etc.), since Swift
  enums make the "one value shape" invariant compiler-checked instead of convention-checked.
- `ufbx_prop` (542-560): `name`, an opaque `_internal_key` (hash used for fast property-name
  binary search — internal only, do not expose), `type`, `flags`, and value fields
  `value_str`/`value_blob`/`value_int`/union-of-real,vec2,vec3,vec4 (`value_real_arr[4]` is
  the raw storage; `value_real/vec2/vec3/vec4` alias into it). Because all fields are always
  populated, a Swift port can synthesize one associated-value enum case per property at parse
  time instead of keeping all fields live simultaneously.
- `ufbx_props` (567-572): a **sorted-by-name** `ufbx_prop_list` (`props`) with `num_animated`
  (count of leading/trailing? — actually just a count, used to know how many entries have
  `ANIMATED` set for iteration shortcuts) and a `nullable defaults` pointer chaining to a
  parent props table (typically the FBX template defaults for that object class, or in
  evaluated scenes, the pre-evaluation original props — see `ufbx_evaluate_scene`, later
  span). Lookup is a **lower-bound binary search by name** across the chain: `props` first,
  then `props->defaults`, then `defaults->defaults`, etc. See `ufbx_find_prop_concat` at
  ufbx.c:30712-30728 for the canonical multi-level chained lookup shape (uses
  `ufbxi_macro_lower_bound_eq` over the sorted array, then falls through to `props->defaults`
  if not found — same pattern is used by every `ufbx_find_prop*` function). Port guidance: in
  Swift, prefer a `Dictionary<String, Prop>` per props table (O(1) not O(log n)) chained via
  an optional `defaults: Props?` parent — same semantics, better ergonomics, and the sorted-
  array/binary-search machinery (`_internal_key`, `ufbxi_macro_lower_bound_eq`) is purely a
  C performance detail that should NOT be ported.

### Elements & connections (574-793)
- `ufbx_element_type` (694-744): one tag per concrete element struct — UNKNOWN, NODE, MESH,
  LIGHT, CAMERA, BONE, EMPTY, LINE_CURVE, NURBS_CURVE, NURBS_SURFACE, NURBS_TRIM_SURFACE,
  NURBS_TRIM_BOUNDARY, PROCEDURAL_GEOMETRY, STEREO_CAMERA, CAMERA_SWITCHER, MARKER, LOD_GROUP,
  SKIN_DEFORMER, SKIN_CLUSTER, BLEND_DEFORMER, BLEND_CHANNEL, BLEND_SHAPE, CACHE_DEFORMER,
  CACHE_FILE, MATERIAL, TEXTURE, VIDEO, SHADER, SHADER_BINDING, ANIM_STACK, ANIM_LAYER,
  ANIM_VALUE, ANIM_CURVE, DISPLAY_LAYER, SELECTION_SET, SELECTION_NODE, CHARACTER,
  CONSTRAINT, AUDIO_LAYER, AUDIO_CLIP, POSE, METADATA_OBJECT. `FIRST_ATTRIB`/`LAST_ATTRIB`
  mark the contiguous sub-range (MESH..LOD_GROUP) that can be a node's `attrib`. In Swift this
  is the natural discriminator for an `enum Element` with associated values per case, OR a
  class-hierarchy-free approach: a protocol `ElementBase` + concrete structs/classes, with the
  type tag derivable from the Swift case/type itself (no need to port the raw int enum at all
  if using an enum-with-payload design — flag this as a design decision).
- `ufbx_connection` (749-754): arbitrary `src`/`dst` element pointers plus optional
  `src_prop`/`dst_prop` names — this is the *generic graph edge* underlying every specific
  relationship (parent/child, mesh↔deformer, material↔texture, anim curve↔property, etc).
  Every element carries both `connections_src` and `connections_dst` (770-771) lists. This
  low-level graph is what specific typed fields (like `ufbx_node.parent`, `ufbx_mesh.materials`)
  are pre-resolved *views* over — a scene-construction subsystem (different span) walks
  `connections_*` to populate the typed fields. Port guidance: keep a raw connection list
  internally (needed to resolve everything else), but the *public* Swift API should almost
  never need to expose it directly — prefer the typed accessors.
- `ufbx_element` (763-774): the shared "base class" — `name`, `props`, `element_id` (stable
  within one load, invalidated by re-export — NOTE for anyone diffing files), `typed_id` (index
  within its type's array, e.g. `scene.meshes[mesh->typed_id] == mesh`), `instances` (nodes
  that reference this element — elements like meshes are shared/instanced, nodes are not),
  `type`, `connections_src/dst`, `dom_node` (nullable), and back-pointer `scene`. C models
  "inheritance" via the recurring
  `union { ufbx_element element; struct { <same first N fields> }; }` idiom at the top of every
  concrete struct (e.g. ufbx_node 844-850, ufbx_mesh 1257-1264) — this lets code either treat
  any element as `ufbx_element*` or access common fields directly without a cast. **This union
  trick has no Swift equivalent and shouldn't be ported as-is.** Recommended Swift shape: a
  `class Element` (or protocol) holding the common fields, with concrete types either
  subclassing it (if reference identity/shared instancing matters — it does, per
  `instances`/`connections`) or using a protocol with a required `var base: ElementBase`.
  Given the port brief's note "reference types where identity matters", classes are likely
  right here: elements are graph nodes with pointer identity, shared instancing, and mutation
  during evaluation.

### Nodes & the transform chain (795-996)
- `ufbx_inherit_mode` (802-826): NORMAL (`R*S*r*s`, i.e. child's full parent-to-world times
  local), IGNORE_PARENT_SCALE ("segment scale compensate" in Maya/3ds Max — parent scale is
  dropped from the child's composition; child's own translation is still scaled by parent's
  *inherited* scale though), COMPONENTWISE_SCALE (parent and child scale multiply
  component-wise rather than via full matrix composition — avoids shear from non-uniform
  parent scale + rotated child). The header gives exact formulas in comments (804-821); the
  real implementation is `ufbxi_update_node` or its downstream matrix code (ufbx.c:22955-23042,
  see Control Flow below).
- `ufbx_mirror_axis` (829-839): NONE/X/Y/Z — used for handedness/axis-conversion mirroring
  (see Quirks: mirrors flip translation and swap two rotation quaternion components, ufbx.c
  22745-22756).
- `ufbx_node` (844-996): the transform-hierarchy node.
  - Hierarchy: `parent` (nullable only for root, or if
    `ufbx_load_opts.allow_nodes_out_of_root`), `children`.
  - Attachment: `mesh`/`light`/`camera`/`bone` typed convenience pointers (nullable — only one
    is normally set), `attrib` (generic first-attribute pointer), `all_attribs` (rare
    multi-attribute case), `attrib_type`.
  - Helper nodes: `geometry_transform_helper` and `scale_helper` — **synthetic nodes ufbx
    injects** when geometry transforms or scale-compensation can't be represented purely as
    node-local math (see Quirks — `UFBX_GEOMETRY_TRANSFORM_HANDLING_HELPER_NODES` and
    `UFBX_INHERIT_MODE_HANDLING_HELPER_NODES`, load-option-gated features in a different span
    but the *fields* live here); `is_geometry_transform_helper`/`is_scale_helper` flags mark
    these synthetic nodes so consumers can filter them out if desired.
  - `local_transform`/`geometry_transform` (T/R/S, quaternion rotation) — geometry_transform
    applies only to the attached attribute (mesh geometry), not to children.
  - `inherit_scale`/`inherit_scale_node`: precomputed helper state for
    COMPONENTWISE_SCALE/IGNORE_PARENT_SCALE resolution — see Control Flow.
  - `rotation_order`/`euler_rotation`: the *raw* Euler angle representation for consumers who
    want it (ufbx internally always uses quaternions for composition, matching
    `local_transform.rotation`).
  - Derived matrices: `node_to_parent`, `node_to_world`, `geometry_to_node`,
    `geometry_to_world`, `unscaled_node_to_world` (world transform with all ancestor *and
    self* scaling stripped — used to implement IGNORE_PARENT_SCALE/COMPONENTWISE_SCALE
    correctly without recomputing the whole chain).
  - `adjust_pre_translation/adjust_pre_rotation/adjust_pre_scale/adjust_post_rotation/
    adjust_post_scale/adjust_translation_scale/adjust_mirror_axis` — ufbx-internal correction
    factors folded into the transform to implement **axis/unit conversion** (target axes/unit
    scale requested via load options) without needing a separate global root transform.
    `has_adjust_transform` gates whether these are non-identity. This is central to the port
    brief's "axis conversion metadata" requirement — the actual computation of these values
    happens in scene-setup code (~ufbx.c:23750+, a different span) but *how they're consumed*
    is entirely in `ufbxi_get_transform`/`ufbxi_get_rotation`/`ufbxi_get_scale`/
    `ufbxi_get_geometry_transform` (see Control Flow).
  - `materials`: per-*instance* (per-node) material list — can differ from
    `mesh->materials` when one mesh is instanced by multiple nodes with different material
    assignments (explicit NOTE at 953-956; this is a real FBX authoring pattern).
  - `bind_pose`: nullable link to an `ufbx_pose` (rest pose override, pose subsystem elsewhere).
  - `visible`, `is_root`, `has_geometry_transform`, `use_rotation_space` (whether
    RotationOrder/PreRotation/PostRotation should even be applied — see quirk below),
    `has_adjust_transform`, `has_root_adjust_transform`, `is_geometry_transform_helper`,
    `is_scale_helper`, `is_scale_compensate_parent`, `node_depth` (root = 0).

### Vertex attributes & mesh (998-1378)
- `ufbx_vertex_attrib` (1007-1025) and its four typed twins `ufbx_vertex_real/vec2/vec3/vec4`
  (1028-1073) are **the** core geometry idiom: `exists` (bool — attribute may be entirely
  absent, check this rather than assuming empty list == absent, though empty implies false),
  `values` (the deduplicated value pool), `indices` (one uint32 per mesh corner/index, always
  sized `mesh->num_indices` when `exists`, pointing into `values`), `value_reals` (component
  count redundant with the typed struct but present for the generic `ufbx_vertex_attrib` view),
  `unique_per_vertex` (true iff every corner of a given logical vertex maps to the same
  `values` entry — lets consumers safely read "per vertex" via
  `values[indices[vertex_first_index[vertex]]]`), and `values_w` (optional parallel 4th
  component array, same length as `values`, only populated for normal/tangent/bitangent when
  `ufbx_load_opts.retain_vertex_attrib_w` is set — off by default). **Invariant to port
  faithfully**: `indices.count == mesh.num_indices` whenever `exists == true`; `values.count`
  is attribute-specific (can be smaller than `num_indices`, e.g. shared per-vertex normals, or
  equal to it for split/seam attributes). Swift shape: rather than four near-identical parallel
  structs (`ufbx_vertex_real/vec2/vec3/vec4`), use one generic
  `struct VertexAttribute<Value> { var values: [Value]; var indices: [UInt32]; var
  uniquePerVertex: Bool; var w: [Double]? }` with `exists` folded into an `Optional` at the
  mesh-field level (`var normal: VertexAttribute<Vector3>?`) — this is a clean case where the
  C parallel-struct duplication (driven by lack of generics) should NOT be ported 1:1.
- `ufbx_uv_set`/`ufbx_color_set` (1076-1096): named layer wrapper — `name`, `index` (layer
  ordinal), plus the vertex attributes for that layer (UV/tangent/bitangent, or color). The
  *first* UV/color set's data is duplicated into `mesh.vertex_uv`/`vertex_tangent`/
  `vertex_bitangent`/`vertex_color` for convenience (explicit NOTE at 1318-1319) — Swift should
  probably not duplicate storage; expose `mesh.uvSets.first` as the "primary" set instead of
  literally copying data twice.
- `ufbx_edge` (1099-1104): a pair of **mesh index** values (not vertex indices) — `a,b` into
  `mesh.vertex_indices`/any per-index attribute, not into `mesh.vertices`. May be entirely
  absent (`num_edges == 0`) even in valid meshes if the file lacked edge adjacency data (1274).
- `ufbx_face` (1108-1118): `{index_begin, num_indices}` — a contiguous slice of the mesh's
  flat index array. Explicit warning (1111): `num_indices` may be `< 3`, meaning **invalid
  polygon** — ufbx does not filter these out at load time (TODO #23 acknowledged in the
  source); consumer code must handle degenerate faces defensively. `mesh.num_empty_faces` /
  `num_point_faces` / `num_line_faces` classify these (0/1/2-index faces respectively).
- `ufbx_mesh_part` (1121-1140): one bucket of faces sharing a material (or a face group),
  giving `num_faces`, `num_triangles` (post-triangulation count for this subset alone),
  degenerate-face counts, and `face_indices` (indices into `mesh.faces[]`, length ==
  `num_faces`).
- `ufbx_face_group` (1142-1147): a numeric `id` + `name` — FBX polygon groups (distinct from
  material assignment); `mesh.face_group[]` (per-face) indexes into `mesh.face_groups[]` via
  `mesh.face_group_parts` bucketing (parallel structure to `material_parts`).
- Subdivision types (1149-1207: `ufbx_subdivision_weight[_range]`, `ufbx_subdivision_result`,
  `ufbx_subdivision_display_mode`, `ufbx_subdivision_boundary`) — **OUT of v1 scope**
  (subdivision surface evaluation excluded per port brief); the *display mode/boundary enum
  fields* on `ufbx_mesh` (subdivision_preview_levels etc, 1358-1362) should still be parsed/
  exposed as passthrough metadata since they're just FBX properties, but the actual Catmull-
  Clark evaluation (`ufbx_subdivide_mesh`, elsewhere) should be skipped.
- `ufbx_mesh` (1257-1378): the full mesh struct.
  - Counts: `num_vertices` (logical points), `num_indices` (flattened corners = sum of all
    `faces[i].num_indices`), `num_faces`, `num_triangles` (post-fan-triangulation count, see
    NGON triangulation utility — in scope), `num_edges`, `max_face_triangles`, plus the
    degenerate-face counts mirrored from mesh_part.
  - Per-face arrays (`faces`, `face_smoothing`, `face_material` → index into
    `mesh.materials[]`/`node.materials[]`, `face_group` → index into `mesh.face_groups[]`,
    `face_hole`): all sized `num_faces` when present, empty list when the source data doesn't
    define that channel (e.g. no smoothing groups in file ⇒ `face_smoothing.count == 0`, not
    an error).
  - Per-edge arrays (`edges`, `edge_smoothing`, `edge_crease`, `edge_visibility`): sized
    `num_edges`.
  - `vertex_indices` (size `num_indices`, values `< num_vertices`) + `vertices` (size
    `num_vertices`, raw positions) + `vertex_first_index` (size `num_vertices`, first index
    referencing each vertex, or `UFBX_NO_INDEX` if the vertex is literally unused — can happen
    with orphaned/unreferenced verts in some exporters).
  - The "uniform" attribute view `vertex_position` duplicates `vertices`/`vertex_indices` as a
    `ufbx_vertex_vec3` so callers can use one consistent accessor pattern for position and all
    other attributes (1296-1299, 1310).
  - `vertex_normal/uv/tangent/bitangent/color/crease`: all optional
    (`exists==false`/empty when absent), each documented with which mesh feature triggers
    fallback generation (`vertex_normal` "always defined if generate_missing_normals").
  - `uv_sets`/`color_sets`: full multi-layer lists (first entry mirrors the singular fields).
  - `materials` (mesh-level, "can be wrong for per-instance materials" — prefer
    `node.materials`), `face_groups`, `material_parts`, `face_group_parts`,
    `material_part_usage_order` (order material_parts by first face referencing them — exists
    purely for FBX-SDK-compatible ordering expectations some importers rely on).
  - `skinned_is_local`/`skinned_position`/`skinned_normal`: precomputed post-skin-deformation
    positions/normals. `skinned_is_local == true` for **non-skinned** meshes (the "skinned"
    arrays are literally aliases of the static ones, still in local/geometry space) — caller
    must apply `geometry_to_world` manually in that case; skinned meshes have this already
    baked to a consistent space (need to verify exact space when porting the deformer-
    evaluation subsystem, flagged below).
  - `skin_deformers`/`blend_deformers`/`cache_deformers`/`all_deformers`: element lists (note
    cache deformers are OUT of scope for v1).
  - `reversed_winding`, `generated_normals` (true if normals were synthesized rather than read
    — from missing-normal generation, post-skin/tessellation/subdivision recompute),
    `from_tessellated_nurbs` (NURBS tessellation is OUT of scope; if ever encountered on an
    input mesh flag it as not directly produced by SwiftFBX v1, but the field may still appear
    on meshes from files with tessellated NURBS baked in by other tools — treat as opaque bool).

### Lights, cameras, bones, empties (1380-1665)
- `ufbx_light_type` (1381-1400): POINT, DIRECTIONAL, SPOT, AREA, VOLUME. `light->color *
  light->intensity` is the recommended combined value; **intensity units quirk**: ufbx divides
  the raw FBX `"Intensity"` property by 100 (see Quirks — light intensity is stored 100x by
  DCC tools before export).
- `ufbx_light_decay` (1403-1412): NONE(1), LINEAR(1/d), QUADRATIC(1/d², physically accurate),
  CUBIC(1/d³).
- `ufbx_light_area_shape` (1414-1421): RECTANGLE, SPHERE.
- `ufbx_light` (1424-1451): `color`, `intensity` (already /100, see above), `local_direction`
  (local-space aim direction, usually -Y; must be transformed by `node_to_world` — not by
  `node_to_parent` — for world-space direction, per doc comment using
  `ufbx_transform_direction`), `type`, `decay`, `area_shape`, `inner_angle`/`outer_angle`
  (spot cone angles), `cast_light`/`cast_shadows`.
- Camera property-source enums (1453-1556) — `ufbx_projection_mode` (PERSPECTIVE/
  ORTHOGRAPHIC), `ufbx_aspect_mode` (how "AspectWidth/Height" props should be interpreted:
  WINDOW_SIZE/FIXED_RATIO/FIXED_RESOLUTION/FIXED_WIDTH/FIXED_HEIGHT), `ufbx_aperture_mode`
  (how FOV is derived: HORIZONTAL_AND_VERTICAL / HORIZONTAL / VERTICAL / FOCAL_LENGTH),
  `ufbx_gate_fit` (NONE/VERTICAL/HORIZONTAL/FILL/OVERSCAN/STRETCH — render-gate-to-film-gate
  fitting), `ufbx_aperture_format` (named real-world film gate presets: 16mm Theatrical, Super
  16mm, 35mm Academy/TV/Full Aperture/185/Anamorphic, 70mm Projection, VistaVision, Dynavision,
  IMAX — each with fixed inch dimensions given in the header comments, 1526-1542; treat these
  as a lookup table to reproduce verbatim if implementing `CUSTOM` vs named-format resolution).
  These four enums only affect how upstream *raw FBX properties* resolve into the final
  computed camera fields below — the header explicitly says "handled internally by ufbx,
  ignore unless you interpret ufbx_props directly" (1466, 1485, 1502, 1524).
- `ufbx_coordinate_axis`/`ufbx_coordinate_axes` (1544-1564): POSITIVE/NEGATIVE_X/Y/Z + UNKNOWN;
  `ufbx_coordinate_axes{right, up, front}` describes a coordinate system — **NOTE: `front` is
  the opposite of forward** (explicit warning at 1559). Used both for scene-level axis metadata
  (`ufbx_scene.settings`, later span) and per-camera `projection_axes` — camera projection is
  defined in FBX's fixed +X-forward/+Y-up space by default, and ufbx can remap it via
  `ufbx_load_opts.target_camera_axes`.
- `ufbx_camera` (1567-1630): `projection_mode`, `resolution_is_pixels` + `resolution`,
  `field_of_view_deg`/`field_of_view_tan` (perspective only), `orthographic_extent`/
  `orthographic_size` (ortho only), `projection_plane` (unifies the two — tan(FOV) or ortho
  size, "size of the frustum slice at distance 1"), `aspect_ratio`, `near_plane`/`far_plane`,
  `projection_axes`, plus the raw property-derived inputs (`aspect_mode`, `aperture_mode`,
  `gate_fit`, `aperture_format`, `focal_length_mm`, `film_size_inch`, `aperture_size_inch`,
  `squeeze_ratio` for anamorphic lenses) kept around for consumers who want to redo the
  derivation differently. **Camera math derivation itself lives in a different code region**
  (likely load/update-camera function, not required for this span's data-model documentation,
  but flagged as a dependency for whichever subsystem covers camera evaluation).
- `ufbx_bone` (1635-1652): `radius` (visual thickness), `relative_length` (bone length as a
  fraction of the inter-node distance — FBX "LimbLength" convention), `is_root`. Actual bone
  endpoints are derived from the node hierarchy (parent/child node positions), not stored here.
- `ufbx_empty` (1656-1664): pure marker/locator/"Null" node attribute — carries no fields of
  its own beyond the element base; all interesting data is on the owning `ufbx_node`.

### Curve/surface & advanced node attributes (1666-1931) — mostly OUT of v1 scope (NURBS
tessellation excluded) but the *data types* are in this span:
- `ufbx_line_curve` (1676-1694): polyline data — `control_points`, `point_indices` (indices
  into control_points forming the polyline), `segments` (`ufbx_line_segment` = index_begin +
  num_indices into `point_indices`), `from_tessellated_nurbs`.
- `ufbx_nurbs_topology` (1696-1707): OPEN / PERIODIC (wraps by repeating `order-1` control
  points) / CLOSED (wraps by repeating just the first point).
- `ufbx_nurbs_basis` (1710-1743): `order` (degree+1), `topology`, `knot_vector`, `t_min/t_max`,
  `spans` (parameter values of control points), `is_2d`, `num_wrap_control_points` (redundant
  convenience — how many leading control points to duplicate at the end per `topology`+`order`),
  `valid`.
- `ufbx_nurbs_curve`/`ufbx_nurbs_surface`/`ufbx_nurbs_trim_surface`/`ufbx_nurbs_trim_boundary`
  (1745-1816): control points stored **non-homogeneous** (must multiply by `w` before
  evaluating — explicit NOTE at 1758-1759, 1782-1783); surface control points laid out
  `V * num_control_points_u + U`; `span_subdivision_u/v` (tessellation density hints, unused if
  NURBS tessellation is skipped); `flip_normals`; per-surface `material`.
- `ufbx_procedural_geometry`/`ufbx_stereo_camera`/`ufbx_camera_switcher`/`ufbx_marker`/
  `ufbx_lod_group` (1818-1931): `stereo_camera` links `left`/`right` `ufbx_camera`;
  `ufbx_marker_type` distinguishes FK/IK effectors; `ufbx_lod_group` gives `relative_distances`
  (screen-percent vs world-unit `distance`), `lod_levels` (parallel array to the owning node's
  `children`, **not stored on the group itself** — must zip with `node.children` by index),
  `ignore_parent_transform`, `use_distance_limit`+min/max.

### Deformers (1933-2283)
- `ufbx_skinning_method` (1936-1949): LINEAR (standard LBS), RIGID (one bone per vertex),
  DUAL_QUATERNION, BLENDED_DQ_LINEAR (per-vertex blend between LBS and DQ via
  `ufbx_skin_vertex.dq_weight` or deformer-level `dq_vertices/dq_weights`).
- `ufbx_skin_vertex` (1954-1967): `weight_begin`/`num_weights` — slice into
  `ufbx_skin_deformer.weights[]`, **weights pre-sorted descending** so callers can truncate to
  top-N cheaply; **not guaranteed normalized** (explicit NOTE, 1959) — Swift consumers must
  normalize if they need weights summing to 1. `dq_weight` for the blended method.
- `ufbx_skin_weight` (1972-1975): `cluster_index` (into `ufbx_skin_deformer.clusters[]`) +
  `weight`.
- `ufbx_skin_deformer` (1982-2008): `skinning_method`, `clusters` (one per bone), `vertices`
  (per-mesh-vertex `ufbx_skin_vertex`, count == mesh vertex count), `weights` (flat pool
  referenced by `vertices[i].weight_begin/num_weights`), `max_weights_per_vertex`, and the
  deformer-level DQ blend arrays `dq_vertices`/`dq_weights` (**may be out of bounds for a
  given mesh** — explicit warning, 2004; always prefer `vertices[]`/`dq_weight` per-vertex
  data which is guaranteed safe).
- `ufbx_skin_cluster` (2011-2046): `bone_node` (nullable only if
  `connect_broken_elements` load option is set), `geometry_to_bone` (bind matrix, mesh-local-
  space → bone-space — **the one to use for skinning**), `mesh_node_to_bone` (alternative from
  node space, prefer geometry_to_bone), `bind_to_world` (rest pose of the node, not usually
  needed directly), `geometry_to_world` + `geometry_to_world_transform` (precomputed current
  = `bone->node_to_world * geometry_to_bone`, i.e. exactly what you multiply a bind-space
  vertex by to get its currently-skinned world position for this one bone's contribution),
  `vertices`/`weights` (raw parallel arrays indexed by **mesh vertex**, not corner — "may be
  out-of-bounds for a given mesh" if the cluster was authored against a different vertex count
  than currently loaded, same caveat as above; `ufbx_skin_deformer.vertices/weights` is the
  safe alternative).
- Blend shapes (2048-2116): `ufbx_blend_deformer` (just a `channels` list),
  `ufbx_blend_keyframe` (`shape` pointer, `target_weight` at which it's 100% applied,
  `effective_weight` currently in use), `ufbx_blend_channel` (current `weight`, ordered
  `keyframes` list — "in usual cases there's only one keyframe", `target_shape` = final shape
  ignoring intermediate blend keys), `ufbx_blend_shape` (`num_offsets` sized parallel arrays
  `offset_vertices` (indices into mesh vertices, **may be out of bounds**, 2107),
  `position_offsets` (always present), `normal_offsets` (empty if not specified),
  `offset_weights` (NOTE: not standard FBX, Blender-specific extension, 2114)). Blend shape
  *evaluation* (interpolating between keyframes by weight and applying offsets) is explicitly
  in v1 scope per the port brief — the struct here is the data model; the evaluation algorithm
  itself will live in a different subsystem (animation evaluation) span.
- Cache deformer types (2118-2283): `ufbx_cache_file_format` (UNKNOWN/PC2/MC),
  `ufbx_cache_data_format` (REAL/VEC3 × FLOAT/DOUBLE), `ufbx_cache_data_encoding`
  (LITTLE/BIG_ENDIAN), `ufbx_cache_interpretation` (UNKNOWN/POINTS/VERTEX_POSITION/
  VERTEX_NORMAL), `ufbx_cache_frame`/`ufbx_cache_channel`/`ufbx_geometry_cache`,
  `ufbx_cache_deformer`, `ufbx_cache_file`. **Entirely OUT of v1 scope** (".pc2/.mc/.xml
  geometry caches" explicitly excluded) — document only for completeness; do not port.

## Materials & textures (2285-3035)
- `ufbx_material_map` (2288-2320): the core "value-or-texture" cell used for every FBX/PBR
  material channel. `value_real/vec2/vec3/vec4` (union) + `value_int`, `texture` (nullable),
  `has_value` (file specified *any* value — note some factors get a synthesized non-zero
  default even when `has_value==false`, see `ufbxi_update_factor` in Control Flow),
  `texture_enabled` (whether shading should actually use `texture` — can be true even with
  `texture==nil` for some shading models per the doc comment, meaning "texturing is
  conceptually enabled" as a feature flag independent of whether one was actually connected),
  `feature_disabled`, `value_components` (0-4, how many of value_vec4's components are
  meaningful). Swift shape: an enum would be tempting (`.constant(Double)`/`.textured(...)`)
  but note value and texture can coexist (multiplicative tint) — better as a struct with an
  optional texture + a `value` that is itself a small enum-by-component-count or just a
  `SIMD4<Double>` with a `componentCount` tag, mirroring the C shape fairly directly since the
  "texture tints value" semantic is real and needed by both fields at once.
- `ufbx_material_feature_info` (2323-2332): `enabled` + `is_explicit` (was this deliberately
  set by the file vs. a shading-model default).
- `ufbx_material_texture` (2335-2342): `material_prop` name + `shader_prop` name + `texture` —
  used for the material's flat sorted `textures` list (any texture connected to any prop, for
  generic enumeration beyond the named fbx/pbr maps).
- `ufbx_shader_type` (2347-2388): UNKNOWN, FBX_LAMBERT, FBX_PHONG, OSL_STANDARD_SURFACE,
  ARNOLD_STANDARD_SURFACE, 3DS_MAX_PHYSICAL_MATERIAL, 3DS_MAX_PBR_METAL_ROUGH,
  3DS_MAX_PBR_SPEC_GLOSS, GLTF_MATERIAL, OPENPBR_MATERIAL, SHADERFX_GRAPH (Stingray — data is
  a serialized "ShaderGraph" string prop, opaque), BLENDER_PHONG (needs
  `use_blender_pbr_material` load opt to activate the PBR-recovery heuristics),
  WAVEFRONT_MTL (.obj — OUT of scope). This tag drives which shader-specific property-name
  table `ufbxi_fetch_maps` uses to populate `pbr.*` (see Control Flow) — porting this table
  faithfully is required to get PBR values right across DCC tools.
- `ufbx_material_fbx_map` (2391-2416) and `ufbx_material_fbx_maps` (2513-2539): fixed set of
  20 legacy-FBX (Lambert/Phong) channels — diffuse/specular/reflection/transparency/emission/
  ambient factor+color pairs, specular_exponent, normal_map, bump+bump_factor,
  displacement+displacement_factor, vector_displacement+vector_displacement_factor. Exposed
  both as a `maps[N]` array (indexable by the enum) and as named struct fields aliasing the
  same memory (anonymous union) — Swift should drop the union and expose named properties
  only, with a computed `Array<MaterialMap>`/subscript-by-enum if array-style access is
  useful.
- `ufbx_material_pbr_map` (2419-2480) and `ufbx_material_pbr_maps` (2541-2603): a much larger
  ~55-entry table covering base/roughness/metalness/diffuse_roughness, full specular
  (factor/color/ior/anisotropy/rotation), transmission (factor/color/depth/scatter/
  scatter_anisotropy/dispersion/roughness/extra_roughness/priority/enable_in_aov),
  subsurface (factor/color/radius/scale/anisotropy/tint_color/type), sheen
  (factor/color/roughness), coat (factor/color/roughness/ior/anisotropy/rotation/normal/
  affect_base_color/affect_base_roughness), thin_film (factor/thickness/ior), emission
  (factor/color), opacity, indirect_diffuse/specular, normal_map/tangent_map/
  displacement_map, matte (factor/color), ambient_occlusion, glossiness/coat_glossiness/
  transmission_glossiness (roughness↔glossiness alternates, see Quirks). This is ufbx's
  normalized cross-vendor PBR schema that every `ufbx_shader_type` gets mapped into. Per the
  port brief, "PBR mapping tables are stretch" — i.e. the fbx maps + basic texture wiring are
  P0, but faithfully reproducing every per-shader-vendor mapping table (the actual property-
  name-to-map tables consumed by `ufbxi_fetch_maps`, stored elsewhere in ufbx.c as
  `ufbxi_shader_pbr_mappings[]` / `ufbxi_base_fbx_mapping[]` / `ufbxi_obj_fbx_mapping[]`, not
  yet located precisely in this span's reading — flag for the subsystem that owns materials
  construction) is stretch/lower priority.
- `ufbx_material_feature` (2483-2511) and `ufbx_material_features` (2605-2634): ~23 boolean-ish
  feature toggles (PBR, METALNESS, DIFFUSE, SPECULAR, EMISSION, TRANSMISSION, COAT, SHEEN,
  OPACITY, AMBIENT_OCCLUSION, MATTE, UNLIT, IOR, DIFFUSE_ROUGHNESS,
  TRANSMISSION_ROUGHNESS, THIN_WALLED, CAUSTICS, EXIT_TO_BACKGROUND, INTERNAL_REFLECTIONS,
  DOUBLE_SIDED, ROUGHNESS_AS_GLOSSINESS, COAT_ROUGHNESS_AS_GLOSSINESS,
  TRANSMISSION_ROUGHNESS_AS_GLOSSINESS) — each an `ufbx_material_feature_info`. Same
  array/named-union duplication as the maps structs.
- `ufbx_material` (2638-2671): `fbx` (all 20 legacy maps, always populated even for PBR
  shaders on a best-effort basis), `pbr` (all ~55 PBR maps, populated for every shader,
  "may be somewhat approximate if shader == NULL" i.e. derived from Lambert/Phong via
  heuristics), `features`, `shader_type` (always defined, UNKNOWN if not recognized),
  `shader` (nullable extended info), `shading_model_name` (raw FBX string, commonly
  "lambert"/"phong"/"unknown"), `shader_prop_prefix` (e.g. `"3dsMax|Parameters|"` — needed
  only if bypassing the normalized `fbx`/`pbr` structs and reading raw shader props directly),
  `textures` (flat sorted-by-property-name list of every texture connection).
- `ufbx_texture_type` (2673-2694): FILE (has filename/content), LAYERED (composited stack),
  PROCEDURAL (reserved, "should exist in FBX files" per comment but essentially unused),
  SHADER (a shader-graph node masquerading as a texture — see below).
- `ufbx_blend_mode` (2700-2736): 30 Photoshop/W3C-compositing-style blend modes for layered
  textures (TRANSLUCENT, ADDITIVE, MULTIPLY, MULTIPLY_2X, OVER, REPLACE, DISSOLVE, DARKEN,
  COLOR_BURN, LINEAR_BURN, DARKER_COLOR, LIGHTEN, SCREEN, COLOR_DODGE, LINEAR_DODGE,
  LIGHTER_COLOR, SOFT_LIGHT, HARD_LIGHT, VIVID_LIGHT, LINEAR_LIGHT, PIN_LIGHT, HARD_MIX,
  DIFFERENCE, EXCLUSION, SUBTRACT, DIVIDE, HUE, SATURATION, COLOR, LUMINOSITY, OVERLAY) —
  formula comments given inline in the enum (2701-2731); cite these rather than re-deriving if
  actually implementing texture layer compositing (likely out of scope for a loader — ufbx
  itself doesn't rasterize, just exposes the mode).
- `ufbx_wrap_mode` (2739-2746): REPEAT/CLAMP, per U/V axis on `ufbx_texture`.
- `ufbx_texture_layer` (2749-2753): one entry in a LAYERED texture — `texture`, `blend_mode`,
  `alpha` weight. Layer order is bottom-to-top (2935).
- Shader-texture types (2757-2852): `ufbx_shader_texture_type` (UNKNOWN/SELECT_OUTPUT/OSL),
  `ufbx_shader_texture_input` (name, constant-value union, optional connected `texture` +
  `texture_output_index`, `texture_enabled`, back-references to the underlying `ufbx_prop`s),
  `ufbx_shader_texture` (models a 3ds Max shader-graph node exported *as* a texture element —
  `type`, `shader_name`, opaque `shader_type_id`, sorted `inputs` list, optional
  `shader_source`/`raw_shader_source`, `main_texture`+`main_texture_output_index` for
  multi-output passthrough, `prop_prefix`). Comment (2814-2820) explains the real-world need:
  3ds Max sometimes hides a normal map behind a bump/shader node graph, and ufbx partially
  unwraps a "small subset" of these so `texture.file_textures[]` still surfaces the real image
  textures underneath.
- `ufbx_texture_file` (2855-2885) + `ufbx_texture` (2890-2959): standard filename triple
  (`filename`/`absolute_filename`/`relative_filename`, each duplicated in a non-UTF8 `raw_*`
  blob form for exotic encodings), optional embedded `content` blob, optional `video` link,
  `file_index`/`has_file` (dedup index into `ufbx_scene.texture_files[]`), `layers` (if
  LAYERED), `shader` (if masquerading as shader node), `file_textures` (always defined — even
  a plain FILE texture reports itself as a 1-element list, simplifying uniform traversal),
  `uv_set` name, `wrap_u`/`wrap_v`, and a full UV-space transform
  (`has_uv_transform`/`uv_transform`/`texture_to_uv`/`uv_to_texture` matrices) — computed by
  `ufbxi_get_texture_transform` (see Control Flow), independent of the node transform system.
- `ufbx_video` (2962-2994): same filename-quad pattern + `content` blob — "TODO: Video
  textures" comment in source (2961) signals this is a minimally-supported passthrough type.
- `ufbx_shader` (2996-3014) + `ufbx_shader_prop_binding`/`ufbx_shader_binding` (3016-3034):
  `shader.type` + `bindings` (list of shader-property-name ↔ material-property-name pairs) —
  the generic mechanism `ufbx_find_shader_prop_bindings_len` uses (called from
  `ufbxi_fetch_maps`, ufbx.c:20003) to redirect a normalized PBR/FBX map lookup to whatever
  differently-named property the actual shader graph uses.

## Control flow / algorithms

1. **Property lookup with defaults chain** — `ufbx_find_prop_concat`
   (ufbx.c:30712-30728, representative of the whole `ufbx_find_prop*` family): binary-search
   the current `ufbx_props.props` (sorted array) by hashed key + name equality; on miss, follow
   `props->defaults` and repeat. This is how "class default" properties (FBX object templates)
   are transparently merged with per-instance overrides without copying data. Port as a
   dictionary-chain lookup (see Key Data Structures note above).

2. **Node local transform composition** — `ufbxi_get_transform`
   (ufbx.c:22836-22905), called from `ufbxi_update_node` (ufbx.c:22955-23042) for every
   non-root node. Exact composition order (comment at 22852-22853, matches FBX SDK spec):
   ```
   WorldTransform = ParentWorldTransform
                  * T * Roff * Rp * Rpre * R * Rpost^-1 * Rp^-1
                  * Soff * Sp * S * Sp^-1
   ```
   Step by step (all via helper `ufbxi_mul_rotate`/`ufbxi_mul_scale`/`ufbxi_add_translate`/
   `ufbxi_sub_translate`/`ufbxi_mul_inv_rotate` accumulating into a running `ufbx_transform t`
   that starts as identity):
   a. Read `ScalingPivot`, `RotationPivot`, `ScalingOffset`, `RotationOffset`,
      `Lcl Translation`, `Lcl Rotation`, `Lcl Scaling`, `PreRotation`, `PostRotation` from
      props (defaults 0,0,0 / scaling defaults 1,1,1).
   b. If `translation_scale` supplied (used only when the parent has a `scale_helper`, i.e.
      COMPONENTWISE_SCALE bookkeeping), scale `translation` componentwise by it *before*
      anything else.
   c. If `node->has_adjust_transform`: pre-multiply by `adjust_post_rotation` then
      `adjust_post_scale` (this is applied *first* into `t` because the whole chain below is
      built by successive left-multiplication via the mul_* helpers, i.e. it ends up as the
      outermost/last-applied factor — read the helper semantics before porting, don't assume
      naive order-of-calls == order-of-application).
   d. `t = t · Sp^-1 · S · Sp` (subtract scale pivot, scale, add scale pivot back) then
      `· Soff` (scaling offset).
   e. `t = t · Rp^-1 · [rotation composition] · Rp` (subtract rotation pivot, apply rotation,
      add back) then `· Roff` (rotation offset). Rotation composition itself branches:
      - if `node->use_rotation_space` (see quirk below): `PostRotation^-1 (XYZ order) · Rotation
        (node's own rotation_order) · PreRotation (XYZ order)`, i.e. pre/post rotation are
        *always* XYZ-ordered Euler regardless of the node's own configured `RotationOrder`.
      - else: just `Rotation` alone, in the node's configured `rotation_order`.
   f. `t = t · Translation`.
   g. If `has_adjust_transform`: add `adjust_pre_translation`, rotate by `adjust_pre_rotation`,
      scale by `adjust_pre_scale`, then scale `t.translation` by `adjust_translation_scale`
      (this is where an overall unit-conversion scale gets applied to position only, not
      rotation/scale).
   h. If `adjust_mirror_axis != NONE`: mirror `t.translation` (negate the one component on
      that axis) and mirror `t.rotation` (negate two of the quaternion's imaginary
      components per `ufbxi_mirror_rotation`, ufbx.c:22751-22756 — the exact pair is
      `axis%3` and `(axis+1)%3`, NOT the axis-th component alone; this is the correct way to
      mirror a quaternion's *effect* under a single-axis reflection, not just negate one term).
   i. Regression self-check (debug builds): result must equal `ufbxi_get_rotation`/
      `ufbxi_get_scale` computed independently (22901-22902) — a good property-based test to
      port too.
   Companion functions with the same pivot/adjust logic but simplified to rotation-only or
   scale-only extraction: `ufbxi_get_rotation` (22786-22815), `ufbxi_get_scale`
   (22817-22834) — used as fast paths elsewhere when only one component is needed.

3. **Geometry transform** — `ufbxi_get_geometry_transform` (ufbx.c:22758-22784): reads
   `GeometricTranslation`/`GeometricRotation`/`GeometricScaling` (defaults 0/0/1), composes as
   `S then R then T` (simple order, comment "WorldTransform = ParentWorldTransform * T * R * S
   * (OT * OR * OS)" — this *is* the "OT*OR*OS" part), then applies `adjust_translation_scale`
   to the translation and mirrors if `adjust_mirror_axis` set. Called once per node in
   `ufbxi_update_node` (22990) only for non-root nodes.

4. **World transform assembly with inherit-mode branching** — inside `ufbxi_update_node`
   (ufbx.c:22955-23042), after `local_transform`/`geometry_transform` are computed:
   a. `unscaled_node_to_parent = ufbxi_unscaled_transform_to_matrix(local_transform)` (a
      matrix built from just translation+rotation, scale forced to 1 — helper not read in
      this span but name is self-explanatory; needed for the two special inherit modes).
   b. `node->inherit_scale = local_transform.scale` initially (overwritten below in the
      non-NORMAL branch).
   c. If no parent (root): `node_to_world = node_to_parent`, `unscaled_node_to_world =
      unscaled_node_to_parent`.
   d. Else if `inherit_mode == NORMAL`: plain matrix chaining —
      `node_to_world = parent.node_to_world * node_to_parent`;
      `unscaled_node_to_world = parent.node_to_world * unscaled_node_to_parent` (note: still
      multiplies by the *parent's regular* world matrix, only this node's own contribution is
      unscaled).
   e. Else (`IGNORE_PARENT_SCALE` or `COMPONENTWISE_SCALE`): build a *derived* transform
      copy of `local_transform` where
      `scale *= inherit_scale_node.inherit_scale` (componentwise; `inherit_scale_node` walks
      up to whichever ancestor supplies the scale to inherit — for COMPONENTWISE_SCALE this is
      simply `parent`; for IGNORE_PARENT_SCALE it's the parent of the nearest
      componentwise-scaled ancestor, per the header doc at 908-912) and
      `translation *= parent.inherit_scale` (also componentwise — this is why translation is
      still scaled even though rotation/scale composition otherwise ignores parent scale).
      Then: `node_to_world = parent.unscaled_node_to_world * matrix(that derived transform)`;
      `unscaled_node_to_world = parent.unscaled_node_to_world *
      unscaled_matrix(that derived transform)`. `node->inherit_scale` is updated to the
      derived transform's scale (so descendants can chain off it).
   f. `geometry_to_node`/`geometry_to_world`: identity passthrough if `geometry_transform` is
      identity (`has_geometry_transform=false`), else `geometry_to_node =
      matrix(geometry_transform)`, `geometry_to_world = node_to_world * geometry_to_node`.
   g. `node->visible = find_int(Visibility, default 1) != 0`.
   This function must be called in **parent-before-child order** (topological, root first) —
   not explicitly stated here but implied by every step reading `parent->node_to_world`/
   `parent->unscaled_node_to_world`, which must already be finalized.

5. **Texture UV transform** — `ufbxi_get_texture_transform` (ufbx.c:22907-22936): reads
   `TextureScalingPivot`/`TextureRotationPivot`/`Translation`/`Rotation`/`Scaling` (note:
   generic prop names, not `Lcl *`-prefixed — texture props reuse the plain names), composes
   `Sp^-1·S·Sp` then `Rp^-1·R·Rp` then `T` (always XYZ rotation order, no pre/post rotation
   concept for textures), and if the boolean prop `UVSwap` is set, appends a fixed swap
   transform: scale `(-1, 0, 0)` then rotate `(0, 0, -90deg)` — this is the exact quirk
   fallback for FBX's "swap UV" texture flag (used by some exporters to swap U/V axes instead
   of literally transposing UV data).

6. **Material map / feature fetch** — `ufbxi_fetch_maps` (ufbx.c:20124-20216), called once
   per material during scene construction, driving `ufbx_material.fbx`/`pbr`/`features`:
   a. Zero all three output structs.
   b. Fetch the 20 FBX legacy maps via `ufbxi_fetch_mapping_maps` using a base table
      (`ufbxi_base_fbx_mapping` normally, or `ufbxi_obj_fbx_mapping` if
      `scene->metadata.file_format` is OBJ/MTL) — `UFBXI_MAPPING_FETCH_VALUE |
      UFBXI_MAPPING_FETCH_TEXTURE` flags (fetch both constant value and any bound texture per
      map).
   c. Look up the shader-specific PBR mapping table for `material->shader_type` from
      `ufbxi_shader_pbr_mappings[material->shader_type]` (a `ufbxi_shader_mapping_list`,
      definition/table not located within this span — flag for materials-subsystem span) and
      seed `features` with that shading model's `default_features` bitmask.
   d. Fetch PBR *textures* first if the mapping table defines a texture name
      prefix/suffix convention (some shader graphs name texture-carrying props differently
      from value-carrying props of the same logical channel).
   e. Fetch PBR values+textures uniformly (VALUE | TEXTURE flags) using the main table.
   f. Fetch `texture_enabled` booleans if the table defines a prefix/suffix convention for
      that.
   g. Fetch material *features* (booleans like PBR/METALNESS/...) via the table's
      `features`/`feature_count`, honoring `UFBXI_SHADER_FEATURE_IF_AROUND_1` (treat value in
      [0.5,1.5] as boolean true — handles shaders that store a "toggle" as a near-1.0 float),
      `UFBXI_SHADER_FEATURE_INVERTED`, `UFBX_SHADER_FEATURE_IF_EXISTS` (presence alone implies
      true), and `UFBXI_SHADER_FEATURE_IF_TEXTURE` (feature considered enabled merely if *any*
      texture is bound to that property, regardless of value).
   h. Per-channel factor defaulting via `ufbxi_update_factor` (ufbx.c:20096-20107): for six FBX
      pairs and six PBR pairs (diffuse/specular/reflection/transparency/emission/ambient for
      FBX; base/specular/emission/sheen/thin_film/transmission for PBR) — if the *factor* map
      has no explicit value but the paired *color* map does and is non-zero, synthesize
      `factor = 1.0`; otherwise (no color or color is exactly zero) synthesize `factor = 0.0`.
      This is why `ufbx_material_map.has_value == false` can still carry a meaningful non-zero
      default per the header's own warning (2306-2307) — this function is exactly that case.
   i. Transmission-roughness patch (20196-20198): if `transmission_roughness` wasn't set but
      both `roughness` and `transmission_extra_roughness` were, synthesize
      `transmission_roughness = roughness + transmission_extra_roughness` — a heuristic for
      shaders (Arnold-style) that store transmission roughness as a *delta* from base
      roughness rather than an absolute value.
   j. Roughness↔glossiness reconciliation loop (20118-20122 table, 20200-20215 loop) over the
      three `{feature, roughness_map, glossiness_map}` triples (plain roughness↔glossiness,
      coat, transmission): if the corresponding `*_AS_GLOSSINESS` feature is enabled, the value
      that was fetched into the "roughness" slot is actually glossiness data — move it over
      (`*glossiness = *roughness`, zero the roughness slot) and derive `roughness = 1 -
      glossiness` if a value exists; if the feature is *not* enabled, the roughness slot is
      correct as-fetched and glossiness is derived as `1 - roughness` instead. This
      "roughness-or-glossiness-in-the-same-slot-depending-on-a-flag" pattern is a real quirk of
      how 3ds Max's PBR Spec/Gloss shaders vs. Metal/Rough shaders both map onto the same
      normalized property names.

7. **Curve evaluation entry point** — `ufbx_evaluate_curve`/`ufbx_evaluate_curve_flags`
   (ufbx.c:30827-30840+, body continues past what was read in this span): trivial early-outs
   for 0 or 1 keyframes (return default/only value), otherwise delegates to per-key
   interpolation using `ufbx_keyframe.interpolation` of the **previous** key to decide how to
   interpolate to the next (per header comment at ufbx.h:3191-3202) — full cubic Bezier/TCB
   tangent math is in a later part of ufbx.c outside this span's line range; flagged as a
   dependency for the animation-evaluation subsystem.

## Format details
- `UFBX_NO_INDEX = (uint32_t)~0u` (ufbx.h:396) — universal "absent index" sentinel used for
  `vertex_first_index`, `texture.file_index`, and elsewhere.
- Light intensity: raw FBX `"Intensity"` property is divided by 100 to produce
  `ufbx_light.intensity` (ufbx.c ~20044, matched to header comment ufbx.h:1433-1435) — DCC
  tools (Maya, presumably others) author/export at 100x the "natural" unit.
- Aperture format table (ufbx.h:1526-1542): fixed inch dimensions for 12 named film gates —
  CUSTOM, 16MM_THEATRICAL (0.404×0.295in), SUPER_16MM (0.493×0.292in), 35MM_ACADEMY
  (0.864×0.630in), 35MM_TV_PROJECTION (0.816×0.612in), 35MM_FULL_APERTURE (0.980×0.735in),
  35MM_185_PROJECTION (0.825×0.446in), 35MM_ANAMORPHIC (0.864×0.732in, squeeze ratio 2),
  70MM_PROJECTION (2.066×0.906in), VISTAVISION (1.485×0.991in), DYNAVISION (2.080×1.480in),
  IMAX (2.772×2.072in) — cite verbatim from header comments if reproducing camera aperture
  defaults; do not re-derive.
- Rotation composition full formula (ufbx.c:22852-22853, cited in Control Flow #2):
  `WorldTransform = ParentWorldTransform * T * Roff * Rp * Rpre * R * Rpost^-1 * Rp^-1 * Soff *
  Sp * S * Sp^-1` — this is the canonical FBX SDK transform formula and must be reproduced
  exactly, including that `PostRotation` enters as its **inverse**.
- `UVSwap` texture quirk fixed values (ufbx.c:22929-22932): scale `(-1, 0, 0)`, rotate
  `(0, 0, -90)` degrees, both XYZ order, applied *after* the normal UV pivot/rotate/scale/
  translate chain.
- Mirror-rotation quirk (ufbx.c:22751-22756): for `ufbx_mirror_axis axis` (1=X,2=Y,3=Z),
  negate quaternion components at indices `axis % 3` and `(axis + 1) % 3` (i.e. the two
  imaginary components *other than* the mirrored axis are negated, not the mirrored axis's own
  component) — easy to get backwards when porting, verify against this exact indexing.
- `ufbx_prop_flags` numeric values are real bit positions (0x1 .. 0x4000000, ufbx.h:483-536) —
  if any lower-level code (outside this span) reads raw flag bytes from the file format,
  these exact bit assignments matter; otherwise treat as an opaque OptionSet in Swift.

## Quirks & edge cases
- **Degenerate faces are not filtered at load time** (ufbx.h:1111-1112, explicit `TODO #23`):
  `ufbx_face.num_indices` can be 0/1/2 for empty/point/line "faces" respectively; every mesh
  reports `num_empty_faces`/`num_point_faces`/`num_line_faces` (both at mesh level and per
  mesh_part level) so consumers can skip them, but they are NOT removed from `faces[]`. A
  Swift triangulation/rendering path must explicitly skip or special-case these.
- **`skinned_is_local`**: for a *non-skinned* mesh, `skinned_position`/`skinned_normal` are
  literally the same storage as `vertex_position`/`vertex_normal` and remain in local
  (pre-`geometry_to_world`) space — callers must know to apply the node's `geometry_to_world`
  themselves in that case (ufbx.h:1343-1349). Don't assume "skinned_position" is always
  world-space; check the flag.
- **`unique_per_vertex` correctness contingent on caller discipline**: even when true, safe
  per-vertex access requires going through `vertex_first_index[vertex]` as the index into
  `.indices[]` — direct `values[vertex]` indexing is *not* guaranteed valid because `values`
  is deduplicated/compacted independently of vertex ordering (ufbx.h:1004-1006, 1247-1255).
- **Multiple attributes per node** are rare but explicitly supported (`all_attribs`,
  ufbx.h:891-895) — "very exotic FBX file" case; a Swift port that only exposes `mesh`/`light`/
  `camera`/`bone` convenience accessors must still keep `allAttribs` for completeness or
  explicitly document the simplification as a scope cut.
- **Per-instance vs per-mesh materials**: `ufbx_mesh.materials` can be *wrong* for a
  multi-instanced mesh with different per-node material overrides; the authoritative list per
  instance is `ufbx_node.materials` at the same indices (ufbx.h:953-956, 1323-1326). Any
  Swift API surfacing "the materials of a mesh" must take the owning node into account, not
  just the mesh.
- **Synthetic helper nodes**: ufbx may inject `geometry_transform_helper` and `scale_helper`
  child/sibling nodes to represent FBX transform features (geometry transforms baked as extra
  hierarchy, or scale-compensation) that don't cleanly fit the plain parent/child matrix model
  otherwise. These are marked via `is_geometry_transform_helper`/`is_scale_helper` and should
  probably be filterable/hidden in a "clean" Swift scene graph view, while still being present
  for consumers who need exact FBX SDK-compatible topology.
- **`use_rotation_space` gates PreRotation/PostRotation/RotationOrder entirely**
  (ufbx.h:970-972): if false, `rotation_order` is effectively forced to XYZ semantics and pre/
  post rotation are not applied at all — determined by two other props, `RotationActive` and
  `RotationSpaceForLimitOnly` (ufbx.c:22961-22963): `use_rotation_space = RotationActive &&
  !RotationSpaceForLimitOnly`. A file with `RotationActive=false` (the common/default case for
  many exporters when pre/post rotation isn't used) means PreRotation/PostRotation values, even
  if present as properties, must be ignored for the actual transform — but *are* still read
  and folded in by `ufbxi_get_transform` since the branch (`if use_rotation_space {...} else {
  just apply Rotation }`) is decided per-call, i.e. this is not a "read but discard" quirk but
  an actual branch skipping pre/post entirely.
- **`adjust_*` fields fold axis/unit conversion invisibly into every transform** — a Swift
  port that wants a "clean" per-node local transform without ufbx's axis-conversion baked in
  would need to either replicate this exact injection point-for-point, or restructure to do
  axis conversion as a single top-level scene transform instead (a legitimate design deviation
  worth calling out explicitly to whoever owns scene-settings/axis-conversion, since it
  changes where in the chain the correction is applied — ufbx bakes per-node, not globally).
- **Root node's `local_transform`** can come from `ufbx_load_opts.root_transform` (an override)
  or defaults to identity (ufbx.c:15830-15833) — not derived from FBX properties at all, since
  the root has no FBX node record.
- **Roughness/glossiness are stored in the same logical slot depending on a feature flag**
  (Control Flow #6j) — a materials port that doesn't replicate this swap will silently invert
  or lose roughness data for 3ds Max Spec/Gloss-style materials.
- **Transmission roughness synthesized from "extra roughness" delta** (Control Flow #6i) is an
  Arnold-shader-specific heuristic, easy to miss since it only fires when the primary
  transmission_roughness prop is entirely absent.
- **Material factor defaulting to 1.0 or 0.0 based on paired color's presence/zero-ness**
  (Control Flow #6h) means `has_value == false` on a `ufbx_material_map` does NOT mean the
  numeric fields are garbage/zero garbage — they may hold a meaningful synthesized default;
  Swift API design should make this explicit (e.g. always expose a resolved `value` plus a
  separate `wasExplicit: Bool`, matching `has_value`, rather than conflating "no value" with
  "zero").
- **`UVSwap` and other legacy per-texture props are read under plain names, not `Lcl `-prefixed
  names** — a naming quirk purely from FBX's own schema (texture transform props vs. object
  transform props use different property-name conventions) that must be preserved in whatever
  prop-name constant tables the port defines.
- **3ds Max shader graphs disguised as textures** (`ufbx_shader_texture`, ufbx.h:2814-2820):
  bump/normal map chains can be hidden behind opaque shader-graph nodes; ufbx only unwraps a
  "small subset" — a Swift port inheriting this scope should not assume `file_textures` will
  always yield a usable image texture for every material channel; this is a known partial
  coverage gap in ufbx itself, not just the port.
- **`ufbx_cache_deformer`/`ufbx_cache_file`/`ufbx_geometry_cache` `external_cache`/
  `external_channel` fields are only populated when `ufbx_load_opts.load_external_files` is
  set** (ufbx.h:2246-2248, 2281-2283) — irrelevant for v1 anyway (cache deformers OUT of
  scope), but if any struct is retained purely for passthrough completeness, remember these
  fields will simply be `nil` under SwiftFBX's Data/URL-based IO model unless equivalent
  external-file-resolution is deliberately implemented (it isn't, per scope).

## Port guidance
- **Faithful-port list** (numeric/behavioral fidelity required, these are load-bearing for
  correctness, not just style):
  - The exact transform composition formula and operation order in `ufbxi_get_transform`/
    `ufbxi_get_rotation`/`ufbxi_get_scale`/`ufbxi_get_geometry_transform` (Control Flow #2-3),
    including the `PostRotation` inversion, the pivot subtract/add pattern, and the
    mirror-rotation index quirk.
  - The inherit-mode branch in world-transform assembly (Control Flow #4), including which
    matrix (`node_to_world` vs `unscaled_node_to_world`) is used as the base for each mode, and
    the `inherit_scale_node` walk described in ufbx.h:908-912.
  - `use_rotation_space` derivation (`RotationActive && !RotationSpaceForLimitOnly`) and its
    effect of entirely skipping pre/post rotation composition when false.
  - Light intensity /100 scaling; the aperture-format inch table; the `UVSwap` fixed
    transform; the roughness/glossiness slot-swap logic; the transmission-roughness-from-delta
    heuristic; the factor-from-color defaulting logic — all in Control Flow #6 and Format
    Details.
  - Vertex attribute invariants: `indices.count == mesh.num_indices` when `exists`; degenerate
    face handling counts.
- **Replace with Swift idioms** (do not port the C mechanism, only the semantics):
  - `UFBX_LIST_TYPE` non-owning slices → `Array<T>` (owned, value-type, ARC/COW-managed);
    drop the arena-allocator-lifetime reasoning entirely.
  - The element "base-class via anonymous union" idiom → a `class Element`/protocol hierarchy
    or, given "value-type-friendly API but reference types where identity matters" from the
    port brief, likely `class` for every element type (they participate in a mutable
    connection graph with pointer identity and shared instancing via `instances`).
  - `ufbx_element_type` tag-plus-union-of-pointers-on-`ufbx_node`(mesh/light/camera/bone) →
    a Swift `enum NodeAttribute { case mesh(Mesh); case light(Light); case camera(Camera); case
    bone(Bone); case other(Element) }` is far more idiomatic and eliminates the "check
    attrib_type before touching the nullable pointer" pattern entirely, while `allAttribs`
    remains available for the rare multi-attribute case.
  - Sorted-array + binary-search props lookup → `Dictionary<String, Prop>` chain via optional
    parent (`defaults`).
  - Parallel `ufbx_material_fbx_maps`/`ufbx_material_pbr_maps` named-union-plus-array structs
    → plain Swift structs with named `let`/`var` properties; if array-style enumeration over
    "all maps" is genuinely needed (e.g. for a generic property inspector UI), add a
    computed `var allMaps: [(name: String, map: MaterialMap)]` instead of relying on memory
    layout.
  - `UFBX_NO_INDEX` sentinel → `nil` in an `Optional<Int>`/`Optional<UInt32>`.
  - `ufbx_string`/`ufbx_blob` → `String`/`Data`.
  - `ufbx_matrix`'s union-of-three-views → a single named-field struct (or use
    `simd_double4x3` if targeting Apple platforms specifically; note the port brief says
    "zero dependencies" so plain custom struct + a few operators is probably right instead of
    `simd`).
- **Skip entirely per v1 scope** (data types exist in this header span but the feature is
  explicitly OUT):
  - NURBS curve/surface/trim-boundary tessellation math (structs can still be parsed/exposed
    as opaque control-point data if trivial, but no evaluation).
  - Subdivision surface evaluation (`ufbx_subdivision_result` and friends) — parse the
    boundary/display-mode *properties* as passthrough metadata only.
  - Geometry cache (.pc2/.mc) types (`ufbx_cache_*`, `ufbx_geometry_cache`) — entirely skip,
    including the `ufbx_cache_deformer` element type if feasible (or keep as an inert
    passthrough element with no data resolution).
  - `ufbx_procedural_geometry` (reserved/unused in practice).
- **Cross-subsystem dependencies to flag for other spans**:
  - Scene construction (populating `ufbx_node.parent/children`, resolving
    `ufbx_connection` lists into typed fields, computing `adjust_*` fields from load options
    and detected exporter/axis conventions) is NOT in this span — this span only covers what
    the fields *mean* and how they're *consumed* once populated. The actual `adjust_pre/post_*`
    *derivation* (from target axis/unit conversion) lives around ufbx.c:23750+ and should be
    documented by whichever span covers scene setup / axis conversion.
  - `ufbxi_shader_pbr_mappings[]` / `ufbxi_base_fbx_mapping[]` / `ufbxi_obj_fbx_mapping[]` (the
    actual per-shader-vendor property-name tables driving `ufbxi_fetch_maps`) were not located
    precisely within lines 1-3200 of either file during this pass — needed by whichever
    subsystem/span implements full material construction; search ufbx.c for
    `ufbxi_shader_mapping` struct definitions and the mapping table arrays.
  - Animation curve evaluation (cubic/TCB/auto tangent math) is DECLARED in this span
    (`ufbx_keyframe`, `ufbx_tangent`, `ufbx_interpolation`, `ufbx_extrapolation`,
    `ufbx_anim_curve`) but the evaluation *algorithm* body (`ufbx_evaluate_curve_flags`
    continues past ufbx.c:30840, and per-key cubic Bezier math is further down) belongs to the
    animation-evaluation span — this span only documents the data shapes.
  - Property system underpins everything else (materials, animation, node transforms all read
    through `ufbx_find_prop*`) — any span touching those areas depends on the props-chain
    lookup semantics documented here.
  - Skin cluster / blend shape *evaluation* (applying weights to produce final vertex
    positions) is in scope per the port brief but its algorithm lives outside lines 1-3200;
    this span only documents the data model (`ufbx_skin_deformer/cluster`,
    `ufbx_blend_deformer/channel/shape`) that the evaluation subsystem will consume.
