# Sources/SwiftFBX/Scene

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

The public scene model: every `FBXElement` subclass (node, mesh, material,
light/camera/bone/empty, deformers, animation), the property system, and the
`FBXScene` arena that owns them all. This directory defines STORAGE ONLY —
readers (`Loader/*Reader.swift`), `SceneLinker`, and `SceneFinalizer` populate
these fields; nothing here computes anything beyond simple typed accessors.

## Files

- `Elements.swift` — `FBXElementType` (ufbx element-type ordinals, `isAttribute`
  range check), `FBXConnection` (raw graph edge), `FBXElement` (shared base:
  `unowned scene`, `elementID`, `typedID`, `type`, `fbxID`, `instanceIDs`,
  `typedElement<T>(_:)` downcast helper), `FBXUnknownElement`,
  `FBXElementList<T>` (the generic `RandomAccessCollection` list view) and its
  20 `typealias`es (`FBXNodeList`, `FBXMeshList`, …).
- `Properties.swift` — `FBXPropType`, `FBXPropFlags` (`OptionSet`), `FBXProp`
  (key/value with `internalKey`/`nameKey(_:)`/`less(_:_:)`/`byteLess(_:_:)`
  sort comparator), `FBXProps` (sorted table + `defaults` chain, `find(_:)`
  binary search, `findReal/findVec2/findVec3/findVec4/findInt/findBool/
  findString/findEnum`).
- `Scene.swift` — `FBXCoordinateAxis`/`FBXCoordinateAxes`, `FBXTimeMode`/
  `FBXTimeProtocol`/`FBXSnapMode`, `FBXMetadata`, `FBXSceneSettings`,
  `FBXScene` itself: the arena (`elements` + one typed array per element
  type), `connections`/`connectionsDstOrder`, `rootNode`, `anim`, `warnings`,
  `element(_:)` lookup, and the two `load(...)` entry points (delegate to
  `Loader.load`).
- `Node.swift` — `FBXInheritMode`, `FBXMirrorAxis`, `FBXNode`: hierarchy
  (`parentID`/`childrenIDs`), attached attributes (`meshID`/`lightID`/
  `cameraID`/`boneID`/`attribID`/`allAttribIDs`), synthetic helper links
  (`geometryTransformHelperID`/`scaleHelperID`/`inheritScaleNodeID`/
  `bindPoseID`), transform inputs (`inheritMode`, `rotationOrder`,
  `eulerRotation`), finalizer-derived transforms/matrices (`localTransform`,
  `geometryTransform`, `inheritScale`, `nodeToParent/World`,
  `geometryToNode/World`, `unscaledNodeToWorld`), axis/unit adjust factors
  (`adjustPre/Post*`), and flags (`visible`, `isRoot`, `hasGeometryTransform`,
  `nodeDepth`, …).
- `Mesh.swift` — `FBXVertexAttribute<Value>` (+ `FBXVertexReal/Vec2/Vec3/Vec4`
  aliases), `FBXUVSet`, `FBXColorSet`, `FBXFace`, `FBXEdge`, `FBXFaceGroup`,
  `FBXMeshPart`, `FBXSubdivisionDisplayMode`/`Boundary`, `FBXMesh` (all
  per-face/per-edge/per-vertex arrays, the `vertexPosition`/`vertexNormal`/…
  first-layer mirrors, `uvSets`/`colorSets`, `materialIDs`, deformer id
  arrays, and the internal `LegacyTextureLayer` staging struct consumed by the
  linker's 6x00 legacy-material-texture patch).
- `Material.swift` — `FBXMaterialMap`, `FBXMaterialFeatureInfo`,
  `FBXMaterialTexture`, `FBXMaterialFBXMaps` (20 legacy channels +
  `allMaps` dumper helper), `FBXMaterialPBRMaps` (~55 channels, stretch),
  `FBXMaterialFeatures` (23 toggles), `FBXShaderType`, `FBXMaterial`,
  `FBXTextureType`, `FBXWrapMode`, `FBXBlendMode`, `FBXTextureLayer`,
  `FBXTexture`, `FBXVideo`.
- `Attributes.swift` — node-attachable attribute elements that aren't mesh:
  `FBXLightType`/`Decay`/`AreaShape`, `FBXLight`; `FBXProjectionMode`,
  `FBXAspectMode`, `FBXApertureMode`, `FBXGateFit`, `FBXApertureFormat`,
  `FBXCamera`; `FBXBone`; `FBXEmpty`; `FBXBonePose`, `FBXPose`.
- `Deformers.swift` — `FBXSkinningMethod`, `FBXSkinVertex`, `FBXSkinWeight`,
  `FBXSkinDeformer`, `FBXSkinCluster`; `FBXBlendDeformer`, `FBXBlendKeyframe`,
  `FBXBlendChannel` (+ `shape(for:)` keyframe resolver), `FBXBlendShape`.
- `Animation.swift` — `FBXAnimProp`, `FBXAnim` (evaluation descriptor),
  `FBXKeyframe`, `FBXExtrapolationMode`/`FBXExtrapolation`, `FBXAnimStack`,
  `FBXAnimLayer` (+ computed `anim` wrapping `[self]`), `FBXAnimValue` (+
  `curves`/`curve(_:)` accessors), `FBXAnimCurve`.
- `TransformChain.swift` — `enum TransformChain`: the ONE port of
  `ufbxi_get_transform` (ufbx.c:22836) plus its accumulation/mirror helpers.
  Not an `FBXElement`; pure static math shared by `Loader/SceneFinalizer.swift`
  and `Evaluate/AnimEval.swift`.

## Business rules & invariants

- **`element_id` is the only cross-ref currency.** Every `*ID: Int32` /
  `*IDs: [Int32]` field is an index into `scene.elements`, `-1` = none. Never
  store an `FBXElement` reference directly in another element (would create a
  strong retain cycle) — go through `typedElement<T>(_:)` /
  `FBXElementList<T>` instead. `FBXElement.scene` is `unowned` for the same
  reason.
- **`elementID` vs `typedID`.** `elementID` is dense creation order across ALL
  elements and never changes. `typedID` is the index into the element's typed
  array (`scene.nodes`, `scene.meshes`, …) and IS reassigned for nodes when
  `SceneLinker` linearizes the hierarchy (parent-before-child order) — never
  cache a `typedID` across that step, and never assume `typedID == elementID`.
- **`FBXProps.find` requires sortedness.** `props` MUST stay sorted by
  `FBXProp.less` (name key, then byte-wise name comparison, matching C
  `strcmp` — NOT Swift's Unicode `<`) or the binary search in `find(_:)`
  silently returns wrong/missing results. Readers populate `props` presorted;
  don't `append` to a loaded element's `props` array.
- **Prop lookup skips `NO_VALUE`.** `find` walks the matching-key run and
  skips any prop with `.flags.contains(.noValue)` (ufbx.c:11480-11509) — a
  present-but-valueless prop must NOT shadow a `defaults`-chain value.
- **`FBXMaterialMap.hasValue` is not "value is non-default".** Per
  `ufbxi_update_factor` (ufbx.c:20096-20107, notes 14 step 6h), a factor map
  can have `hasValue == false` while still carrying a synthesized non-zero
  `valueVec4`/`valueComponents` (e.g. `factor = 1.0` when the paired color was
  set and non-zero). Never treat `hasValue == false` as "ignore this map's
  value" — only as "the file did not explicitly author it."
  `valueComponents`/`hasValue` come from the `ufbxi_fetch_maps` mapping
  tables, NOT from the source FBX prop's arity.
- **`FBXInheritMode` int mapping is non-ordinal.** Raw `InheritType` FBX
  values: `0 → componentwiseScale`, `2 → ignoreParentScale`, everything else
  (including the unset default of 1) `→ normal` (ufbx.c:12608-12622). Do not
  `FBXInheritMode(rawValue:)` a raw file value directly.
  `originalInheritMode` preserves the raw mapped value for the dumper;
  `inheritMode` may differ after finalizer adjustment.
- **`TransformChain.getTransform` is the single pivot-chain implementation.**
  Both the finalizer (`node.localTransform`) and `AnimEval.evaluateTransform`
  call it — this is what guarantees a non-animated node's evaluated transform
  is byte-identical to its static one. NEVER re-derive or fork this math in
  either caller; if the chain needs a behavior change, change it here once.
  Order matters: `T·Roff·Rp·Rpre·R·Rpost⁻¹·Rp⁻¹·Soff·Sp·S·Sp⁻¹`, built by
  left-multiplying each op onto `t` (see `addTranslate`/`mulScale`/
  `mulRotate` call order in `getTransform`). PostRotation is applied
  *inverted*; Pre/PostRotation always use XYZ order regardless of
  `node.rotationOrder`, which applies ONLY to `Lcl Rotation`.
- **Angles vs everything else.** `FBXNode.eulerRotation` and all pivot/rotation
  props read via `TransformChain` are **degrees** (raw FBX convention);
  `FBXQuat`/`FBXMatrix` math is otherwise unitless. `FBXCamera.fieldOfViewDeg`
  is explicitly degrees (there's a separate `fieldOfViewTan`). Time values in
  `FBXAnimStack`/`FBXKeyframe`/`FBXSceneSettings` are **seconds** (`Double`),
  already converted from FBX ticks upstream — don't re-divide by the ticks
  constant here.
- **`FBXLight.intensity`** is pre-divided by 100 from the raw `"Intensity"`
  FBX property (ufbx.c ~20044) — a DCC authoring-scale quirk, not a bug if a
  golden diff looks "100x off" on the *raw* prop value.
- **`FBXMesh.noIndex` (`0xFFFF_FFFF`)** is the universal "absent index"
  sentinel (`UFBX_NO_INDEX`), reused for `vertexFirstIndex`,
  `FBXTexture.fileIndex`, skin-cluster overflow, etc. — comparisons must use
  this exact `UInt32` constant, not `-1` or `Int`.
  `FBXVertexAttribute.indices` length equals `mesh.numIndices` **only when
  `exists == true`**; don't index into it unconditionally.
  `FBXFace.numIndices` may legitimately be `< 3` (degenerate/point/line
  faces) — ufbx does not filter these at load, so consumers must handle them.
  `FBXEdge.a/b` are indices into the flat per-corner index stream, not vertex
  ids.
- **Deformer weight pools are flat and unclamped.** `FBXSkinVertex.weightBegin/
  numWeights` slice into `FBXSkinDeformer.weights[]`; weights are pre-sorted
  descending but NOT normalized to sum to 1. `FBXSkinCluster.vertices`/
  `weights` and `FBXBlendShape.offsetVertices` are documented as "may be out
  of bounds for a given mesh" — always bounds-check before indexing
  `mesh.vertices` with them (ufbx itself tolerates stale/mismatched indices
  here).
- **Connection graph ordering is load-bearing.** `scene.connections` is sorted
  by `srcID` (stable, tie-broken); `connectionsDstOrder` is a permutation
  sorted by `dstID`. Each element's `connectionsSrc`/`connectionsDst` are
  `Range<Int>` slices into these two arrays, assigned once by `SceneLinker`
  and never mutated after. Swift's `sort` is NOT stable — any code that
  re-sorts a `[FBXConnection]` must tie-break explicitly (see DESIGN.md
  "Known fidelity traps").
- **`FBXAnimLayer.animProps`** must stay sorted by `(elementID, propName)` —
  DESIGN/ufbx contract; `AnimEval` and the dumper both rely on this order for
  determinism, not just correctness.
- **`fbxID`** (internal, `UInt64`) is the *file* identity, distinct from
  `elementID`. For `version < 7000` (including 6100 ASCII) there is no
  numeric id in the file — the reader synthesizes one via a hash of
  `Type::Name`. Never assume `fbxID` is stable/meaningful across files or use
  it as an array index.

## Swift tips for this code

- These are the types `FBXDumpCore` (no `@testable`) reads to build golden
  dumps — any field the dump format needs MUST be `public` (typically
  `public internal(set) var`), never `internal`/`private`. Check
  `docs/DUMP_FORMAT.md` before removing or narrowing a stored property's
  access level.
- `FBXElementList<T>`'s `subscript` does `as! T` — a forced downcast. It is
  safe only because every `elementIDs` array here is constructed from
  already-typed id arrays (e.g. `childrenIDs`, `materialIDs`) that the linker
  populated correctly; do not construct an `FBXElementList<T>` from an
  arbitrary/untrusted `[Int32]`.
  `typedElement<T>(_:)` is the *safe* counterpart (`as?`, returns `nil` on
  mismatch/-1/out-of-range) — prefer it for anything not already
  type-guaranteed by construction.
- `FBXAnimValue.curve(_:)` exists specifically to avoid allocating the
  `curves` array on the animation-eval hot path — use `curve(_:)` in any new
  hot-path code, reserve `.curves` for convenience/dumper call sites.
  `FBXAnimLayer.anim` is a *computed* property (`FBXAnim(layers: [self])`),
  not stored — this sidesteps a self-referential retain cycle that a stored
  `anim.layers == [self]` would create.
- Don't add `lazy var` or any memoized/cached field to a class in this
  directory — the freeze rule means everything is `@unchecked Sendable`
  after `load()` returns, and a lazily-initialized var mutated from multiple
  threads after that point is a real data race, not just a style nit.
- Prefer adding a stored field only to the element file that DESIGN.md's
  Internal Contracts / ownership map assigns it to; readers/linker/finalizer
  get temporary append rights to these files per their task, never
  concurrent ownership.
- `Double` everywhere for FBX "real" values (matches `ufbx_real`); don't
  introduce `Float` here except where a type already deliberately uses it
  (there are none in this directory — bit-exact `Float` paths live in the
  document/parse layer).

## Dependencies & boundaries

- May import only `Foundation` and other `SwiftFBX` files (`Math/*`,
  `FBXError`, `FBXWarning`, `FBXRotationOrder`, `FBXLoadOptions`). Must NOT
  import `Loader/*` types directly — `Scene.swift`'s `load(...)` calls into
  `Loader.load` as the one sanctioned exception, kept to a single call site.
- Must NOT depend on `FBXDumpCore` or `Tests` — dependency direction is
  strictly `Scene` → (consumed by) `Loader`, `Evaluate`, `FBXDumpCore`, tests.
- Public surface here (element classes, `FBXElementList` typealiases,
  `FBXProps.find*`, `FBXScene.load`) is what `Loader/*`, `Evaluate/AnimEval.swift`,
  `FBXDumpCore/SceneDump.swift`, and every test target build against — treat
  any signature change as a cross-module break, not a local edit.
- `TransformChain` is `internal` (no `public`), used only by `Loader/
  SceneFinalizer.swift` and `Evaluate/AnimEval.swift` within this package.

## Testing

- No dedicated unit-test file for `Scene/*` types themselves — they're
  exercised indirectly through:
  - `swift test --filter GoldenTests` — the primary acceptance suite;
    loads all 44 files under `Tests/SwiftFBXTests/Resources/fbx/` and diffs
    against `Resources/golden/*.json` (1e-6 tolerance). Any change to a
    stored field's meaning, default, or population order will likely show up
    here.
  - `swift test --filter CurveEvalTests` and `MathTests` — cover
    `FBXKeyframe`/`FBXExtrapolation` evaluation semantics and the math types
    (`FBXQuat`, `FBXMatrix`, `FBXTransform`) that `TransformChain` composes.
  - `swift test --filter MalformedInputTests` — fuzz/crash-safety, relevant
    if you add bounds-sensitive access (e.g. new `NO_INDEX`-sentineled array).
- Full suite: `swift test` from repo root.
- If you change `TransformChain.getTransform` or any accumulation helper, run
  both `GoldenTests` (static transforms) and `CurveEvalTests`/any animated
  golden fixtures — a fix that only touches the static path but not
  `AnimEval` (or vice versa) breaks the shared-source-of-truth invariant.

## Rules for the model

- Any behavior change in this directory must keep `GoldenTests` at 44/44
  (`swift test --filter GoldenTests`) before considering the change done.
- Never fork `TransformChain`'s pivot math into `SceneFinalizer` or
  `AnimEval` "just for this one case" — fix it in `TransformChain.swift` so
  both callers stay identical.
- Never weaken `FBXMesh.noIndex` / bounds checks on deformer weight arrays to
  make a crash or test go away — those arrays are documented as
  intentionally possibly-out-of-bounds; the correct fix is a guard at the
  call site, not removing the sentinel semantics.
- Before changing anything under `find(_:)` in `Properties.swift` or the
  `FBXProp.less`/`byteLess` comparator, re-read `docs/ufbx-notes/05-read-objects-1.md`
  (prop sort) — `find`'s binary search correctness depends on exact ufbx sort
  order, not just "roughly sorted."
- Before changing `FBXMaterialMap`/`FBXMaterialFBXMaps` semantics, re-read
  `docs/ufbx-notes/14-public-model-1.md` step 6 (`ufbxi_fetch_maps`) — the
  `hasValue`/factor-defaulting/roughness-glossiness-swap quirks are easy to
  "fix" incorrectly if you reason from first principles instead of ufbx.c.
- When adding a new stored field, mirror the exact ufbx struct field name/
  order in a doc comment citing the `ufbx.h` line, and confirm it's `public`
  if `docs/DUMP_FORMAT.md` needs it.
- Don't add convenience computed properties that allocate on paths documented
  as "hot" (see `FBXAnimValue.curve(_:)` vs `.curves`) without checking
  whether `Evaluate/AnimEval.swift` already has a non-allocating alternative
  it expects to keep using.
