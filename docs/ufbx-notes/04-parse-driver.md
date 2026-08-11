# Parse Driver (DOM retention, general parsing, setup) + IO skim

Source: `ufbx.c` lines 10696–11762 (primary), 6714–7245 (IO skim). Cross-references
chase into `ufbx.c` 7900–8033 (parse state table, defined just before this span),
8964–9260 / 10285–10670 (binary/ascii node parsers, owned by the tokenizer
subsystem), and 11981–12130 / 15844–15936 (header-extension reading and
`ufbxi_read_root`, owned by the scene-loading subsystem) — included here only
because the task explicitly asks how format detection, header parsing, and
document metadata capture fit into the overall driver.

## Purpose

This subsystem is the "spine" that turns a raw byte stream into the coarse
tree of `ufbxi_node`s that later subsystems (properties, objects, connections,
animation) consume. It: (1) sniffs binary-vs-ASCII and file format, (2) drives
lazy/eager top-level-node parsing with a small cache so sections can be visited
out of file order, (3) optionally mirrors every parsed node into a public,
retained DOM tree (`ufbx_dom_node`) for introspection, and (4) does one-time
setup (string pool of well-known names, property-type name table, node-property
name set) used throughout parsing. The IO layer underneath (6714–7245) is a
pull-based buffered reader that both the binary and ASCII tokenizers call into.

## Key data structures

- **`ufbxi_node`** (ufbx.c:6197) — the internal (non-retained) parse-tree node.
  `name`/`name_len`: pooled interned string + length (names are compared with
  pointer equality `==` against globals like `ufbxi_Objects`, not `strcmp`,
  except for a few ad-hoc `strcmp` fallbacks for rare/legacy names).
  `num_children`/`children`: child array (only populated when the node's
  children were actually walked — see lazy parsing below).
  `value_type_mask`: either the sentinel `UFBXI_VALUE_ARRAY` (node is a single
  typed array, `array` union member valid) or a packed 2-bit-per-slot mask
  (up to `UFBXI_MAX_NON_ARRAY_VALUES` = 8 slots) selecting `UFBXI_VALUE_NUMBER`
  or `UFBXI_VALUE_STRING` per positional value, `vals` union member valid.
  `ufbxi_value_array` (6191): `data`/`size`/`type` (FBX type code char:
  `b,i,l,f,d`, or `-` ignored, `s`/`C` for strings/content-blobs).
- **`ufbxi_value`** (6186) — tagged union slot: either `{f: double, i: int64}`
  (numbers, both interpretations always populated) or a sanitized string.
- **`ufbxi_parse_state`** (7915) — a coarse FSM label attached to each node
  during parsing (`UFBXI_PARSE_ROOT`, `_FBX_HEADER_EXTENSION`, `_OBJECTS`,
  `_MODEL`, `_GEOMETRY`, `_LAYER_ELEMENT_UV`, …, full list at 7915–7967).
  Computed by `ufbxi_update_parse_state(parent, name)` (7982) purely from the
  parent's state + child name; used only to decide array handling (see Format
  details) — it has no bearing on tree topology.
- **`ufbxi_array_info`** (7977) — `{ type: char, flags: uint8 }` returned per
  node by lookup keyed on parse state; `flags` is a bitset
  (`UFBXI_ARRAY_FLAG_RESULT` = allocate from permanent result arena,
  `_TMP_BUF` = long-term tmp arena, `_PAD_BEGIN` = reserve 4 zero elements
  before the array so a `-1`/invalid index read is still in-bounds,
  `_ACCURATE_F32` = must decode as bit-exact 32-bit float). This table (not in
  our line range, immediately above at 7900s, owned by the tokenizer/array
  subsystem) is what lets the tokenizer decompress `Vertices`/`PolygonVertexIndex`
  etc. directly into their final typed home instead of a generic buffer.
- **`ufbx_dom_node` / `ufbx_dom_value`** (ufbx.h 416–439) — the *public*,
  retained mirror of `ufbxi_node`. `ufbx_dom_node`: `name`, `children` (list of
  child pointers), `values` (list of `ufbx_dom_value`). `ufbx_dom_value`:
  `type` (`ufbx_dom_value_type`, ufbx.h 400–412: NUMBER, STRING, BLOB,
  ARRAY_I32/I64/F32/F64/ARRAY_BLOB/ARRAY_IGNORED), plus all-of `value_str`,
  `value_blob`, `value_int`, `value_float` populated redundantly regardless of
  `type` (consumer picks the field matching `type`; e.g. an array node also
  fills `value_int`/`value_float` with its element *count*).
- **`ufbxi_dom_mapping`** (10698) — `{ node_ptr: uintptr_t, dom_node: ufbx_dom_node* }`,
  entry in `uc->dom_node_map`, a pointer-keyed hash map from internal node
  address to its retained DOM counterpart (needed later so e.g. property
  parsing can attach `dom_node` back-references, ufbx.h:772).
- **IO context fields on `ufbxi_context`** (used throughout 6714+): `data`/
  `data_size`/`yield_size` (current readable window), `read_buffer`/
  `read_buffer_size` (owned scratch buffer, grows geometrically — see
  `ufbxi_refill`), `eof`, `data_offset` (absolute stream position of
  `data_begin`), `read_fn`/`skip_fn`/`read_user` (caller-supplied IO callbacks
  — **Swift: replaced entirely by `Data`/`InputStream` slicing, no callback
  abstraction needed**), `progress_interval`/`latest_progress_bytes` (progress
  callback throttling — out of v1 scope).

## Control flow / algorithms

### IO primitives (6714–6970, skim only)
1. `ufbxi_refill(uc, size, require_size)` (6716): grows `read_buffer` if the
   requested size exceeds current capacity (`max(size, opts.read_buffer_size,
   2*current)`), `memmove`s any unconsumed remainder to the front, then loops
   calling `read_fn` until either the buffer is full or `read_fn` returns 0
   (EOF). Tracks `data_offset` for absolute-position bookkeeping (used for
   binary offset fields elsewhere).
2. `ufbxi_yield`/`ufbxi_peek_bytes`/`ufbxi_read_bytes`/`ufbxi_consume_bytes`
   (6801–6849): a peek/commit pattern — `peek_bytes(n)` returns a pointer to
   at least `n` bytes without consuming, `read_bytes(n)` peeks then advances,
   `consume_bytes(n)` advances after a prior peek. `yield_size` is the count
   of bytes in `data` guaranteed available without another refill; it's
   deliberately capped at `progress_interval` chunks so progress callbacks fire
   at regular byte intervals even mid-array (progress reporting: out of v1
   scope, but the peek/commit chunking pattern itself is worth keeping for
   backpressure-free `Data` slicing).
3. `ufbxi_skip_bytes(uc, size)` (6851): if a `skip_fn` (seek) is available,
   skips in `UFBXI_MAX_SKIP_SIZE` chunks with a paranoid 1-byte read-back after
   each chunk to detect an `fseek()` that silently ran past EOF; otherwise
   falls back to read-and-discard. **Swift: irrelevant — `Data` slicing has no
   seek cost, just advance an index/offset.**
4. `ufbxi_read_to(uc, dst, size)` (6898): copies from the current buffer first,
   then reads remaining bytes directly into `dst` (bypassing `read_buffer`) if
   IO is available — used for big point-blank array reads.

Port guidance for IO: none of the callback/refill machinery needs porting.
Swift's parser should hold a `Data` (or `UnsafeRawBufferPointer` view) and a
cursor `Int`, with `peek(_:)`/`consume(_:)`/`readBytes(_:)` as trivial slice
operations. The one behavior worth preserving is *not* materializing the whole
file for the format-sniff step if streaming from a URL — but since Swift's
target types are `Data`/`URL` and files are typically loaded whole, this can be
simplified to plain slicing with no chunking logic at all.

### Format detection (11096–11191)
1. `ufbxi_is_format(data, size, format)` (11096): for `UFBX_FILE_FORMAT_FBX`,
   returns true if the first `UFBXI_BINARY_MAGIC_SIZE` (22) bytes equal the
   binary magic, OR if any line (via `ufbxi_next_line`, see below) matches the
   mini-regex `;\s*FBX\s*\d+\.\d+\.\d+\s*project\s+file` or
   `FBXHeaderExtension:.*` (covers ASCII files). OBJ/MTL sniffing (lines
   11109–11122) is out of scope for the port (v1 excludes .obj/.mtl) but shares
   the same line-scan machinery.
2. `ufbxi_determine_format(uc)` (11130): if `opts.file_format` wasn't forced
   and `!opts.no_format_from_content`, does an exponentially-growing lookahead
   (`UFBXI_MIN_FILE_FORMAT_LOOKAHEAD` = 32 bytes, doubling up to
   `opts.file_format_lookahead`) re-running `ufbxi_is_format` for every known
   format each time more data is available, stopping at first match or EOF.
   Falls back to filename-extension sniffing (`\.fbx`/`\.obj`/`\.mtl`, case
   insensitive via the `\c` regex escape) if content sniffing is disabled or
   inconclusive. Fails with "Unrecognized file format" if still unknown.
   Result stored in `uc->scene.metadata.file_format`.
3. Tiny regex engine backing this: `ufbxi_match`/`ufbxi_match_imp`/
   `ufbxi_match_skip` (10882–11094) — supports literal chars, `\d \F \s \S \c\C`
   (macros/case-insensitive-toggle), `[...]` classes with `a-z` ranges and `\x`
   escapes, `(...)` groups, `|` alternation, and `* + ?` quantifiers, all
   hand-rolled with no backtracking stack (uses `ufbxi_match_skip` to jump over
   failed alternatives). **Port guidance: replace with Swift regex literals or
   a couple of hand-written scanners — do not port the custom engine.** Only
   the *set of patterns* it currently recognizes (cited above) needs to be
   preserved for format-sniffing fidelity.
4. `ufbxi_next_line(line, buf, skip_space)` (10857): simple `memchr('\n')`
   line splitter with optional leading/trailing whitespace trim; trivial to
   replace with Swift's own line splitting.

### Binary-vs-ASCII detection & version capture — `ufbxi_begin_parse` (11193–11240)
1. Peeks `UFBXI_BINARY_HEADER_SIZE` (27) bytes.
2. If the first 22 bytes equal `ufbxi_binary_magic` → binary mode:
   - Byte 22 is the endianness flag (`0` = little, nonzero = big) →
     `uc->file_big_endian`.
   - Bytes 23–26 are a little/big-endian `uint32` FBX version, byte-swapped if
     big-endian, stored as `uc->version`.
   - Sets `uc->sure_fbx = true` (this affects a later strictness check, see
     Quirks). Consumes the 27-byte header.
3. Else → ASCII mode (`uc->from_ascii = true`):
   - Initializes the ASCII tokenizer's cursor window (`uc->ascii.src`/
     `src_yield`/`src_end`) directly from the already-peeked buffer, then reads
     the first token via `ufbxi_ascii_next_token` (belongs to the ASCII
     tokenizer subsystem, not detailed further here).
   - Version is NOT in a fixed header for ASCII; it is picked up later while
     scanning top-level nodes (the `FBXVersion` node inside
     `FBXHeaderExtension`, see `ufbxi_read_header_extension` below) and,
     critically, `ufbxi_begin_parse` itself only sets a **default of 7400**
     if no version was found *and* `!opts.strict`; in strict mode an absent
     version is a hard error ("Not an FBX file").

### Top-level node caching / lazy section parsing (11242–11407)
This is the central trick that lets sections be visited in an order convenient
to the reader (`ufbxi_read_root`, see below) regardless of file order, while
only parsing each top-level node's subtree once, on demand.

- `ufbxi_parse_toplevel_child_imp(uc, state, buf, p_end)` (11242): thin
  dispatch to `ufbxi_ascii_parse_node` or `ufbxi_binary_parse_node` depending
  on `uc->from_ascii`, always with `depth=0` and `recursive=true` (i.e. parse
  one full node+subtree, non-lazily, at the top level).
- `ufbxi_parse_toplevel(uc, name)` (11253) — the main entry other subsystems
  call (e.g. `ufbxi_parse_toplevel(uc, ufbxi_Objects)`):
  1. Linear-scans `uc->top_nodes[0..top_nodes_len)` (a growable cache array)
     for a node whose interned `name` pointer matches; if found, sets
     `uc->top_node`/`top_child_index = 0` and returns immediately (cache hit).
  2. If `uc->parsed_to_end` (EOF already reached while filling the cache) and
     not found, sets `top_node = NULL` (section absent) and returns.
  3. Otherwise loops: parses the *next* top-level node from the stream
     (`UFBXI_PARSE_ROOT` state) into `uc->tmp_stack`/`uc->tmp` buffers.
     - On EOF (`end == true`): marks `parsed_to_end`, finalizes DOM retention
       via `ufbxi_retain_toplevel(uc, NULL)` if enabled, frees `uc->tmp_parse`
       (no longer needed), returns not-found.
     - Otherwise appends the node to the `top_nodes` cache
       (`ufbxi_grow_array`), optionally retains it into the DOM
       (`ufbxi_retain_toplevel`).
     - If this node's name matches the requested `name`: sets `top_node`,
       and — importantly — sets `top_child_index = SIZE_MAX` as a sentinel
       meaning "children not yet parsed, parse on demand" (lazy!), then
       returns.
     - If it does NOT match: since this section must still be walkable later
       from the cache, it eagerly parses **all of this node's children**
       right now (loop calling `ufbxi_parse_toplevel_child_imp` until `end`),
       storing them into `node->children`/`num_children`, and retains each
       child into the DOM if enabled. This is O(children) done once per
       skipped top-level node, then cached — the wanted node's children are
       deliberately left unparsed (lazy) since the caller will walk them
       itself via `ufbxi_parse_toplevel_child`.
- `ufbxi_parse_toplevel_child(uc, p_node, tmp_buf)` (11332) — iterator used by
  a caller that has just called `parse_toplevel` and now wants each child:
  - If `top_child_index == SIZE_MAX` (lazy/streaming mode): parses one more
    child from the stream via `ufbxi_parse_toplevel_child_imp` on each call
    (clears `uc->tmp_parse` first unless caller supplied its own `tmp_buf` to
    retain results in, e.g. when the caller needs to keep the node around
    rather than a transient scratch parse). Copies the parsed node into
    `uc->top_child` (reused scratch) or, if `tmp_buf` given, pushes a durable
    copy there. Retains into DOM if enabled. `end` → `*p_node = NULL`.
  - Else (children were already eagerly cached, i.e. this top-level node was
    NOT the one that matched last `parse_toplevel` call... actually: any node
    reached via the cache-hit path in step 1 above has `top_child_index` left
    at `0` from a *previous* pass, not `SIZE_MAX` — so this branch also
    handles the case of re-visiting an already-fully-parsed cached node):
    walks `top_node->children[child_index]` incrementing `top_child_index`
    until exhausted.
- `ufbxi_parse_legacy_toplevel(uc)` (11379) — used for the pre-6000 "legacy"
  path where there's no name-based lookup, just "parse the next top-level
  node, whatever it is" into `uc->legacy_node`/`uc->top_node`, retaining into
  DOM if enabled.

### Driving order — `ufbxi_read_root` (15844–15936, outside this span but is
*the* answer to "how sections are visited"):
1. `FBXHeaderExtension` (optional) → `ufbxi_read_header_extension` (eager,
   see below) — captures creator string, resolves KTime scale, may bump
   pre-6000 version.
2. If exporter resolved to Blender-ASCII: re-parse toplevel `Creator` node
   directly (ASCII Blender puts a duplicate/plain creator string at the top
   level outside the header extension).
3. `ufbxi_match_exporter(uc)` — pattern-matches `creator` string against known
   exporter signatures (Blender, FBX SDK, MotionBuilder, `ufbx_write`) — see
   Format details.
4. Pre-7000: `ufbxi_init_node_prop_names(uc)` (loads the “is this transform
   property name” set used to reinterpret legacy loose properties as typed
   node props).
5. `uc->ascii.found_version = true` freezes further version auto-detection.
6. Version ≥ 7000: `Documents` toplevel → `ufbxi_read_document` (root object
   ID). Version < 7000: synthesizes a root id from the literal string
   `"Model::Scene"` (ASCII) / `"Scene\0\x01Model"` (binary) via
   `ufbxi_synthetic_id_from_string` — pre-7000 files don't have real 64-bit
   object IDs for the implicit scene root.
7. Pushes a nameless root `ufbx_node` element with that ID.
8. `Definitions` (optional) → `ufbxi_read_definitions` — object-type counts +
   property templates (feeds the properties/objects subsystem).
9. `Objects` (required-ish: if `!uc->sure_fbx`, absence here is a hard
   "Not an FBX file" error) → `ufbxi_read_objects` or, if
   `uc->thread_pool.enabled`, `ufbxi_read_objects_threaded` — bulk of scene
   data; owned by the objects subsystem.
10. `Connections` → `ufbxi_read_connections` — parent/child + property
    connection graph.
11. `Takes` → `ufbxi_read_takes` — pre-7000 "Take" animation (in v1 scope).
12. `GlobalSettings` (optional, only if actually present in cache) →
    `ufbxi_read_global_settings` — axes/units/frame-rate metadata (in v1
    scope, but owned by a different subsystem's notes).
13. `Version5` (optional, pre-6000) → nested `Settings` child →
    `ufbxi_read_legacy_settings`.
14. If `opts.retain_dom`: one final `ufbxi_parse_toplevel(uc, NULL)` call with
    a name that can never match, purely to force-drain any remaining
    unvisited top-level nodes into the `top_nodes` cache (and hence into the
    DOM) — otherwise sections never queried by name would be silently
    missing from the retained DOM.

This order is a **fixed traversal script**, not file order — the lazy cache
(`ufbxi_parse_toplevel`) is precisely what makes "ask for `Objects` before
`Connections` even though `Connections` appears earlier in the file" work
without a second file pass.

### Header extension — `ufbxi_read_header_extension` (11981–12033, adjacent
to this span, included because the task calls it out explicitly)
Iterates children of `FBXHeaderExtension` via `ufbxi_parse_toplevel_child`:
- `Creator` (string) → `uc->scene.metadata.creator`.
- `FBXVersion` (int), only if `uc->version < 6000`: may *raise* `uc->version`
  to this value if `0 < version < 6000` and it's larger than current — a
  pre-6000-only correction path.
- `FBXHeaderVersion` (int) → local `header_version`.
- `OtherFlags.TCDefinition` (int) → `tc_definition` + `has_tc_definition` flag.
- `SceneInfo` child → delegates to `ufbxi_read_scene_info` (owned by another
  subsystem; not detailed here).
After the loop: determines KTime tick scale (see Format details) and stores
`uc->ktime_sec`/`uc->ktime_sec_double`. This value feeds the animation
subsystem's time conversion (1 KTime tick → seconds) — **note the
dependency**: animation curve/keyframe time decoding needs this value, so the
header extension must be read before any curve is interpreted.

### One-time setup functions (11411–11760, this span)
- `ufbxi_load_strings(uc)` (11411): pushes every string in the global
  `ufbxi_strings` table (not shown here, a giant array of every well-known FBX
  element/property name literal, e.g. `ufbxi_Objects`, `ufbxi_Creator`, ~line
  5350–5700+) into `uc->string_pool` *without copying* (`copy=false`), so that
  later name comparisons against these constants can use pointer identity
  (`==`) instead of `strcmp`. In `UFBX_REGRESSION` builds, asserts the table is
  sorted and each entry's `strlen` matches its stored length (a build-time
  self-check, not runtime behavior).
- `ufbxi_load_maps(uc)` (11746): builds `uc->prop_type_map`, a hash map from
  pooled property-type-name string → `ufbx_prop_type` enum, from the
  `ufbxi_prop_type_names` table (11436–11468, ~28 entries, e.g. `"Boolean"`/
  `"bool"`/`"Bool"` → `UFBX_PROP_BOOLEAN`, `"Lcl Translation"` →
  `UFBX_PROP_TRANSLATION`, etc. — describes the many spelling variants FBX
  exporters use for the same conceptual type). Looked up later via
  `ufbxi_get_prop_type` (11470) whenever a `Property70`/`P` node's type string
  needs mapping to the enum.
- `ufbxi_init_node_prop_names(uc)` (11720): builds `uc->node_prop_set`, a
  pointer-set of pooled names from `ufbxi_node_prop_names` (11645–11718, ~65
  names: `RotationPivot`, `PreRotation`, `Lcl Translation`, `Visibility`, …) —
  this is the fixed list of "legacy loose properties on a pre-7000 `Model`
  node that should be treated as typed node transform/visibility properties"
  even though pre-7000 files don't use the modern `Properties70` block.
  Queried via `ufbxi_is_node_property_name`. Only initialized when
  `uc->version < 7000` (called from `ufbxi_read_root`, item 4 above).
- `ufbxi_find_prop_with_key`/`ufbxi_find_prop`/`ufbxi_find_real`/`_vec3`/
  `_int`/`_enum` (11480–11564): binary-search + linear-scan helpers over a
  sorted `ufbx_props` array with a 4-byte name-prefix "hash key"
  (`_internal_key`, computed by `ufbxi_get_name_key`/`_c`, 11609–11631) for
  fast rejection before falling back to a full `memcmp`; walks the
  `props->defaults` chain (property template inheritance) if not found
  locally. These are generic property-lookup utilities used throughout scene
  construction, not part of the parse driver itself, but defined in this
  span because they're needed immediately by setup/format code below them.
- Small numeric/geometric predicate helpers (11566–11607): zero/one/identity
  checks for vec3/vec4/quat/matrix — generic utilities, not driver logic.

### DOM retention plumbing (10696–10853, this span)
- `ufbxi_get_dom_node_imp`/`ufbxi_get_dom_node` (10703–10716): looks up the
  retained `ufbx_dom_node*` for a given internal `ufbxi_node*` via the
  pointer-keyed `dom_node_map`; the public wrapper is a no-op returning `NULL`
  if `opts.retain_dom` is off (so callers can unconditionally call it — the
  cost is only paid when retention is enabled).
- `ufbxi_retain_dom_node(uc, node, p_dom_node)` (10719, recursive, depth
  bounded by `UFBXI_MAX_NODE_DEPTH + 1`): allocates one `ufbx_dom_node` in the
  permanent result arena, records it in `dom_node_map` keyed by the source
  node's address, copies the name into the string pool, then:
  - If the source node is an array (`value_type_mask == UFBXI_VALUE_ARRAY`):
    builds exactly one `ufbx_dom_value` whose `type` is derived from the FBX
    array type char (mapping table at 10762–10772 — see Format details) and
    whose `value_blob` points at the raw decoded array data
    (`size * elem_size` bytes) while `value_int`/`value_float` both hold the
    element *count* (not a value!). `elem_size` from
    `ufbxi_array_type_size(arr->type)`.
  - Else: iterates up to `UFBXI_MAX_NON_ARRAY_VALUES` positional values reading
    the 2-bit type mask, building one `ufbx_dom_value` per slot (STRING via
    `ufbxi_get_val_at(...,'S',...)`/`'b'` for blob view, or NUMBER copying both
    int and float interpretations), stopping at the first zero mask entry
    (mask==0 means "no more values" — masks are never sparse).
  - Recurses into every child, then captures the child pointer array.
- `ufbxi_retain_toplevel(uc, node)` (10813) and
  `ufbxi_retain_toplevel_child(uc, child)` (10846): thin wrappers tying DOM
  retention into the top-level cache described above — `retain_toplevel`
  either starts retaining a new top-level node (`node != NULL`, sets
  `uc->dom_parse_toplevel` as the "current top node being filled") or, when
  called with `node == NULL`, finalizes: builds the final root `ufbx_dom_node`
  (empty name, `children` = every top-level node ever retained) and stores it
  at `uc->scene.dom_root` (ufbx.h:4030) — this is the one and only entry point
  by which the public `ufbx_scene.dom_root` gets populated.

## Format details

- Binary magic: `"Kaydara FBX Binary  \x00\x1a"`, 22 bytes
  (`UFBXI_BINARY_MAGIC_SIZE`, ufbx.c:9400–9402). Full binary header is 27
  bytes (`UFBXI_BINARY_HEADER_SIZE`): 22-byte magic + 1 endian byte (0 =
  little-endian, else big-endian) + 4-byte little/big `uint32` version.
- ASCII detection fallback patterns (regex-like, see engine above):
  `;\s*FBX\s*\d+\.\d+\.\d+\s*project\s+file` or `FBXHeaderExtension:.*`
  anywhere in a scanned line, scanned over an exponentially growing lookahead
  window starting at 32 bytes (`UFBXI_MIN_FILE_FORMAT_LOOKAHEAD`).
- ASCII files with no discoverable version default to **7400** (only when
  `!opts.strict`); strict mode makes a missing version a hard parse error.
  Binary files always carry an explicit version in the header.
- Pre-6000 version correction: if header says `< 6000`, a nested
  `FBXHeaderExtension/FBXVersion` int value can *raise* (never lower)
  `uc->version`, clamped to `< 6000` and `> 0` (ufbx.c:11996–12002).
- KTime scale (ufbx.c:12021–12030) — the tick-to-seconds divisor for animation
  keyframe times, decided once, here:
  - `use_v7_ktime = version < 8000` by default.
  - Overridden by `OtherFlags.TCDefinition` **only if** `FBXHeaderVersion >=
    1004`: `TCDefinition == 127` ⇒ use old (v7) scale even on version ≥ 8000;
    any other TCDefinition value ⇒ use new scale.
  - `ktime_sec = 46186158000` (old/v7 units) or `141120000` (new/v8+ units).
    **This constant is load-bearing for every animation curve's time
    values — the animation subsystem notes should reference it.**
- Non-array node value slots: max `UFBXI_MAX_NON_ARRAY_VALUES` = 8 positional
  values per node, packed 2 bits/slot in `value_type_mask` (0=none,
  1=number, 2=string, per `UFBXI_VALUE_*` enum order — note the DOM code
  additionally treats "array" as a third top-level node kind, mutually
  exclusive with the positional-values interpretation, signaled by the full
  mask being the special `UFBXI_VALUE_ARRAY` sentinel rather than being
  read 2 bits at a time).
- Array FBX type code → `ufbx_dom_value_type` map (10762–10772): `c`/`b` →
  BLOB, `i` → ARRAY_I32, `l` → ARRAY_I64, `f` → ARRAY_F32, `d` → ARRAY_F64,
  `s`/`C` → ARRAY_BLOB, `-` → ARRAY_IGNORED (ufbx's internal "don't care,
  discard" type used for arrays the reader skips).
- Property-type name table: ~28 string spellings → 12 `ufbx_prop_type`
  values, table at ufbx.c:11436–11468 (cite, don't duplicate) — multiple
  historical spellings map to the same enum (e.g. `Boolean`/`bool`/`Bool` all
  → `UFBX_PROP_BOOLEAN`; `Enum`/`enum`/`Visibility`/`Visibility Inheritance`/
  `KTime` all → `UFBX_PROP_INTEGER`).
- Legacy node-property name set: ~65 names, table at 11645–11718 (cite) —
  transform-related (`RotationPivot`, `PreRotation`, `Lcl Translation`, …),
  limit/damp properties, and a few misc (`Show`, `notes`, `AxisLen`).
- Exporter signature matching (12084+, adjacent span): tiny custom pattern
  matcher `ufbxi_match_version_string` (12035) supporting literal chars,
  space-skipping, `-`-delimited-skip-to-dash, `.`/`(`/`)`/`_` literal,
  case-insensitive letters, and `?` = "capture one decimal integer run" (up
  to 3 captures). Patterns tried in order (12088–12110+): `blender-- ?.?.?`
  (Blender binary), `blender- ?.?` (Blender binary, older), `blender version
  ?.?` (Blender ASCII), `fbx sdk/fbx plugins version ?.?`, `fbx sdk/fbx
  plugins build ?`, `motionbuilder version ?.?`, `motionbuilder/mocap/online
  version ?.?`, `ufbx_write` (self-produced files) — sets `uc->exporter` +
  packed `uc->exporter_version`. Belongs to a neighboring subsystem but is
  triggered directly from `ufbxi_read_root` right after header-extension
  parsing, so the port must run it at the same point (before node-property
  legacy handling, since Blender-ASCII needs a second `Creator` lookup at the
  true top level — ufbx.c:15851–15856).
- Threaded array deflate gating (ufbx.c:9097, adjacent subsystem): only
  offloads to the thread pool when `uc->parse_threaded && encoding==1
  (deflate) && encoded_size >= UFBXI_MIN_THREADED_DEFLATE_BYTES (256, or 2 in
  regression/test builds, ufbx.c:60/1016) && !file_big_endian &&
  !local_big_endian`. Both `ufbxi_binary_parse_node` (9096–9135) and the ASCII
  equivalent (`ufbxi_ascii_array_task_fn`, ~10653) follow the same
  create-task/run-task pattern via `ufbxi_thread_pool_create_task`/
  `_run_task` (6167+, "thread pool" subsystem, out of scope entirely).

## Quirks & edge cases

- **Cache-then-lazy hybrid** (11253–11407): only the *requested* top-level
  section is left with unparsed children (`top_child_index = SIZE_MAX`); every
  section skipped along the way gets its children eagerly parsed and cached
  in full. This means asking for sections in a "bad" order (e.g. `Objects`
  then `FBXHeaderExtension`) still works but forces eager parsing of
  everything in between — functionally correct either way since
  `ufbxi_read_root` fixes a canonical order, but a Swift port that lets
  callers reorder queries needs to replicate this caching, not just a naive
  memoized dictionary, if it wants matching performance characteristics.
- **DOM force-drain** (`ufbxi_read_root` line 15931–15933): a
  `ufbxi_parse_toplevel(uc, NULL)` call — since no node's interned name
  pointer can ever equal a literal C `NULL`, this reliably parses *every*
  remaining top-level node purely for its DOM-retention side effect. A Swift
  port needs an explicit "drain remaining top-level nodes" method rather than
  overloading a lookup with a null sentinel.
- **Pointer-identity name comparison**: relies on all well-known names being
  pre-interned into the same pool (`ufbxi_load_strings`) so that `==` works;
  any name read from the *file* must be pooled through the same intern table
  before being compared, or comparisons silently and permanently fail (falls
  through to "unknown node", not a crash) — a subtle correctness trap to avoid
  in the Swift port by making the "pooled name" concept a distinct type (e.g.
  an interned-symbol enum/struct) rather than comparing raw `String`s by value
  everywhere (functionally equivalent to `==` in Swift for `String` anyway,
  but the *reason* ufbx uses pointer comparison — avoiding repeated strcmp
  during the hot node-parsing loop — doesn't apply in Swift; still, the
  concept of "is this exact one of ~200 known element names" is worth an enum).
- **Version can move during header parsing**: `uc->version` isn't fully fixed
  until after `ufbxi_read_header_extension` returns (pre-6000 correction) —
  code must not branch on `uc->version` before that point except the very
  coarse binary-vs-ascii default-7400 logic in `ufbxi_begin_parse`.
- **`uc->ascii.found_version = true`** freezes version changes after
  `ufbxi_read_root`'s header step (15864) — implies there's ASCII-tokenizer
  logic elsewhere that *would* keep adjusting version if allowed to (worth
  flagging to whoever owns the ASCII tokenizer notes).
- **`sure_fbx` strictness gate** (11215, 11232, 15896–15900): binary files
  with a valid magic are automatically "sure"; ASCII files are only "sure" if
  a version was actually found in the header extension (not just defaulted).
  An unsure file that also lacks an `Objects` top-level section is rejected
  outright ("Not an FBX file") — this is the main defense against
  misidentifying a random text file as FBX.
- **DOM values always populate all union-like fields**: `value_str.data`
  defaults to `ufbxi_empty_char` (a static empty-string sentinel) even for
  numeric values (10757, 10781) so consumers can safely read `.value_str`
  without a null check regardless of `.type`. Swift port should use an enum
  with associated values instead — this sentinel-filling trick is a C-ism to
  avoid null pointers, not meaningful behavior to replicate.
- **DOM array value's `value_int`/`value_float` store element count, not a
  value** (10760) — easy to misport if skimmed quickly; make sure the Swift
  `case` for array DOM values has an explicit `count` (or just uses
  `.count` on the associated array) rather than reusing generic
  int/float fields.
- **Blender-ASCII double `Creator` read** (15851–15856): only Blender's ASCII
  exporter needs a second, top-level (not header-extension-nested) `Creator`
  node lookup — a quirk of how that specific exporter emits metadata,
  discovered only after the first exporter-match pass.
- **TCDefinition == 127 exact sentinel** (12026) gates old vs new KTime scale
  and only applies when `FBXHeaderVersion >= 1004`; getting this wrong
  silently produces animation timings off by a large constant factor (v7 tick
  ≈ 1/46186158000 s vs v8+ tick ≈ 1/141120000 s) — a "quiet" bug class since
  nothing else validates it.
- **Thread-pool array offload changes memory ownership timing**: when
  deferred, the array bytes get decoded asynchronously and the "commit" step
  is a later `ufbxi_thread_pool_wait_*` call (not in this span) — a Swift port
  doing synchronous decompression avoids this whole class of concern, but
  should note that ufbx's threaded path still falls back to the same
  synchronous decode when the task pool is disabled/full/ineligible
  (9097–9149), so semantics (not performance) are identical either way — safe
  to always take the synchronous path in Swift.

## Port guidance

- **Port faithfully**: the overall section-visiting order in `ufbxi_read_root`
  (header extension → optional Blender creator re-read → exporter match →
  legacy node-prop-name init if <7000 → Documents/root-id → Definitions →
  Objects → Connections → Takes → GlobalSettings → Version5); the KTime scale
  decision table (version/TCDefinition/FBXHeaderVersion thresholds); the
  version-defaulting/strictness rules (7400 default only if non-strict, binary
  header version always trusted, pre-6000 upward-only correction); the
  exporter signature list and its effect on parsing quirks noted elsewhere;
  the property-type-name and legacy-node-property-name tables (just port as
  Swift dictionaries/sets, verbatim contents).
- **Replace with Swift idioms**: the custom mini-regex matcher → use Swift's
  `Regex`/`String` methods for format sniffing (same pattern set, different
  engine); the IO callback/refill/peek-commit machinery → `Data` slicing with
  a cursor, no callbacks, no buffer growth logic, no progress throttling; the
  pointer-identity-interned-name comparison strategy → a `enum
  KnownElementName` (or similar) matched during tokenization, or just Swift
  `String` equality if performance is adequate; the top-level lazy/eager
  cache → can likely be simplified to "parse the whole top-level tree once
  into an array of typed sections up front" since Swift will have the whole
  `Data` in memory anyway and doesn't need to avoid a second file pass —
  **but if doing so, verify the eager-parse-of-skipped-sections quirk above
  doesn't hide something (e.g. it's also what feeds the DOM), i.e. the
  simplification is safe only if DOM retention drains everything at the end
  as this code already does explicitly**.
- **Skip entirely (out of v1 scope, per task)**: thread-pool task
  batching for array deflate (9096–9135, 10653–10668, and the whole
  `ufbxi_thread_pool_*` family at 5983–6180-ish) — Swift should always
  synchronously inflate; progress-callback throttling
  (`ufbxi_pause_progress`/`resume_progress`/`report_progress`); custom
  allocator plumbing implicit in every `ufbxi_push_*`/`ufbxi_alloc` call
  (Swift uses native arrays/`ContiguousArray`); DOM retention could be a v1
  *feature* (scope doc lists "DOM retention option" under OUT — confirm with
  scope owner whether `ufbx_dom_node` introspection is wanted at all; if not,
  skip 10696–10853 and the retain-call sites in `ufbxi_read_root` entirely).
- **Suggested Swift shapes**:
  - `enum FileFormat { case fbx, obj, mtl }` with a `static func detect(data:
    filename:) -> FileFormat?` doing the same content-then-extension fallback.
  - `enum FBXEncoding { case binary(bigEndian: Bool), ascii }` decided once
    up front, feeding version + tokenizer choice.
  - A `ParsedNode` struct (Swift's `ufbxi_node` analogue) with `name:
    ElementName` (interned enum or plain String), `children: [ParsedNode]`,
    `value: NodeValue` where `enum NodeValue { case values([PropertyValue]),
    case array(ArrayValue) }` — cleanly separates the "positional values vs.
    single big array" duality that C encodes via a bit-packed mask +
    union, matching Swift's preference for sum types.
  - `struct DocumentMetadata { creator: String; version: Int; exporter:
    Exporter?; exporterVersion: PackedVersion?; ktimeTicksPerSecond: Int64;
    fileFormat: FileFormat }` populated by a `readHeaderExtension` +
    `matchExporter` pair mirroring 11981–12130.
  - A throwing `func parseTopLevel(named:) throws -> ParsedNode?` (or, given
    the simplification above, just `documentSections: [ElementName:
    ParsedNode]` built once) replacing the whole lazy-cache dance.
- **Dependencies / feeds**: this subsystem *feeds* essentially everything
  downstream — properties (via `prop_type_map`), node transforms (via
  `node_prop_set`, only for <7000 files), animation curves (via
  `ktime_sec`/`ktime_sec_double`), and the whole objects/connections/takes/
  global-settings subsystems (via the section-by-name lookup it exposes). It
  *depends on* the binary/ASCII tokenizer subsystems (`ufbxi_binary_parse_node`
  / `ufbxi_ascii_parse_node`, ufbx.c 8964 / 10285 — not in this span) for
  actually producing `ufbxi_node`s, and on the array-info/parse-state table
  (7900–8033, also not in this span) for deciding array allocation strategy.
