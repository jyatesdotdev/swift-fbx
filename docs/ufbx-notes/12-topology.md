# Topology & Utility (NGON triangulation, mesh half-edge topology, index generation)

## Purpose
This subsystem turns an FBX polygon (`ufbx_face`, an arbitrary-N-gon range of the flat per-corner
index array) into triangles, robust to concave/self-touching/degenerate polygons produced by real
exporters. It also builds a half-edge-like adjacency structure (`ufbx_topo_edge`) over a whole mesh
used (elsewhere) to derive smoothing-aware vertex normals, and a generic "weld identical vertices /
build an index buffer" utility (`ufbx_generate_indices`) for users building GPU-ready flat vertex
buffers. None of this feeds FBX *parsing*; it is post-processing utility API consumed after a
`ufbx_scene` already exists.

## Key data structures
- **`ufbx_face`** (defined elsewhere, used here): `{ index_begin, num_indices }` — a contiguous run
  in the mesh's flat corner/index arrays (`vertex_indices`, `vertex_position.indices`, etc).
- **`ufbxi_ngon_context`** (ufbx.c:28255-28265, internal only): per-triangulation-call scratch:
  - `face` — the ngon being triangulated.
  - `positions` — `ufbx_vertex_vec3` (values + per-corner indices) for the mesh.
  - `axes[3]` — orthonormal basis `{u, v, normal}` the polygon is projected into for 2D geometry
    tests (`axes[2]` is the polygon normal).
  - `kd_nodes[1 << (UFBXI_KD_FAST_DEPTH+1)]` — fixed-size "fast" KD-tree levels (see below), stored
    inline (no heap alloc) up to depth `UFBXI_KD_FAST_DEPTH`.
  - `kd_indices` — pointer into the caller-provided scratch buffer holding the "slow" tail of the KD
    tree (reflex-vertex indices beyond the fast levels).
  - `cur_axis_dir`, `cur_face` — transient fields used only while sorting during KD build
    (`ufbxi_kd_index_less`, ufbx.c:28408-28416, is a comparator callback and can't take extra args).
- **`ufbxi_kd_node`** (28247-28253): one node of the fixed/array-indexed part of the KD-tree:
  `split` (coordinate of the split plane along the node's axis), `index_plus_one` (1 + vertex-corner
  index stored at this node, 0 = empty node), `slow_left/slow_right/slow_end` — once recursion drops
  below the fast depth, these are byte-index bounds into the flat `kd_indices` slow array delimiting
  the left subtree / right subtree / end, so the fast tree can hand off into `ufbxi_kd_check_slow`.
- **`ufbxi_kd_triangle`** (28267-28272): a query object — the 3 candidate-ear points/indices being
  tested, plus `min_t`/`max_t` (axis-aligned bounding box of the 3 points in the 2D projected space,
  per axis 0/1) used to prune KD subtrees.
- **`ufbx_topo_edge`** (ufbx.h:4056-4065, public): one directed half-edge per polygon corner:
  - `index` — its own corner index (== position in the flat corner array).
  - `next` — corner index of the edge's "to" vertex (next corner in the same face, wrapping).
  - `prev` — corner index of the previous half-edge in the same face (wrapping).
  - `twin` — the opposite-direction half-edge's corner index across the shared edge, or
    `UFBX_NO_INDEX` if the edge is a boundary or non-manifold.
  - `face` — owning face index.
  - `edge` — index into `mesh->edges[]` if this corner's edge matches an explicit FBX "Edges" record,
    else `UFBX_NO_INDEX`.
  - `flags` — `UFBX_TOPO_NON_MANIFOLD` (0x1) if 3+ faces share the underlying undirected edge.
- **`ufbx_vertex_stream`** (ufbx.h:4070-4074, public): `{ data, vertex_count, vertex_size }` — one
  parallel flat vertex array (e.g. positions, or normals) to be deduplicated together by
  `ufbx_generate_indices`. Padding inside the vertex struct MUST be zeroed by the caller because
  comparison is raw `memcmp`/hash over the bytes.
- **`ufbxi_vertex_stream`** (30101-30105, internal): a compacted variant used during
  `ufbxi_generate_indices` — `begin`/`ptr` (read cursor into user data), `vertex_size`,
  `packed_offset` (byte offset of this stream's fields inside one interleaved "packed vertex" used as
  the hash-map key).

## Control flow / algorithms

### 1. `ufbx_triangulate_face` / `ufbx_catch_triangulate_face` (ufbx.c:32392-32475, public entry)
Dispatches on `face.num_indices`:
- `< 3`: returns 0 (degenerate, no triangles).
- `== 3`: fast path, copies `{index_begin+0,+1,+2}` verbatim, returns 1.
- `== 4` (quad, 32408-32454): decide which diagonal to split along:
  - Compute diagonal vectors `a = v2-v0`, `b = v3-v1`.
  - Compute 4 triangle-normals at the "wrong" corners: `na1 = cross(a, v1-v0)`, `na3 = cross(a,
    v0-v3)` (for the a-diagonal split), `nb0 = cross(b, v1-v0)`, `nb2 = cross(b, v2-v1)` (for the
    b-diagonal split).
  - Default: `split_a = dot(a,a) <= dot(b,b)` (split along the *shorter* diagonal).
  - Convexity override: if `dot(na1,na3) < 0` or `dot(nb0,nb2) < 0` (i.e. one candidate split
    produces two triangles whose normals disagree — meaning that diagonal lies outside the quad,
    i.e. the quad is non-planar/concave w.r.t. that diagonal), instead pick whichever diagonal's
    normal-dot is larger (`split_a = dot_na >= dot_nb`), i.e. avoid the diagonal that flips winding.
  - Emits either `{0,1,2, 2,3,0}` or `{1,2,3, 3,0,1}` (both preserving face winding order), returns 2.
- `> 4` (true n-gon): calls `ufbxi_triangulate_ngon` (below), with a 12-`uint32_t` on-stack fallback
  buffer when the caller's buffer is smaller than 12 words (since the algorithm needs scratch space
  beyond the final triangle list for very small n-gons where the caller under-allocated relative to
  the KD/edge scratch requirement — see Format details for the exact sizing formula).
- Bounds-checked via `ufbxi_panicf` (panics instead of asserting in the `ufbx_catch_*` variant);
  `ufbx_triangulate_face` is a thin non-panicking wrapper calling `ufbx_catch_triangulate_face(NULL,
  ...)`.

### 2. `ufbxi_triangulate_ngon` (28489-28688) — concave-polygon ear clipping with KD-tree acceleration
This is the core algorithm; only called for `num_indices > 4`.
1. **Projection basis** (28494-28517): compute the polygon's area-weighted normal via
   `ufbx_get_weighted_face_normal` (Newell's method, see `ufbx_catch_get_weighted_face_normal`,
   32501-32532, called from within scope but defined further down at 32501 — cited since triangulation
   depends on it). Normalize; if degenerate (`len <= UFBX_EPSILON`) fall back to `+X` as the normal.
   Pick a seed axis (`+X` if `normal.x² < 0.5`, else `+Y`) and Gram-Schmidt it against the normal to
   build `axes[0]` (`u`), then `axes[1] = normal × axes[0]` (`v`), `axes[2] = normal`. All later
   geometry (`ufbxi_ngon_project`, 28274-28282) projects corner positions to 2D via dot products
   against `axes[0]`/`axes[1]`.
2. **Collect reflex corners** (28524-28540): walk the polygon's corners in order computing the signed
   area (`ufbxi_orient2d`, 28284-28287: 2D cross product `(b-a)×(c-a)`) of each corner triplet
   `(prev, cur, next)`. Any corner with `orient2d <= 0` (i.e. NOT strictly convex given the polygon's
   CCW-in-this-basis orientation) is recorded into `kd_indices[]`. These are exactly the vertices that
   could block an ear-clip (a candidate ear triangle is invalid if a reflex vertex lies inside it).
3. **Build KD-tree over reflex corners** (28542-28547, `ufbxi_kd_build` 28419-28468): a 2D KD-tree
   (alternating axis 0/1) over just the reflex-corner positions, used later to answer "is any reflex
   vertex inside this candidate ear triangle's bounding box" fast. Two-tier structure:
   - Top `UFBXI_KD_FAST_DEPTH` levels stored as an implicit array (`kd_nodes`, complete binary tree
     indexing `2*i+1`/`2*i+2`) for cache-friendly traversal without recursion depth trouble.
   - Below that depth, `slow_left/slow_right/slow_end` fields point into a flat sorted-by-axis array
     (`kd_indices`) and `ufbxi_kd_check_slow` walks it with an implicit-in-place binary search
     (median-of-remaining-range) rather than real tree nodes, to bound recursion depth by `32 -
     UFBXI_KD_FAST_DEPTH` regardless of polygon size (indices are 32-bit, so `count/2` halves at most
     32 times).
   - Build recursively picks the median (after `ufbxi_stable_sort` on the current axis) as the node,
     recurses left/right on the other axis, alternating; `depth < UFBXI_KD_FAST_DEPTH` populates a
     `kd_nodes[fast_index]` entry, otherwise elements are simply left in place in `kd_indices` for the
     slow-path binary search to consume later (no explicit node objects below the fast depth).
4. **KD point-in-triangle query** (`ufbxi_kd_check`, 28392-28406 building the query AABB + calling
   `ufbxi_kd_check_fast` 28345-28390 which descends the fast array levels using the query's `min_t/
   max_t` per axis to decide whether to recurse left/right/both, handing off to `ufbxi_kd_check_slow`
   28304-28342 once past the fast depth). At each visited node, `ufbxi_kd_check_point` (28289-28301)
   tests the point via 3 `orient2d` sign checks against the triangle's edges (same-sign-for-all-three
   in either direction ⇒ inside, standard barycentric-sign point-in-triangle test); a node's own point
   is skipped if it's one of the triangle's 3 corners themselves.
5. **Doubly-linked-list ear clipping** (28549-28656): build a `prev/next` adjacency array (`edges[2*i
   +0/+1]`) over polygon corners (not yet triangles). Walk a 4-corner sliding window
   `point_indices[0..3]` = candidate `(a,b,c,d)`; for each of the two possible "ears" at `b` (using
   `a,b,c`) and at `c` (using `b,c,d`) compute a weight via `ufbxi_ngon_tri_weight` (28474-28487: signed
   area must be `> 0`, i.e. convex/CCW, else weight `-1` meaning "reject"; otherwise weight is `2 -
   max(normalized-edge-length-ratio "aspect" terms ab/bc/ca)`, i.e. prefers *well-shaped* (closer to
   equilateral) ears over slivers, clamped to be `>= UFBX_EPSILON` so it's never non-positive for a
   valid convex corner). Prefer whichever of the two candidate ears has the higher weight
   (`first_side`), try it first, and only clip an ear if `ufbxi_kd_check` finds NO reflex vertex inside
   its triangle. On a successful clip: mark the removed corner's `edges[]` entries with the high bit
   `0x80000000` (clipped-marker) and splice its neighbors together in the linked list; slide the
   4-window backward or forward depending which side clipped, and reset `num_steps` (a safety counter
   for detecting we've walked the whole ring without finding an ear — `num_steps >= face.num_indices*2`
   breaks out of the "smart" loop). This is a standard "clip one ear at a time, resume scanning at the
   splice point rather than restarting" ear-clipping loop; comment at 28604 flags it can be **O(n²)**
   worst case since a bad clip can force restarting the scan.
6. **Fallback pass** (28634-28655): if the main loop exits with more than a triangle left (irregular
   ngon where ear-clipping got stuck — self-intersecting/degenerate polygon), just cut off whatever
   corner is current (`ix`) repeatedly without further validity checks until 3 remain, then clip the
   final triangle. This guarantees termination/coverage for garbage/degenerate input at the cost of
   possibly-wrong (but always *some*) triangulation.
7. **Expand adjacency to triangle list** (28657-28687): each corner `ix` whose `edges[ix*2+0]` (prev)
   has the clipped-bit set was consumed as the "ear tip" of some triangle `(prev&~bit, ix,
   next&~bit)`; walking all corners in original order and emitting one triangle per clipped corner
   reconstructs the triangle list in original polygon order. Special care (28660-28685): since output
   triangles are written into the *same* buffer that held the scratch `indices`/`edges` arrays, the
   last up-to-4 triangles could overlap source data still being read; those are buffered into a
   16-`uint32_t` stack array (`last_triangles`) and `memcpy`'d into place only after the main write
   loop completes. `max_triangles = face.num_indices - 2` (standard ear-clipping triangle count); an
   assert confirms exactly that many were produced.

### 3. `ufbxi_compute_topology` (28707-28784), driving `ufbx_compute_topology`/`ufbx_catch_compute_topology`
Builds `ufbx_topo_edge[mesh->num_indices]` (caller-allocated, sized exactly to `num_indices`):
1. First pass (28712-28731): for every face corner, compute the *undirected* vertex-index pair
   `(va,vb)` of that corner's outgoing edge (to the next corner in the face, wrapping), with `va <=
   vb` (canonicalized by swap) — temporarily stash the canonical pair into the `prev`/`next` fields
   (reused as scratch) rather than corner indices; also set `index`, `face`, and mark `twin=edge=
   UFBX_NO_INDEX`.
2. Sort all `topo[]` entries by `(prev, next)` i.e. by canonical undirected-edge key
   (`ufbxi_topo_less_index_prev_next`, 28692-28698, `ufbxi_unstable_sort`) — this groups all
   half-edges of the same undirected edge contiguously.
3. If the mesh has explicit `edges[]` (28735-28752): for each `ufbx_edge{a,b}`, canonicalize
   `(va,vb)` from the *vertex* indices at those corners, binary-search (`ufbxi_macro_lower_bound_eq`)
   the sorted range for matching `(prev,next)`, and stamp the matched contiguous run's `.edge` field
   with that edge's index — so multiple explicit `Edges` entries pointing at logically-identical
   vertex pairs all resolve correctly even with duplicated/UV-split corners.
4. Pair up twins (28755-28771): scan the sorted array for runs of identical `(prev,next)` keys. Exactly
   2 entries in a run ⇒ normal manifold interior edge, set `.twin` on each to the other's `.index`.
   0 entries is impossible (loop skips). More than 2 ⇒ non-manifold: mark ALL of them with
   `UFBX_TOPO_NON_MANIFOLD` and leave `.twin = UFBX_NO_INDEX` (ambiguous which one is "the" twin).
   Exactly 1 (boundary edge, e.g. an open mesh) ⇒ leave `.twin = UFBX_NO_INDEX`, no flag.
5. Re-sort by `.index` (`ufbxi_topo_less_index_index`, 28700-28705) to restore corner order, since the
   previous sort scrambled it.
6. Final pass (28776-28783): overwrite `prev`/`next` (which held the scratch canonical vertex pair)
   with their *real* meaning — the corner index of the previous/next half-edge within the same face
   (wrapping) — since callers need per-face adjacency, not the vertex-pair scratch value.

### 4. Vertex-edge walk helpers (32484-32499)
`ufbx_topo_next_vertex_edge`/`ufbx_topo_prev_vertex_edge`: given a half-edge `index`, walk to the
next/previous half-edge sharing the same origin vertex, by following `twin` then `next`/`prev`
(`next = topo[twin(index)].next`; `prev = topo[topo[index].prev].twin`). Returns `UFBX_NO_INDEX` at a
boundary. These are the primitives `ufbx_generate_normal_mapping` (32534-32583, just outside this
region's line span but directly depends on this subsystem's output — see Port guidance) uses to walk
the fan of corners around a vertex, splitting at non-smooth edges.

### 5. `ufbxi_generate_indices` / `ufbx_generate_indices` (30107-30241, public utility, unrelated
algorithmically to triangulation but grouped under "Utility")
Given `N` parallel `ufbx_vertex_stream`s each with `num_indices` un-deduplicated vertices, produces a
compacted, deduplicated vertex buffer (written back in-place into each stream's `data`) plus an
`indices[num_indices]` array mapping original position → compacted vertex id.
1. Compute `packed_size` = sum of all streams' `vertex_size`, with each stream's substruct aligned to
   its own size's alignment mask, and the total rounded up to a mask of `7` (8-byte multiple) — this
   is the width of one "packed vertex" key used for hashing/equality.
2. Allocate a `packed_vertex` scratch buffer (stack `local_packed_vertex[64]` = 512 bytes if it fits,
   else heap) and an open-addressing hash map (`ufbxi_map`, general internal hash-map type) keyed by
   the packed bytes, compared via `ufbxi_map_cmp_vertex` (30087-30099: **memcmp in 8-byte-at-a-time
   uint64 chunks** — `packed_size` MUST be a multiple of 8, asserted in `UFBX_REGRESSION` builds; this
   is why alignment/padding must be zeroed by the caller and why the size is rounded up to 8).
3. For each of the `num_indices` original vertices: gather each stream's current vertex (streams are
   read sequentially/streaming via a `ptr` cursor, not random access — i.e. **the streams are consumed
   in original index order once**) into `packed_vertex`, hash it (`ufbxi_hash_string`, a generic
   internal byte-hash), look up/insert in the map; new entries get `memcpy`'d in. The resulting
   `indices[i]` is computed as `(entry_ptr - map.items) / packed_size`, i.e. the map storage is itself
   a flat array of packed vertices in *insertion order*, so the entry's position directly gives the
   new compacted index — no separate remapping table needed.
4. After processing all vertices, for each stream, copy the deduplicated data back out of the packed
   map storage into the *original* stream's memory (in-place compaction: `result_vertices <=
   num_indices` so this is always safe to write over the front of the original buffer) at that
   stream's `packed_offset`/`vertex_size` slice.
5. Returns `result_vertices` (deduplicated vertex count) or 0 + populates `ufbx_error` on failure
   (truncated stream, zero total vertex size, allocation failure).
Compile-time-gated: if `UFBXI_FEATURE_INDEX_GENERATION` is off, a stub (30231-30239) always returns 0
and reports a "feature disabled" error.

## Format details
- `UFBXI_KD_FAST_DEPTH` = 6 normally, but **redefined to 2** in some reduced/embedded build
  configuration (ufbx.c:56 default, overridden at ufbx.c:1007-1008 — check the surrounding `#if` at
  that location if porting build-size variants; not chased further as out of scope, but note the
  constant is NOT a fixed universal value — it changes recursion/tree shape and memory layout for
  `ufbxi_kd_node` array size `1 << (depth+1)`).
- Scratch-buffer sizing contract for `ufbx_triangulate_face` on n-gons (>4 corners): the public doc
  (ufbx.h:5654-5655) says callers need `(face.num_indices - 2) * 3` `uint32_t`s for the **output**,
  and hints `mesh->max_face_triangles * 3` (a precomputed per-mesh field, ufbx.h:1277/3813) is always
  safe for sizing a reusable buffer across all faces of a mesh. Internally, though, `indices` doubles
  as scratch for the KD build (`kd_indices`/`kd_tmp`) and the `edges` adjacency array
  (`indices + num_indices - face.num_indices*2`, 28549) *during* the algorithm, all packed within the
  same caller buffer — the assert at 28546 (`kd_slow_indices + face.num_indices*2 <= num_indices`)
  is the real internal invariant. This is why `ufbx_catch_triangulate_face` special-cases buffers
  smaller than 12 words (32462-32466): it runs the algorithm into a 12-word on-stack buffer first
  (guaranteed enough scratch room for tiny n-gons) then copies just the (small) triangle output into
  the caller's true buffer.
- `ufbxi_kd_node` array size: `1 << (UFBXI_KD_FAST_DEPTH + 1)` entries (a complete binary tree of that
  depth), stored inline in `ufbxi_ngon_context` (fixed size, no heap alloc for this part regardless of
  polygon size).
- Ear weight formula constants (28474-28487): weight is invalid (`-1`) if signed area `<= 0`;
  otherwise `2 - max(ab, bc, ca)` where each of `ab/bc/ca` is a normalized "cosine-like" term
  `(a+b-c)/sqrt(4ab)` (law-of-cosines-derived edge-angle proxy) for each vertex of the candidate
  triangle, floored at `UFBX_EPSILON` via `ufbx_fmax`. `UFBX_EPSILON` is defined elsewhere (a small
  constant, referenced but not defined in this region — check math/constants module).
- `ufbx_generate_indices` packed-vertex alignment: individual stream offsets aligned to their own
  `vertex_size`'s natural alignment mask (`ufbxi_size_align_mask`), overall `packed_size` rounded to a
  multiple of 8 (mask `7`). Local fast-path buffers: `local_streams[16]`, `local_packed_vertex[64]`
  (× 8 bytes = 512-byte stack budget) before falling back to heap allocation.
- `ufbx_topo_flags`: single bit `UFBX_TOPO_NON_MANIFOLD = 0x1` (ufbx.h:4051).
- Sentinel: `UFBX_NO_INDEX` (== `UINT32_MAX`, defined elsewhere) used throughout for "no twin / no
  edge / no next".

## Quirks & edge cases
- **Quad splitting winding-flip guard** (32434-32436): naive shortest-diagonal quad splitting can
  produce inverted-normal triangles on non-planar/bowtie quads; ufbx detects this via the sign of
  `dot(na1,na3)`/`dot(nb0,nb2)` and overrides the split choice to whichever diagonal keeps consistent
  triangle normals, rather than blindly using the shorter diagonal. Port this exactly — it's a
  concrete exporter-robustness fix, not just "nice to have."
- **Degenerate polygon normal** (28497-28503): if area-weighted normal has near-zero length (all
  points colinear/coincident), ufbx defaults to `(1,0,0)` rather than failing, so triangulation always
  produces *some* geometrically nonsensical-but-valid-index triangulation instead of crashing/erroring.
- **Ear-clip starvation fallback** (28634-28655): self-intersecting or otherwise pathological n-gons
  (exporter bugs, manually authored garbage) can make the "valid ear" search loop back to its start
  without finding a valid clip (`num_steps >= face.num_indices*2`). ufbx does NOT error in this case;
  it falls back to blindly clipping corners in ring order with zero geometric validity checks, purely
  to guarantee the triangle *count* invariant and termination. Port faithfully: any Swift port must
  guarantee it *always* returns exactly `num_indices - 2` triangles even for garbage input, never
  throw/crash from a bad polygon shape.
- **Weight-based ear preference, not first-valid**: even when both ear candidates at the 4-window are
  geometrically valid, ufbx tries the more "well-shaped" one first (`first_side` from
  `ufbxi_ngon_tri_weight` comparison) purely as a heuristic for nicer output triangles, not correctness
  — but the *order* of preference is deterministic and should be replicated if bit-exact index output
  matters for snapshot/regression tests against the reference lib.
- **O(n²) worst case acknowledged but not fixed** (28604 comment): resetting `num_steps = 0` on every
  successful clip means a pathological polygon (or floating point ties causing repeated backtracking)
  could be quadratic; not a bug to "fix" when porting — replicate the same behavior/complexity profile
  since output must match, but a Swift port could note this as a known potential perf cliff on huge
  ngons.
- **Non-manifold edges get no twin** (28764-28768): 3+ faces sharing an edge is explicitly detected and
  flagged rather than arbitrarily picking one twin; consumers (e.g. normal generation) must handle
  `twin == UFBX_NO_INDEX` AND check the flag rather than assuming boundary == flag-absent.
  `ufbx_topo_next_vertex_edge`/`prev` simply stop (return `UFBX_NO_INDEX`) at both true boundaries and
  non-manifold edges since there's no unambiguous single twin to follow.
- **Explicit `Edges[]` matching is many-to-one safe** (28744-28751): the binary-search-then-scan-
  forward pattern handles the case where several duplicate corners (e.g. split for differing UVs)
  share the same canonical vertex-pair key, stamping `.edge` on all of them, not just the first match.
- **`ufbx_generate_indices` requires 8-byte-aligned/padded vertex structs**: any Swift struct passed
  through an equivalent API must have all padding zeroed (or better: avoid padding entirely, e.g. via
  `@frozen` layout with only 4/8-byte fields) since equality is byte-exact, not field-wise — a subtle
  correctness trap if porting this as raw memory rather than proper `Equatable`/`Hashable` Swift
  values (a Swift port should almost certainly REPLACE the memcmp/hash-map approach with idiomatic
  `Hashable`/`Set`/`Dictionary` keyed by a value type, sidestepping the padding hazard entirely — see
  Port guidance).
- **Streams consumed strictly in order** (30173-30190): `ufbxi_generate_indices` reads each stream via
  a monotonically-advancing pointer, meaning `indices[i]` for compaction purposes is exactly a
  first-seen order preserved by the map's flat storage — a Swift `OrderedSet`/manual insertion-order
  dictionary is the direct analogue if bit-identical dedup vertex *ordering* is required for
  regression parity (it likely does not need to be, since it's just "an" index buffer, but note as a
  possible parity concern for snapshot tests).

## Port guidance
- **Port faithfully (numerically/algorithmically)**: the ear-clipping n-gon triangulator including its
  weighting heuristic, KD-tree acceleration *behavior* (though a Swift port need not literally
  replicate the two-tier fast/slow array trick used purely for C recursion-depth/stack-safety — a
  simple recursive or iterative balanced KD-tree, or even a straightforward O(n·r) reflex-point scan
  for typical small n-gons, is a reasonable Swift-idiomatic replacement AS LONG AS the *chosen ear at
  each step* matches, since output triangle order/identity should match the reference for parity
  testing). The quad-split winding-flip guard and the degenerate-polygon fallback must be ported
  exactly (same formulas/thresholds), because they encode real exporter workarounds validated in the
  wild.
- **Replace with Swift idioms**: 
  - `ufbxi_generate_indices`'s manual packed-byte-hash-map: replace with a Swift value type conforming
    to `Hashable` (deriving hash/equality from its stored fields) and a `Dictionary`/ordered-map, or
    simply build with `Set` semantics — avoids the padding/memcmp hazard entirely and is far more
    idiomatic; only the externally observable behavior (dedup + stable insertion-order indices) needs
    to match, not the mechanism.
  - The C `ufbxi_kd_*` two-tier fixed/dynamic-depth trick exists solely to bound recursion for
    untrusted/adversarial 32-bit-indexed input in a language with fixed C stacks; Swift can use a
    simple recursive KD-tree (Array-of-nodes or indirect enum) without needing the fast/slow split,
    as long as recursion depth stays reasonable (n-gon vertex counts in practice are small — this is
    a defense against pathological/fuzzed input, worth keeping *some* depth bound in Swift too, but
    not necessarily the exact two-tier mechanism).
  - `ufbx_topo_edge` maps cleanly onto a Swift struct with `Int`/optional (`nil` for `UFBX_NO_INDEX`)
    fields, or an `OptionSet` for flags.
- **Skip per scope**: nothing in the assigned line ranges was subdivision or embedded-cache-adjacent;
  the "-- Subdivision" section begins immediately after this span (ufbx.c:28821) and was correctly
  excluded. `ufbxi_kd_*`/triangulation is gated by `UFBXI_FEATURE_TRIANGULATION`/`UFBXI_FEATURE_KD`
  compile flags in the C source — the Swift port has no equivalent feature-flagging need (triangulation
  is in v1 scope per the task brief) but note `ufbx_generate_indices` is gated by
  `UFBXI_FEATURE_INDEX_GENERATION` and could be considered optional/stretch if the Swift API instead
  leans on native `Set`-based dedup patterns callers write themselves — evaluate whether this utility
  is worth a first-class API vs. leaving to consumer code, since it is generic "flat vertex buffer"
  tooling unrelated to FBX semantics.
- **Depends on / feeds other subsystems**:
  - Triangulation depends on `ufbx_get_weighted_face_normal`/`ufbx_catch_get_weighted_face_normal`
    (ufbx.c:32501-32532, Newell's-method face normal — outside this span but essential; port this
    function too, it's simple) and on the mesh's `vertex_position` vertex-attribute array (from the
    Mesh subsystem — needs its `ufbx_vertex_vec3`/indices layout).
  - `ufbx_compute_topology`'s output (`ufbx_topo_edge[]`) directly feeds
    `ufbx_generate_normal_mapping`/`ufbx_compute_normals` (ufbx.c:32534-32610, just past this span) —
    these are the actual consumers of smoothing-group-aware normal generation and depend on this
    subsystem's `.twin`/`.edge`/flags fields plus `ufbx_topo_next_vertex_edge`/`prev`. If another
    subsystem's notes cover "Mesh"/"Normals", flag this dependency there too.
  - `ufbx_generate_indices` is a standalone leaf utility with no FBX-specific dependencies; it can be
    ported independently at any time.
  - Both `ufbx_triangulate_face` and `ufbx_compute_topology` need `mesh->faces`, `mesh->vertex_indices`,
    `mesh->edges`, `mesh->edge_smoothing`/`face_smoothing` (the latter two consumed by
    `ufbxi_is_edge_smooth`, 28786-28819, also just outside this span but tightly coupled — cross-check
    against whichever subsystem documents `ufbx_mesh`'s smoothing fields).
