# Sources/FBXDumpCore

See ../../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

Converts a loaded `FBXScene` into the golden-dump JSON structure defined by
`docs/DUMP_FORMAT.md`, field-for-field and order-for-order identical to the C
reference dumper `tools/ufbx_dump.c`. This is the Swift half of the
parity-verification contract that `GoldenTests` checks against.

## Files

- `SceneDump.swift` — the entire target. `public enum SceneDump` with a single
  entry point `public static func build(scene: FBXScene, filename: String) ->
  [String: Any]`. Internally: numeric/vector helpers (`num`, `arr`, `mat`,
  `transform`), the `idx(_:_:)` element_id→typedID resolver, the
  `vertexAttribDict` vertex-attribute flattener, one `enumName`-style function
  per dumped enum (`axisName`, `timeModeName`, `rotationOrderName`,
  `inheritModeName`, `lightTypeName`, `lightDecayName`, `areaShapeName`,
  `projectionModeName`, `aspectModeName`, `textureTypeName`, `wrapModeName`,
  `skinningMethodName`, `interpolationName`, `elementTypeName`), and one
  `buildX` function per top-level section (`buildMetadata`, `buildSettings`,
  `buildNode`, `buildMesh`, `buildMaterial`, `buildTexture`, `buildLight`,
  `buildCamera`, `buildBone`, `buildSkinDeformer`, `buildBlendDeformer`,
  `buildAnimStack`/`buildAnimLayer`/`buildAnimProp`/`buildAnimCurve`,
  `buildEvaluate`). All are `private` except `build`.

Also relevant but owned by a sibling target (no AGENTS.md of its own):
`Sources/fbx-dump/main.swift` — thin CLI wrapper. Loads a file via
`FBXScene.load(contentsOf:)`, calls `SceneDump.build`, serializes with
`JSONSerialization` (`.sortedKeys`) to stdout. Exit code 2 on bad args, 1 on
load failure (mirrors `ufbx_dump.c`'s `main`). Change it only for CLI-usage
reasons, not dump-format reasons — format changes belong in `SceneDump.swift`.

## Business rules & invariants

- **Field-for-field mirror**: every `buildX` function's key set, key order (JSON
  object key order is irrelevant per DUMP_FORMAT.md, but keep source order
  matching the C file for diffability), and omission rules must match the
  corresponding block in `tools/ufbx_dump.c` exactly. When editing one side,
  edit the other in the same change.
- **Cross-references are `typedID`, not `elementID`**: `idx(scene, elementID)`
  downcasts via `scene.element(elementID)?.typedID ?? -1` — this mirrors
  ufbx's `node->mesh->typed_id` pattern. Never dump a raw `elementID`.
- **Non-finite doubles** are dumped as the strings `"nan"`/`"inf"`/`"-inf"`
  (see `num(_:)`), matching `ufbx_dump.c`'s `j_num`. Do not let
  `JSONSerialization` see a literal NaN/Inf Double — it will trap/fail.
- **Vertex attributes are omitted, not null, when absent**: `vertexAttribDict`
  returns `nil` unless `attrib.exists`, matching `dump_vertex_attrib`'s early
  `return` when `!attrib->exists`. `NO_INDEX` (`FBXMesh.noIndex`) maps to `-1`.
- **Optional mesh arrays are omitted when empty**: `edges`, `edge_smoothing`,
  `edge_crease`, `face_smoothing`, `face_material` are only added to the dict
  when non-empty, mirroring the C file's `if (mesh->edges.count > 0)` guards.
  This is a documented golden-parity trap (see LOG.md 2026-07-17: spurious
  `face_material` arrays were an 11-file regression class) — do not emit these
  keys unconditionally.
- **Material maps are omitted unless meaningful**: `mapField` skips a map
  entirely unless `m.hasValue || m.textureID != -1`, matching
  `dump_material_map`'s `if (!map->has_value && !map->texture) return;`. Inside
  a dumped map, `"value"` is present only when `hasValue && valueComponents >
  0`, and only the first `min(valueComponents, 4)` vector components are
  emitted.
- **Matrix layout**: `mat(_:)` emits `FBXMatrix` as 12 numbers, columns
  `cols.0..3` each `x,y,z` — the ufbx 3×4 affine layout, NOT row-major and NOT
  including a 4th (translation-only) row. Get this wrong and every transform
  diffs.
- **`evaluate` sampling**: `buildEvaluate` samples `stack.anim.evaluateTransform`
  at 8 times when `timeEnd > timeBegin`, else 1 time at `timeBegin`, and always
  skips `node.isRoot`, in `scene.nodes` order — matches `ufbx_dump.c`'s
  `evaluate` block exactly, including the `t0 + t*(t1-t0)/7.0` interpolation
  (7, not 8 — 8 samples over 7 intervals).
- **Filename**: only the basename is emitted (`(filename as
  NSString).lastPathComponent`), mirroring `strrchr(argv[1], '/')` in the C
  harness — never emit a full path.

## Swift tips for this code

- `[String: Any]` / `[Any]` are used deliberately (not `Codable`/`Encodable`)
  so the tree can be handed straight to `JSONSerialization`; keep new fields in
  that idiom rather than introducing a parallel `Codable` model.
- This file has **no `@testable import SwiftFBX`** — everything it touches
  must already be `public` on the scene/element types. If a value you need to
  dump is `internal`, that is a signal the SwiftFBX public API is missing an
  accessor, not that this file should reach around it. Fix the visibility in
  `Sources/SwiftFBX/Scene/*.swift`, not here.
- `idx(_:_:)` and the `buildX` functions take `scene` explicitly rather than
  reading `element.scene` internally where avoidable, to keep this file
  readable top-to-bottom against the C dumper's linear structure — preserve
  that shape in new code.
- Enum-name functions intentionally have no `default:` case in Swift (unlike
  the C `switch`'s `default: return "unknown"`) except `elementTypeName`,
  which does need one (`element_\(t.rawValue)`) because `FBXElementType` has
  values beyond the ones DUMP_FORMAT names explicitly (skin/blend
  sub-elements etc.) — keep that fallback in sync with
  `tools/ufbx_dump.c`'s `element_type_name`.

## Dependencies & boundaries

- May import `Foundation` and `SwiftFBX` (public API only, no `@testable`).
- Must NOT import `FBXDumpCore` from `SwiftFBX` (one-directional: SwiftFBX
  never depends on its own dumper).
- Consumed by `Sources/fbx-dump` (CLI) and by `Tests/SwiftFBXTests/GoldenTests.swift`
  (`@testable import SwiftFBX` there is fine — the test target, not this one,
  has that access).
- Public surface other modules rely on: `SceneDump.build(scene:filename:) ->
  [String: Any]` — this is the entire API surface; do not add other public
  symbols without a reason tied to DUMP_FORMAT.md.

## Testing

- No unit tests of its own; it is exercised entirely through
  `Tests/SwiftFBXTests/GoldenTests.swift`, which runs `SceneDump.build` against
  every file in `Tests/SwiftFBXTests/Resources/fbx/` and structurally diffs
  the result against `Resources/golden/<name>.json` via `JSONCompare.diff`
  (tolerance `|a-b| <= 1e-6 + 1e-6*max(|a|,|b|)` per DUMP_FORMAT.md).
- Run the whole suite: `swift test`.
- Run just golden tests: `swift test --filter GoldenTests`.
- Run one file: `swift test --filter "GoldenTests/golden.*<name>"` (test is
  parameterized over `GoldenTests.fbxFiles`, derived from the `.fbx` files
  present in `Resources/fbx/`).
- To inspect a single diff by hand: `swift run fbx-dump
  Tests/SwiftFBXTests/Resources/fbx/<name>.fbx > /tmp/actual.json` and compare
  against `Tests/SwiftFBXTests/Resources/golden/<name>.json`.
- If goldens themselves change (see `../../tools/AGENTS.md` for regeneration),
  re-run the full golden suite, not just the files you think are affected —
  dumper changes are usually global.

## Rules for the model

- Any change here must keep the golden suite at 44/44 (`swift test --filter
  GoldenTests`) — a partial regression (e.g. 43/44) is not acceptable to land.
- Never change `SceneDump.swift`'s output shape without making the matching
  change in `tools/ufbx_dump.c` AND regenerating goldens (see
  `../../tools/AGENTS.md`) AND updating `docs/DUMP_FORMAT.md` — the three must
  move together or the golden tests stop meaning anything.
- Never "fix" a golden test failure by loosening `JSONCompare` tolerance or by
  omitting/nulling a field to dodge a diff — find and fix the actual ufbx
  behavior gap (consult `docs/ufbx-notes/`), or fix a genuine bug in the
  dumper itself if the field is being computed wrong here.
- When a diff shows a key present in one JSON and absent in the other, check
  the omission-guard rules above (vertex attribs, mesh optional arrays,
  material maps) before assuming a data bug — dump code and scene code are
  both plausible culprits.
- Do not add fields to the dump output that aren't in `docs/DUMP_FORMAT.md`;
  extend the spec first, then this file, then `tools/ufbx_dump.c`.
