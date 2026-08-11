# 00 — SwiftFBX Port Overview & Architecture

Synthesis of subsystem notes 01–15. This is the map: how ufbx turns FBX bytes
into a finished `ufbx_scene`, what each stage hands to the next, how to carve
that into Swift modules an agent can build semi-independently, and the traps.

All line numbers refer to `ufbx.c` / `ufbx.h` as read for these notes.

---

## 1. End-to-end load pipeline (bytes → scene)

The driver is `ufbxi_load_imp` (ufbx.c:25204), wrapped by `ufbxi_load`
(25472) which owns the `ufbxi_context` and error/warning plumbing. The exact
ordered stages, verified from the `ufbxi_load_imp` body (25286–25369):

| # | Stage | Entry function(s) | Notes file |
|---|-------|-------------------|------------|
| 0 | Init string/hash pools | `ufbxi_load_strings` (25286), `ufbxi_load_maps` | 08, 13 |
| 1 | **Format detection** | `ufbxi_determine_format` (11130) | 04 |
| 2 | **Begin parse / header / magic / version** | `ufbxi_begin_parse` (11193), `ufbxi_parse_toplevel` (11253) | 02, 04 |
| 3a | **Read objects** (FBX ≥6000) | `ufbxi_read_root` (15844) → `ufbxi_read_objects` (15101) → per-type readers | 05, 06 |
| 3b | **Read legacy root** (FBX <6000) | `ufbxi_read_legacy_root` (16424) | 07 |
| 3c | **Takes** (pre-7000 anim + ≥7000 time-range) | `ufbxi_read_take` (15688) | 07 |
| 4 | Metadata + file paths | `ufbxi_update_scene_metadata` (25302), `ufbxi_init_file_paths` | 04, 13 |
| 5 | **Pre-finalize** (optional: helper nodes, pivot rewrite) | `ufbxi_pre_finalize_scene` (18116) | 08 |
| 6 | **Finalize** (connection resolve → typed graph) | `ufbxi_finalize_scene` (21641) | 08, 09 |
| 7 | Scene settings (axes, units, framerate) | `ufbxi_update_scene_settings` (23903) | 09, 10 |
| 8 | **Axis conversion** | `ufbxi_transform_to_axes` (24946) | 10, 13 |
| 9 | **Unit conversion** | `ufbxi_scale_units` (24983) | 10, 13 |
| 10 | **Adjust transforms** (axis/unit bake-in) | `ufbxi_update_adjust_transforms` (23676) | 10 |
| 11 | Geometry modify + postprocess | `ufbxi_modify_geometry`, `ufbxi_postprocess_scene` (25345) | 09, 12 |
| 12 | **Update scene** (compute all world transforms) | `ufbxi_update_scene` (23806) → `ufbxi_update_node` (22955) → `ufbxi_get_transform` (22836) | 10, 11 |
| 13 | Warnings → metadata | `ufbxi_pop_warnings` (25368) | 13, 15 |

Underneath stage 2–3: the binary reader `ufbxi_binary_parse_node` (8964) and
the ASCII reader share the parse **state machine** (`ufbxi_update_parse_state`
7982, `ufbxi_is_array_node` 8092, `ufbxi_is_raw_string` 8508); array payloads
are DEFLATE-decoded via `ufbx_inflate` (3131) and numbers via
`ufbxi_parse_double` (1601). Post-load, evaluation at time *t* runs on demand
through `ufbx_evaluate_*` (30827–31192), reusing stages 12's transform code.

---

## 2. Data-flow map (what each stage consumes/produces)

```
raw Data
  └─(1 detect)→ file_format
  └─(2 parse)→  ufbxi_node TREE  (untyped DOM: name + typed value arrays,
                                  strings interned, arrays inflated)
  └─(3 read)→   TYPED ELEMENT LIST (ufbx_mesh/material/node/anim_curve… each
                a props-bag + a few direct fields)
              + PENDING CONNECTION LIST (flat fbx_id src→dst tuples, unresolved)
  └─(5 pre)→    (optional) + synthetic helper nodes, rewritten pivot props
  └─(6 finalize)→ LINKED SCENE: connections resolved to typed ufbx_connection,
                  element_id assigned, nodes linearized parents-before-children,
                  typed_id reassigned, cross-refs wired (mesh↔material↔texture,
                  skin↔bone, blend↔channel, anim stack↔layer↔curve_node↔curve),
                  sorted lookup maps (elements_by_name, connections_src/dst)
  └─(7-11)→     scene settings + axis/unit conversion baked into adjust_* fields
                and/or root transform; mesh triangulation-ready
  └─(12 update)→ EVALUATED STATE: node.local_transform, node_to_world,
                 node_to_parent, geometry_to_world for every node at rest pose
  └─(eval t)→   per-time transforms/props via layered curve evaluation
```

Key handoff invariants: the untyped node tree (stage 2) is the ONLY thing the
readers see; readers never look at bytes. The pending connection list (stage 3)
is the ONLY link between elements until finalize — readers must not resolve
pointers. Everything after finalize reads sorted arrays by binary search.

---

## 3. Proposed Swift module breakdown (dependency order)

Single SwiftPM library target `SwiftFBX`, internal file groups. Ordered so each
module compiles/tests against only earlier ones.

1. **Core** — value types, `FBXError`/`FBXWarning` enums, id newtypes
   (`FBXID`, `ElementID`, `TypedID`), `StringPool` (interning). Math: vec/quat/
   matrix/transform. *(notes 14, 15; §4 below)*
2. **Inflate** — pure-Swift `inflate(_:)` + Adler-32; `parseDouble`/`parseInt64`
   (locale-independent, MSVC-special-float aware). Leaf, testable first.
   *(note 01: ufbx.c 1601–3276)*
3. **ParseTables** — the shared state machine: `updateParseState`,
   `isArrayNode`, `isRawString`, type-code tables. Consumed by both readers;
   port entry-for-entry. *(notes 02, 03: 7982–8605)*
4. **BinaryReader** — `binaryParseNode` over a `Data` cursor; 13/25-byte
   headers; array tag decode + inflate. *(note 02: 8964)*
5. **AsciiReader** — tokenizer, bare + `*count{}` arrays, escapes, version
   detect. Reuses ParseTables. *(note 03: 9497–10696)*
6. **ParseDriver** — format detect, magic/version, top-level lazy sections,
   KTime scale decision. Produces the untyped node tree + metadata.
   *(note 04: 11130–11981)*
7. **ObjectReaders** — per-type ingestion into typed elements + props bags +
   pending connections: nodes/mesh/vertex-elements (05), materials/textures/
   videos/deformers/anim-curves/poses/connections (06). *(notes 05, 06:
   11981–15312)*
8. **LegacyReaders** — pre-7000 Takes + pre-6000 inline Model geometry;
   synthetic ids. *(note 07: 15314–16485)*
9. **SceneFinalize** — pre-finalize (08), connection resolve, linearize nodes,
   `finalizeScene` ordered wiring, all sort comparators (09). The determinism
   core. *(notes 08, 09: 18116–23344)*
10. **Materials** — FBX shading-model map fetch (`fetchMaps`), texture UV
    transforms, shader-type tables. PBR mapping tables = **stretch**.
    *(notes 09, 10, 14: 19372–20692)*
11. **Transforms** — `getTransform` pivot chain, `updateNode` inherit modes,
    `eulerToQuat` tables, axis/unit/adjust conversion. *(note 10: 22836–23676,
    24946–24983)*
12. **AnimEval** — curve cubic-bezier (Newton-Raphson), keyframe search,
    extrapolation, layer blending, prop/transform evaluation. *(notes 11, 15:
    25012–26670, 30827–31192)*
13. **Topology** — NGON triangulation, quad-split, half-edge topology, normal
    generation, index dedup. *(note 12: 28489–30241, 32408–32610)*
14. **PublicAPI** — `Scene`/`Node`/`Mesh`/… facade, throwing accessors,
    `loadOpts`, `find*` lookups, load driver assembling stages 1–13.
    *(notes 13, 14, 15)*

Parallelizable clusters once Core+Inflate land: {2,3}→{4,5}→6; ObjectReaders
(7) and Topology (13) and AnimEval (12) can be built against SceneFinalize (9)
interfaces largely in parallel.

---

## 4. Cross-cutting concerns

- **String handling.** ufbx interns every string into pools and relies on
  **pointer equality** for name comparison (fetch builders, note 08). Swift port
  MUST provide a `StringPool` returning interned handles (or use `StaticString`/
  a `[String:Int]` symbol table); do NOT compare `String` by value in hot paths
  where ufbx compares pointers. Raw vs sanitized UTF-8 is a per-node decision
  (`isRawString`, 8508); `utf8_length == UINT32_MAX` = raw-invalid sentinel
  (note 02). Honor `unicode_error_handling` (default REPLACEMENT_CHARACTER).
- **Deterministic ordering.** This is ufbx's contract. Many explicit stable-sort
  comparators (material_part_usage_order, skin weights descending, anim_props by
  element/key/name, blend keyframes by target_weight, bone poses by typed_id,
  node depth-sort parents-before-children) — note 09. Use **stable** sorts and
  reproduce comparator keys exactly; Swift `sort` is not stable — use a stable
  sort or index-tiebreak.
- **Three id spaces (keep separate).** `fbx_id` (UInt64 file identity: post-7000
  file UID, pre-7000 hash of `Type::Name`); `element_id` (dense global UInt32,
  the connection sort key); `typed_id` (per-type UInt32, reassigned to
  depth-sorted order by `linearizeNodes`, 18984). Note 08. Pre-6000's
  pointer-as-id trick (`synthetic_id_from_string`) must become a real interned
  id map in Swift (note 07).
- **Error propagation.** Swift `throws` replacing ufbx error codes; map the
  22-value `ufbx_error_type` taxonomy to `FBXError` cases (note 15). Warnings are
  non-fatal, collected into `metadata.warnings` (15-value taxonomy, dedup
  boundary quirk). Bad base64, unsupported version, dangling connections =
  warnings, not throws. `index_error_handling` default CLAMP.
- **Numeric conventions.** `ufbx_real` = **double** by default (UFBX_REAL_TYPE,
  ufbx.h:154) — use `Double` everywhere for geometry/transform/anim. Exceptions
  where **float** matters bit-exactly: `KeyAttrDataFloat` / ACCURATE_F32 paths
  (notes 02, 03) store f32 and must round like f32; array element type comes from
  `isArrayNode` flags, not from `ufbx_real`. Float→int is **saturating**
  (`f64_to_i32/i64`), not C truncation (note 02).
- **Index sanitization.** Two distinct, non-unifiable policies (note 05): index
  arrays pad missing entries with `UFBX_NO_INDEX` (→ Swift `nil`/`Optional`);
  plain value arrays repeat their last element. PAD_BEGIN prepends 4 zero
  elements so `[-1]` indexing is safe (notes 02, 03). Model `UFBX_NO_INDEX` as
  `Int?`/sentinel consistently.

---

## 5. Top 10 riskiest things to get wrong

1. **Transform pivot chain** `T·Roff·Rp·Rpre·R·Rpost⁻¹·Rp⁻¹·Soff·Sp·S·Sp⁻¹`
   with PostRotation **inverted**, Pre/Post always XYZ, only Lcl Rotation uses
   `rotation_order`; plus the `use_rotation_space` gate that drops pre/post +
   custom order. Corrupts rigs silently. — note 10 §1–2, ufbx.c:22836–22905.
2. **Float parser bit-exactness.** `Double(String)` will NOT reproduce
   ufbx's arbitrary-precision strtod, ACCURATE_F32 rounding, or MSVC `1.#IND`/
   `1.#INF` forms. Port `ufbxi_parse_double` faithfully incl. the negative-
   decimal-exponent shortcut. — note 01, ufbx.c:1601–1793, esp. ~1717.
3. **DEFLATE overlapping matches.** The byte-by-byte fallback for match
   distance < 16 (RLE/overlap) is correctness-critical, not an optimization.
   Validate tables against a known zlib vector, don't hand-transcribe. — note
   01, ufbx.c ~2887, 3065; LUT warning.
4. **Parse state machine tables.** `updateParseState`/`isArrayNode`/
   `isRawString` carry all version/option-gated behavior (pre-7200 ASCII float
   vs int32; Connections raw <7000; PAD_BEGIN; ACCURATE_F32). Port entry-for-
   entry, shared across binary+ASCII. — notes 02/03, ufbx.c:7982–8605.
5. **Finalize ordering.** `finalizeScene` steps read fields written by earlier
   steps; reorder = null cross-refs. Reproduce the exact sequence and every sort
   comparator. — note 09, ufbx.c:21641+.
6. **Connection resolution + id spaces.** Silently drop dangling; version-gated
   redirections (pre-7000 prop→attribute, deformer→geometry); helper remaps;
   two src/dst sorted arrays. Mixing the three id spaces breaks the whole graph.
   — note 08, ufbx.c:18665, 18950–18984.
7. **Animation curve decode + cubic eval.** Run-length decode of
   KeyAttrFlags/DataFloat/RefCount, bit-packed tangent weights, TCB/auto/user
   tangent modes with magic auto-bias; then tangents-are-derivatives → bezier
   control points, Newton-Raphson `findCubicBezierT` (eps 8.88e-16, ≤11 iters,
   no bisection). — notes 06 (14257–14532) + 11 (25014/30832).
8. **Layer blending special cases.** Override/additive/blended modes, with
   quaternion slerp-from-identity for Lcl Rotation and log-space `pow(|v|,w)` for
   Lcl Scaling; layer 0 always writes direct; weight percent clamp `>0.99999→1`.
   — note 11 / 15, `ufbxi_combine_anim_layer`.
9. **Axis/unit/adjust conversion order.** settings → transform_to_axes →
   scale_units → update_adjust_transforms → update_scene, with three handedness
   strategies (ADJUST_TRANSFORMS / MODIFY_GEOMETRY / TRANSFORM_ROOT default) and
   the one-axis-mirror-priority flip. Wrong order = wrong world scale/handedness.
   — note 10 §5, note 13; ufbx.c:25327–25348, 23676.
10. **NGON triangulation + quad winding.** Ear-clipping with reflex-KD pruning
    and guaranteed-termination fallback; quad split picks shorter diagonal EXCEPT
    overrides to preserve consistent normals on non-planar/bowtie quads. Also
    `~ix` polygon terminator is bitwise complement, decode edges before
    un-negating. — note 12 (28489–28688, 32408–32454), note 05 (poly terminator).

---

*Sources: docs/ufbx-notes/01–15. Pipeline order verified against
`ufbxi_load_imp` body, ufbx.c:25286–25369.*
