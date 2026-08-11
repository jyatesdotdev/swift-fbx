# Tests/SwiftFBXTests

See ../../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

All tests for SwiftFBX: the primary ufbx-parity acceptance suite (`GoldenTests`),
crash-safety regressions (`MalformedInputTests`), and focused unit suites per
subsystem (inflate, float/int parsing, binary/ASCII record parsing, math,
curve evaluation, triangulation, numeric coercion). Also owns the on-disk test
corpus under `Resources/`.

## Files

- `JSONCompare.swift` — `enum JSONCompare`, the tolerant structural JSON diff
  engine shared by `GoldenTests`. `JSONCompare.diff(expected:actual:maxDiffs:)`
  returns divergence strings (empty = match). See "Comparer semantics" below.
- `GoldenTests.swift` — `@Suite GoldenTests`, the primary acceptance suite.
  Parameterized over every `Resources/fbx/*.fbx` (`fbxFiles`, sorted, name
  derived by stripping `.fbx`); loads via `FBXScene.load(contentsOf:)`, builds
  a dump via `SceneDump.build(scene:filename:)` (FBXDumpCore), and diffs
  against `Resources/golden/<name>.json`.
- `MalformedInputTests.swift` — `@Suite MalformedInputTests`. Two parameterized
  tests: `malformedFileNeverCrashes` (every `Resources/malformed/*.fbx`) and
  `truncationsNeverCrash` (every `Resources/fbx/*.fbx`, truncated at ~24+10
  offsets via `expectCleanLoad`). Plus one handcrafted regression,
  `hugeValuesLenDoesNotTrap`, building a binary record with `values_len =
  UInt64.max` byte-for-byte.
- `ResourceLimitTests.swift` — exact/over-boundary coverage for source bytes,
  aggregate decoded bytes/elements, invalid options, compact compressed-array
  amplification, and bounded file-URL loading.
- `NumericCoercionTests.swift` (XCTest) — `NumericCoercionTests`. Regression
  guard for the `f64ToI64` boundary trap (`FBXValue.f64ToI64`,
  `FBXValue.asInt64/.asInt32/.asFloat`, `FBXArrayValue.asInt64Array/.asInt32Array`)
  at exactly `2^63` and beyond.
- `MathTests.swift` (XCTest) — `MathTests`. Vector/quaternion/matrix/transform
  primitives: `FBXVec3/2/4`, `FBXQuat` (`.rotate`, `*`, `.slerp`, euler
  round-trips via `.toEuler`/`init(euler:order:)` for all 6 `FBXRotationOrder`
  cases plus `.spheric`), `FBXMatrix` (`transformPoint`, `transformDirection`,
  `.determinant`, `.inverted()`), `FBXTransform` (`.toMatrix()`/`.toTransform()`
  round trip, `.unscaled`), plus raw-value checks for `FBXRotationOrder`,
  `FBXInterpolation`, `FBXTangent`.
- `DataReaderTests.swift` (XCTest) — `DataReaderTests`. `DataReader` byte-level
  reads: LE/BE scalar decode (`readUInt8/16/32/64`, `readInt*`, `readFloat`,
  `readDouble`), `readBytes`/`peekBytes`/`peekByte`, `skip`/`skipClamped`,
  bounds-check `FBXError` cases (`.truncatedFile`), the non-throwing
  `tryRead*` family, and runtime-mutable `bigEndian` flag.
- `InflateTests.swift` — hosts **two** suites:
  - `@Suite InflateTests` — `Inflate.inflate(_:into:)` round-trips every vector
    in `Resources/inflate/vectors.json` against its `.zlib`/`.raw` pair, plus
    negative cases: bad zlib header, corrupted Adler-32 checksum, output-buffer
    overflow — all must throw `FBXError`.
  - `@Suite FloatParseTests` — `FloatParse.parseDouble(_:flags:)` and
    `FloatParse.parseInt64(_:)`. Covers integers/decimals/scientific notation,
    subnormals (bigint slow path), >18-digit mantissas, overflow/underflow to
    `±.infinity`/`0.0`, `inf`/`nan`/MSVC `1.#INF`/`1.#IND` spellings, and
    `.asBinary32` (`FloatParse.Flags`) float-rounding accuracy. Most cases
    assert bit-pattern equality against Swift's native `Double(String)`/`Float(String)`.
- `BinaryParserTests.swift` — `@Suite BinaryParserTests`. Exercises
  `BinaryParser.parseBinaryDocument(_:)` / `BinaryParser.detectHeader(_:)`
  against real Maya-exported cubes: version/endianness detection (7500, 6100,
  big-endian 7500), `nonBinaryReturnsNil` (ASCII bytes must not false-positive
  as binary and must not move the reader), top-level node name ordering,
  string property decode, and vertex-array decode across both the 7000+ typed
  `'d'`-array path and the pre-7000 multivalue-scalar path
  (`FBXDocNode.asDoubleArray()`/`.asInt32Array()`).
- `AsciiParserTests.swift` — `@Suite AsciiParserTests`. Exercises
  `AsciiParser.parseAsciiDocument(_:)` against Maya ASCII cubes at 6100/7400/7500:
  magic-comment version detection, top-level node ordering, `*N{}` vs bare
  comma-list vertex arrays, negative-zero scalar sign preservation
  (`negativeZeroScalarKeepsSignInRealView`, ufbx.c:10466-10469 — `int64(at:)`
  must read `0` while `double(at:)` must read `-0.0`), and raw object-name
  string decoding.
- `CurveEvalTests.swift` (XCTest) — `CurveEvalTests`. Builds minimal
  hand-wired `FBXScene`/`FBXAnimCurve`/`FBXAnimValue`/`FBXAnimLayer`/`FBXNode`
  graphs directly (bypassing the loader) to test `FBXAnimCurve.evaluate(time:default:)`,
  `FBXAnimCurve.findCubicBezierT`, `evaluateAnimValueVec3`/`evaluateAnimValueReal`,
  `FBXAnim.evaluateProps(element:time:)`, and `FBXAnim.evaluateTransform(node:time:)`
  (including parity against `TransformChain.getTransform`, the shared
  static/animated pivot-chain builder). Covers degenerate curves (0/1 keys),
  linear/constant/cubic interpolation, the cubic Bezier-x solver, slope
  extrapolation, multi-layer blended-weight evaluation with the float-precision
  `0.99999` saturation trap.
- `TriangulateTests.swift` — `@Suite TriangulateTests`. Ports
  `ufbx_triangulate_face` (ufbx.c:32391-32468) / `ufbxi_triangulate_ngon`
  (ufbx.c:28471-28688) coverage for `FBXMesh.triangulateFace(_:into:)` (and the
  convenience `[UInt32]`-returning overload): degenerate 0/1/2-vertex faces,
  triangle fast path, quad diagonal-split (shorter-diagonal rule plus the
  winding-flip guard override, ufbx.c:32434-32436), convex-pentagon and
  concave-L-shape ear-clipping order, `indexBegin` offset honoring, and output
  buffer growth/truncation/tail-preservation semantics. Expected ear-clip
  outputs were derived by independently re-implementing the C algorithm in a
  scratch script, not by running the Swift code under test — see per-test
  comments for the derivation trace.

## Resources/ layout

- `Resources/fbx/` — 44 real-world exporter inputs (Maya/Max/Blender, ASCII +
  binary, versions 6100-7700, one big-endian). Filenames encode
  `exporter_scene_version_format[_variant].fbx`.
- `Resources/golden/` — 44 matching `<name>.json` dumps, **generated** by the
  real ufbx C reference (`tools/ufbx_dump.c` against `tools/ufbx/ufbx.c`), one
  per `fbx/` file, same basename. Format defined by `docs/DUMP_FORMAT.md`.
- `Resources/inflate/` — DEFLATE test vectors: paired `<name>.zlib`/`<name>.raw`
  files (stored, fixed-Huffman, dynamic-Huffman, mixed-blocks, incompressible,
  empty, double_array cases) plus `vectors.json` (name/compressed_size/raw_size/raw_sha256
  index consumed by `InflateTests.Vector`).
- `Resources/malformed/` — 7 known-crasher FBX files (byte-flipped
  `maya_cube_7500_binary.fbx` at specific offsets, named `<orig>.fbx.<offset>.rc-5.fbx`)
  that previously triggered fatal-error traps in `BinaryParser`. Every file in
  this directory must load cleanly or throw `FBXError` — never trap.

## Business rules & invariants

- **Golden JSONs are generated artifacts — never hand-edit.** Regenerate via
  the C harness: build `tools/ufbx_dump.c` + `tools/ufbx/ufbx.c` (see root
  AGENTS.md `cc` command) and run it over the `.fbx` file, redirecting stdout
  to `Resources/golden/<name>.json`. Hand-editing a golden file defeats the
  entire acceptance mechanism — it stops being an independent oracle.
- **Adding a new golden-tested file requires BOTH halves**: drop the `.fbx`
  into `Resources/fbx/` AND generate the matching `Resources/golden/<name>.json`.
  `GoldenTests.fbxFiles` derives its test list by scanning `Resources/fbx/`, so
  a `.fbx` with no matching golden JSON fails with a file-not-found, not a
  skip.
- **Comparer semantics** (`JSONCompare`, used only by `GoldenTests`):
  - Numeric tolerance: `|a-b| <= 1e-6 + 1e-6 * max(|a|,|b|)`.
  - A key **absent** on one side is treated as equal to `null`, `false`, `-1`,
    `[]`, or `{}` on the other (`isAbsentEquivalent`) — but NOT equal to an
    empty string or `0`. This mirrors the dump format's "missing/none = -1 or
    omitted key" convention (docs/DUMP_FORMAT.md).
  - Keys literally named `absolute_filename` are ignored entirely (path is
    machine-dependent).
  - Everything else — strings, bools, array *length* and *order* — must match
    exactly. Array order encodes ufbx's deterministic scene ordering; a
    reordering is a real bug, not a diff-tool false positive.
  - Diff reporting caps at `maxDiffs` (default 25) so one badly-diverged file
    doesn't produce unreadable output.
- **`MalformedInputTests` asserts throw-not-crash over the whole `malformed/`
  directory**, automatically — any new file dropped in that directory is
  picked up by `malformedFiles` (no test-file edit needed) and must satisfy
  the same contract: load successfully or throw `FBXError`. A Swift runtime
  trap, an uncaught non-`FBXError`, or a hang fails the whole process, not
  just one `#expect`.
- `NumericCoercionTests`/`MathTests`/`DataReaderTests` use **XCTest**
  (`XCTAssertEqual(..., accuracy:)`); everything else in this directory uses
  **Swift Testing** (`@Suite`/`@Test`/`#expect`). Both run under one `swift
  test` invocation — don't assume a single framework when adding a file.
- `CurveEvalTests`/`TriangulateTests` construct `FBXScene`/element graphs
  directly rather than going through the loader — they are testing pure
  evaluation/geometry math in isolation, deliberately decoupled from
  parse/link correctness (which golden tests cover end-to-end).

## Swift tips for this code

- `FBXScene` elements are `unowned let scene` inside each element — a curve,
  node, etc. constructed for a test **must** be kept alive by something the
  test retains (see `CurveEvalTests.scenes: [FBXScene]` accumulator) or it
  will dangle before assertions run.
- When hand-building a scene graph (`CurveEvalTests`, `TriangulateTests`),
  cross-references (`curveIDs`, `animProps[].elementID/animValueID`, mesh
  vertex `indices`) are **element_id / plain integer indices**, not object
  identity — get the numbering right or you index into the wrong element.
  `-1` in an ID slot means "absent" (see `FBXAnimValue.curveIDs` with `-1` for
  an unanimated axis in `testAnimValueVec3Composition`).
  Test-file props built manually must be pre-sorted with `FBXProp.less`
  (`.sorted(by: FBXProp.less)`) when property ordering matters — construction
  order is not automatically canonical.
  Building an `FBXMesh` corner-index-equals-vertex-index fixture (see
  `TriangulateTests.makeMesh`) is a convention, not a library requirement —
  don't assume real meshes have identity index maps.
- `Bundle.module.url(forResource: "Resources", withExtension: nil)!` is the
  standard resource-root pattern in every suite that touches `Resources/`
  (`GoldenTests`, `MalformedInputTests`, `InflateTests`, `BinaryParserTests`,
  `AsciiParserTests`) — reuse it rather than hardcoding paths.
- `DataReader` bounds failures throw `FBXError` with `.code == .truncatedFile`;
  assert on `.code`, not on the error's description (message text is not part
  of the contract).
- Float-vs-double precision is load-bearing in `CurveEvalTests`
  (`testAnimatedLayerWeightSaturatesWithFloatConstant`): ufbx's weight-saturation
  constant is a `float` literal `0.99999f`, which is `0.9999899864196777` in
  double, not the double literal `0.99999`. Don't "simplify" ported comparisons
  by switching a `Float` constant to the nearest `Double` literal — the bit
  difference changes behavior at the boundary.
- Quaternion/Euler tests compare via `q.dot(q2)` (up to sign) rather than raw
  angles, because Euler angles are ambiguous under gimbal lock and ±360 wraps
  — don't "fix" a failing angle-equality assertion by loosening tolerance;
  compare the resulting rotation instead, as the existing tests do.

## Dependencies & boundaries

- May import `SwiftFBX` (`@testable`, for internal types like `DataReader`,
  `BinaryParser`, `AsciiParser`, `FloatParse`, `Inflate`, `FBXValue`,
  `FBXArrayValue`) and `FBXDumpCore` (public-API-only, for `SceneDump.build`).
- `JSONCompare` has no dependency on `SwiftFBX` — it is a generic JSON diff
  utility and could theoretically be lifted out; keep it that way (don't give
  it FBX-specific knowledge).
- Nothing outside this directory depends on these test files. Resource paths
  under `Resources/` are referenced by relative name only through
  `Bundle.module` — don't hardcode absolute paths.

## Testing

```sh
swift test                                   # everything, including golden (44/44 required)
swift test --filter GoldenTests              # parity suite only
swift test --filter MalformedInputTests      # crash-safety corpus + truncation fuzzing
swift test --filter InflateTests             # DEFLATE + FloatParseTests (same file)
swift test --filter BinaryParserTests
swift test --filter AsciiParserTests
swift test --filter CurveEvalTests
swift test --filter TriangulateTests
swift test --filter MathTests
swift test --filter DataReaderTests
swift test --filter NumericCoercionTests
```

- `GoldenTests` is the acceptance bar for the whole project — see root
  AGENTS.md. Any library change (parser, linker, finalizer, eval, geometry)
  must leave it at 44/44.
- New parser/geometry/eval edge cases belong in the matching unit suite
  first (fast, precise failure); golden tests catch end-to-end regressions
  but a golden diff rarely pinpoints *which* subsystem broke.

## Rules for the model

- Never hand-edit a file under `Resources/golden/` — regenerate it via the C
  harness (`tools/ufbx_dump.c` + `tools/ufbx/ufbx.c`) against the real `.fbx`
  input. If you can't run the C harness in your environment, say so rather
  than fabricating or approximating a dump.
- Adding a golden-parity test case means adding to **both** `Resources/fbx/`
  and `Resources/golden/` — one without the other breaks `GoldenTests`
  (missing input) or leaves a file untested (missing golden, though the
  suite would fail loudly on file-not-found, not silently skip).
- Never weaken `JSONCompare`'s tolerance, the absent-equivalence rules, or the
  `absolute_filename` skip to make a failing `GoldenTests` case pass — a
  widened tolerance or a new ignored key hides a real parity regression from
  every future file, not just the one you're debugging. Fix the scene
  builder/dump instead.
- Never weaken a `DataReader`/`BinaryParser` bounds check to make
  `MalformedInputTests` or a fuzz input pass — the whole point of that suite
  is to prove bounds checks hold; a loosened check is the regression class
  this suite exists to catch.
- When a `CurveEvalTests`/`TriangulateTests` expectation looks wrong, recheck
  against `docs/ufbx-notes/11-anim-eval.md` / `docs/ufbx-notes/12-topology.md`
  and the cited `ufbx.c` line ranges before changing the expected value —
  several expectations encode non-obvious ufbx tie-breaks (e.g. ear-clip
  weight ties, winding-flip diagonal override) that are easy to mis-derive by
  hand.
- If you add a new `Resources/fbx/` file for a non-golden unit test (e.g. a
  new `BinaryParserTests` fixture), you do not need a matching golden JSON —
  golden-file pairing is only required for files that `GoldenTests` picks up
  automatically (i.e. every file you add there needs one).
