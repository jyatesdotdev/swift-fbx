# Sources/SwiftFBX

See the root `AGENTS.md` for project purpose, commands, glossary, and repo-wide
rules. This file covers library-wide architecture; each subdirectory has its own
`AGENTS.md` with per-file detail.

## Load pipeline (who does what, in order)

```
Data
 → DocumentParser (Document/)   format+version detect, drive parse
 → Binary/AsciiParser + ParseState + Inflate
                                → FBXDocument node tree (arrays already
                                  type-converted, PAD_BEGIN applied)
 → ElementReader (Loader/)      header ext, templates, object dispatch, models,
                                Connections → LoadContext.tmpConnections
 → GeometryReader / AnimationReader (Loader/)   meshes / materials-textures-
                                deformers-anim objects
 → TakesReader (Loader/)        6100 full anim; ≥7000 stack time-range back-fill
 → SceneLinker (Loader/)        resolve connections, hierarchy, linearize nodes
                                (reassigns node typedIDs), wire all cross-refs,
                                every deterministic sort
 → SceneFinalizer (Loader/)     settings, props→fields per element, transform
                                chain (via Scene/TransformChain.swift), world
                                matrices, material fetchMaps
 → FBXScene (Scene/)            frozen result
```

Post-load, `Evaluate/` computes animated values on demand; `Geometry/` offers
triangulation; `Math/` underpins everything.

## Subdirectory boundaries

- `Math/` — leaf; depends on nothing.
- `Core/` — errors, byte reader, inflate, float parse; depends on nothing else.
- `Document/` — depends on Core + Loader/LoadOptions only. Knows NOTHING about
  scene elements.
- `Scene/` — the object model + `TransformChain`; depends on Math. Contains **no
  parsing or linking logic**.
- `Loader/` — the pipeline; may depend on everything above. Nothing depends on
  Loader except `FBXScene.load` entry points.
- `Evaluate/`, `Geometry/` — post-load utilities over Scene (+ Math).

## The ownership/arena model (why the code looks like this)

FBX scenes are cyclic graphs; ARC would leak with naive strong references.
So: `FBXScene` strongly owns every element (`elements: [FBXElement]` in
element_id order + typed arrays); every element is a `final class` holding
`unowned let scene`; **all stored cross-refs are `Int32` element_ids** with
computed accessors that downcast (`scene.elements[Int(id)] as! FBXNode`);
list-valued refs use `FBXElementList<T>` (RandomAccessCollection over
element_ids). Scene is constructed empty BEFORE any element, so `unowned` never
dangles. Releasing the scene deallocates everything — do not introduce strong
element→element references.

## Library-wide invariants

- **Freeze rule**: nothing is mutated after `load` returns. Every shared class
  is `@unchecked Sendable` on that basis — adding a `lazy var` or post-load
  mutation silently breaks it.
- **Public-surface rule**: everything `docs/DUMP_FORMAT.md` dumps must be
  reachable via `public` getters (FBXDumpCore has no `@testable`). Prefer
  `public internal(set) var`.
- **Determinism**: element ordering and every sort must match ufbx exactly.
  Swift's `sort` is unstable — always tie-break explicitly (usually on
  element_id, or original file order where ufbx does; see SceneLinker).
- **Numeric conventions**: `Double` everywhere except deliberate bit-exact
  `Float` paths (ACCURATE_F32, `KeyAttrDataFloat`, some ufbx float literals like
  the `0.99999f` layer-weight clamp). Float→int conversions saturate; untrusted
  sizes/offsets use checked math that throws, never traps.
- Angles are **degrees** in FBX props and public fields; conversion points
  mirror ufbx (see `Scene/TransformChain.swift`, `Loader/SceneFinalizer.swift`).

## Rules for the model

- Read `docs/DESIGN.md` §Internal contracts before adding/renaming public API;
  the contracts there are binding and `FBXDumpCore` + tests compile against them.
- Any behavior change here must keep `swift test` fully green (44/44 golden).
  If a golden diff appears, the fix is to match ufbx, not to adjust the test.
- Consult the matching `docs/ufbx-notes/NN-*.md` before touching a subsystem;
  the notes cite the exact ufbx.c lines the code was ported from.
- Transform math exists ONCE (`Scene/TransformChain.swift`), shared by the
  finalizer and the evaluator — never fork or inline a second copy.
