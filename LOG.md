# LOG
Running log of noteworthy work; newest first.

## 2026-07-17 21:23 — Complete the port: hardened, reviewed, all gates green
- **What:** Hardening + adversarial-review workflow finished: fixed both fuzz crash classes (unchecked `Int(UInt64)` on hostile size fields in BinaryParser; negative `KeyCount` → Swift `Range` trap in TakesReader, fixed at ufbx's exact `"Z"`-format rejection boundary, ufbx.c:7743) and applied 8 verified review findings — notably `f64ToI64` trapping at the 2^63 boundary (`Double(Int64.max)` rounds UP to 2^63, admitting a value that traps; use exclusive `< 9223372036854775808.0`) and ufbx's `0.99999f` layer-weight clamp needing `Double(Float(0.99999))` for bit parity.
- **Why:** A parser must throw, never trap, on malformed input; the review lenses caught boundary bugs fuzzing and goldens couldn't reach.
- **Impact:** Final state: 144 tests / 0 failures (44/44 golden, 44 malformed-truncation cases), zero crashes over 749 corpus files + 2400+ mutations on debug AND release, clean builds. The "release exits 0 / debug traps" mystery was a fuzz-harness artifact (shared temp path saved post-hoc), not a code bug — verify crasher inputs are saved at crash time before chasing such ghosts. Tree is complete but uncommitted.

## 2026-07-17 19:40 — Reach 44/44 golden parity; fuzz pass finds 7 crashers
- **What:** Closed the last two golden classes: (1) pre-7000 frame rate lives in `Version5 > Settings > FrameRate`, which ufbx turns into synthetic `CustomFrameRate`+`TimeMode=CUSTOM` props (ufbx.c:15766/15921); (2) 6100 textures wire via `LayerElement*Textures` mesh blocks + a patch-from-meshes pass (ufbx.c:22364–22466). Then fuzzed: 749 corpus files + truncations + seeded mutations → 7 crashers (unchecked int conversion in `BinaryParser.parseNode` + a nondeterministic release-mode class). Hardening/review workflow launched.
- **Why:** Golden parity is the port's acceptance bar; crash-on-malformed-input is unacceptable for a parser library.
- **Impact:** Gotcha found en route: ufbx's dst-sorted connection array tie-breaks on ORIGINAL file order, not src-sorted order (ufbx.c:18768–18774) — was silently wrong for 42/44 files because ties are rare; `TextureId` indexing exposed it. Fuzz repro harnesses live in the session scratchpad (`fuzzrun2.py`, seed 42); crash inputs preserved to Tests/Resources/malformed/ by the running workflow.

## 2026-07-17 17:20 — Land full SwiftFBX implementation: 129 unit tests green, 31/44 golden parity
- **What:** All six implementation waves completed (19 agents, zero failures): full library from inflate/float-parse through parsers, scene model, readers, linker/finalizer, evaluation, triangulation, and the golden dumper. Package builds clean on Swift 6; every unit suite passes; first-ever golden run scored 31/44.
- **Why:** Milestone — the port is functionally complete end-to-end; remaining work is parity debugging, not construction.
- **Impact:** The 13 golden failures cluster into 3 classes (spurious `face_material` arrays ×11, 6100-ASCII texture→material links, Max time_mode/fps mapping) — a parity fix loop is running. Gotcha for future integrations: cross-wave interface drift was ~zero; the only integration fixes needed were two test-file bugs, validating the contracts-first DESIGN.md approach.

## 2026-07-17 15:09 — Harden DESIGN.md via pre-implementation critique; launch build waves
- **What:** Two adversarial reviewers audited `docs/DESIGN.md` against the ufbx notes before any code was written; 18 findings fixed. Then launched the 6-wave implementation workflow (foundations → parsers+model → readers → link/finalize → eval/dump → integrate) with strict per-agent file ownership.
- **Why:** Worst finding would have silently broken every 6100 file: synthetic fbx_ids apply to ALL `version < 7000` objects (not just <6000) — without them every connection dangles and the scene graph comes out empty. Also: Takes must be read for 7x00 too (stack time-range back-fill), and `InheritType` maps non-ordinally (`0→componentwiseScale, 2→ignoreParentScale, else normal`).
- **Impact:** These traps are now recorded in DESIGN.md's "Known fidelity traps"; check that list first when a golden diff shows empty scenes, degenerate anim ranges, or wrong scale inheritance.

## 2026-07-17 14:50 — Bootstrap SwiftFBX port with ufbx golden-dump verification
- **What:** Scaffolded the SwiftPM package and built the verification backbone before any parser code: vendored ufbx (rev in `tools/ufbx/VERSION`), wrote a C harness (`tools/ufbx_dump.c`) emitting a deterministic JSON scene dump (spec: `docs/DUMP_FORMAT.md`), generated golden dumps for 44 representative FBX files, and fanned out 15 agents to write line-cited port notes (`docs/ufbx-notes/`).
- **Why:** Porting 33k lines of quirk-laden C needs an executable acceptance criterion, not code review by vibes — structural parity with real ufbx output (1e-6 float tolerance) catches subtle behavioral drift per file/feature.
- **Impact:** `swift test` golden suite defines "done" for the port. Key design decision recorded in `docs/DESIGN.md`: ARC-safe arena ownership (scene owns elements; cross-refs are Int32 indices behind computed properties), mirroring ufbx's typed_id model to avoid retain cycles.
