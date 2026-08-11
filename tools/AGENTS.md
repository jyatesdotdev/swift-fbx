# tools

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

Holds the C reference toolchain used to produce the golden-dump JSON files
that `Tests/SwiftFBXTests/GoldenTests.swift` checks SwiftFBX against: a
vendored copy of real ufbx plus a small dumper program built on top of it.
Nothing here is Swift and nothing here ships in the `SwiftFBX` library or
`fbx-dump` executable — it exists purely to generate/regenerate test fixtures.

## Files

- `ufbx_dump.c` — the reference scene dumper. `main(argc, argv)` loads one FBX
  file via `ufbx_load_file` with default `ufbx_load_opts`, walks the resulting
  `ufbx_scene`, and writes the DUMP_FORMAT JSON (`docs/DUMP_FORMAT.md`) to
  stdout via a minimal hand-rolled JSON writer (`j_obj`/`j_arr`/`j_key`/
  `j_num`/... + `dump_vertex_attrib`/`dump_material_map` helpers). This is the
  authoritative half of the golden-format contract; `Sources/FBXDumpCore/SceneDump.swift`
  is the Swift port of the same logic (see `../Sources/FBXDumpCore/AGENTS.md`).
- `ufbx/` — **vendored, read-only**. Upstream ufbx C library at the revision
  pinned in `ufbx/VERSION` (currently `fcc5d6ba444cfd3eb80677dba5e37e493941abe5`).
  Contains `ufbx.h`, `ufbx.c` (~1.1M, the ground-truth implementation SwiftFBX
  is ported from), `LICENSE`, `VERSION`. Do not document its internals here —
  its role is only "the ground truth SwiftFBX is verified against and ported
  from"; per-subsystem behavior notes citing its line numbers live in
  `docs/ufbx-notes/`, not in this file.

## Business rules & invariants

- `tools/ufbx/*` is vendored and must **never be edited**. If upstream ufbx
  needs to change (bug fix, new feature to port), that is a deliberate
  re-vendor: replace the files wholesale, bump `ufbx/VERSION` to the new git
  revision, and treat every golden file as potentially stale (regenerate all
  44, not a subset — an upstream behavior change can shift dump output for
  files that don't obviously touch the changed code path).
- `ufbx_dump.c` must load with **default `ufbx_load_opts` (`{ 0 }`)** — the
  Swift side (`FBXScene.load(contentsOf:)` in `GoldenTests`) also uses default
  `FBXLoadOptions`. If either side starts passing non-default options, parity
  is meaningless; keep both at defaults unless `docs/DUMP_FORMAT.md` is
  updated to specify otherwise.
- `setlocale(LC_ALL, "C")` at the top of `main` is required — it forces
  locale-independent `%.17g` number formatting so golden JSON doesn't vary by
  build machine locale (e.g. comma vs period decimal separator in `de_DE`).
  Do not remove it.
- Output must be valid JSON on stdout only; errors go to stderr with exit code
  2 (bad args) or 1 (load failure) — `Sources/fbx-dump/main.swift` mirrors
  these exact codes, so keep them in sync if either changes.

## Rebuilding the harness

```sh
cc -O2 -o tools/ufbx_dump tools/ufbx_dump.c tools/ufbx/ufbx.c -lm
```

(Run from the repo root; adjust the `-o` path if invoking from inside
`tools/`.) The built `ufbx_dump` binary is a local build artifact — do not
commit it.

## Regenerating goldens

For each fixture FBX file under `Tests/SwiftFBXTests/Resources/fbx/`, run the
harness and overwrite the matching golden:

```sh
for f in Tests/SwiftFBXTests/Resources/fbx/*.fbx; do
  name=$(basename "$f" .fbx)
  ./tools/ufbx_dump "$f" > "Tests/SwiftFBXTests/Resources/golden/${name}.json"
done
```

Then run `swift test --filter GoldenTests` — SwiftFBX must reproduce every
regenerated golden exactly (within the documented float tolerance); a
regeneration that causes new SwiftFBX failures means SwiftFBX has a real
fidelity gap against the new ufbx behavior, not that the goldens are wrong.

## Dependencies & boundaries

- C code only, built with a plain system `cc`; no SwiftPM target references
  this directory (Package.swift has no target here — see
  `../Package.swift`). Nothing under `Sources/` or `Tests/` should read files
  from `tools/` at build or run time except the human/agent workflow of
  regenerating `Tests/SwiftFBXTests/Resources/golden/*.json` by hand.
- `tools/ufbx_dump.c` may only depend on `ufbx/ufbx.h` (+ libc/libm) — keep it
  a thin dumper, not a place to add SwiftFBX-side logic.

## Testing

- This directory has no Swift tests of its own. Its correctness is validated
  indirectly: golden JSON it produces is what `GoldenTests` (see
  `../Tests/SwiftFBXTests/GoldenTests.swift` and
  `../Sources/FBXDumpCore/AGENTS.md`) compares SwiftFBX's own dump against.
- To sanity-check a harness change before trusting new goldens, diff its
  output for one file against the currently-committed golden and eyeball the
  change is the one you intended:
  `./tools/ufbx_dump Tests/SwiftFBXTests/Resources/fbx/<name>.fbx | diff - Tests/SwiftFBXTests/Resources/golden/<name>.json`.

## Rules for the model

- Never edit anything under `tools/ufbx/` — treat it as read-only vendored
  code. If a fix is needed, it belongs upstream in ufbx or as a documented
  behavioral deviation in `docs/DESIGN.md`, not a local patch here.
- Any change to `ufbx_dump.c`'s output shape (new field, changed omission
  rule, changed formatting) is a **three-way, lockstep change**: update
  `ufbx_dump.c`, update `docs/DUMP_FORMAT.md` to describe the new contract,
  update `Sources/FBXDumpCore/SceneDump.swift` to match, then regenerate ALL
  44 goldens and re-run `swift test --filter GoldenTests`. Landing only one or
  two of these silently breaks golden parity in a way tests may not catch
  immediately (both sides can drift together and still "pass").
- Do not regenerate goldens speculatively as a way to make a failing
  `GoldenTests` case pass — that erases the acceptance signal. Only
  regenerate when the harness (or vendored ufbx) itself intentionally
  changed; a SwiftFBX-side bug must be fixed in `Sources/SwiftFBX`, not
  papered over by re-baselining goldens to match the bug.
- When re-vendoring `tools/ufbx/`, note the old and new revision (from
  `ufbx/VERSION`) in the commit/LOG.md entry — future agents need it to
  understand why golden values shifted.
