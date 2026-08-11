# ASCII FBX Parsing (ufbx.c 9404–10696)

## Purpose
Tokenizes and parses text-form FBX files (ASCII 6100 through 7700) into the same
`ufbxi_node` DOM tree the binary parser produces, so all downstream scene
construction is format-agnostic. Covers a streaming tokenizer (whitespace/comment
skipping, bare words, names, numbers, quoted strings with XML-like escapes), the
node/brace/property grammar, both ASCII array syntaxes (comma lists and the
`*count { a: ... }` form), version detection from the leading magic comment,
base64 embedded-content decoding, and exporter/version quirk handling. It shares
the array-classification (`ufbxi_is_array_node`), parse-state (`ufbxi_update_parse_state`),
raw-string (`ufbxi_is_raw_string`), and number-parsing (`ufbxi_parse_double/int64/inf_nan`)
helpers with the binary parser.

## Key data structures

### `ufbxi_ascii_token` (6248–6272)
One lexer token.
- `str_data` / `str_len` / `str_cap`: growable byte buffer holding the token's raw
  text (bare word text, string contents, or the number as ASCII incl. a trailing
  `'\0'` for numeric tokens).
- `type`: a `char` — either a `UFBXI_ASCII_*` category constant (`'N'`,`'B'`,`'I'`,`'F'`,`'S'`,`'\0'`)
  or a literal single-char punctuation byte (`'{'`, `'}'`, `','`, `'*'`, `':'`, etc.).
- `negative`: true if the number token started with `'-'` (needed to preserve the
  sign of negative-zero, e.g. `-0`).
- `value` union: `f64` (parsed double), `i64` (parsed int), or `name_len` (byte
  length of the identifier part of a `Name:` token, excluding the colon).

### `ufbxi_ascii` (6274–6291) — the lexer/stream state (`uc->ascii`, alias `ua`)
- `max_token_length`: currently unused bookkeeping.
- `src` / `src_yield` / `src_end`: cursor into the current buffer. `src` is the read
  position; `src_end` is the end of valid buffered bytes; `src_yield` is a soft
  checkpoint ≤ `src_end` used to bound work between progress-callback/refill points
  (`src_yield = min(src_end, src + progress_interval)`).
- `read_first_comment`: set once the first `;` comment line has been examined for the
  magic version string.
- `found_version`: true once a version has been established (from magic comment or the
  `FBXVersion:` integer node).
- `parse_as_f32`: when set, float arrays are parsed bit-accurately as 32-bit floats
  (used for `KeyAttrDataFloat`, which packs int bits into floats). Also causes the
  fast int/float array readers to bail (return without consuming).
- `src_is_retained`: true when the current buffer lives in a retained ufbxi_buf (so
  spans can point directly into it without copying).
- `retain_buf` / `src_buf`: buffers used when storing raw array spans for deferred/threaded parse.
- `prev_token` / `token`: the just-consumed token and the lookahead token. Buffers are
  swapped rather than copied between the two on each `next_token` (see quirks).

### `ufbxi_ascii_span` (9661–9664)
`{ const char *source; size_t length; }` — a contiguous chunk of raw array text
captured for deferred parsing. Multiple spans may be needed if the array crosses
read-buffer refill boundaries.

### `ufbxi_ascii_array_task` (9966–9973)
Deferred/threaded array-parse job: `arr_data` (destination base + already-parsed
prefix offset), `arr_type` (`i`/`l`/`f`/`d`), `arr_size` (remaining element count to
fill = `deferred_size`), `spans`/`num_spans`, and `offset` (running fill index).

### `ufbxi_array_info` (7977–7980) and flags (7970–7975)
`{ char type; uint8_t flags; }`. `type` is the FBX array element code:
`b,i,l,f,d`, `r`=ufbx_real, `c`=uint8, `s`/`S`=string, `C`=base64 content, `-`=ignore.
Flags: `RESULT`(0x1, allocate from result buffer / DOM retention), `TMP_BUF`(0x2),
`PAD_BEGIN`(0x4, prepend 4 zero elements so index `-1` is safe), `ACCURATE_F32`(0x8,
set `parse_as_f32`).

### `ufbxi_value` / `ufbxi_node` (6186–6194, shared)
Non-array node values live in a `ufbxi_value` union (`{double f; int64 i}` or sanitized
string `s`). `node->value_type_mask` is 2 bits per value slot
(`NONE/NUMBER/STRING/ARRAY`), up to `UFBXI_MAX_NON_ARRAY_VALUES = 8` (51). Array nodes
set the whole mask to `UFBXI_VALUE_ARRAY` and point `node->array` at a `ufbxi_value_array`.

## Control flow / algorithms

### Buffer plumbing: `ufbxi_ascii_refill` (9413), `_yield` (9458), `_peek`/`_next` (9481/9488)
- `_next` returns the char at the *new* position after advancing; `_peek` returns the
  current char without advancing. Both trampoline to `_yield` when `src == src_yield`.
- `_yield` refills via `_refill` if fully drained, recomputes `src_yield`, and fires the
  progress callback. `_refill` calls the user `read_fn` into either a retained buffer
  (when `retain_buf != NULL`) or the reusable `read_buffer`; returns `'\0'` on EOF. With
  no `read_fn`, everything past the initial buffer is EOF (`src` points at a static `""`).
- Port note: SwiftFBX uses `Data`, so the whole file is in memory. Replace this whole
  layer with a single `[UInt8]`/`UnsafeBufferPointer` + index. `src_yield` chunking,
  `read_fn`, retained buffers, and progress callbacks are all OUT of scope — collapse
  `peek`/`next` to plain index reads, and `_yield`/`_refill` disappear.

### Version detection: `ufbxi_ascii_parse_version` (9497)
Called on the very first `;` comment. Matches the fixed template `" FBX ?.?.?"`
(9504) where `' '` = skip run of spaces/tabs, `'?'` = one decimal digit, other = literal.
Collects exactly 3 digits → `version = 1000*d0 + 100*d1 + 10*d2` (so "7.7.0" → 7700,
"6.1.0" → 6100). Returns 0 on any mismatch. Consumes from the stream via `_next`.

### Whitespace & comments: `ufbxi_ascii_skip_whitespace` (9552)
Loop: consume spaces (`ufbxi_is_space`, mask over `' ' \t \r \n`, 9536–9550). On `;`:
- If this is the first comment (`!read_first_comment`), try `parse_version`; on success
  set `uc->version`, `found_version`, and `read_magic=true`.
- Skip to end of line (to `'\n'` or `'\0'`), advance past newline.
- If we just read the magic AND the next line is also a `;` comment, copy up to 32 bytes
  of it; if it begins with `" Created by Blender"` (19 bytes) set
  `uc->exporter = UFBX_EXPORTER_BLENDER_ASCII` (used later to detect Blender-6100 quirks).
Returns the first non-comment, non-space char.

### Token buffers: `ufbxi_ascii_push_token_char` (9612) / `_push_token_string` (9625)
Append to `token->str_data`, growing via `ufbxi_grow_array` (min capacity 256).

### Skipping helpers
- `ufbxi_ascii_skip_until(dst)` (9639): `memchr` forward to byte `dst` across yields;
  used to skip a quoted string body and to skip ignored `*N{...}` array bodies (to `}`).
- `ufbxi_ascii_store_array` (9666): captures raw array text into `ufbxi_ascii_span`s up
  to and including the closing `}`, either pointing into a retained buffer or copying
  into `tmp_buf`. Feeds deferred/threaded parsing. (Threading is OUT of scope — but the
  span-capture + `ufbxi_ascii_array_task_imp` single-thread path IS how large `*N{...}`
  arrays get parsed; see below.)
- `ufbxi_ascii_try_ignore_string` (9710): if the next token is a `"`-string, swap it in as
  `prev_token` and skip its body without interning (used to drop embedded `Content`
  when `ignore_embedded`).

### The tokenizer: `ufbxi_ascii_next_token` (9738)
1. Swap `prev_token` ⇄ `token` buffers (so the new token reuses the old prev buffer;
   this is why after `accept`, the just-consumed token is read from `ua->prev_token`).
2. `skip_whitespace`, reset `str_len = 0`, classify by first char `c`:
   - **Bare word / name** (`A–Z a–z _`): type `BARE_WORD`. Consume run of
     `[A-Za-z0-9_-()]` into `str_data`. Then `skip_whitespace`; if next char is `':'`,
     retype to `NAME`, record `value.name_len = str_len`, consume the colon. Note bare
     words may contain `-`, `(`, `)`.
   - **Number** (`0–9 - + .`): start as `INT`; set `negative = (c=='-')`. Consume run of
     `[0-9-+.eE]`, upgrading to `FLOAT` on seeing `.`, `e`, or `E`. Then consume any
     trailing "nan-like" run `[A-Za-z0-9#()]` (e.g. `1.#IND`, `nan(...)`), forcing FLOAT
     if present. Push a `'\0'` terminator. Then parse: `INT` via `ufbxi_parse_int64`,
     `FLOAT` via `ufbxi_parse_double` (with `UFBXI_PARSE_DOUBLE_AS_BINARY32` when
     `parse_as_f32`). Both must consume exactly to `str_data + str_len - 1` (i.e. the
     whole token, excluding the terminator) or the check fails.
   - **String** (`"`): type `STRING`. Consume until unescaped `"`. Fast path: `memchr`
     for the next `"` or `&` within the current yield window and bulk-copy the run.
     Escape handling (9827): `&quot;`→`"`, `&cr;`→`\r`, `&lf;`→`\n`; any other `&…`
     (including a bare `&`) is emitted literally char-by-char up to the point of
     mismatch (there is deliberately no `&amp;`). After the closing quote, if the next
     char is `':'`, retype to `NAME` (legacy names with spaces like `"Transport Tool Settings":`).
   - **Else**: single-char punctuation token; `type = c`; advance one.

### `ufbxi_ascii_accept(type)` (9898)
If `token.type == type`, advance (`next_token` into `token`) and return 1; else return 0
without consuming. The consumed token becomes `prev_token`.

### Fast array readers: `ufbxi_ascii_read_int_array` (9910) / `_read_float_array` (10160)
These are the fast path for *comma-separated* value lists (not `*N{}`). Entered from the
node loop when `arr_type` is set. Seed with the current `token` value, then scan `ua->src`
directly with a hand loop: skip `\s*,\s*`; a value is only committed once a following
comma is confirmed (so a trailing value with no comma stays as a normal token for the
grammar). Push each committed value to `uc->tmp_stack` (`int32`/`int64` or `float`/`double`),
re-parsing the next candidate with `ufbxi_parse_int64`/`ufbxi_parse_double`. Bail early if
fewer than 32 bytes remain in the window (safety margin against crossing buffer edges).
On exit, if `src` moved, re-sync the token stream via `next_token`. Return count in
`*p_num_read`. Both no-op (return 1, read 0) when `parse_as_f32` is set (forces slow path)
or when the current token isn't the right kind. Note float reader's int seed reproduces
`-0.0` via `fsign` (10169).

### Deferred/threaded `*N{}` array parse: `ufbxi_ascii_array_task_*` (9975–10158)
`_parse_floats`/`_parse_ints` fill `arr_data[offset..]` from a text range, comma-separated,
committing only fully-comma-terminated values (same conservative rule). `_task_imp` (10059)
walks the captured spans with a 4-state machine (VALUE/WHITESPACE/COMMENT/COMMA) using a
128-byte carry `buffer` to parse values that straddle span boundaries; it rejects strings
(`"`) and requires the final `offset == arr_size`. `_task_fn` is the thread entry. Only used
for arrays ≥ `UFBXI_MIN_THREADED_ASCII_VALUES` (64; note the "no-threads" build redefines
it to 2 at line 1019). Port: keep `_imp`/`_parse_*` as the *large-array* parser but call it
inline; drop the thread pool entirely (OUT of scope).

### base64: `ufbxi_setup_base64` (10224) / `ufbxi_decode_base64` (10241)
Builds a 256-entry decode table (invalid=0x80, `'='`=0x40) and decodes 4→3 bytes. Handles
`=`/`==` padding by trimming 1/2 output bytes; sets `UFBX_WARNING_BAD_BASE64_CONTENT` and
`*p_failed` on any invalid char, bad padding, or `length % 4 != 0`. Used for `arr_type == 'C'`
content arrays. Destination capacity is pre-sized as `str_len/4*3 + 3`.

### The grammar driver: `ufbxi_ascii_parse_node` (10285)
Recursive, depth-limited (`UFBXI_MAX_NODE_DEPTH = 32`, 52). One call parses one node and
(if `recursive`) all its children. Steps:
1. If current token is `'}'`: consume, `*p_end = true`, return (closes parent's child list).
2. If token is `END` (`'\0'`): require `depth == 0` else "Truncated file"; `*p_end = true`.
3. Require `depth < 32`. If `!sure_fbx && depth==0 && token != NAME`: fail
   "Expected a 'Name:' token" / "Not an FBX file" (this is the ASCII sniff test).
4. `accept(NAME)`; intern `prev_token` text (≤ 255 bytes) as the node name via the string
   pool. Push a zeroed `ufbxi_node` onto `tmp_stack`.
5. Classify the node as array or not: `ufbxi_is_array_node(parent_state,name,&arr_info)`.
   If array: `arr_type = normalize(type,'b')`, choose `arr_buf` (result/tmp/tmp_buf per
   flags), allocate a `ufbxi_value_array`, set `parse_as_f32` if `ACCURATE_F32`, compute
   `arr_elem_size`. If real array (`!= '-'`): push 8-byte alignment marker onto tmp_stack,
   and if `PAD_BEGIN` push 4 zero elements (num_values += 4).
6. Leading-comma hack (10370): some fields are `Name: , "value"`. Consume a leading `,`
   token; for an ignored (`'-'`) content array, try `try_ignore_string` first.
7. Compute `parse_state = ufbxi_update_parse_state(parent_state, name)` for children.
8. **Value loop** (10388, infinite, uses `continue` to stay inside a `*N{}` block):
   - If `arr_type` set, first drain the fast comma-array reader (int or float) → num_values.
   - Then dispatch on the next token via `accept`:
     - `STRING`: if array of `s`/`S`/`C`: push `ufbx_string` (C = base64-decode into
       result/tmp_buf, else intern raw/non-raw). Other array types: ignore (num_values--).
       Non-array: store into `vals[num_values]` as a sanitized string; `raw` if pure ASCII
       or `ufbxi_is_raw_string(...)` says so; non-ASCII+raw marks `utf8_length = UINT32_MAX`.
     - `INT`: non-array (arr_type 0): **version fallback** — if `!found_version` and
       `parse_state == FBX_VERSION` and first value and `6000 ≤ val ≤ 10000`, set version.
       Store number in `vals` (`v->f = (double)(v->i = val) * fsign`, preserving `-0`).
       Array: convert-and-push per `arr_type` (b/c/i/l/f/d), `-` ignores.
     - `FLOAT`: non-array stores `v->i = f64_to_i64(v->f = val)`. Array pushes per type,
       f64→int via `f64_to_i32/i64`.
     - `BARE_WORD`: `val = first char code`; if 2..63 chars, try `ufbxi_parse_inf_nan` on
       the whole word (so `inf`/`nan`/`1.#IND` bare words become floats). Store as number.
     - `'*'`: **post-7000 array syntax** `*count { Name: v,v,v }`. Assert not already in an
       array; accept the INT count; if `{` follows, accept the inner NAME (the `a:`), set
       `in_ascii_array`. If ignored (`'-'`): `skip_until('}')`. Else if threaded-eligible
       (`i/l/f/d`, not f32, count ≥ 64): set `deferred_size = count-1` and `store_array`
       the raw span(s). Otherwise fall through so the normal readers parse the body.
       `continue` (does NOT increment num_values or eat a comma).
     - else: break out of the value loop.
   - After a value: `num_values++`; if next token isn't `,`, break.
9. If `in_ascii_array`: `accept('}')` to close it. Clear `parse_as_f32`.
10. **Finalize array** (10606): for `'-'` set data=NULL,size=0. Else materialize:
    - If `deferred_size>0`: allocate `num_values+deferred_size` elements in `arr_buf`, move
      the eagerly-parsed prefix out of tmp_stack into it, then run the array task
      (inline or threaded) to fill the tail from the stored spans.
    - Else if `arr_error` (bad base64): pop and discard, size 0, point at zero buffer.
    - Else `push_pop` the tmp_stack contents into `arr_buf`.
    - Pop the 8-byte alignment marker. If `PAD_BEGIN`, expose `data = base + 4*elem` and
      `size -= 4` (the 4 pad elements stay addressable at negative indices).
    Non-array: clamp num_values to 8, set `value_type_mask`, copy `vals` into `tmp_buf`.
11. **Children** (10672): if `accept('{')`: if `recursive`, loop `parse_node(depth+1, parse_state, ...)`
    until a child returns `end`, then `push_pop` children into a contiguous array on
    `node`. Set `uc->has_next_child` accordingly (non-recursive/DOM-streaming path).

### Entry: `ufbxi_begin_parse` (11193)
Peeks the binary header; if it is NOT the binary magic, sets `from_ascii=true`, zeroes
`uc->ascii`, seeds `src/src_yield/src_end`, primes the first token (`next_token`), and if
no version was found in the magic comment defaults `uc->version = 7400` (unless `opts.strict`,
which then fails "Not an FBX file"). Top-level iteration calls `ufbxi_ascii_parse_node(uc, 0, state, ...)`
via `ufbxi_parse_toplevel_child_imp` (11244).

## Format details
- Token category codes (9406–9411): `END='\0'`, `NAME='N'`, `BARE_WORD='B'`, `INT='I'`,
  `FLOAT='F'`, `STRING='S'`. Punctuation tokens carry their literal byte as `type`.
- Magic comment template: `"; FBX X.Y.Z ..."`; version = `X*1000 + Y*100 + Z*10`
  (7.7.0→7700, 7.4.0→7400, 6.1.0→6100). Default when absent: **7400**.
- Version int fallback: only the `FBXVersion:` node's first integer, accepted if in
  `[6000, 10000]` (10458).
- Blender-ASCII detection: second comment line prefix `" Created by Blender"` (19 bytes).
- Array element type codes: `b`(bool,1B) `c`(uint8,1B) `i`(int32,4B) `l`(int64,8B)
  `f`(float,4B) `d`(double,8B) `r`(ufbx_real→f/d) `s`/`S`/`C`(ufbx_string, C=base64)
  `-`(ignore). Sizes in `ufbxi_array_type_size` (7694). `normalize`: `r`→f/d by
  `sizeof(ufbx_real)`, `b`→caller's bool code (7686).
- String escapes: `&quot;`→`"`, `&cr;`→`\r`, `&lf;`→`\n`; no `&amp;` (bare `&` is literal).
- Limits: `UFBXI_MAX_NON_ARRAY_VALUES=8`, `UFBXI_MAX_NODE_DEPTH=32`,
  `UFBXI_MIN_THREADED_ASCII_VALUES=64` (2 in no-thread builds), node name ≤ 255 bytes.
- Version-dependent array typing (external, but ASCII-relevant): `UvIndex`/normals-w
  etc. in `ufbxi_is_array_node` branch on `uc->from_ascii && uc->version >= 7200`
  (8191–8193) — pre-7200 ASCII uses `f` where 7200+ uses `i`.
- Raw-string rules (`ufbxi_is_raw_string`, 8508): Connections/Relations use raw strings
  when `version < 7000` (pre-7000 `Name\0\1Type` encoding); Objects always raw; various
  named fields raw. This drives whether ASCII string values are UTF-8 sanitized.

## Quirks & edge cases
- **Two ASCII array syntaxes**: bare comma lists (`Vertices: 1,2,3`) handled by the fast
  readers, and post-7000 `*count { a: 1,2,3 }`. The `*count` header count can mismatch;
  `deferred_size = count-1` (10579) because the first element is parsed eagerly from the
  seed token before span capture. (Line 10285 header note: recursion is depth-limited.)
- **Conservative comma commit**: all fast/deferred readers only accept a value once a
  following comma is confirmed; the last (comma-less) value is left for the normal token
  path. Prevents mis-parsing a value split across a buffer boundary. (9929, 10125, 10186.)
- **Negative zero preservation**: `token.negative` + `fsign` reconstruct `-0.0` from the
  integer token path (10169, 10451, 10477); matters for exact float round-trips.
- **`KeyAttrDataFloat` / ACCURATE_F32**: sets `parse_as_f32`, which (a) forces the slow
  token-by-token path (fast readers early-return), and (b) parses doubles with
  `UFBXI_PARSE_DOUBLE_AS_BINARY32` so integer bit-patterns stashed in floats survive
  exactly (9347/9796–9797, comment at 10347).
- **Special float text**: `1.#IND`, `1.#INF`, `nan`, `nan(...)`, `inf`, `infinity`,
  `+/-` variants all recognized by `ufbxi_parse_inf_nan` (1545) via bit construction
  (`0x7ff0…`=inf, `0x7ff8…`=nan, `0x8000` sign). Bare-word numbers (`inf`) route here too
  (10521). MSVC legacy `d.#…` form handled specially.
- **Bare words as numbers**: a bare word's value is its first character's code unless it
  parses as inf/nan (10514). This is how single-letter enum-ish tokens become numbers.
- **Leading comma fields**: `Content: , "..."` — a stray leading comma is consumed before
  the value loop (10369).
- **Legacy names with spaces**: quoted string immediately followed by `:` becomes a NAME
  token (`"Transport Tool Settings":`) (9883). Bare-word names also allow `-()` chars.
- **`&` is unescapable**: partial-match escapes are emitted literally char-by-char; a lone
  `&` maps to `&` (9845–9870).
- **PAD_BEGIN arrays**: 4 zero elements prepended, `data` pointer offset past them, `size`
  excludes them — lets consumers index `[-1]` safely (10627). Vertices/Points use this.
- **Ignored arrays (`'-'`)**: whole body skipped (`skip_until('}')` for `*N{}`, or
  `try_ignore_string` for content), array left NULL/0. Driven by `opts.ignore_geometry`/
  `ignore_embedded`/`retain_dom` in `is_array_node`.
- **Bad base64 → warning, not error**: `arr_error` set; array discarded to a zero buffer,
  size 0; emits `UFBX_WARNING_BAD_BASE64_CONTENT` (10619, 10275).
- **Blender-6100** exporter tag captured here feeds later exporter-specific fixups.
- **strict vs default version**: no magic + non-strict → assume 7400; strict → hard fail.
- **`sure_fbx`**: ASCII files aren't "sure FBX" unless a version was found; if not sure,
  the first top-level token MUST be a `Name:` or parsing fails as "Not an FBX file"
  (10305) — the ASCII content sniff.
- **f64→int rounding** uses `ufbxi_f64_to_i32/i64` (saturating helpers), not C casts.
- Node name length capped at 0xff; longer → fail (10310).

## Port guidance
- **Replace the streaming layer wholesale.** With `Data` fully in memory, drop
  `ufbxi_ascii_refill`, `_yield`, `retain_buf`, `read_fn`, `src_yield` chunking, progress
  callbacks, and the thread pool. `peek`/`next` become index reads over a
  `UnsafeBufferPointer<UInt8>` (or `[UInt8]`). This eliminates most of 9413–9495,
  9639–9708 (span capture), and the threaded task fan-out — but KEEP the *logic* of
  `ufbxi_ascii_array_task_imp`/`_parse_ints`/`_parse_floats` as the large-array parser,
  invoked inline; you can even fold it back into a single comma-scanning loop since you
  no longer straddle spans.
- **Port faithfully (correctness-critical):** the tokenizer classification and number/
  string/name disambiguation (9738–9896); `parse_version` template matching; the value
  loop dispatch and `*N{}` handling (10388–10602); array finalization incl. PAD_BEGIN
  offset math and the deferred-size seed-off-by-one; all quirks above. Number parsing
  (`ufbxi_parse_double`/`int64`/`inf_nan`, 1545–1828) is shared with binary — port it as
  its own module (bigint decimal parser + inf/nan bit construction); do not use
  `Double(string)` (it won't reproduce ACCURATE_F32 or MSVC `1.#IND`).
- **Swift shapes:** model the token as an enum with associated values
  (`.name(String)`, `.bareWord([UInt8])`, `.int(Int64, negative: Bool)`,
  `.float(Double)`, `.string([UInt8])`, `.punct(UInt8)`, `.end`). The lexer's
  buffer-swap trick (prev/token) is a C micro-opt — in Swift just keep `previous` and
  `current` tokens as values. Use throwing funcs instead of the `int` return / `p_end`
  out-params; `*p_end`/`has_next_child` become normal returns. Represent `arr_type` as an
  enum. Escapes and the base64 decoder are straightforward ports.
- **Skip per scope:** thread pool, retained/streaming IO, DOM-retention-only allocation
  choices (`retain_dom` flag paths), progress callbacks.
- **Cross-subsystem dependencies (name them):**
  - `ufbxi_is_array_node` (8092), `ufbxi_update_parse_state` (7982), `ufbxi_is_raw_string`
    (8508) — the **shared classification/parse-state subsystem** used by both ASCII and
    binary parsers; ASCII passes `parent_state`/`name` through them. These carry the
    version- and option-dependent type/flag tables (do not inline-dump; cite).
  - Number parsing (`ufbxi_parse_double/int64/inf_nan`, 1545–1828) — shared **number
    subsystem**.
  - Produces the `ufbxi_node` DOM consumed by the **scene-construction subsystem**; sets
    `uc->version`, `uc->exporter`, `uc->sure_fbx`, `uc->from_ascii` consumed downstream.
  - String interning (`ufbxi_push_string`/`_push_sanitized_string`/`_place_str`) and
    `tmp_stack`/buffer allocators are the shared **memory/string-pool subsystem**.
```
