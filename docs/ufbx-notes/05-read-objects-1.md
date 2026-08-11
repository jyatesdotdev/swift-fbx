# Reading the parsed data, part 1: header/templates/object dispatch/model/geometry

## Purpose
This span turns the generic DOM tree (`ufbxi_node` trees produced by the binary/ASCII parser) into typed ufbx
elements. It covers: reading the `FBXHeaderExtension` block and exporter/version detection, reading property
templates from the `Definitions` section, the `Type::Name` / `Name\x00\x01Type` splitting and per-object-type
dispatch that instantiates elements (`ufbxi_read_object`/`ufbxi_read_objects`), `ufbxi_read_model` (turns a
`Model` FBX node into a `ufbx_node`, including synthetic "geometry transform helper" and "scale helper" nodes),
and the single biggest function in this span, `ufbxi_read_mesh`, which decodes vertex positions, the
polygon/face index encoding, and every per-vertex "layer element" (normals, UV, colors, tangents/binormals,
smoothing, materials, polygon groups, edge creases/visibility, "hole" flags) across all FBX mapping/reference
mode combinations. It also documents `ufbxi_read_shape` (blend shape deltas) and the face-grouping/material
partition logic that `ufbxi_read_mesh` and later finalization reuse.

## Key data structures

- **`ufbxi_template`** (ufbx.c:6293-6297) — one entry per `Definitions > ObjectType` block: `type` (interned FBX
  class name, e.g. `"Model"`), `sub_type` (from `PropertyTemplate`'s name, `Fbx` prefix stripped), `props`
  (default `ufbx_props` for that class/sub_type pair). Looked up later by `ufbxi_find_template`.
- **`ufbxi_element_info`** (ufbx.c:6322-6327) — scratch struct passed down into every `ufbxi_read_*` element
  reader: `fbx_id` (64-bit object id, real or synthetic), `name`, `props` (already-read+templated properties),
  `dom_node` (optional DOM retention pointer). This is the "pre-typed" bag of data that `ufbxi_push_element_size`
  bakes into the actual `ufbx_element` header.
- **`ufbx_prop` / `ufbx_props`** (ufbx.h:449-539, 567-572) — a property has `name`, `type` (`ufbx_prop_type`),
  `_internal_key` (first 4 bytes of name packed into a `uint32_t`, used for fast binary-search comparisons),
  value slots for int/real/vec/string/blob (all populated redundantly regardless of declared type), and
  `flags` (`ufbx_prop_flags`, ufbx.c:11807-11866 sets ANIMATABLE/USER_DEFINED/HIDDEN/LOCK_*/MUTE_* from the FBX
  "flags string"; VALUE_INT/VALUE_REAL/VALUE_STR/VALUE_BLOB record which value slots are actually present).
  `ufbx_props.defaults` chains to the class's `ufbxi_template` props (or another node's props for
  inheritance), forming a linked lookup chain walked by `ufbxi_find_prop_with_key` (ufbx.c:11480-11509, binary
  search + linear scan + fall through to `defaults`).
- **`ufbx_element` / `ufbx_element_type`** (ufbx.h:763-774 and the type enum) — common header prepended to
  every typed element (`ufbx_node`, `ufbx_mesh`, `ufbx_light`, ...) via an anonymous union; carries
  `element_id` (global dense index), `typed_id` (per-type dense index), `name`, `props`, `instances`
  (`ufbx_node_list` — nodes that instance this element), `connections_src/dst`, `dom_node`.
- **`ufbx_vertex_attrib`** (ufbx.h:1007-1025, and its typed aliases `ufbx_vertex_real/vec2/vec3/vec4`, same
  layout, checked via `ufbx_static_assert`s at ufbx.c:12730-12733) — generic "layer element" representation:
  `exists`, `values` (deduplicated value array), `indices` (per mesh-index lookup into `values`, length =
  `mesh->num_indices` once normalized), `value_reals` (components per value, patched in by
  `ufbxi_patch_mesh_reals`), `unique_per_vertex` (true if the attribute is guaranteed 1:1 with logical
  vertices, enabling the `vertex_first_index` fast path), `values_w` (optional 4th component, e.g. tangent/
  normal W, only populated when `retain_vertex_attrib_w` is set).
- **`ufbx_face`** (ufbx.h:1113-1116) — `{index_begin, num_indices}` into the mesh's flat index array; a face
  with `num_indices < 3` is a degenerate "empty/point/line" face (still recorded, not dropped in v1 decode —
  filtering happens downstream in the option-scoped skip logic).
- **`ufbx_edge`** (ufbx.h:1099-1104) — `{a, b}`, each an index into the mesh's flat vertex-index array (NOT a
  vertex id); an edge connects two consecutive polygon corners.
- **`ufbx_uv_set` / `ufbx_color_set`** (ufbx.h:1076-1093) — named/indexed UV or color layers, each owning a
  `ufbx_vertex_vec2`/`vec4` plus (for UV sets) optional per-set tangent/bitangent attributes hung off later by
  the `Layer`/`LayerElement` cross-reference pass.
- **`ufbx_mesh_part` / `ufbx_face_group`** (ufbx.h:1121-1147) — a `ufbx_face_group` is one polygon-group id
  (`LayerElementPolygonGroup`) with a display `name` (filled in later from `Layer`/grouping node when present);
  a `ufbx_mesh_part` is the face-index partition for one group *or* one material id (reused code path,
  `ufbxi_assign_face_groups`, also called later per-material during finalization — this span only shows the
  face_group variant).
- **`ufbxi_tangent_layer`** (ufbx.c:12655-12658) — transient struct pairing a `LayerElementTangent`/`Binormal`'s
  FBX `TypedIndex` with its decoded `ufbx_vertex_vec3`, used to cross-link tangents/binormals into the right
  UV set via the mesh's `Layer` children.
- **`ufbxi_tmp_mesh_texture`** (ufbx.c:6334-6339) — pre-7000-style per-face texture-id assignment
  (`LayerElementTexture`/`LayerElement<Prop>Textures`), stashed as `ufbxi_mesh_extra` for later resolution by
  the materials subsystem (out of this span's detailed scope).
- **`ufbxi_blend_offset`** (ufbx.c:12990-12994) — sortable `{vertex, position_offset, normal_offset}` triple
  used to re-sort blend shape deltas into ascending vertex order when the source data isn't already sorted.
- **Sentinel index pointers** `ufbxi_sentinel_index_zero` / `ufbxi_sentinel_index_consecutive` (ufbx.c:12663-12664)
  — fake 1-element/marker arrays used as `indices.data` for "AllSame" (all zero) or "Direct ByPolygonVertex with
  enough elements" (0,1,2,3,...) mapping modes; real backing storage is allocated once, sized to
  `uc->max_zero_indices` / `uc->max_consecutive_indices` (running maxima updated throughout parsing, e.g.
  ufbx.c:12848, 12866, 12901, 13213-13214, 13711), during finalization (not in this span) and the sentinel
  pointer is swapped for a real pointer into that shared buffer. **Port implication**: a Swift port doesn't need
  this optimization; a real allocated `[UInt32]` (all-zero, or `0..<n`) is fine and far simpler — but the
  *semantics* (all-same / consecutive index generation for these mapping modes) must be preserved.

## Control flow / algorithms

### 1. `ufbxi_read_header_extension` (ufbx.c:11981-12033)
Iterates top-level children of `FBXHeaderExtension` via `ufbxi_parse_toplevel_child` (loop until null):
- `Creator` (string) → `uc->scene.metadata.creator`.
- `FBXVersion` (int), only if `uc->version < 6000`: pre-6000 ASCII files store the version here instead of the
  top header; take the max of current `uc->version` and this value if it's a plausible pre-6000 version.
- `FBXHeaderVersion` (int) → local `header_version`.
- `OtherFlags > TCDefinition` (int) → `tc_definition`, `has_tc_definition = true`.
- `SceneInfo` → `ufbxi_read_scene_info` (reads scene metadata props + optional embedded `Thumbnail`).

After the loop: FBX 8000+ changed KTime tick units; the new unit is opt-in via `TCDefinition`. Rule (ufbx.c:12021-12029):
`use_v7_ktime = version < 8000`; if `header_version >= 1004 && has_tc_definition`, override to
`use_v7_ktime = (tc_definition == 127)`. Then `uc->ktime_sec = use_v7_ktime ? 46186158000 : 141120000` (ticks
per second — this feeds the animation-curve time-decoding subsystem, NOT covered in this span but is a critical
constant to carry over).

### 2. Exporter/version-string matching — `ufbxi_match_version_string` + `ufbxi_match_exporter` (ufbx.c:12035-12128)
A tiny pattern-matcher against the `Creator` string: lowercase-letter literals match case-insensitively, `' '`
skips whitespace/tabs, `'-'` skips-until-next-hyphen (then consumes it), `./()_ ` are literal single chars,
`'?'` greedily consumes digits into `p_version[]`. `ufbxi_match_exporter` (ufbx.c:12084-12128) tries a fixed
ordered list of patterns (`"blender-- ?.?.?"`, `"blender- ?.?"`, `"blender version ?.?"`,
`"fbx sdk/fbx plugins version ?.?"`, `"fbx sdk/fbx plugins build ?"` — note this one packs a single 6-digit
number into major/minor/patch via `/10000, /100%100, %100`, cf. `1006` build-number style numbering used by
Autodesk —, `"motionbuilder version ?.?"`, `"motionbuilder/mocap/online version ?.?"`, `"ufbx_write"`) and sets
`uc->exporter` / `uc->exporter_version` (via `ufbx_pack_version`). If `opts.disable_quirks`, the detected
exporter is reset to `UFBX_EXPORTER_UNKNOWN` (used purely to gate quirk workarounds later, e.g.
`uc->blender_full_weights = true` for Blender binary exports at ufbx.c:12124). **Port guidance**: keep this
faithfully — it gates many quirks elsewhere in ufbx that a faithful Swift port will also need to replicate.

### 3. `ufbxi_read_document` (ufbx.c:12130-12149)
Scans top-level `Document` nodes (post-7000 only in practice); takes the **first** `Document` block's
`RootNode` (Int64) as `uc->root_id`. TODO comment in source: multiple documents/roots aren't handled.

### 4. `ufbxi_read_definitions` (ufbx.c:12151-12193) + `ufbxi_find_template` (ufbx.c:12195-12218)
For each top-level `ObjectType` node: push a `ufbxi_template`, read its class name (`C` value = interned FBX
type string, e.g. `"Model"`, `"Material"`). If the node has a `PropertyTemplate` child (post-7000 files only —
pre-7000 files only have raw object counts and no templates): read its `S` value as `sub_type`, strip a leading
`"Fbx"` prefix (re-interning the trimmed string into the string pool since it's now a substring pointer, ufbx.c:12172-12182),
with a **hack**: `"LODGroup"` (8 chars, from the Template) is rewritten to `"LodGroup"` (matches how `Object`
blocks spell it — case mismatch between `Definitions` and `Objects` sections). Then reads that
`PropertyTemplate`'s properties via `ufbxi_read_properties` into `tmpl->props`. All templates are moved from
the temp stack into `uc->templates` at the end.

`ufbxi_find_template(uc, name, sub_type)` linear-scans `uc->templates` (marked TODO: binary search) matching
`tmpl->type == name` (pointer equality — relies on string interning) AND (for everything except
`Material`/`Model`/`AnimationStack`/`AnimationLayer`, which match **any** sub-type) `tmpl->sub_type.data ==
sub_type` (also pointer equality). Returns `NULL` if no match or the template has zero properties. This becomes
`info.props.defaults` for every object of that class (ufbx.c:14985), i.e. the inheritance chain root for
property lookups.

### 5. Property reading — `ufbxi_read_property` (ufbx.c:11798-11869), `ufbxi_read_properties` (ufbx.c:11903-11932)
Per FBX `P:` node, values are positional (`S`=string, `C`=raw char*, `L`=int64, `R`=real, `B`? not used directly
here). Layout differs by `Properties70` (version=70) vs `Properties60` (version=60, older):
`name, type[, subtype (70 only)], flags_str, value...`. Steps:
1. Get `name` (val 0) and `type_str` (val 1) always.
2. version==70 only: also read `subtype_str` at val 2, advancing `val_ix` to 3 (else stays at 2).
3. Read optional flags string at `val_ix++`: char-by-char — `'A'`→ANIMATABLE, `'U'`→USER_DEFINED, `'H'`→HIDDEN,
   `'L'`+digit→ `LOCK_*` (digit 0-15 packed into bits 4-7 of flags, i.e. `(digit&0xf)<<4`),
   `'M'`+digit→`MUTE_*` (bits 8-11). Unknown letters ignored.
4. Resolve `prop->type` via `ufbxi_get_prop_type(type_str)`; if `UFBX_PROP_UNKNOWN` and a `subtype_str` was
   read, retry with that. The type-name → `ufbx_prop_type` table is at ufbx.c:11436-11467 (pointer-hashed map;
   entries include both proper-case and lowercase spellings like `"Boolean"/"bool"/"Bool"`, `"Number"/"double"/
   "Real"/"Float"/"Intensity"`, `"Vector"/"Vector3D"`, `"Color"/"ColorRGB"` vs `"ColorAndAlpha"`,
   `"String"/"KString"/"object"`, `"Lcl Translation"/"Lcl Rotation"/"Lcl Scaling"`, `"Distance"`, `"Compound"`,
   `"Blob"`, `"Reference"`, `"Integer"/"int"/"enum"/"Enum"/"Visibility"/"Visibility Inheritance"/"KTime"`).
5. Read optional int (`L`) at `val_ix` → sets `VALUE_INT` flag if present.
6. Read up to 4 consecutive `R` (real) values starting at `val_ix` → `value_real_arr[0..3]`; `real_ix` counts
   how many were found; if `real_ix>0`, sets `VALUE_REAL << (real_ix-1)` i.e. `VALUE_REAL` for 1 real,
   `VALUE_VEC2` for 2, `VALUE_VEC3` for 3, `VALUE_VEC4` for 4 (bit-shifted flag trick since the four flags are
   consecutive powers of two, ufbx.h:530-533).
7. **Quirk** (ufbx.c:11842-11848): if the value at `val_ix` (after the reals) is *not* a string, skip one slot
   forward before checking for the trailing string — because some exporters emit mixed number+string tuples,
   e.g. `Lod Distance: P: "Thresholds|Level0","Distance","","",64,"cm"` (number then unit string) or
   `User_Enum: P: "User_Enum","Enum","","A+U",1,"ValueA~ValueB~ValueC"` (int then pipe-list string) — without
   this skip the string would be misread as occupying the number's slot.
8. Read trailing string (`S`) at (possibly advanced) `val_ix` → `prop->value_str`; if non-empty, ALSO try to
   reinterpret the same slot as blob (`'b'`) into `prop->value_blob` (best-effort, ignored on failure) — sets
   `VALUE_STR` flag. If no string, `value_str = ufbx_empty_string`.
9. Rare non-standard case (ufbx.c:11859-11864): if the `P:` node has children, look for a `BinaryData` child
   and read it via `ufbxi_read_embedded_blob` into `prop->value_blob`, set `VALUE_BLOB` flag.
10. `prop->flags` finalized.

`ufbxi_read_properties` (parent, props): finds `Properties70` else `Properties60` child (absence is NOT an
error — props are just empty); allocates one `ufbx_prop` per child node, calls `ufbxi_read_property` on each,
then **stable-sorts** by `(_internal_key, then strcmp(name))` (`ufbxi_sort_properties`/`ufbxi_prop_less`,
ufbx.c:11871-11883) and **deduplicates** consecutive entries with identical *interned* `name.data` pointer
(`ufbxi_deduplicate_properties`, ufbx.c:11885-11901 — keeps the LAST of a run of duplicates, since it does
`src++` without ever copying the earlier duplicate forward). Sorting enables the later binary-search lookup
(`ufbxi_find_prop_with_key`).

### 6. Embedded blob reading — `ufbxi_read_embedded_blob` (ufbx.c:11764-11796)
Reads a `Content`/binary-data node's array of string "parts" (an FBX oddity: large embedded binary content, e.g.
textures, can be split across multiple `C` array entries, especially from ASCII files that must chunk it).
Fast path: exactly 1 part and not ASCII-parsed → use it directly (no copy). Otherwise concatenate all parts into
one contiguous allocation in `uc->result`.

### 7. Object dispatch — `ufbxi_read_object` (ufbx.c:14947-15099) and `ufbxi_read_objects`/`_threaded` (ufbx.c:15101-15160+)
*(These specific functions live at lines 14947-15160+, past this span's nominal 11762-13550 boundary — the
next notes file should own their exhaustive per-class dispatch table; documented here only because
`ufbxi_split_type_and_name`, which they depend on, lives in-range and the task calls out the dispatch
explicitly.)*

`ufbxi_read_objects` loops `ufbxi_parse_toplevel_child` over the `Objects` section, calling `ufbxi_read_object`
per child (plus bookkeeping a "deferred element id" slot used to attribute warnings to the right element even
before it's fully constructed — `uc->p_element_id`). A threaded variant (`ufbxi_read_objects_threaded`) batches
nodes across a thread pool; **out of v1 Swift scope** (scope excludes threading).

`ufbxi_read_object(uc, node)` (ufbx.c:14947-15099):
1. Special-case: `node->name == GlobalSettings` → `ufbxi_read_global_settings` (scene metadata: axes/units/frame
   rate — a different subsystem) and return.
2. Parse the object's identity tuple, format depends on version:
   - `version >= 7000`: node values are `"Lss"` → `(fbx_id: Int64, type_and_name: String, sub_type: String)`.
     `fbx_id` is validated/remapped via `ufbxi_validate_fbx_id` (ufbx.c:12260-12269) — if it's `>=
     UFBXI_POINTER_ID_START` (`0x8000000000000000`, an out-of-band sentinel range reserved for synthetic
     "pointer-based" ids that might collide with real 64-bit FBX ids), it's rehashed through
     `ufbxi_synthetic_id_from_ptr_id` into the actual synthetic-id space.
   - `version < 7000`: node values are `"ss"` → `(type_and_name, sub_type)` only; `fbx_id` is *derived* from
     the string pointer via `ufbxi_synthetic_id_from_string` (ufbx.c:12250-12258) — pre-7000 FBX has no numeric
     object ids, so the interned `Name::Type` string's pointer identity stands in for one (fast path: if the
     pointer value itself is small enough to not collide with the reserved ranges, use it directly, else hash
     it through the ptr→id map).
   - Failing to parse either tuple is **not a load error**: `return 1` (skip node) — "there's some weird
     objects mixed in every now and then" (ufbx.c:14959-14960).
3. Strip a leading `"Fbx"` prefix from `sub_type_str` (same as templates), re-intern.
4. `ufbxi_split_type_and_name(type_and_name, &type_str, &info.name)` — see below.
5. `info.props` read via `ufbxi_read_properties`; `info.props.defaults = ufbxi_find_template(node->name,
   sub_type)`.
6. Dispatch on `node->name` (the outer FBX node tag, e.g. `"Model"`, `"NodeAttribute"`, `"Geometry"`,
   `"Deformer"`, `"Material"`, `"Texture"`, `"LayeredTexture"`, `"Video"`, `"AnimationStack"`,
   `"AnimationLayer"`, `"AnimationCurveNode"`, `"AnimationCurve"`, `"Pose"`, `"Implementation"`,
   `"BindingTable"`, `"Collection"`, `"CollectionExclusive"`, `"SelectionNode"`, `"Constraint"`, `"SceneInfo"`,
   `"Cache"`, `"ObjectMetaData"`, `"AudioLayer"`, `"Audio"`), and for `"NodeAttribute"`/`"Geometry"`/
   `"Deformer"`/`"Constraint"` further dispatch on `sub_type` (e.g. `NodeAttribute`+`"Light"` →
   `ufbx_light`/`UFBX_ELEMENT_LIGHT` via the generic `ufbxi_read_element(uc,node,&info,sizeof(T),TYPE)` helper
   for types with no custom reader; `NodeAttribute`+`"LimbNode"|"Limb"|"Root"` → `ufbxi_read_bone`;
   `NodeAttribute`+`"Null"|"Marker"` → generic `ufbx_empty`; `Geometry`+`"Mesh"` → `ufbxi_read_mesh`;
   `Geometry`+`"Shape"` → `ufbxi_read_shape`; `Geometry`+`"NurbsCurve"/"NurbsSurface"/"Line"` → the NURBS/line
   readers (lines 13825-13964, **out of this span, and NURBS *tessellation* is explicitly OUT of v1 scope** —
   but note the NURBS/line *data* readers themselves live just past this span's line range and should probably
   be captured by whichever span covers 13550+). Anything unrecognized at any level falls through to
   `ufbxi_read_unknown` (ufbx.c:14992ff, 15029, 15043 etc.), which still creates a `UFBX_ELEMENT_UNKNOWN`
   element carrying the raw `type`/`sub_type`/`super_type` strings — **never silently dropped**, an important
   fidelity point for a lossless Swift port.
7. Every concrete reader ultimately calls one of `ufbxi_push_element_size`/`ufbxi_push_element` (typed, real
   `info.fbx_id`) or `ufbxi_push_synthetic_element_size`/`ufbxi_push_synthetic_element` (synthetic elements
   created out of nowhere, e.g. helper nodes, pre-7000 synthetic blend shapes/attributes — mints a fresh
   `ufbxi_push_synthetic_id`).

### 8. `ufbxi_split_type_and_name` (ufbx.c:12271-12305)
FBX packs "Type::Name" (ASCII) or "Name\x00\x01Type" (binary) into one string. Note the **order is swapped**
between formats (comment at ufbx.c:12282 literally says "???"). Algorithm: scan for the 2-byte separator
(`"::"` for ASCII, `"\x00\x01"` for binary) anywhere in the combined string (not just once — takes the first
occurrence found scanning left to right by incrementing `type_end` from 2); if found, split into name/type
per-format ordering as above; if not found, the whole string is the `name` and `type` is empty. Both output
strings are then re-interned (`ufbxi_push_string_place_str`) since they're now substrings of the pooled string
(pointer identity matters for later `==` comparisons on interned strings).

### 9. Element push mechanics — `ufbxi_push_element_size` (ufbx.c:12352-12382), `ufbxi_push_synthetic_element_size` (ufbx.c:12384-12414)
Both: compute `aligned_size = (size+7) & ~7` (8-byte alignment for the flexible per-type payload), assign
`typed_id` (current count of elements of this `type`, tracked via `uc->tmp_typed_element_offsets[type]`) and
`element_id` (global monotonically-increasing counter `uc->num_elements++`). Record parallel arrays: per-type
byte offset, global byte offset, fbx-id (real path only for the size variant), pointer to the element (for
later resolving connections). Zero-allocate `aligned_size` bytes in `uc->tmp_elements`, cast to `ufbx_element*`,
fill in `type`/`element_id`/`typed_id`/`name`/`props`/`dom_node`. Real variant additionally calls
`ufbxi_insert_fbx_id` (hash map `fbx_id → element_id`, warns `UFBX_WARNING_DUPLICATE_OBJECT_ID` on collision,
ufbx.c:12307-12323) so later `Connections` resolution can map `fbx_id`s to elements. Synthetic variant instead
mints a brand new id via `ufbxi_push_synthetic_id` (simple incrementing counter, ufbx.c:12229-12232) and still
registers it in the same `fbx_id_map` so it can participate in `Connections`-style OO/OP linking
(`ufbxi_connect_oo`/`_op`/`_pp`, ufbx.c:12419-12449 — push `{src,dst,src_prop,dst_prop}` tuples onto
`uc->tmp_connections` for later resolution, not covered here).

### 10. `ufbxi_read_model` (ufbx.c:12601-12627)
Pushes a `ufbx_node` element (`UFBX_ELEMENT_NODE`). Records its element id into `uc->tmp_node_ids` (a flat list
of node element-ids, used later to iterate all nodes). Reads `InheritType` int property (default `-1` =
unset): `0` → `original_inherit_mode = COMPONENTWISE_SCALE` ("RrSs"), `2` → `IGNORE_PARENT_SCALE` ("Rrs"); any
other value (including the FBX default `1`, "RSrs"/normal) leaves it at the zero-initialized
`UFBX_INHERIT_MODE_NORMAL`. Then, per `uc->opts.inherit_mode_handling`: `PRESERVE` copies
`original_inherit_mode` into the effective `inherit_mode`; `IGNORE` forces both fields to `NORMAL` (i.e. treat
every node as if it had normal inheritance, discarding the FBX file's stated mode) — the third handling mode
("current default", not shown here) is evidently the transform-chain subsystem's job to apply
`inherit_mode`/`original_inherit_mode` semantics at evaluation time (**out of this span**, feeds the node
transform-chain subsystem).

### 11. Geometry transform / scale helper synthesis
- `ufbxi_setup_geometry_transform_helper` (ufbx.c:12512-12546): if a `ufbx_node` has non-identity
  `GeometricTranslation/Rotation/Scaling` properties (FBX's "geometric transform", which affects only the mesh
  geometry, not children — unlike the main transform), synthesizes an **extra synthetic child node**
  (`is_geometry_transform_helper = true`) carrying those three values as its own `Lcl_Translation/Rotation/
  Scaling` properties, `oo`-connects it as a child of the real node, and marks `node->has_geometry_transform =
  true`. Stores the helper's element id in a per-node "extra" struct (`ufbxi_node_extra`, ufbx.c:12507-12510,
  reached via `ufbxi_push_element_extra` — a side-table keyed by element id, mechanism defined elsewhere).
  Rationale: ufbx's public transform chain model doesn't have a first-class "geometric transform" slot on
  `ufbx_node` for the *scene graph* (children must not inherit it), so it's modeled as an invisible extra node
  in the hierarchy instead. **Depends on / feeds**: the node transform-chain and scene-graph-construction
  subsystems (must know to filter/mark these helper nodes and apply their transform only to the mesh, not to
  real children).
- `ufbxi_setup_scale_helper` (ufbx.c:12560-12599): similar mechanism, but for `UFBX_INHERIT_MODE_*` scale
  workarounds — creates a synthetic child node that "absorbs" the parent's scale so children can have
  correct-looking transforms under non-standard inherit modes; moves (not copies) 4 named properties
  (`GeometricRotation/Scaling/Translation`, `Lcl_Scaling` — table at ufbx.c:12553-12558, defaults `{0,0,0}` for
  rotation/translation, `{1,1,1}` for scalings) from the real node onto the helper, resetting the real node's
  copies to their listed defaults. **This is transform-chain-subsystem territory**; noted here because the
  property-shuffling mechanics live in this span's line range.

### 12. Index sanitization — `ufbxi_fix_index` (ufbx.c:12666-12690) and `ufbxi_check_indices` (ufbx.c:12692-12728)
Central out-of-range-index policy, parameterized by `uc->opts.index_error_handling`:
- `UFBX_INDEX_ERROR_HANDLING_CLAMP`: clamp to `one_past_max_val - 1` (requires `one_past_max_val > 0`), emit
  `UFBX_WARNING_INDEX_CLAMPED`.
- `UFBX_INDEX_ERROR_HANDLING_NO_INDEX`: set to sentinel `UFBX_NO_INDEX` (`0xFFFFFFFF`).
- `UFBX_INDEX_ERROR_HANDLING_ABORT_LOADING`: format `"%u (max %u)"` into the error info and hard-fail the load.
- `UFBX_INDEX_ERROR_HANDLING_UNSAFE_IGNORE`: keep the bad index verbatim (caller beware — matches the option's
  name).
`ufbxi_check_indices(p_dst, indices, owns_indices, num_indices, num_indexers, num_elems)`: if the source index
array is shorter than required (`num_indices < num_indexers`), it is **copy-extended** with `UFBX_NO_INDEX`
padding (so truncated index arrays degrade to the same per-element handling as any other OOB index, rather than
being a special case) — this requires allocating a fresh buffer (`owns_indices = true`). Then does a single pass
replacing any `indices[i] >= num_elems` via `ufbxi_fix_index`; only copies the array (if not already owned) the
first time an actual out-of-bounds value is hit, to avoid needless allocation on well-formed files.

### 13. Generic layer-element reader — `ufbxi_read_vertex_element` (ufbx.c:12741-12926)
This is the single workhorse for every FBX "LayerElement*" node (normals/UV/color/tangent/binormal/vertex
crease). Signature takes the target `ufbx_vertex_attrib*`, the FBX array field names for `data`
(`data_name`/`data_type`, e.g. `"Normals"`/`'r'`), `indices` (`index_name`, always `'i'`), the optional `W`
component array name (`w_name`), and `num_components` (reals per value: 3 for normal/tangent/binormal, 2 for
UV, 4 for color, 1 for vertex crease).

Steps:
1. Look up the `data` array (required unless `!opts.strict`, in which case a totally missing data array just
   leaves the attribute absent rather than erroring — ufbx.c:12749-12753).
2. `num_elems = data->size / num_components` (validated evenly divisible). **HACK**: if `num_elems == 0`, leave
   the attribute unset entirely and return success (ufbx.c:12758-12762) — an empty data array is treated as "no
   attribute", not a zero-length one.
3. Set `attrib->exists = true`, `indices.count = mesh->num_indices`, `values.count = num_elems`. If
   `num_elems>0`, `values.data` points directly at the FBX array's storage (no copy — Swift port should slice/
   retain the decompressed array here, not copy). If (impossible given the above early-return, but defensive)
   `num_elems==0`, points at `ufbxi_zero_element + 4` (a static all-zero `ufbx_real[8]`, offset by 4 so that
   even a negative/`-1` index landing 4 slots back stays in bounds — belt-and-suspenders default value source).
4. Read `MappingInformationType` (`mapping`, one of `"ByPolygonVertex"`, `"ByVertex"`/`"ByVertice"` (both spellings
   accepted — Vertice is an older FBX SDK/exporter spelling), `"ByPolygon"`, `"AllSame"`; unrecognized values are
   handled by the `else` fallback of each branch below).
5. **Quirk**: if `mapping == "ByPolygon"` but the index array's length equals `mesh->num_indices` (i.e. it's
   actually per-corner, not per-face), silently remap `mapping` to `"ByPolygonVertex"` — "some old exporters
   seem to use ByPolygon to mean ByPolygonVertex" (ufbx.c:12783-12790).
6. Two top-level branches: **ReferenceInformationType == IndexToDirect** (an `<index_name>` array is present) vs
   **Direct** (no index array — values used positionally):
   - **IndexToDirect + ByPolygonVertex**: indices used as-is via `ufbxi_check_indices` against
     `mesh->num_indices` indexers and `num_elems` bound (ufbx.c:12796-12799).
   - **IndexToDirect + ByVertex/ByVertice**: the provided index array is itself indexed **by logical vertex**,
     not by corner — so a NEW per-corner index array is built by following `mesh->vertex_indices[corner] →
     index_data[vertex]` for every corner (ufbx.c:12801-12818); out-of-range vertex lookups go through
     `ufbxi_fix_index` directly (not `ufbxi_check_indices`, since the source index itself, not it's ultimate
     value, is what's out of range) . Sets `attrib->unique_per_vertex = true`.
   - **IndexToDirect + ByPolygon**: one index per **face**, broadcast to every corner of that face
     (ufbx.c:12820-12839); missing/short arrays default to `UFBX_NO_INDEX` per-face before broadcasting.
   - **IndexToDirect + AllSame**: entire attribute maps to the shared zero-index sentinel buffer
     (`unique_per_vertex = true`); bumps `uc->max_zero_indices`.
   - Unknown mapping under IndexToDirect: `memset(attrib,0,...)` (fully clears/disables it) + warn via
     `ufbxi_warn_polygon_mapping` (`UFBX_WARNING_MISSING_POLYGON_MAPPING`) and return success (not a hard error).
   - **Direct (no index array) + ByPolygonVertex**: if `num_elems >= mesh->num_indices`, reuse the shared
     consecutive-index sentinel (0,1,2,...); else (there are fewer direct values than corners — a truncated/
     malformed direct array) build an explicit `0..<num_indices` array and run it through `ufbxi_check_indices`
     so any index `>= num_elems` still gets sanitized.
   - **Direct + ByVertex/ByVertice**: reuse `mesh->vertex_position.indices.data` directly (borrowed, not owned
     — `owns_indices=false` passed to `ufbxi_check_indices`, which only copies if an OOB fixup is actually
     needed). `unique_per_vertex = true`.
   - **Direct + ByPolygon**: one value per face broadcast to corners, same as the indexed case but the "index"
     *is* the face number itself.
   - **Direct + AllSame**: shared zero-index sentinel, `unique_per_vertex = true`.
   - Unknown mapping under Direct: same clear+warn+return-success fallback.
7. Optional W-component (ufbx.c:12912-12923): only if `opts.retain_vertex_attrib_w` and a `w_name` was given;
   requires the `w` array's size to exactly equal `num_elems` (mismatch → warn
   `UFBX_WARNING_BAD_VERTEX_W_ATTRIBUTE`, W left unset — not fatal).

**Port guidance**: this function's branching (mapping mode × reference mode × index-array-shape) is exactly the
kind of logic that benefits from an explicit Swift enum-driven `switch` over `(MappingMode, ReferenceMode)`
tuples rather than string comparisons — but every one of the listed edge cases (ByPolygon→ByPolygonVertex
remap, ByVertice spelling, empty-data-means-absent, truncated Direct arrays, AllSame sentinel semantics) must be
preserved exactly, since real-world exporters rely on all of them.

### 14. `ufbxi_read_truncated_array` (ufbx.c:12928-12960)
Used for the simpler "one value per face/edge, no mapping-mode fan-out" attributes (edge crease/smoothing/
visibility ByEdge, face smoothing/hole/material ByPolygon, polygon group). Reads array `name`/`fmt`; if the
array doesn't exist, only warns (`UFBX_WARNING_MISSING_GEOMETRY_DATA`) and leaves the output empty — not fatal.
If the array is shorter than the required `size`, warns `UFBX_WARNING_TRUNCATED_ARRAY` and **extends** it: any
existing elements are copied as-is, and the array is padded by repeating the array's *last* element for all
remaining slots (or all-zero if the source array was itself empty). This is a different truncation policy than
`ufbxi_check_indices`'s `UFBX_NO_INDEX` padding — value arrays repeat-last, index arrays pad-with-sentinel.

### 15. `ufbxi_read_shape` (ufbx.c:13010-13075) — blend shape deltas
Requires both `Vertices` (position offset deltas, `'r'`, /3 per offset) and `Indexes` (target logical-vertex
index per offset, `'i'`); returns success-with-empty-element if either is absent (blend shape channel with no
geometry — not an error). Validates `indices.size == vertices.size/3`. Optional `Normals` child, same length as
`Vertices`, becomes `normal_offsets`. **No copy** of the underlying arrays — points directly into parsed array
storage. Then checks if `offset_vertices` (vertex index per offset) is already sorted ascending; if not, sorts
`{vertex, position_offset, normal_offset}` triples via `ufbxi_sort_blend_offsets` (stable sort, tmp-stack
scratch buffer) and writes the reordered fields back in place. Sorted-by-target-vertex order is presumably
relied on by the blend-deformer evaluation subsystem for binary-search/merge access patterns (out of this
span).

### 16. `ufbxi_read_synthetic_blend_shapes` (ufbx.c:13077-13137) — pre-7100 inline blend shapes
For FBX ≤7100, blend shapes are nested directly as `Shape` children of the `Geometry`/mesh node itself (rather
than being separate `Geometry`+`"Shape"` typed objects wired up via `Connections`, as in later versions). This
function synthesizes the missing object graph: on the first `Shape` child, creates one synthetic
`ufbx_blend_deformer` (`oo`-connected to the mesh); for every `Shape` child creates a synthetic
`ufbx_blend_channel` carrying a single synthetic `DeformPercent` property (type `NUMBER`), whose initial value
is pulled from a same-named property on the *mesh* itself if present (numeric `Number`/`Integer` type) — and if
so, a `pp` (prop-to-prop) connection is registered from the mesh's `name`-named prop to the channel's
`DeformPercent` prop so future animation on that mesh property continues to drive the channel (this `pp`
connection is unconditionally made for `version < 6000` even without a matching mesh property, ufbx.c:13116-13118
— presumably because pre-6000 files always drive shapes this way). Reads the shape geometry itself via
`ufbxi_read_shape` with a freshly synthesized `fbx_id`+`dom_node`, then `oo`-connects
`channel → deformer → mesh-owner` and `shape → channel`. Called from `ufbxi_read_mesh` only when
`uc->version <= 7100` (ufbx.c:13440-13442).

### 17. `ufbxi_process_indices` (ufbx.c:13139-13217) — polygon index decoding
Given the flat `PolygonVertexIndex` array (`index_data`, length `mesh->num_indices`), where **any negative
value marks the last corner of a polygon** (FBX's bit-flip-encoded face terminator, see Format details below):
1. First pass: count negative entries → `num_total_faces`; allocate `mesh->faces`.
2. Second pass: walk every index. On a negative value, un-negate it in place (`ix = ~ix; *p_ix = ix;` — bitwise
   NOT, not arithmetic negation) and close out the current face: `num_indices = (p_ix - p_face_begin) + 1`,
   record `{index_begin, num_indices}`. If `num_indices >= 3`: accumulate `num_triangles += num_indices - 2`
   (fan triangulation count) and track `max_face_triangles`. Else: bump `num_bad_faces[num_indices]` (index 0 =
   empty/degenerate zero-vertex face, 1 = point, 2 = line — these buckets become
   `mesh->num_empty_faces/num_point_faces/num_line_faces`). Every (unnegated) `ix` is bounds-checked against
   `mesh->num_vertices` via `ufbxi_check` — **this is a hard failure**, not sanitized via `ufbxi_fix_index` (a
   raw vertex-index overflow in the base position index array is treated as file corruption, unlike the
   layer-element index arrays which get the lenient `ufbxi_fix_index` treatment).
3. `mesh->vertex_position.indices.data = index_data` (the now-un-negated array becomes the position-attribute's
   index array too — same underlying storage, positions are "just another attribute" that happens to also
   define face structure).
4. Builds `mesh->vertex_first_index[vertex] = <first corner index using that vertex>` (initialized to
   `UFBX_NO_INDEX`, first-write-wins scan) — the lookup table that makes `unique_per_vertex` attributes
   accessible per logical vertex (ufbx.h:1244-1255 diagram). Any vertex index out of range here IS run through
   `ufbxi_fix_index` (lenient) rather than hard failure — inconsistent with step 2's hard check on the same
   values, but by this point the array only contains previously-validated indices, so this is defensive-only
   dead code in the well-formed case.
5. Bumps the shared `max_zero_indices`/`max_consecutive_indices` running maxima by `mesh->num_faces`, for reuse
   by the (not-yet-assigned-here) default face-material sentinel buffer.

### 18. `ufbxi_read_mesh` (ufbx.c:13434-13811) — top-level mesh reader, full walkthrough
1. Push `ufbx_mesh` element.
2. If `uc->version <= 7100`: read inline pre-7100 blend shapes (`ufbxi_read_synthetic_blend_shapes`, item 16).
3. `ufbxi_patch_mesh_reals(mesh)` (ufbx.c:13219-13240) — sets the fixed `value_reals` component counts on every
   attribute slot up front (position/normal/tangent/bitangent=3, uv=2, color=4, crease=1) including all UV/
   color sets — done both here (before layer-element reading, so `ufbxi_read_vertex_element` isn't required to
   set it) and again at the end (ufbx.c:13775, redundant safety net after UV/color set arrays have been resized/
   reallocated by `push_zero`).
4. Bail early (success, empty mesh) if there's no `Vertices` child at all (ufbx.c:13448-13450) — "sometimes
   there are empty meshes" (explicit TODO about whether these should be filtered, left as-is for v1 fidelity).
   Also bails (success) if `opts.ignore_geometry` is set.
5. Read `Vertices` (`'r'`, /3 → `num_vertices`), `PolygonVertexIndex` (`'i'` → `num_indices`; the node itself
   may be entirely absent, in which case `num_indices=0` and `index_data=NULL` — a topology-less point cloud is
   tolerated), and top-level `Edges` array (`'i'`).
   `opts.retain_dom`: when set, `index_data` is deep-copied before mutation (since DOM retention means the
   original parsed arrays must remain byte-identical for later inspection, but face decoding mutates the array
   in place to un-negate terminators).
6. Wires `mesh->vertices`, `vertex_indices`, and the `vertex_position` attrib directly from the arrays (position
   is `unique_per_vertex = true` by construction).
7. **Quirk** (ufbx.c:13485-13490): if the very last index in the array is not already negative (malformed file
   missing its final face terminator), and NOT in strict mode, silently bit-flip it in place so
   `ufbxi_process_indices` still terminates the last face correctly; in strict mode this is a hard failure
   ("Non-negated last index").
8. **Edges, read BEFORE index un-negation** (comment explicitly calls this out, ufbx.c:13492): each `Edges`
   entry is an index into `PolygonVertexIndex` for corner **a**; corner **b** is derived by looking at whether
   `index_data[index_ix]` is already negative (i.e. `a` is the *last* corner of its polygon) — if so, walk
   backward (`index_ix--`) while the previous entry is still non-negative, to find the polygon's *first* corner
   (edges wrap around to close the polygon); otherwise `b = index_ix + 1` (next corner in the same polygon).
   Out-of-range edge index_ix or invalid computed `b` are dropped silently unless `opts.strict` (hard fail on
   both the initial bounds check and final `index_ix < num_indices` check). Note this algorithm depends on
   reading the raw (still-negative-terminated) index array — hence must run before `ufbxi_process_indices`.
9. `ufbxi_process_indices(mesh, index_data)` — decode faces/triangulation counts (item 17); this ALSO
   un-negates the index array in place, which is why edges were read first.
10. Count `LayerElementUV/Color/Binormal/Tangent` children up front (single pre-pass over `node->children`) to
    size the `uv_sets`/`color_sets`/tangent/bitangent scratch arrays exactly (`ufbxi_push_zero` on `uc->tmp_stack`
    for tangents/bitangents, on `uc->result` for the persisted uv/color set arrays).
11. Main per-child loop (`ufbxi_for` over `node->children`, filtering `n->name[0]=='L'` first as a cheap
    pre-filter since all relevant tags start with `"LayerElement"`):
    - `LayerElementNormal` → `mesh->vertex_normal` via generic reader (`Normals`/`NormalsIndex`/`NormalsW`, 3
      comps); **first one wins** (`if (mesh->vertex_normal.exists) continue;` — duplicate normal layers beyond
      the first are ignored).
    - `LayerElementBinormal`/`Tangent` → appended to the `bitangents`/`tangents` scratch arrays, tagging each
      with its FBX `TypedIndex` (`I` value, read via `ufbxi_get_val1`) so it can later be matched to the UV set
      sharing that index via the `Layer` cross-reference (step 13); if the attribute turned out not to `exist`
      (e.g. genuinely empty data), the scratch slot is un-counted (`num_*_read--`) so it doesn't pollute the
      final matching pass.
    - `LayerElementUV` → new `ufbx_uv_set` slot; reads `TypedIndex`(`I`)→`set->index`, optional `Name`(`S`)
      (defaults to empty string if absent); reads UV data (`UV`/`UVIndex`, 2 comps) into `set->vertex_uv`; if it
      didn't actually exist, the just-reserved slot is un-counted.
    - `LayerElementColor` → same pattern for `ufbx_color_set` (`Colors`/`ColorIndex`, 4 comps).
    - `LayerElementVertexCrease` → `mesh->vertex_crease` (`VertexCrease`/`VertexCreaseIndex`, 1 comp, no W).
    - `LayerElementEdgeCrease` → only if `MappingInformationType == "ByEdge"` (else warn+skip); first-wins;
      truncated-array read (`EdgeCrease`, `'r'`, sized to `mesh->num_edges`).
    - `LayerElementSmoothing` → mapping can be `"ByEdge"` (→`mesh->edge_smoothing`, bool truncated array sized
      `num_edges`) OR `"ByPolygon"` (→`mesh->face_smoothing`, sized `num_faces`); anything else warns. Both are
      first-wins (checks `.count` non-zero before reading).
    - `LayerElementVisibility` → `"ByEdge"` only → `mesh->edge_visibility` (bool, sized `num_edges`); else warn.
    - `LayerElementMaterial` → first-wins. `"ByPolygon"` → truncated int array `Materials` sized `num_faces`
      into `mesh->face_material`. `"AllSame"` → reads a single `Materials` value; if it's `0`, reuses the
      shared zero-index sentinel; otherwise allocates a real `num_faces`-length array filled with that constant
      material index (can't use the zero-sentinel since the value is non-zero). Anything else warns.
    - `LayerElementPolygonGroup` → first-wins, `"ByPolygon"` only → truncated int array `PolygonGroup` sized
      `num_faces` into `mesh->face_group` (non-`"ByPolygon"` mappings are silently ignored here, no warning —
      asymmetric with the other cases).
    - `LayerElementHole` → first-wins (shares the SAME first-wins guard as PolygonGroup — reads
      `mesh->face_group.count` even though it writes `face_hole`; this looks like it *should* independently
      guard on `face_hole.count`, but guards on `face_group.count` instead, ufbx.c:13664 — worth flagging as a
      possible upstream quirk/bug to replicate faithfully rather than "fix" in the port unless verified against
      ufbx's own test suite), `"ByPolygon"` only → bool truncated array `Hole` sized `num_faces` into
      `mesh->face_hole`.
    - Any other `"LayerElement*"`-prefixed tag (`strncmp(n->name,"LayerElement",12)==0`) falls to a **legacy
      pre-7000 per-face-texture-assignment** path (see Quirks below): validates no embedded NUL in the tag name,
      then derives a *material property name* from the tag: if the tag ends in `"Textures"` (length>20) the
      property name is the middle slice (`name+12 .. name+len-8`, minus a trailing `_` if present, e.g.
      `"LayerElementEmissive_Textures"` → `"Emissive"`); special-cased exact match `"LayerElementTexture"` →
      property name `"Diffuse"`. If a mapping-type + `TextureId` int array is present, records a
      `ufbxi_tmp_mesh_texture` `{prop_name, face_texture ptr, num_faces, all_same}` entry (materials subsystem
      consumes these later via `ufbxi_mesh_extra`, out of this span).
12. If no material layer was found at all, force a **default all-zero material assignment** covering every face
    (`mesh->face_material` = shared zero-index sentinel, `count = num_faces`) — every mesh always has *some*
    face_material array, even meshes with zero real materials (removed later during finalization if the mesh
    truly has no materials, per the comment).
13. `opts.strict` sanity checks that every discovered UV/color/tangent/bitangent layer was actually read
    successfully (counts match the pre-pass tallies) — a strict-mode-only consistency check.
14. Cross-link tangent/bitangent layers to their owning UV set (ufbx.c:13724-13769): iterate `Layer` children,
    within each iterate `LayerElement` children looking for `(TypedIndex, Type)` pairs; match `Type ==
    "LayerElementUV"` to find the target `uv_set` by index; match `Type == "LayerElementBinormal"`/`"...Tangent"`
    against the scratch `bitangents`/`tangents` arrays by index; if both a uv_set and a tangent/bitangent layer
    were found under the same `Layer` node, copy the tangent/bitangent attrib *by value* into
    `uv_set->vertex_tangent`/`vertex_bitangent` (the scratch tangent/bitangent arrays are otherwise discarded —
    UV-set-less tangent layers are dropped).
15. `mesh->skinned_is_local = true; skinned_position = vertex_position; skinned_normal = vertex_normal;` — the
    "skinned" (post-deformation, pre-evaluation default) attributes start out aliased to the raw geometry;
    actual skin evaluation (out of this span) overwrites these.
16. `ufbxi_patch_mesh_reals` called again (redundant safety net, see step 3).
17. If any `face_group` data was read (from `LayerElementPolygonGroup`) and `face_groups` wasn't already
    populated, calls `ufbxi_assign_face_groups` (item 19) to build the dedup'd `ufbx_face_group` list and
    (if `uc->retain_mesh_parts`) per-group `ufbx_mesh_part`s.
18. Sort `uv_sets`/`color_sets` by their FBX `index` field (stable sort, `ufbxi_sort_uv_sets`/`_color_sets`,
    ufbx.c:12962-12988) — the `LayerElementUV`/`Color` children may appear in file order rather than index
    order; consumers expect index-ordered lists.
19. If any per-face legacy textures were collected, stash them via `ufbxi_push_element_extra` as a
    `ufbxi_mesh_extra` (out-of-span struct) for the materials subsystem.
20. Subdivision metadata (out of v1 tessellation scope, but the *properties* are still read for passthrough):
    `PreviewDivisionLevels`/`RenderDivisionLevels` (ints, best-effort/ignorable), `Smoothness` (int, mapped to
    `ufbx_subdivision_display_mode` if in `[0, SMOOTH]`), `BoundaryRule` (int, mapped to
    `ufbx_subdivision_boundary`, **note the `+1` offset**: raw FBX value `0` maps to enum value `1`
    (`UFBX_SUBDIVISION_BOUNDARY_LEGACY`), i.e. enum index 0 (`DEFAULT`) is reserved for "property absent", not
    for FBX value 0 — range-checked against `[0, SHARP_CORNERS-1]` i.e. FBX values 0..3).

### 19. Face grouping — `ufbxi_assign_face_groups` (ufbx.c:13267-13397) and `ufbxi_update_face_groups` (ufbx.c:13399-13432)
Generic "partition faces into named/ID'd buckets" routine, reused for both `face_group` (polygon groups) here
and (per comments elsewhere) for per-material partitioning during finalization. Algorithm:
1. Loosely deduplicate the per-face group-id stream using a small fixed-size open-addressed hash cache
   (`seen_ids[1<<UFBXI_FACE_GROUP_HASH_BITS]`, multiplicative hash with an adaptive reseed: if any hash bucket
   collides more than `rehash_threshold` times, `seed *= seed` and `rehash_threshold *= 2` — a cheap defense
   against adversarial/pathological id sequences causing O(n²) behavior) to collect a candidate id list with
   likely-duplicates removed, cheaply, without a full sort.
2. Fully sort+dedupe that candidate list (`ufbxi_unstable_sort` + linear scan) to get the final authoritative
   sorted `ids[]`.
3. Allocate one `ufbx_face_group` per unique id (`groups[i].id`, name defaults to empty string — populated
   elsewhere from a `Layer`/`PolygonGroup` name-lookup, not in this function).
4. **Optimization**: if there's exactly one group total, everything maps to group 0 — `mesh->face_group` is
   reset to all-zero and, if `retain_parts`, the single part directly aliases the shared consecutive-index
   sentinel (whole mesh, no allocation needed) and bumps `*p_consecutive_indices`. Early return.
5. Otherwise, re-walks the per-face id stream (using the same adaptive hash cache, reset, as an id→group-index
   memoizer to avoid repeated binary search) doing a `ufbxi_macro_lower_bound_eq` binary search into the sorted
   `groups[]` to remap each face's raw id to a compact `[0,num_groups)` group index, both rewriting
   `mesh->face_group[i]` in place to the compact index and (if `retain_parts`) accumulating per-part face/
   triangle/degenerate-face counts via `ufbxi_mesh_part_add_face` (ufbx.c:13255-13265 — relies on
   `num_empty/point/line_faces` being layout-consecutive after `num_faces`/`num_triangles`, enforced by static
   asserts at ufbx.c:13253-13254, so `(&part->num_empty_faces)[num_indices]++` indexes 0/1/2 for
   empty/point/line).
6. If parts were requested, subdivides the (reused) `ids` buffer into per-part `face_indices` slices sized by
   each part's now-known `num_faces`, then a final pass fills each part's `face_indices` with the actual face
   indices belonging to that group.
`ufbxi_update_face_groups` is a simpler variant used later (outside this reading pass, likely during finalize)
to rebuild `face_group_parts` from an already-finalized `face_group` array — not central to this span.

## Format details

- **FBX ticks-per-second** (ufbx.c:12029): `46186158000` (FBX ≥8000 with `TCDefinition != 127`, or any file
  without `TCDefinition`/with `FBXHeaderVersion < 1004`) vs `141120000` (FBX <8000, or ≥8000 files explicitly
  marked `TCDefinition == 127` for backward compat). Both stored as int64 and mirrored as double.
- **Property table format** (`Properties70`/`Properties60`): `P: name(S), type(C)[, subtype(C) if v70], flags(S), value(s)...`.
  v60 files omit the subtype slot entirely.
- **Property flags string** chars: `A`=animatable, `U`=user-defined, `H`=hidden, `L<digit>`=lock mask (bits
  4-7), `M<digit>`=mute mask (bits 8-11); unknown chars ignored (ufbx.c:11814-11822).
- **Type/name packing**: ASCII separator `"::"` giving order `Type::Name`; binary separator `"\x00\x01"` giving
  order `Name\x00\x01Type` (ufbx.c:12275, 12283-12294).
- **`Fbx` prefix stripping**: applied to both template sub-types (ufbx.c:12172) and object sub-types
  (ufbx.c:12974) — first 3 chars `"Fbx"` checked via `memcmp`/`strncmp`, stripped if present, requires
  `length > 3` (i.e. won't strip if the *entire* string is exactly `"Fbx"` with nothing after — guards against a
  0-length resulting sub-type).
- **`LODGroup`→`LodGroup`** casing hack (ufbx.c:12176-12179): only applied to *template* sub-types (post-prefix-
  strip, exact 8-char match), because `Definitions` templates spell it `FbxLODGroup` while `Objects` spell it
  `FbxLodGroup`.
- **Synthetic id ranges** (ufbx.c:12220-12227): `UFBXI_POINTER_ID_START = 0x8000000000000000`,
  `UFBXI_MAXIMUM_FAST_POINTER_ID = 0x4000000000000000` (or `0x100` under `UFBX_REGRESSION` builds, to force
  exercising the hashed path in tests), `UFBXI_SYNTHETIC_ID_START = POINTER_ID_START + MAXIMUM_FAST_POINTER_ID`.
  Real FBX 64-bit object ids are assumed to never legitimately reach `0x8000000000000000+`; if pre-7000
  string-pointer-derived or explicit sentinel ids do, they're funneled through the ptr→id hash map instead of
  used raw.
- **Polygon index terminator encoding**: last corner of each polygon in `PolygonVertexIndex` (and `Indexes` for
  NURBS lines) is stored as the **bitwise complement** (`~actual_index`, i.e. `-actual_index - 1`, NOT simple
  negation) of the true vertex index — this is why decoding uses `~ix`, not `-ix`, and why "index 0" can still
  be a valid terminator (`~0 = -1`, unambiguous, whereas plain negation of 0 would be indistinguishable from a
  non-terminator).
- **Mapping mode strings** (interned constants compared by pointer, exact spellings): `"ByPolygonVertex"`,
  `"ByVertex"` and legacy `"ByVertice"` (both accepted as synonyms), `"ByPolygon"`, `"ByEdge"`, `"AllSame"`.
- **Reference mode**: presence vs. absence of an `<Name>Index` array is itself what distinguishes
  `IndexToDirect` from `Direct` in this code (the literal `ReferenceInformationType` string is never read —
  the code infers it structurally from whether the index array exists, ufbx.c:12746-12747, 12792).
- **`ufbxi_zero_element`**: `ufbx_real[8]` all-zero static; attribute value pointer for a nominally-empty data
  array is offset to `+4` (ufbx.c:12660, 12780) to keep small negative/garbage index math safely in-bounds.
- **Subdivision boundary encoding**: FBX `BoundaryRule` raw int `0..3` maps to `ufbx_subdivision_boundary` enum
  value `raw+1` (`LEGACY..SHARP_INTERIOR`), reserving enum `0` (`DEFAULT`) for "not specified in file"
  (ufbx.c:13804-13807; enum defined ufbx.h:1192-1207).
- **`Smoothness`** raw int maps 1:1 (no offset) to `ufbx_subdivision_display_mode` (`DISABLED..SMOOTH`, ufbx.h:1181-1190),
  range-checked `[0, SMOOTH]`.
- **Legacy per-face-texture tag naming** (ufbx.c:13670-13705): `"LayerElementTexture"` (exact) → material slot
  `"Diffuse"`; `"LayerElement<X>Textures"` (tag length >20, ends in `"Textures"`) → material slot `<X>` (with a
  trailing underscore before `Textures` stripped if present, e.g. `LayerElementEmissive_Textures` → `Emissive`,
  `LayerElementDiffuseFactorTextures` → `DiffuseFactor`).

## Quirks & edge cases

- **Mixed number+string property tuples** (ufbx.c:11842-11848): `Lod Distance` (`Distance` type property with a
  trailing unit string like `"cm"`) and `User_Enum`-style enum properties (int + pipe-delimited value list
  string) require peeking whether the next value is a string before deciding whether to consume an extra slot —
  otherwise the string gets misread as a number slot's value.
- **`ByPolygon`-really-means-`ByPolygonVertex`** exporter bug workaround (ufbx.c:12783-12790): detected purely
  by index-array-length heuristic (matches `mesh->num_indices`), not by any FBX version/exporter check.
- **`ByVertice`** (archaic misspelling of `ByVertex`) accepted everywhere `ByVertex` is (ufbx.c:12801, 12876,
  and used identically in the mapping remap check).
- **Empty-data-array-means-absent** for layer elements (ufbx.c:12758-12762): a `LayerElement*` node with a
  syntactically valid but zero-length data array does NOT produce a zero-length attribute — it produces
  "attribute doesn't exist," matching apparent exporter behavior of emitting empty arrays as a way of omitting
  data while satisfying schema requirements.
- **First-layer-of-a-kind wins** dedup policy for nearly every geometry layer type (normal, edge crease, face/
  edge smoothing, visibility, material, polygon group, hole) — later duplicate `LayerElement*` blocks of the
  same kind are silently ignored (`continue`), EXCEPT UV/color/tangent/binormal sets, which are genuinely
  multi-valued (indexed by their own `TypedIndex`) so duplicates there are legitimate distinct sets, not errors.
- **`LayerElementHole` guards on `mesh->face_group.count`, not `face_hole.count`** (ufbx.c:13664) — reads as
  likely accidental (copy-paste from the adjacent `PolygonGroup` branch) but must be replicated faithfully
  unless verified fixed upstream; effectively means: if a `PolygonGroup` layer was already read, a later `Hole`
  layer in the same mesh will be skipped even though it targets a different field.
- **Non-negated last index tolerance** (ufbx.c:13485-13490): malformed files missing the final face's negative
  terminator are silently patched (bit-flip in place) unless `opts.strict`.
- **Edges must be decoded before index un-negation** (explicit ordering dependency, ufbx.c:13492) since the
  edge→corner-range algorithm relies on reading the *original* sign bits to detect polygon boundaries.
- **Truncated array padding differs by kind**: index arrays pad with `UFBX_NO_INDEX` (`ufbxi_check_indices`);
  plain value arrays (crease/smoothing/visibility/material/hole) pad by **repeating the last element**
  (`ufbxi_read_truncated_array`) — a Swift port must keep both policies, not unify them.
  Correspondingly, a `LayerElementMaterial`/`AllSame` value of exactly `0` reuses the shared zero-sentinel
  buffer as an optimization but the *same* logical "all faces get material N" semantics apply for any N (just
  without the sentinel optimization when N≠0, ufbx.c:13639-13652).
  - `pp` (prop-to-prop) connections for pre-7100 blend shape channels are unconditionally created for
    `version < 6000` regardless of whether a matching mesh property was found (ufbx.c:13116-13118) — a
    version-gated behavioral branch, not just a fallback.
  - `Fbx`-prefix stripping requires the sub-type string to be **longer** than 3 chars (`length > 3`, not
    `>= 3`) so a bare `"Fbx"` sub-type is left alone rather than becoming an empty string.
  - Blend shape offset arrays are only re-sorted "if absolutely necessary" (ufbx.c:13045-13052) — an explicit
    perf-motivated skip-if-already-sorted check before paying for an allocation + stable sort.
  - The face-group id deduplication hash (`ufbxi_assign_face_groups`) uses an **adaptive reseed** when any
    single hash bucket sees more than `rehash_threshold` (starts at 256, doubling) hits — explicitly defends
    against pathological/adversarial group-id sequences that would otherwise degrade the "loose dedup" pass to
    quadratic time; the *correctness* fallback (full sort+dedup afterward) means the hash pass only affects
    performance, never correctness, so a Swift port can use any deduplication strategy (e.g. `Set`) here as
    long as the final sorted-unique-ids-per-group semantics match.
  - `ufbxi_read_object` treats parse failures of the `Type::Name`/`fbx_id` tuple as **soft** (skip the node,
    not a load error) — "there's some weird objects mixed in every now and then" (ufbx.c:14959-14960) — but
    once parsed, unrecognized `sub_type`s still produce a first-class `UFBX_ELEMENT_UNKNOWN` element rather
    than being dropped.
  - `ufbxi_find_template`'s sub-type matching is waived entirely for `Material`/`Model`/`AnimationStack`/
    `AnimationLayer` classes (ufbx.c:12203-12208) — any object of those classes gets that class's single
    template regardless of its own declared sub-type (these FBX classes don't meaningfully vary defaults by
    sub-type in practice).

## Port guidance

**Port faithfully (these encode real-world exporter behavior / are load-bearing correctness, not just
implementation detail):**
- The entire `ufbxi_read_vertex_element` mapping-mode × reference-mode matrix (item 13), including the
  `ByPolygon`→`ByPolygonVertex` remap heuristic, `ByVertice` synonym, empty-array-means-absent, and every
  fallback/degenerate branch.
- Polygon index terminator encoding (bitwise complement, not negation) and the tolerate-missing-final-terminator
  patch.
- Edge-before-unnegation ordering and the edge→corner-range walk-back algorithm.
- Index sanitization policy (`UFBX_INDEX_ERROR_HANDLING_*` modes) and its distinct truncation-padding behavior
  vs. plain value-array truncation (repeat-last).
- `Type::Name`/`Name\x00\x01Type` splitting with its per-format field-order swap.
- Property flags-string decoding and the mixed number+string skip-ahead heuristic.
- `Fbx` prefix stripping + the `LODGroup`/`LodGroup` casing hack.
- Version-gated behavior: pre-6000 synthetic-id-from-string-pointer scheme, pre-7100 inline blend shapes,
  pre-6000 unconditional blend-channel `pp` connections, `Properties60` vs `Properties70` layout, the KTime
  ticks-per-second selection logic.
- Exporter/version-string matching (`ufbxi_match_exporter`) if any downstream quirk in the ported subsystems
  depends on `uc->exporter`/`exporter_version` (must check other spans — this span only shows where it's
  computed, at ufbx.c:12084-12128).
- The default-all-zero-material-assignment fallback and "first layer of a kind wins" dedup rule (with the
  UV/color/tangent/binormal exception).

**Replace with Swift idioms:**
- Sentinel pointer buffers (`ufbxi_sentinel_index_zero/consecutive`) and the `max_zero_indices`/
  `max_consecutive_indices` running-maximum-then-backfill scheme: in Swift, either eagerly materialize a real
  `[UInt32]` for these (simplicity) or use a lazy/repeating-sequence abstraction — the C code's approach exists
  purely to avoid redundant allocations in a single-pass, no-GC, manual-arena allocator context that doesn't
  map cleanly onto Swift's array value semantics anyway.
- The hand-rolled property `defaults`-chain linked list + binary-search-by-`_internal_key`
  (`ufbxi_find_prop_with_key`) can become a Swift `Dictionary<String, Prop>` per element with an optional
  `defaults` pointer/class reference walked via recursion or a flattened lookup, dropping the manual 4-byte-key
  hack entirely (Swift string hashing is fine here; this was a C micro-optimization).
  Deduplication of properties by *pointer identity of interned name* becomes dedup-by-`String`-equality (or
  keep string interning if the Swift port already interns FBX names for performance elsewhere — check subsystem
  01/02 notes on the parser/string pool).
- Face-group id deduplication: use `Set<Int32>`/sort, skip the adaptive-reseed hash cache — it's a pure
  perf optimization with no behavioral effect (see Quirks).
- `ufbxi_push_element_size`/`_push_synthetic_element_size`'s manual byte-offset/alignment bookkeeping into
  parallel flat arrays (`tmp_element_offsets`, `tmp_typed_element_offsets`, `tmp_elements` as a raw byte arena)
  should become normal Swift class instances (reference types, since `ufbx_element` identity/connections matter
  per the port scope's own guidance) with an `elementID`/`typedID` assigned during a construction pass, and a
  `[ElementID: AnyElement]` or similarly-indexed registry instead of raw pointer arithmetic.
- Suggested Swift shapes:
  - `enum VertexMappingMode { case byPolygonVertex, byVertex, byPolygon, byEdge, allSame, byControlPoint }` /
    `enum VertexReferenceMode { case direct, indexToDirect }` consumed by a generic
    `func readVertexLayer<T>(...) throws -> VertexAttribute<T>?` mirroring item 13, but structured as an
    explicit `switch (mapping, reference)` rather than nested if/else string comparisons.
  - `enum IndexErrorHandling { case clamp, noIndex, abortLoading, unsafeIgnore }` with `func sanitize(index:
    bound:) throws -> UInt32?` mirroring `ufbxi_fix_index`.
  - `struct Face { var indexBegin: Int; var numIndices: Int }`, `struct Edge { var a: Int; var b: Int }` as
    plain value types — no pointer/offset tricks needed.
  - Element class hierarchy: an `class Element { let id: ElementID; var name: String; var props: Properties;
    ...}` base with `final class Node: Element`, `final class Mesh: Element`, etc., matching ufbx's tagged-union-
    via-common-header approach but using real Swift subclassing or protocol conformance + associated element
    kind enum instead of C's struct-prefix trick.
  - `Properties` as `struct Properties { var props: [String: Prop]; var defaults: Properties? }` with a
    `func find(_ name: String) -> Prop?` walking `defaults` — matches `ufbx_props`/`ufbxi_find_prop_with_key`
    semantics without the manual key-hash/binary-search machinery.

**Skip per v1 scope:**
- `ufbxi_read_objects_threaded` and the thread-pool batching (scope excludes threading).
- NURBS curve/surface **tessellation** is out of scope, but note `ufbxi_read_nurbs_curve`/`_surface`/`_line`
  (ufbx.c:13825-13964, just past this span) still read the raw control-point/knot-vector *data* — if the DOM/
  data-model layer wants to expose NURBS control points without tessellating (a judgment call for the scene
  subsystem), that reading logic would need porting even though tessellation itself is skipped. Flag this as a
  scope question for whoever owns the NURBS-adjacent span.
- Embedded texture decoding is out of scope; the "legacy per-face texture assignment" mechanism (item 11's
  final else-branch, `ufbxi_tmp_mesh_texture`) still needs to be read/passed through structurally (it's just
  FBX DOM data, e.g. which face uses which texture-id) even if actual texture *decoding* is out of scope —
  this feeds the materials subsystem, which should confirm whether it wants this data at all for v1.
- Subdivision **evaluation** is out of scope, but `subdivision_preview_levels`/`render_levels`/
  `display_mode`/`boundary` are cheap passthrough properties read directly in `ufbxi_read_mesh` (item 18 step
  20) — trivial to keep even without implementing subdivision itself, purely as scene metadata.

**Depends on / feeds other subsystems:**
- **Feeds transform-chain subsystem**: `ufbxi_read_model`'s `InheritType`→`inherit_mode` mapping, and the
  geometry-transform-helper / scale-helper synthetic node mechanism (item 11) — the transform-chain subsystem
  must know how to recognize `is_geometry_transform_helper`/`is_scale_helper` nodes and apply their transforms
  correctly (helper's transform affects only the real node's geometry / children respectively, per ufbx's
  documented semantics — verify exact semantics against the transform-evaluation subsystem's own notes).
- **Depends on the DOM/parser subsystem** (prior span, not itself documented here) for: `ufbxi_node`,
  `ufbxi_value_array`, `ufbxi_get_val1/2/3/_at`, `ufbxi_find_child`/`_array`, `ufbxi_parse_toplevel_child`,
  the string pool / interning (`ufbxi_push_string_place_str`), and the underlying binary/ASCII array decoding
  (int/real/bool/string typed arrays) — this span assumes those arrays are already fully decoded (including
  zlib-decompressed for binary FBX) and simply reinterprets their `void*`/`size` as typed spans.
- **Feeds the Connections-resolution subsystem** (not in this span): `ufbxi_connect_oo/_op/_pp` push raw
  `{src_id, dst_id, prop names}` tuples that must later be resolved to real element pointers using the
  `fbx_id_map` built by `ufbxi_insert_fbx_id`/looked-up by `ufbxi_find_fbx_id` — this span only produces the
  inputs to that resolution pass.
- **Feeds the materials subsystem**: `ufbxi_mesh_extra`/`ufbxi_tmp_mesh_texture` (legacy per-face textures),
  `mesh->face_material` (material-index-per-face).
- **Feeds blend-shape evaluation subsystem**: `ufbx_blend_shape.position_offsets/normal_offsets/offset_vertices`
  (sorted-by-vertex, item 15) and the synthetic deformer/channel graph from item 16.
- **The object dispatch table itself (`ufbxi_read_object`, ufbx.c:14947-15099) is out of this span's assigned
  line range** and should be exhaustively cross-referenced against whichever notes file covers ufbx.c
  ~13550-15200+ (bones/skin/materials/textures/animation curves/poses/constraints/etc.) — this document only
  describes it structurally (dispatch shape + how it consumes `ufbxi_split_type_and_name`/`ufbxi_find_template`)
  since those two helpers live in-range.

## Open questions / warnings for the reviewer
- `ufbxi_read_object`, `ufbxi_read_objects`, `ufbxi_read_objects_threaded` (ufbx.c:14947-15160+) and the NURBS/
  line/bone/marker/skin/blend-channel/animation-curve/material/texture/pose/etc. readers (ufbx.c:13825-14946)
  are **past the nominal 11762-13550 line range** assigned to this span but were referenced because the task
  explicitly asked for "object reading dispatch" and "read_node_attribute" coverage. I've summarized the
  dispatch structurally (section 7) without exhaustively detailing every per-type reader's internals — please
  confirm whether the next span (presumably covering ~13550-15200 or wherever it's split) will pick these up in
  full detail, especially `ufbxi_read_bone`/`_marker`/`_skin`/`_skin_cluster`/`_blend_channel` and the full
  `ufbxi_read_object` dispatch table, so nothing falls in a gap between the two notes files.
- Could not find a function literally named `ufbxi_read_node_attribute` — node-attribute sub-types (Light,
  Camera, Bone/LimbNode, Null/Marker, StereoCamera, CameraSwitcher, FK/IKEffector, LodGroup) are dispatched
  inline inside `ufbxi_read_object`'s `NodeAttribute` branch (ufbx.c:14992-15013), each delegating to either
  the generic `ufbxi_read_element` helper or a dedicated reader (`ufbxi_read_bone`, `ufbxi_read_marker`) that
  live past line 13550. Flagging in case the task's mention of "read_node_attribute" referred to a differently-
  named or since-refactored function I should double check against a different ufbx version.
- The `LayerElementHole` guarding on `mesh->face_group.count` instead of `face_hole.count` (ufbx.c:13664) reads
  as a likely bug in upstream ufbx; ported faithfully here per instructions, but flagging for the team in case
  it's worth a compatibility test against real files that use both `PolygonGroup` and `Hole` layers together.
