# Sources/SwiftFBX/Math

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

Math primitives shared by every other layer: vectors, quaternion, the 3×4
affine matrix, the TRS `FBXTransform`, and euler↔quaternion conversion. Also
the tiny shared enums (`FBXRotationOrder`, `FBXInterpolation`, `FBXTangent`)
that both this layer and the animation/scene layers need — they live here
because Math.swift is built first (wave-2 file-ownership decision, see the
file header comment).

## Files

- `Math.swift` — everything in this directory. Key types:
  - `FBXRotationOrder` (mirrors `ufbx_rotation_order`, raw values 0–6 = xyz…zyx, spheric)
  - `FBXInterpolation` (mirrors `ufbx_interpolation`, raw 0–3)
  - `FBXTangent { dx, dy }` (derivative, not a control point)
  - `FBXVec2` / `FBXVec3` / `FBXVec4` — plain `Double` component structs with `+ - * dot cross normalized`
  - `FBXQuat` — `{x,y,z,w}`, identity `{0,0,0,1}`; `*` (Hamilton product), `normalized()`,
    `rotate(_:)`, `slerp(_:_:_:)`, `init(euler:order:)`, `toEuler(order:)`
  - `FBXTransform` — `{translation, rotation: FBXQuat, scale}`; `.unscaled`, `.toMatrix()`
  - `FBXMatrix` — 3×4 affine, column-major (`cols.0..3`, no stored bottom row);
    `*`, `.determinant`, `.inverted()`, `.transformPoint(_:)`, `.transformDirection(_:)`, `.toTransform()`
  - `fbxEpsilon` (`UFBX_EPSILON` for the `ufbx_real == double` build, `1.4916681462400413e-154`) — the
    shared near-zero/near-singular threshold used throughout this file and by Geometry/Triangulate.swift.

## Business rules & invariants

- **Everything is `Double`.** `ufbx_real == double` in the build this project mirrors (DESIGN.md);
  there is no `Float` variant of any of these types. Do not introduce one for "precision" reasons —
  it would silently break golden parity against the double-build reference dumps.
- **`FBXRotationOrder` name = axis-application order, not multiplication order.** `.xyz` composes as
  matrix `Z*Y*X`. Raw values (0–6) are load-bearing: `find_enum`-style clamping in AnimEval reads the
  raw int directly, so do not reorder the cases.
- **Euler conversion is per-rotation-order closed-form, not a generic matrix decomposition.** Each
  `case` in `init(euler:order:)` / `toEuler(order:)` is copied straight from ufbx.c:31566 /
  ufbx.c:31622 and the six formulas are NOT interchangeable by permuting axes — a bug in one order's
  sign/term does not show up in another order's tests. `.spheric` always falls through to identity /
  all-zero, matching ufbx's `default:` case; it is not "unsupported," it's the correct behavior.
- **Angles are degrees at this API boundary.** `init(euler:)` takes degrees in, `toEuler()` returns
  degrees out (internally converted through `fbxDegToRad`/`fbxRadToDeg`). Every other math op
  (quaternions, matrices) is angle-unit-agnostic.
- **`toEuler`'s gimbal-lock epsilon is `0.999999999`** (ufbx.c:31628), a literal carried over from the
  double build — do not "clean it up" to `1.0 - 1e-9` or similar; keep the exact literal so bit
  patterns match.
- **`FBXQuat.slerp`'s near-zero-angle guard uses `1.175494351e-38`** (`FLT_MIN`) even though this is
  the double build — ufbx.c:31535 uses that literal unconditionally; kept verbatim for parity, not a
  bug to "fix" to `DBL_MIN`.
- **`FBXMatrix.inverted()` returns the all-zero matrix on near-singular input** (`|det| <= fbxEpsilon`),
  never identity and never throws. Downstream multiplies against a zero matrix are the intended
  ufbx behavior for degenerate transforms — do not add a fallback to identity.
- **`FBXMatrix.toTransform()`'s quaternion-length renormalization divides by `len`, not `sqrt(len)`**
  (ufbx.c:31914–31917) when `|len - 1| > fbxEpsilon`. This looks like a bug (should be Pythagorean
  normalization) but is a literal port of what ufbx actually does — changing it to `sqrt` will produce
  a numerically "more correct" but *golden-divergent* result. Do not touch without re-checking ufbx.c.
- **`FBXTransform.toMatrix()`'s `2*scale` factoring is load-bearing**, not accidental — it falls out of
  the quaternion→rotation-matrix derivation. Don't simplify away the factor of 2.
- **`FBXVec3.normalized()` and the ngon-normal fallback pattern**: any `normalized()` on a
  near-zero-length vector returns `.zero` (vectors) or falls back to a fixed axis (callers in
  Geometry/Triangulate.swift use `fbxEpsilon` the same way) — never divide by a length that could be
  zero.

## Swift tips for this code

- `FBXMatrix`'s `m00...m23` accessors exist purely so the ported formulas read textually close to
  `ufbx.c` — when porting more matrix math, keep using those names rather than `cols.0.x` inline, it
  makes future diffing against ufbx.c much easier.
- All arithmetic operators are static funcs on the struct, not `AdditiveArithmetic` conformance —
  stay consistent with that style rather than adding protocol conformances these types don't need.
- No `Equatable` derived from floating-point tolerance — `==` here is bit-exact. Tests that compare
  against golden/ufbx values use tolerance at the JSON-compare layer (`Tests/.../JSONCompare.swift`),
  not here.
- These types are trivial value structs with no invariants enforced by `init` (e.g. `FBXQuat` can be
  constructed non-unit) — normalization is always an explicit caller step (`normalized()`), never
  implicit. Don't add auto-normalizing initializers.

## Dependencies & boundaries

- Imports only `Foundation` (for `cos/sin/acos/atan2/copysign/pow`, etc). No dependency on any other
  `SwiftFBX` module — this is the lowest layer other than `Core/`.
- Everything here is `public` and consumed by `Scene/*`, `Loader/*`, `Evaluate/*`, and
  `Geometry/Triangulate.swift`. Treat the public API shape (especially `FBXTransform`, `FBXMatrix`,
  `FBXQuat`) as frozen — many other files construct/consume these by field name.
- `FBXRotationOrder` / `FBXInterpolation` / `FBXTangent` living here (not in `Scene/Animation.swift`)
  is intentional per the DESIGN.md wave-2 assignment; don't move them without checking every caller.

## Testing

```
swift test --filter MathTests
```

- `Tests/SwiftFBXTests/MathTests.swift` covers vector/quat/matrix ops and euler round-trips per
  rotation order directly (unit/analytic cases, not golden-derived).
- Indirectly exercised by every golden file through `FBXTransform.toMatrix()` /
  `FBXMatrix.toTransform()` (node world matrices) and `FBXQuat(euler:order:)` (animated rotation
  blending) — `swift test --filter GoldenTests` will catch regressions here too, just less precisely
  localized.

## Rules for the model

- Any change to a formula in `Math.swift` must cite the exact `ufbx.c` line it corresponds to (see the
  file header for the line-range map) and must keep both `MathTests` and `GoldenTests` (44/44) green.
- Do not "fix" what looks like a numerical quirk (the `toTransform` length-vs-sqrt divide, the
  `FLT_MIN` slerp epsilon, the `0.999999999` gimbal epsilon) without first re-reading the cited
  ufbx.c line — these are intentional literal ports, verified against golden dumps.
- Never add a `Float`-based variant or generic-precision version of these types.
- If you add a new per-rotation-order formula (e.g. a new euler helper), derive/verify it against
  `docs/ufbx-notes/10-interpret-props.md` and `tools/ufbx/ufbx.c`, not by inferring a pattern from the
  other five orders — the six cases are independently derived, not systematically related.
