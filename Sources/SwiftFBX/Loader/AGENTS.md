# Sources/SwiftFBX/Loader

## Purpose
The fidelity-critical load pipeline: `Data` → parsed `FBXDocument` → typed
`FBXScene`. Ports the FBX branch of ufbx's `ufbxi_load_imp`. Every parity bug
lives or dies here; this directory is where the golden suite is won or lost.

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions (arena
ownership model, id spaces, ufbx-fidelity rule, freeze/Sendable rules,
build/test commands).

## Pipeline stage order (do not reorder)
`Loader.load` runs exactly: `FBXDocument.parse` → `ElementReader.readDocument`
→ `TakesReader.read` → `SceneLinker.link` → `SceneFinalizer.finalize` →
copy `ctx.warnings` to `scene.warnings`. The **handoff contract** between stages
is the load-bearing invariant:
- **Readers** (`ElementReader`, `GeometryReader`, `AnimationReader`,
  `TakesReader`) only APPEND elements (via `ctx.makeElement`) and raw edges
  (`ctx.tmpConnections`), register fbx ids, and stash scratch
  (`tmpFullWeights`, `tmpBonePoses`). They NEVER resolve a connection or a
  cross-reference. Poses are the only thing that references other elements by
  raw fbx id, and even those are stashed, not resolved.
- **`SceneLinker`** resolves `tmpConnections` → typed `FBXConnection`s, sorts
  them twice, linearizes nodes (reassigning node `typedID`s), and wires every
  connection-derived cross-ref (materials, deformers, layers, curves). It stops
  at connection wiring.
- **`SceneFinalizer`** turns interned `props` into interpreted fields
  (transforms, world matrices, lights/cameras/bones, material maps, time ranges).
  It reads the graph Linker built; it must not add elements or connections.

## Files
- `LoadOptions.swift` — `FBXLoadOptions` source/decoded-array limits and the
  per-parse `FBXDecodedArrayBudget`. All limits are positive, checked before
  allocation/growth, and shared by the binary and ASCII document parsers.
- `LoadContext.swift` — `LoadContext` (per-load arena owner + id/scratch tables), the reader scratch types `TmpConnection`/`TemplateKey`/`ObjectInfo`, `FBXExporter`. Owns synthetic-id minting (`nextSyntheticID`, `syntheticID(for:)`, `validateFbxID`), the element factory `makeElement`, template register/`findTemplate`, `insertFbxID`, and warning dedup (`warning`).
- `Loader.swift` — `Loader.load(contentsOf:)`/`load(data:)`: the driver that runs the five stages. Public `FBXScene.load` in Scene/Scene.swift delegates here.
- `ElementReader.swift` — `ElementReader.readDocument`: header extension + exporter detection, KTime unit selection, `Definitions` templates, `Objects` dispatch (`readObject` splits `Type::Name`, per-class creation), `Connections`, `GlobalSettings`, Version5 legacy settings. Owns `readProperties`/`readProperty`, `splitTypeAndName`, `matchExporter`, the `nodePropertyNames` set, and the pre-7000 synthetic-attribute split (`readSyntheticAttribute`).
- `GeometryReader.swift` — `GeometryReader.readGeometry` (mesh), `readShape` (blend deltas), plus per-vertex layer-element decode (`readVertexElement`), index sanitization (`fixIndex`/`checkIndices`), truncated per-face/edge arrays, face groups, pre-7100 inline blend shapes, and the 6x00 `LayerElement*Textures` capture (`readLegacyTextureLayer`).
- `AnimationReader.swift` — `AnimationReader.readObject` dispatch for materials/textures/videos/deformers/anim objects/poses. Contains the animation-curve tangent decode (`readAnimationCurve`, the `KF` flag table, `solveAutoTangent*`/`solveTCB`), skin/cluster/blend-channel readers, and `TmpBonePose`.
- `TakesReader.swift` — `TakesReader.read`: pre-7000 Take → synthetic anim stack/layer/value/curve build (`readTake`/`readTakeObject`/`readTakePropChannel`/`readTakeAnimChannel`); for ≥7000 only back-fills stack `LocalTime`/`ReferenceTime` time ranges.
- `SceneLinker.swift` — `SceneLinker.link`: `resolveConnections`, `addConnectionsToElements` (+ `markAnimatedProps`), `linearizeNodes`, `setupNodes`, `linkPoses`, `setupInstances`, `linkSkinDeformers`, `linkBlendDeformers`, `linkMeshes`, `linkAnim`, `linkMaterials`, `patchLegacyMeshTextures`, and the `fetch*` connection-traversal helpers.
- `SceneFinalizer.swift` — `SceneFinalizer.finalize`: `updateSceneSettings`, `updateAdjustTransforms`, `updateScene` orchestrator, and per-element `updateNode`/`updateLight`/`updateCamera`/`updateBone`/`updateInitialClusters`/`updatePose`/`updateSkinCluster`/`updateBlendChannel`/`updateTexture`/`updateMaterial` (+ `fetchMaps`), `updateAnimStack`. Holds the internal `Meta` scalars.

## Business rules & invariants
- **Synthetic fbx ids for ALL version < 7000** (not <6000). Every pre-7000 object AND every connection endpoint is keyed by `ctx.syntheticID(for:)` on the exact same (sanitized) `Type::Name` string on both sides. Get the string wrong on one side and the connection silently dangles → empty scene. Post-7000 uses real int64 ids run through `validateFbxID` (ufbx.c:12260 rehashes ids ≥ 0x8000… into synthetics).
- **`InheritType` is NOT ordinal** (`readModel`, ufbx.c:12608-12617): `0` → `componentwiseScale`, `2` → `ignoreParentScale`, everything else (incl. default 1 / unset -1) stays `normal`. Then `setupNodes` forces root's direct children to `.normal` under the default TRANSFORM_ROOT space conversion.
- **Dst-connection sort tie-break is ORIGINAL file order, not src-sorted order** (`resolveConnections`, ufbx.c:18768-18774): `connections_dst` is copied from tmp/file order *before* `connections_src` is sorted. The Swift port tie-breaks the dst sort on the original resolved index, not the src position. Matters for 6100 textures OO-connected to a mesh node (fetch order = file order).
- **Version5 legacy settings synthesis** (`readLegacySettings`): a positive `Version5 > Settings > FrameRate` synthesizes `CustomFrameRate` + `TimeMode = CUSTOM (14)` props, prepended then stable-sorted + deduplicated keep-LAST, so an existing GlobalSettings prop of the same name wins.
- **6100 `LayerElement*Textures` patch pass** (`patchLegacyMeshTextures`): pre-7000 stores per-material textures inside mesh geometry, not as material→texture connections. Captured by `readLegacyTextureLayer` (name → material prop; `LayerElementTexture` = Diffuse), then patched onto materials only when a material has no textures from direct connections.
- **KeyAttr run-length decode** (`readAnimationCurve`): time/value arrays are parallel and one-per-key; `KeyAttrFlags`/`KeyAttrRefCount` are run-length coded with 4 attribute floats per run. `refs.count*4 == words.count` and `attrFlags.count == refs.count` are hard-checked; `refsLeft` underflow is corrupt-data.
- **Negative/untrusted counts are rejected, not silently emptied.** `TakesReader.readTakeAnimChannel` rejects a negative `KeyCount` (corrupt), bounds `reserveCapacity` by `data.count` (untrusted `KeyCount` must not OOM), and requires the key stream to consume `data` exactly (`p == data.count`). Skin cluster `Indexes`/`Weights` must match exactly; a skin deformer's DQ arrays may mismatch (truncate to shorter).
- **face_material lifecycle**: `readGeometry` always seeds a full length-`numFaces` `faceMaterial` (sentinel zeros). `linkMeshes` then overwrites by resolved material count: 0 → cleared (dump omits it), 1 → all-zeros, >1 → keep the per-face layer array. Getting this wrong reintroduces the historical "spurious face_material" golden failures.
- **KTime units**: `ktimeSec` = 46186158000 for version < 8000, else 141120000 (opt-in via header `TCDefinition == 127`). Anim-curve/Take times are ticks; divide by `ktimeSecDouble` to get seconds. Anim-stack `LocalStart`/`Stop` are ticks stored in `valueInt`.
- **Determinism**: Swift's `sort` is NOT stable. Every sort here reproduces ufbx's comparator PLUS an explicit original-index tie-break (props, connections, nodes, weights, blend keyframes, material textures, legacy mesh textures). Removing a tie-break is a latent nondeterminism bug even if a golden happens to pass.
- **Units**: rotations in props are degrees; light `Intensity` is stored ×100 (divide by 100); bone `Size` is divided by an exporter-specific unit (Maya 100/3, Blender-binary 33, ASCII/pre-6000 1.0).

## Swift tips for this code
- FBX int32 indices are treated as UNSIGNED — always `UInt32(bitPattern:)` when reinterpreting an `asInt32Array`; face terminators use bitwise complement `~ix`, never arithmetic negation.
- `Float` vs `Double` is load-bearing in the tangent math: ufbx computes `dx = (float)(weight*delta)` (one rounding to float) then `dy = dx*slope` (float×float), and TCB/user tangent data are bit-reinterpreted 32-bit words (`Float(bitPattern:)`), NOT numeric conversions. `attrWords` handles both `.float` and `.int32` parser storage.
- Elements capture `unowned/weak scene`; `ctx.scene` is created empty BEFORE any element. `makeElement` assigns dense `elementID` (== creation order) and per-type `typedID`; node `typedID`s are REASSIGNED by `linearizeNodes` (depth-first) — never assume a node's `typedID` before link.
- `KF.constantNext` deliberately shares bit `0x100` with `tangentAuto`; they are disambiguated by the mutually-exclusive interpolation bits. Do not "clean this up."
- `dstConnections(of:)` must go through `connectionsDstOrder` (dst-sorted view); `srcConnections(of:)` is a direct slice of `scene.connections` (src-sorted). Mixing them up scrambles fetch order.
- Trapping index math: `readTakeAnimChannel`'s `0..<numKeys` loop would trap on a byte-flipped negative count — the guard exists for that reason; do not weaken it.

## Dependencies & boundaries
- May import: Foundation; the Parse layer (`FBXDocument`, `FBXDocNode`, `FloatParse`), the Scene model (all `FBX*` element/prop/geometry types), and `TransformChain`.
- Must NOT be depended on by the Scene model or Parse layer — the Loader is the top of the library's internal stack. Public surface consumed elsewhere is only `Loader.load` (re-exported via `FBXScene.load`).
- `LoadContext` never escapes a single `load()` call; nothing outside this directory should hold a reference to it or to `Tmp*` scratch types.
- `load(contentsOf:)` accepts file URLs only and performs a bounded chunked
  read. Keep the one-byte sentinel beyond `maximumSourceBytes`; it distinguishes
  an exact-boundary file from an oversized file without reading the remainder.

## Testing
- Primary: `swift test --filter GoldenTests` — must stay 44/44. Any behavior change here is validated against the ufbx golden dumps (docs/DUMP_FORMAT.md).
- Curve/tangent decode: `swift test --filter CurveEvalTests`.
- Crash-safety on corrupt/hostile input: `swift test --filter MalformedInputTests` (covers the negative-count / truncated-stream boundaries above).
- Full run: `swift test`. There is no standalone "LoaderTests" file — GoldenTests IS the integration coverage for this whole directory.

## Rules for the model
- Any behavior change here MUST keep `GoldenTests` at 44/44. Run the golden suite before and after.
- Preserve the reader→linker→finalizer handoff: readers only append + stash; never resolve a connection or compute an interpreted field in a reader.
- Never weaken a bounds/negative-count check or an exact-size guard to make a test pass — those are fuzz crash-safety, not incidental.
- Never delete a stable-sort tie-break; if you touch a sort, keep the original-index tie-break.
- Before changing the read/link/finalize behavior for a subsystem, consult the matching `docs/ufbx-notes/`: 05/06 (read objects), 07 (takes/anim), 08 (link/connections), 09 (finalize/skin/pose/blend), 10 (node/transform/material update), and the "Known fidelity traps" in `docs/DESIGN.md`.
- Cite the ufbx.c line when porting; when in doubt, `tools/ufbx/ufbx.c` is ground truth.
