# swift-fbx (repository root)

## What this project is

A **pure-Swift port of [ufbx](https://github.com/ufbx/ufbx)** — a parser for
Autodesk FBX 3D scene files. It loads binary FBX 7100–7700 (including 64-bit
record and big-endian variants) and ASCII FBX 6100–7700 into a typed scene graph
(nodes, meshes, materials, textures, lights, cameras, bones, skinning, blend
shapes, animation) and can evaluate animation at arbitrary times. Zero
dependencies: DEFLATE decompression and locale-independent float parsing are
implemented in-package.

**The defining property of this codebase: behavioral parity with the C ufbx.**
Correctness is defined by golden-dump tests — 44 real exporter files loaded by
SwiftFBX must produce structurally identical scene dumps (1e-6 float tolerance)
to those produced by real ufbx. "Looks right" is not the bar; matching ufbx is.

## Tech stack

- Swift 6 (`swift-tools-version:6.0`), macOS 13+/iOS 16+ platforms in
  `Package.swift`; developed with Swift 6.3 on macOS.
- SwiftPM only. No external dependencies. Foundation allowed.
- Test frameworks: Swift Testing (`@Test`/`#expect`) and XCTest (both in use).

## Commands

```sh
swift build                 # debug build, all targets
swift build -c release
swift test                  # FULL suite incl. golden parity — the acceptance bar
swift test --filter GoldenTests          # parity suite only (44 files)
swift test --filter MalformedInputTests  # crash-safety regressions
swift run fbx-dump <file.fbx>            # emit golden-format JSON for one file
cc -O2 -o /tmp/ufbx_dump tools/ufbx_dump.c tools/ufbx/ufbx.c -lm   # C reference harness
```

There is no linter/formatter configured; match the style of surrounding code.

## Directory map

| Path | What lives there |
|---|---|
| `Sources/SwiftFBX/` | The library. See `Sources/SwiftFBX/AGENTS.md` for architecture + per-subdirectory guides. |
| `Sources/FBXDumpCore/` | `SceneDump` — golden-format JSON builder (public-API-only consumer of SwiftFBX). |
| `Sources/fbx-dump/` | Thin CLI wrapper (`main.swift`) around load + SceneDump. No own AGENTS.md. |
| `Tests/SwiftFBXTests/` | All tests + resources (44 fbx inputs, 44 golden dumps, DEFLATE vectors, malformed corpus). |
| `docs/DESIGN.md` | Architecture, binding internal contracts, **known fidelity traps** — read before changing library code. |
| `docs/DUMP_FORMAT.md` | The dump contract shared by `tools/ufbx_dump.c` and `SceneDump.swift`. |
| `docs/ufbx-notes/` | 15 line-cited subsystem porting guides (00-overview.md = pipeline map + top-10 risks). Reference material — do not edit casually; line numbers refer to the vendored ufbx revision. |
| `tools/` | C reference harness + **vendored ufbx** (never edit; rev pinned in `tools/ufbx/VERSION`). |
| `CLAUDE.md`, `LOG.md` | Session context + decision log (newest first). |

## Domain glossary

- **fbx_id** — `UInt64` identity used inside the FBX file. Post-7000: the file's
  object UID. Pre-7000 (incl. 6100): synthesized hash of `Type::Name`.
- **element_id** — dense `Int` index into `scene.elements`, creation order,
  across all element types. All stored cross-references (`*ID: Int32` fields)
  are element_ids.
- **typed_id** — index within one type's array (`scene.nodes`, `scene.meshes`, …).
  Node typed_ids are REASSIGNED to depth-sorted order during linking. Dumps emit
  typed_ids.
- **KTime** — FBX time tick; seconds = `Double(ticks) / 46186158000.0`.
- **Golden file/dump** — an FBX test input and the JSON dump real ufbx produces
  for it; the parity target.
- **Takes** — pre-7000 animation container; also read for ≥7000 to back-fill
  stack time ranges.

## Rules for the model (repo-wide)

- **Never regress `swift test`.** GoldenTests must stay 44/44; MalformedInputTests
  must stay green. Run the full suite after any library change.
- **When in doubt, do what ufbx.c does** — quirks, defaults, clamps, sort orders
  included. `tools/ufbx/ufbx.c` is ground truth; `docs/ufbx-notes/` tells you
  where to look. Do not "fix" behavior that matches ufbx.
- Never edit: `tools/ufbx/*` (vendored), `Tests/SwiftFBXTests/Resources/golden/*`
  (generated — regenerate via the C harness instead), `docs/ufbx-notes/*` (unless
  the vendored ufbx revision changes).
- Malformed input must **throw `FBXError`, never trap** — no unchecked
  `Int(...)`/subscript/`Range` on file-derived values. Never weaken a bounds
  check to make something pass.
- Comment style: only for non-obvious ported behavior, formatted
  `// ufbx: <what/why>` (often with a ufbx.c line ref). No narration comments.
- Commit only when the user asks. The `LOG.md` gets milestone entries, newest first.
