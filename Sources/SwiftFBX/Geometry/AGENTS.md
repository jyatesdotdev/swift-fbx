# Sources/SwiftFBX/Geometry

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

Post-load mesh utility: turns an arbitrary-N-gon `FBXFace` (a contiguous run
in a mesh's flat per-corner index arrays) into triangles, robust to concave,
self-touching, non-planar, and degenerate polygons from real exporters. This
does not feed FBX *parsing* — it's a utility API consumed after an `FBXScene`
already exists, exactly like `ufbx_triangulate_face` in ufbx.

## Files

- `Triangulate.swift` — everything in this directory, all on `extension FBXMesh`:
  - `triangulateFace(_:into:)` — public entry, ports `ufbx_catch_triangulate_face` (ufbx.c:32391-32468).
    Dispatches on `face.numIndices`: `<3` → 0 triangles, `==3` → fast-path copy, `==4` → `triangulateQuad`,
    `>4` → `triangulateNgon`. Grows the caller's `indices` buffer in place rather than requiring exact
    preallocation (a deliberate deviation from ufbx's C API shape, see file header).
  - `triangulateFace(_:) -> [UInt32]` — convenience wrapper allocating a fresh buffer (not part of
    ufbx's API, added for Swift ergonomics).
  - `private cornerPosition(_:)` — corner → `FBXVec3` lookup via `vertexPosition.indices`/`.values`.
  - `private triangulateQuad(_:into:)` — ports the quad diagonal-split logic (ufbx.c:32407-32449).
  - `private triangulateNgon(_:into:) -> Int` — ports `ufbxi_triangulate_ngon` (ufbx.c:28471-28688):
    the concave-polygon ear-clipping core, using a linear reflex-vertex scan instead of ufbx's KD-tree
    (see below).
  - `private static orient2d(_:_:_:)` / `distsq2(_:_:)` — 2D cross product / squared distance helpers
    (`ufbxi_orient2d`, ufbx.c:28284-28287).
  - `private static ngonTriWeight(_:_:_:)` — ports `ufbxi_ngon_tri_weight` (ufbx.c:28474-28487): ear
    quality heuristic.
  - `private static reflexInsideTriangle(reflex:points:triPoints:triIndices:)` — replaces ufbx's KD-tree
    point-in-triangle query (`ufbxi_kd_check`/`ufbxi_kd_check_point`, ufbx.c:28289-28406) with a linear
    scan (see "Algorithmic deviation" below).

## Business rules & invariants

- **Output values are mesh CORNER indices, not vertex ids.** Written values live in
  `face.indexBegin ..< face.indexBegin + face.numIndices` — index into `vertexPosition.indices`,
  `vertexIndices`, UV/color indices, etc. Never confuse this with a vertex/position id.
- **Degenerate faces (`numIndices < 3`) are not filtered by ufbx at load time**, so `triangulateFace`
  must handle them by returning 0 rather than assuming callers pre-filtered — `FBXFace.numIndices` can
  legitimately be 0, 1, or 2 for point/line "faces" some exporters emit.
- **Output triangle count is exactly `numIndices - 2`** for `numIndices >= 3` (standard ear-clipping
  fan count) — this is also the exact buffer growth math in `triangulateFace(_:into:)`.
- **Triangle 3 fast path**: corners copied verbatim `{indexBegin+0, +1, +2}`, no geometry computed.
- **Quad (4-corner) split rule** (ufbx.c:32407-32449) — NOT simply "always split the shorter diagonal":
  1. Default: split along whichever diagonal (`a = v2-v0` vs `b = v3-v1`) is shorter (`dot(a,a) <=
     dot(b,b)`).
  2. **Winding-flip guard**: compute the two triangle normals for *each* candidate split at the
     "wrong" corner. If either candidate split produces two triangles whose normals disagree
     (`dot(na1,na3) < 0` or `dot(nb0,nb2) < 0` — meaning that diagonal lies outside a non-planar/
     bowtie quad), OVERRIDE the default choice to whichever diagonal keeps agreeing normals
     (`splitA = dotNA >= dotNB`), regardless of diagonal length. This only matters for non-planar
     quads; don't "simplify" by dropping the guard — it changes output on real (slightly warped)
     exported quads.
  3. Both output orderings (`{0,1,2, 2,3,0}` or `{1,2,3, 3,0,1}`) preserve the original face winding.
- **N-gon (`>4` corners) ear clipping is order-preserving and must match ufbx's exact tie-break
  sequence**, not just produce "a valid triangulation":
  - Projection basis: Newell's-method area-weighted face normal (only the `numIndices > 4` branch of
    `ufbx_get_weighted_face_normal` is reachable from here), normalized; near-zero length
    (`len <= fbxEpsilon`) falls back to `+X`, never throws/errors.
  - Seed axis for the in-plane basis: `+X` unless `normal.x*normal.x < 0.5` is false (i.e. normal is
    close to +X), then `+Y` — Gram-Schmidt'd against the normal.
  - Reflex-corner classification: a corner is reflex (can block an ear) iff `orient2d(prev,cur,next)
    <= 0` in the polygon's winding as projected into the 2D basis — boundary-inclusive (`<=`, not `<`).
  - Ear candidate scoring (`ngonTriWeight`): rejects non-convex candidates (`orient2d <= 0` → weight
    `-1`), otherwise `2 - max(ab,bc,ca)` (law-of-cosines edge-angle proxy per vertex), floored at
    `fbxEpsilon` — prefers well-shaped (near-equilateral) ears over slivers.
  - At each step of the 4-corner sliding window, the higher-weighted of the two candidate ears is
    tried FIRST; the other is tried only if the first is blocked by a reflex vertex inside its
    triangle. If the better-weighted candidate is itself invalid (weight `< 0`), the other is never
    tried either (both fail together) — do not add a fallback that tries the worse one regardless.
  - **Starvation guard**: `numSteps >= n * 2` breaks out of the "smart" ear-clipping loop into the
    unconditional fallback. `numSteps` resets to 0 on every successful clip (an acknowledged possible
    O(n²) worst case in ufbx itself — not a bug to "fix" by removing the reset).
  - **Fallback pass**: once triggered (or once the smart loop naturally can't proceed), cuts whatever
    corner is current with ZERO further geometric validity checks, repeatedly, until 3 corners remain.
    Guarantees termination and full corner coverage for pathological/self-intersecting input at the
    cost of a possibly-ugly (but always valid-index) triangulation. This is intentional, not a
    "should be smarter" gap.
  - **Output order**: triangles are emitted by walking corners `0..<n` in ascending ORIGINAL polygon
    index order (not clip order), emitting one triangle per corner that was recorded as an ear tip.
    This determines the exact row order of the output triangle list and must match ufbx's dump
    byte-for-byte for golden parity — do not reorder by clip sequence or by any other key.
- **`fbxEpsilon`** (from `Math/Math.swift`, `UFBX_EPSILON` for the double build) is the single
  near-zero/degenerate threshold used throughout — for normal-length fallback, for the tri-weight
  floor, and shared with other subsystems. Don't introduce a locally-tuned epsilon.

### Algorithmic deviation (documented, verified equivalent)

ufbx accelerates the "is any reflex vertex inside this candidate ear triangle" query with a two-tier
KD-tree (`ufbxi_kd_*`, ufbx.c:28274-28468) built purely to bound worst-case C recursion depth on
adversarial/huge inputs. This port (`reflexInsideTriangle`) instead does a **linear scan** over the
(typically tiny) reflex-corner list. Per `docs/ufbx-notes/12-topology.md`'s "Port guidance": this is a
pure existence test ("does any reflex corner other than the candidate triangle's own 3 corners lie
inside the projected triangle") — order of examination is irrelevant to the boolean result, so the
linear scan gives an IDENTICAL answer to the KD-tree for every call, and therefore an identical
sequence of ear choices / output triangle order. This is the ONE algorithmic simplification taken in
this file; everything else is a literal, order-preserving port. Do not "restore" a KD-tree — it would
be pure complexity with no behavior change (verified by 44/44 golden parity on the current linear-scan
implementation).

## Swift tips for this code

- `indices: inout [UInt32]` growth in `triangulateFace(_:into:)` only ever grows, never truncates or
  reuses stale trailing entries from a previous larger call — if you touch this, keep it that way
  (callers may intentionally reuse a buffer across multiple faces of different sizes).
- The doubly-linked ring (`prevOf`/`nextOf`/`clip`) replaces ufbx's in-place "mark high bit, splice"
  scheme over a shared scratch/output buffer — Swift's separate storage makes the buffer-aliasing
  trick (and its associated `last_triangles` staging buffer in ufbx.c:28660-28687) entirely
  unnecessary. Don't reintroduce buffer aliasing "for fidelity"; the aliasing was a C memory-reuse
  optimization, not a behavior requirement.
- `pointIndices = [0,1,2,3]` sliding window: index math (`pointIndices[side+0/1/2]`, `side ^
  firstSide`) is dense and easy to off-by-one when refactoring — if you touch the window-advance logic,
  re-verify against `TriangulateTests` immediately, the failure mode is silently-wrong triangle
  selection, not a crash.
- `@inline(__always) private func cornerPosition` and the `private static` geometry helpers are
  intentionally file-private — this is leaf utility code with no reason to be called from outside
  triangulation; don't widen access without a concrete caller.

## Dependencies & boundaries

- Imports `Foundation`. Depends on `Math/Math.swift` (`FBXVec2`, `FBXVec3`, `fbxEpsilon`) and
  `Scene/Mesh.swift` (`FBXMesh`, `FBXFace`, `vertexPosition`). No dependency on `Evaluate/*`,
  `Loader/*`, or `Document/*` — triangulation is a pure post-load, read-only utility over an already
  frozen `FBXMesh`.
- Public surface: `FBXMesh.triangulateFace(_:into:)` and `FBXMesh.triangulateFace(_:) -> [UInt32]`.
  Both are read-only extensions on `FBXMesh`; they never mutate the mesh (consistent with the freeze
  rule in the parent AGENTS.md).

## Testing

```
swift test --filter TriangulateTests
```

- `Tests/SwiftFBXTests/TriangulateTests.swift` covers triangle/quad fast paths, convex and concave
  n-gons, degenerate/near-zero-area cases, and (implicitly, via output comparison) the ear-tie-break
  ordering.
- Golden parity is NOT currently wired through `SceneDump`/`GoldenTests` for triangulation output
  specifically (it's a utility API, not part of the base scene dump) — `TriangulateTests` is the
  primary acceptance bar for this file. If you add golden coverage for triangulation, cross-check
  against `tools/ufbx_dump.c` / `tools/ufbx/ufbx.c`'s actual triangulated output, not just "looks
  reasonable."

## Rules for the model

- Any change to `triangulateNgon`'s ear-selection order, weight formula, or reflex classification must
  keep `TriangulateTests` green and must be re-checked against `docs/ufbx-notes/12-topology.md` §2 and
  the cited `ufbx.c:28471-28688` — this is exact-tie-break-order logic, not "any valid triangulation
  is fine."
- Do not reintroduce a KD-tree or any other acceleration structure to "match ufbx more closely" — the
  linear scan is verified equivalent (see "Algorithmic deviation" above); adding one would only add
  risk of introducing an actual behavioral difference.
- Do not weaken the starvation guard (`numSteps >= n * 2`) or the fallback pass's "no validity checks"
  behavior to try to produce "better" triangles on pathological input — both exist specifically to
  guarantee termination on adversarial/fuzzed input, which this port's crash-safety story depends on.
- If a new caller needs vertex ids rather than corner indices, convert at the call site (e.g. via
  `vertexPosition.indices[Int(corner)]`) — do not change `triangulateFace`'s output semantics.
