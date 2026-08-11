# Scene Pre-processing & Scene Processing (part 1)

Covers ufbx.c 18066–20400: `ufbxi_pre_finalize_scene` (the optional graph-mutation
pass that inserts helper nodes and rewrites pivots) plus the first half of scene
processing — connection resolution, id↔element maps, parent/child derivation, node
depth ordering + sort, the `ufbxi_fetch_*` element-list builders, and a few
per-element finalizers (nurbs basis, LOD group, generated normals, constraint props).
The giant material shader-mapping tables at 19372–20240 physically fall in this line
range but belong to the **material subsystem** — described only structurally here.

## Purpose — 2-4 sentences.
This region sits between parsing and the main `ufbxi_finalize_scene` (21641, next
subsystem). `ufbxi_pre_finalize_scene` runs *only when needed* and does the messy,
graph-mutating work of the old ufbx: it computes attribute-instance counts, derives a
provisional parent/child linked list from OO connections, and can synthesize brand-new
helper nodes (geometry-transform helpers, scale helpers) plus rewrite pivot properties
so the rest of ufbx sees a normalized document. Scene processing then resolves the raw
`(src_fbx_id, dst_fbx_id, src_prop, dst_prop)` connection tuples into typed
`ufbx_connection` records pointing at real elements, sorts them for binary search,
attaches per-element connection slices, marks animated properties, and linearizes the
node hierarchy into a depth-ordered array with cached `node_depth` and stable
`typed_id`s. The `ufbxi_fetch_*` helpers then walk sorted connection slices to build
the typed lists (materials, deformers, textures, blend keyframes…) that the DOM exposes.

## Key data structures

**ID identity model (three distinct id spaces — critical):**
- **`fbx_id` (uint64)** — the identity used *inside the FBX file*. Post-7000 it is the
  file's 64-bit object UID; pre-7000 it is a synthesized 64-bit hash of the `Type::Name`
  pair (see 14961/15280/15669). Connections in the file reference elements by fbx_id.
- **`element_id` (uint32)** — a dense global index assigned in creation order across ALL
  elements; indexes `uc->scene.elements` and all the temp side-arrays
  (`instance_counts`, `modify_not_supported`, `tmp_element_flag`, `element_offsets`).
  Stable through pre-finalize; used as the sort key that gives connections a total order.
- **`typed_id` (uint32)** — index *within one element type's* list (e.g. the Nth node,
  Nth mesh). Indexes `pre_nodes`, `pre_meshes`, `pre_anim_values`, and
  `tmp_typed_element_offsets[type]`. NOTE: `ufbxi_linearize_nodes` **reassigns** node
  `typed_id`s to depth-sorted order (18984–18987), so a node's typed_id before/after
  linearize differs; the offset array is permuted in lockstep.

**`ufbxi_fbx_id_entry` (6299):** `{ uint64 fbx_id; uint32 element_id; uint32 user_id; }`
— hash-map value keyed by fbx_id (map `uc->fbx_id_map`, hash = `ufbxi_hash64(fbx_id)`).
The single source of truth for fbx_id → element_id. `ufbxi_find_fbx_id` (12325) does the
lookup; `ufbxi_find_element_by_fbx_id` (18547) returns the resolved `ufbx_element*`.

**`ufbxi_fbx_attr_entry` (6310):** `{ uint64 node_fbx_id; uint64 attr_fbx_id; }` — map
`uc->fbx_attr_map`. Lets a node's fbx_id be remapped to its attribute's fbx_id
(`ufbxi_find_attribute_fbx_id`, 18655; returns the input unchanged if no entry). Used
for pre-7000 property/deformer redirection.

**`ufbxi_tmp_connection` (6316):** the raw parsed connection —
`{ uint64 src, dst; ufbx_string src_prop, dst_prop; }`. OO connections have both props
empty; OP/PO connections carry a property name on one side. These live in
`uc->tmp_connections`; resolution consumes them into `ufbx_connection`.

**`ufbx_connection`** (header): `{ ufbx_element *src, *dst; ufbx_string src_prop, dst_prop; }`.
`ufbx_static_assert` at 18636 guarantees no padding (`2*ptr + 2*string`) so
`(&a->src)[index]` / `(&a->src_prop)[index]` pointer arithmetic works for the dual
src/dst sort.

**`ufbx_element` base (header 763):** `name, props, element_id, typed_id, instances
(ufbx_node_list), type, connections_src, connections_dst, dom_node, scene`. Every typed
struct aliases this header via a union. `instances` = the nodes that reference an
attribute (populated later); `connections_src`/`_dst` are slices into the two globally
sorted connection arrays.

**Pre-finalize scratch structs (18068–18090):**
- `ufbxi_pre_connection { ufbx_element *src, *dst; }` — resolved element ptrs parallel to
  `tmp_connections`, so the two connection passes don't re-hash.
- `ufbxi_pre_node` — per-node working state: `has_constant_scale`,
  `has_recursive_scale_helper`, `has_skin_deformer`, `constant_scale` (vec3),
  `element_id`, and a **child linked list** via `first_child`/`next_child`/`parent`
  (all `~0u` = none). This provisional hierarchy exists *before* real parenting.
- `ufbxi_pre_mesh { bool has_skin_deformer; }`.
- `ufbxi_pre_anim_value { bool has_constant_value; ufbx_vec3 constant_value; }` — tracks
  whether an anim value is effectively constant (for scale-helper elision).

**`ufbxi_node_extra` (12507):** `{ uint32 geometry_helper_id; uint32 scale_helper_id; }`
— side-band data attached to a node via `ufbxi_push_element_extra` and fetched with
`ufbxi_get_element_extra` (7898), recording the element_ids of synthesized helper nodes
so later passes can redirect connections to them.

**`ufbxi_shader_mapping` / `ufbxi_shader_mapping_list` (19423/19431)** and the many
`ufbxi_*_pbr_mapping[]` tables (19445–20240): FBX/OBJ/PBR material property mapping
tables — **material subsystem**, not detailed here (see that subsystem's notes). Shape:
each entry is `{ uint8 index; uint8 flags; uint8 transform; uint8 prop_len; const char*
prop; }` mapping an FBX prop name → a `ufbx_material_(fbx|pbr)_map` slot with optional
value transform (`ufbxi_mat_transform_fns`, 19413) and widen/default flags.

## Control flow / algorithms

### `ufbxi_pre_finalize_scene` (18116) — optional graph mutation
Runs only if `required` (18118–18126): geometry_transform_handling ∈ {HELPER_NODES,
MODIFY_GEOMETRY}, or inherit_mode_handling ∈ {HELPER_NODES, COMPENSATE,
COMPENSATE_NO_FALLBACK}, or pivot_handling ∈ {ADJUST_TO_PIVOT, ADJUST_TO_ROTATION_PIVOT}
(or the UFBX_REGRESSION build flag). Otherwise returns immediately — **in the SwiftFBX
default config this whole function is a no-op** unless the user opts in.

Allocates parallel arrays over `num_elements` and `num_nodes` (18128–18167):
`instance_counts`, `modify_not_supported`, `node_attrib_type`, `has_unscaled_children`,
`has_scale_animation`, `pre_nodes`, `pre_meshes`, `pre_anim_values`, and a snapshot of
`fbx_ids`. Tolerances: `scale_epsilon=0.001`, `pivot_epsilon=0.001`,
`compensate_epsilon=0.01` (18170–18172).

1. **Init pass (18174–18196):** for each element, if NODE seed `pre_node` with
   `constant_scale = Lcl Scaling` (default 1,1,1) and clear child links; if ANIM_VALUE
   seed `constant_value` from X/Y/Z (falling back to `d|X` etc.), default NaN.
2. **Connection pass 1 (18198–18282):** resolve src/dst via `ufbxi_find_fbx_id`, cache in
   `pre_connections`. For OO connections into a NODE:
   - attribute src (type in FIRST_ATTRIB..LAST_ATTRIB) → `++instance_counts[attr]`;
     `node_attrib_type[node.typed_id] = (count==1 ? attr type : UNKNOWN)`; mark
     `modify_not_supported` for attrib types other than mesh/line/nurbs curve/surface.
   - NODE src → set provisional parent + push into `first_child` linked list **only if
     the child had no parent yet** (first-wins, 18239). Also flag
     `has_unscaled_children[dst]` when a child's `original_inherit_mode != NORMAL`.
   - SKIN_DEFORMER → MESH sets `pre_mesh.has_skin_deformer`.
   For OP connections (dst_prop set) ANIM_CURVE→ANIM_VALUE: pick component index from
   dst_prop (X/d|X=0, Y=1, Z=2); if curve range ≥ scale_epsilon mark value non-constant,
   else record/average the constant and mark non-constant if it disagrees > scale_epsilon.
3. **Connection pass 2 (18284–18328):** propagate `instance_counts` up node→attrib (a
   node's count = max of its own and its attribs'), propagate `has_skin_deformer` to
   nodes, and for anim_value→node `Lcl Scaling` OP connections decide `has_constant_scale`
   by comparing the anim value's constant against the node's static scale (error <
   scale_epsilon).
4. **Pivot rewrite (18330–18458):** only under ADJUST_TO_PIVOT / ADJUST_TO_ROTATION_PIVOT.
   For each node reads RotationPivot/ScalingPivot/ScalingOffset; decides
   `should_modify_pivot`. ADJUST_TO_PIVOT requires rotation==scaling pivot within
   pivot_epsilon and appends 3 synthetic props (zeroed RotationPivot/ScalingPivot +
   adjusted GeometricTranslation); child_offset = −rotation_pivot. ADJUST_TO_ROTATION_PIVOT
   uses the algebra in the 18400–18435 comment to split the post-rotation translation into
   a scaled part (folded into new ScalingPivot/ScalingOffset) and a `child_offset` folded
   into children/geometry; `ufbxi_pivot_div` (18099) guards divide-by-≈0 scale
   (epsilon 0.0078125), `ufbxi_pivot_nonzero` (18092) uses epsilon 0.0009765625. After
   editing props it re-sorts + dedups them, sets `node->adjust_pre_translation +=
   rotation_pivot` and `has_adjust_transform`, and walks `first_child` pushing
   `child_offset` into each child's `adjust_pre_translation`.
5. **Geometry-transform helper pass (18460–18477):** for each NODE, create a helper if
   handling==HELPER_NODES, or MODIFY_GEOMETRY with `instance_counts>1 ||
   modify_not_supported` (can't bake geometry into shared/unsupported attribs). Calls
   `ufbxi_setup_geometry_transform_helper`.
6. **Scale helper / inherit-compensate pass (18479–18540):** for nodes with
   `has_unscaled_children` and no scale_helper yet: compute deviation of `constant_scale`
   from a reference (COMPENSATE uses the node's own x, else 1). If it deviates ≥
   scale_epsilon, or scale isn't constant, or |x|≤compensate_epsilon (and not
   COMPENSATE_NO_FALLBACK) → create a scale helper and **recursively** create scale
   helpers down the child linked list for COMPONENTWISE_SCALE / non-NORMAL children
   (the traversal at 18501–18531 is an explicit iterative DFS over first_child/next_child/
   parent, guaranteed to terminate because each pre_node has at most one parent).
   Otherwise under COMPENSATE modes, if |scale.x−1| ≥ scale_epsilon set
   `is_scale_compensate_parent`.

### `ufbxi_setup_geometry_transform_helper` (12512) & `ufbxi_setup_scale_helper` (12560)
Both synthesize a new `ufbx_node` via `ufbxi_push_synthetic_element` (getting a fresh
fbx_id + element_id), push its id to `tmp_node_ids`, connect it OO to the original node
(`ufbxi_connect_oo`), set a flag on `uc` (`has_geometry_transform_nodes` /
`has_scale_helper_nodes`), and record the helper's element_id in `ufbxi_node_extra`.
Geometry helper: only created if Geometric{Translation,Rotation,Scaling} is non-identity;
copies those into the helper's Lcl props and sets `node->has_geometry_transform`. Scale
helper: moves the node's Geometric*/Lcl Scaling props into the helper and resets the
originals to defaults (12585–12593); sets `node->scale_helper` and
`scale_node->is_scale_helper`.

### `ufbxi_resolve_connections` (18665)
Pops `tmp_connections`, allocates a result `connections_src` array (may be truncated).
- **Pre-7000 property redirection (18678–18693):** if a connection's src/dst prop name is
  *not* a known node property (`ufbxi_is_node_property_name`, 11736 — a pointer-set of
  interned node prop names) and the target element doesn't actually have that prop,
  redirect the endpoint's fbx_id to its attribute via `ufbxi_find_attribute_fbx_id`. This
  routes e.g. mesh-level animated props from the node to the geometry.
- For each tmp connection resolve both endpoints; **skip if either is unresolved**
  (dangling ids are silently dropped). Quirk (18700–18706): unless `disable_quirks`, drop
  any non-node src connected to the root node (warn BAD_ELEMENT_CONNECTED_TO_ROOT).
- **Helper remapping:** if `has_geometry_transform_nodes`, an attribute connected to a
  node that `has_geometry_transform` is redirected to that node's geometry helper
  (via node_extra). If `has_scale_helper_nodes`, connections into a node with a
  scale_helper are redirected to the helper *unless* the src is a plain NORMAL-inherit
  node child or a non-`Lcl Scaling` anim value (18722–18747); skin clusters reading a
  node's transform are pointed at the helper on the src side.
- Pre-7000 deformer redirection (18751–18759): SKIN/CACHE_DEFORMER connected to a node is
  re-pointed at the node's attribute (geometry).
- Emits `ufbx_connection` records, duplicates the array into `connections_dst`, then sorts
  src-array by src (index 0) and dst-array by dst (index 1) via `ufbxi_sort_connections`.

### Connection sort/search
`ufbxi_cmp_connection_less` (18638) sorts by `(&src)[index]` element pointer, then the
same-side prop string, then the opposite-side prop. `ufbxi_sort_connections` (18648) is a
stable sort. `ufbxi_find_dst_connections` / `_src_connections` (18997/19016) binary-search
a `[begin,end)` slice for a given prop name (empty = OO connections only, requiring the
*other* prop also empty). `ufbxi_find_prop_connection` (19271) finds the first OP
connection for a prop (opposite prop non-empty). All use interned-pointer equality
(`a->dst_prop.data == prop`) after a strcmp lower-bound — strings are pooled so pointer
identity means string equality.

### `ufbxi_add_connections_to_elements` (18782)
Single merge-walk over the element list and the two sorted connection arrays (both keyed
by element_id, so a forward sweep gives each element a contiguous
`connections_src`/`connections_dst` slice). For each element it then scans its dst
connections to find **animated/connected properties** (18808–18905): a property is
"animated" if it has an OP connection with a non-empty src_prop (→ CONNECTED flag) or a
connection from an ANIM_VALUE (→ ANIMATED flag). If the prop already exists it OR-s in the
flags; otherwise it synthesizes a new prop (copying prefix props to a stack buffer, seeded
from defaults or from anim_value defaults for Lcl Translation/Rotation/Scaling; pre-6000
uses the anim_value's `default_value`), flagged SYNTHETIC|ANIMATABLE, and NO_VALUE if no
default was found. Sets `elem->props.num_animated`.

### `ufbxi_linearize_nodes` (18914)
1. Fetch node ptrs from `tmp_node_ids` (creation order); `root_node = node_ptrs[0]`.
2. **Parenting (18936–18952):** nodes with no parent are attached to the root (unless
   `allow_nodes_out_of_root && version>=6000`; pre-6000 files have no explicit root
   connections). Then for each node, walk its dst OO connections (both props empty, src is
   NODE) and set `src->parent = this` — the authoritative parent assignment.
3. **Depth computation (18955–18975):** for each node, `node_depth` = walk up parents
   summing `p->node_depth+1`, short-circuiting on already-computed parents; guards cyclic
   hierarchy (`depth <= num_nodes`, error "Cyclic node hierarchy") and optional
   `node_depth_limit`. A second up-walk caches partial depths to keep it near O(n).
4. **Sort (18977):** `ufbxi_sort_node_ptrs` using `ufbxi_cmp_node_less` (18592): order by
   `node_depth`, then parent element_id, then geometry-transform-helpers first, then
   scale-helpers, then element_id. This yields a **stable parents-before-children,
   siblings-grouped-by-parent** ordering.
5. **Renumber (18979–18987):** assign each node its new depth-sorted `typed_id` and permute
   `tmp_typed_element_offsets[NODE]` to match.

### `ufbxi_fetch_*` list builders (19047–19262)
All follow the same shape: push matching connected elements onto `tmp_stack`, then
`ufbxi_push_pop` into the result buffer as a typed list.
- `ufbxi_fetch_dst_elements` / `_src_elements` (19047/19085): generic — collect
  connections whose opposite endpoint has a given type and prop; optional
  `search_node` (also search the element's node via `ufbxi_get_element_node`, 19035:
  for a geometry-transform-helper returns its parent, else the attribute's first
  instance) and `ignore_duplicates` (uses `tmp_element_flag` as a visited set, warns
  DUPLICATE_CONNECTION). `ufbxi_fetch_dst_element`/`_src_element` (19123/19137) return the
  first match only.
- `ufbxi_fetch_textures` (19151): material_texture list keyed by dst_prop (material_prop =
  shader_prop = the prop the texture is bound to).
- `ufbxi_fetch_mesh_materials` (19175): materials via OO connections; stops searching up
  the node chain as soon as any materials are found at one level.
- `ufbxi_fetch_deformers` (19199): SKIN/BLEND/CACHE deformers.
- `ufbxi_fetch_blend_keyframes` (19221): BLEND_SHAPE srcs → `ufbx_blend_keyframe`.
- `ufbxi_fetch_texture_layers` (19241): TEXTURE srcs → layers, reading `alpha`
  (Texture_alpha, default 1) and `BlendMode` enum (default REPLACE).

### Per-element finalizers (20244–20403)
- `ufbxi_add_constraint_prop` (20244): maps a constraint's connected node onto a role
  (node / ik_effector / ik_end_node / aim_up / target) by matching against
  `ufbxi_constraint_props`.
- `ufbxi_finalize_nurbs_basis` (20268): sets `num_wrap_control_points` by topology
  (closed=1, periodic=order−1, else 0); if order>1 and enough knots, computes t_min/t_max,
  dedups the knot vector into `spans`, and sets `valid` = knots monotonic non-decreasing.
- `ufbxi_finalize_lod_group` (20314): counts LOD levels from child count and
  `Thresholds|LevelN` props, builds `ufbx_lod_level[]` with distance + display, reads
  relative_distances / ignore_parent_transform / distance limits from props.
- `ufbxi_generate_normals` (20364): computes topology, generates a normal mapping + values
  via public `ufbx_compute_topology` / `ufbx_generate_normal_mapping` /
  `ufbx_compute_normals`, and installs a synthetic `vertex_normal` (index 0 is a shared
  zero normal). Sets `generated_normals`, `skinned_normal = vertex_normal`.

### Name resolution / uniquification
ufbx does **not** rename elements to make them unique. `ufbxi_finalize_scene` (21641, next
subsystem) builds `elements_by_name` — a `ufbx_name_element{name, type, _internal_key,
element}` per element sorted by `ufbxi_sort_name_elements` (18584) via
`ufbxi_cmp_name_element_less` (18556: compare `_internal_key` then strcmp then… stable).
`_internal_key` is the first-4-bytes big-endian packing from `ufbxi_get_name_key` (11609).
Name lookups binary-search this array and iterate the equal-key/equal-name run — so
duplicate names coexist and all are returned. (This map construction sits just past the
20400 boundary but consumes `ufbxi_sort_name_elements` from this span.)

## Format details
- `ufbxi_get_name_key` (11609): 32-bit key = big-endian pack of the first 4 name bytes
  (short names zero-padded on the right). Used for `_internal_key` on props, name-elements,
  anim-props. Same value must be reproduced in Swift for compatible sort/search order.
- Attribute element-type range: `UFBX_ELEMENT_TYPE_FIRST_ATTRIB .. LAST_ATTRIB` — the test
  for "is this a node attribute" throughout this region.
- Version thresholds: pre-7000 (`0 < version < 7000`) triggers property-name→attribute
  redirection (18678) and deformer→geometry redirection (18751). Pre-6000
  (`version < 6000`) sources synthetic-prop defaults from the anim value's `default_value`
  (18874). Pre-6000 files have no explicit root connections → unparented nodes forced to
  root (18939). `allow_nodes_out_of_root` only honored for `version >= 6000`.
- fbx_id: post-7000 = file 64-bit UID; pre-7000 = synthesized hash of `Type::Name`.
- `~0u` (0xFFFFFFFF) is the sentinel for "no child/parent" in `ufbxi_pre_node`.
- Pivot epsilons: `ufbxi_pivot_nonzero` = 0.0009765625 (2⁻¹⁰); `ufbxi_pivot_div` guard =
  0.0078125 (2⁻⁷). Pre-finalize tolerances: scale/pivot 0.001, compensate 0.01.
- `ufbx_connection` layout is padding-free by static assert (2 ptrs + 2 strings); the
  index-based dual sort relies on `&conn->src` and `&conn->src_prop` being packed arrays.

## Quirks & edge cases
- **First-parent-wins (18239):** a node keeps the *first* OO-node parent seen in
  pre-finalize; later parent connections are ignored for the provisional hierarchy. The
  authoritative parenting in `ufbxi_linearize_nodes` (18950) is *last-wins* per its scan
  order — two different rules; the pre-finalize one only feeds helper/offset logic.
- **Non-node connected to root dropped (18700):** unless `disable_quirks`; some exporters
  wire arbitrary elements to root and break downstream code.
- **Dangling connections silently skipped** whenever either fbx_id fails to resolve
  (18209, 18288, 18698).
- **node_attrib_type set to UNKNOWN when >1 attribute instance** (18218) — a node with two
  meshes has ambiguous attrib type.
- **Skinning blocks geometry-transform baking (18365):** `has_skin_deformer` forces
  `can_modify_geometry_transform = false` because baking geometry transform corrupts skin.
- **MODIFY_GEOMETRY_NO_FALLBACK** disables geometry modification when the attribute is
  instanced (>1) or an unsupported type (18359).
- **Empties + pivot handling (18350):** ADJUST_TO_ROTATION_PIVOT skips geometry transform
  for EMPTY attributes unless `pivot_handling_retain_empties`, else disallows geometry mod.
- **`ufbxi_pivot_div` divide-by-≈0 guard (18099):** if |scale| < 2⁻⁷ the offset is returned
  undivided, deliberately leaving a residual parent translation (see 18411 comment) rather
  than producing NaN/Inf.
- **Recursive scale-helper DFS termination (18500 comment):** relies on each `pre_node`
  having at most one parent so any cycle must include the start node, which bounds the walk.
- **Constant-scale/value detection uses averaged curve midpoints** (18272) and NaN-seeded
  components (18189) so an unset component can be filled by the first connection.
- **Duplicate connection warning (19058/19096):** `ignore_duplicates` fetches dedup via
  `tmp_element_flag` and emit UFBX_WARNING_DUPLICATE_CONNECTION; flags are cleared after.
- **Synthetic property NO_VALUE flag (18880):** animated prop with no default and no
  anim_value gets NO_VALUE so evaluation knows there's no base.
- **Interned-pointer string comparison:** `conn->dst_prop.data == name.data` (18834,
  19006, 19161) — depends on all prop-name strings being pooled to a single instance. Any
  Swift port that doesn't intern strings must compare by value here.
- **Root-node inherit-mode override (21736, just past span):** top-level nodes forced to
  NORMAL under TRANSFORM_ROOT + PRESERVE so unit scaling works.
- **NURBS basis validity** requires knots monotonic non-decreasing (20302); LOD relative
  distances default level-0 distance to 100 (20348).

## Port guidance
- **Gate `pre_finalize` behind opts, default off.** For SwiftFBX v1 the entire helper-node
  / pivot-rewrite machinery (18066–18543) is only reached when the user selects a non-
  default `geometryTransformHandling` / `inheritModeHandling` / `pivotHandling`. Port it,
  but it can be a later milestone — the default document path never calls it. If skipped
  initially, ensure `has_geometry_transform_nodes` / `has_scale_helper_nodes` stay false so
  the remapping branches in `ufbxi_resolve_connections` are inert.
- **Port connection resolution + sort faithfully** (18665, 18782, 18914, 18638). This is
  load-bearing for the whole DOM. Represent `ufbx_connection` as a value struct; store the
  two sorted arrays and give each element `connections_src/dst` as `ArraySlice` or
  (offset,count) ranges into them. Keep the exact `_internal_key` packing and the
  compare-key-then-strcmp ordering so binary searches match.
- **Three id spaces:** model `fbxId` (UInt64), `elementId` (UInt32 dense global),
  `typedId` (UInt32 per-type) as distinct types (consider distinct wrapper structs to
  avoid mixups). Replace the C hash maps with Swift `Dictionary<UInt64, Int>` (fbx_id→
  element index) and `Dictionary<UInt64, UInt64>` (node→attr). Note typed_id is mutated by
  linearize — do the same permutation.
- **String interning is a prerequisite.** Either intern all prop/name strings (recommended,
  preserves pointer-equality fast paths) or replace every `data == data` check with value
  comparison. Interning also gives you the O(1) `ufbxi_is_node_property_name` set.
- **`ufbxi_fetch_*` → generic Swift helper** `fetch<T>(connections, type, prop, searchNode,
  ignoreDuplicates)` returning `[T]`. The `search_node` up-walk (`ufbxi_get_element_node`)
  and the duplicate visited-set are the only subtle bits.
- **Throwing errors:** the `ufbxi_check` failure points (allocation, "Cyclic node
  hierarchy", "Node depth limit exceeded") become `throw`s. Warnings
  (BAD_ELEMENT_CONNECTED_TO_ROOT, DUPLICATE_CONNECTION) go to a collected warnings array.
- **Skip per scope:** the material shader-mapping tables (19372–20240) belong to the
  material subsystem; NURBS tessellation is OUT (but `ufbxi_finalize_nurbs_basis` data-model
  fields stay — cheap, keep). `ufbxi_generate_normals` depends on the triangulation/topology
  utilities (`ufbx_compute_topology`, `ufbx_generate_normal_mapping`, `ufbx_compute_normals`)
  which are the NGON/topology subsystem — port those there, call them here.
- **Dependencies FED / CONSUMED:**
  - *Consumes* the parser's output: `tmp_connections`, `tmp_node_ids`,
    `tmp_typed_element_offsets`, `fbx_id_map`, element buffers, and per-element props
    (parser + element-reading subsystems).
  - *Feeds* the main `ufbxi_finalize_scene` (21641, "scene processing part 2"): sorted
    connections, per-element connection slices + animated-prop flags, the depth-ordered
    node array with `node_depth`/`typed_id`, and `elements_by_name` sort. Also feeds the
    **transform-evaluation** subsystem (`adjust_pre_translation`, `has_adjust_transform`,
    `scale_helper`, `is_scale_compensate_parent`, `inherit_scale_node`) and the
    **skin/deformer**, **material**, and **animation** subsystems via the fetch helpers.
