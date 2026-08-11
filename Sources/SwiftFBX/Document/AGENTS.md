# Sources/SwiftFBX/Document

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

Turns a raw FBX byte buffer (binary 7100–7700 or ASCII 6100–7700) into the
low-level `FBXDocument` tree (`FBXDocNode` + `FBXValue`/`FBXArrayValue`) — the
DOM other layers (`Loader/*`) walk by name. No FBX semantics (objects,
connections, props) live here; this is purely "bytes/tokens → typed node
tree", faithfully reproducing ufbx's classifier-driven array typing and quirk
handling.

## Files

- **Value.swift** — `FBXValue` (scalar: bool/int32/int64/float/double/string/raw)
  and `FBXArrayValue` (array variant of the same, plus `.raw(Data)` for
  byte/blob arrays). Implements ufbx's lenient dual `.i`/`.f` numeric coercion
  (`numericPair`, mirrors `ufbxi_get_val_at`) and the array dst-type
  conversion matrix (`asInt32Array`/`asInt64Array`/`asFloatArray`/
  `asDoubleArray`/`asBoolArray`, mirrors `ufbxi_binary_convert_array`).
  Owns the two saturating float→int helpers `FBXValue.f64ToI32`/`f64ToI64`
  used by *both* parsers.
- **Document.swift** — `FBXFormat` (`.binary`/`.ascii`), `FBXDocNode` (name +
  up to 8 `values` XOR one `array`, + `children`; lookup helpers `child(_:)`,
  `children(_:)`, `findChild(_:)`, and typed accessors `bool(at:)`…
  `rawString(at:)`, `asBoolArray()`…`asRawData()`), `FBXDocument` (version,
  format, bigEndian, `root`; internal `init`, public `parse(data:options:)`
  added in DocumentParser.swift).
- **ParseState.swift** — the shared classifier both parsers consult: `ParseState`
  (tree-position enum), `ArrayType`/`ArrayFlags`/`ArrayInfo`, `ParseContext`
  (version + `ignore*`/`retainDom`/`retainVertexW`/`blenderFullWeights`
  option gates), `ParseState.update(parent:name:)` (state transition table),
  `ParseState.arrayInfo(parent:name:context:)` (is-this-child-an-array +
  dst type/flags), `ParseState.isRawString(parent:name:valueIndex:version:)`
  (raw-vs-sanitized string decision). **Both `BinaryParser` and `AsciiParser`
  call into this file before consuming any payload** — it is the single
  source of truth for "what type does this node's data get parsed as."
- **BinaryParser.swift** — binary record reader → `FBXDocNode` tree.
  `BinaryParser.detectHeader(_:)` (27-byte magic/endian/version sniff),
  `nextTopLevelNode()`, `parseBinaryDocument(_:...)` (convenience full
  parse used by DocumentParser). Internals: `parseNode` (13/25-byte record
  header, NULL-sentinel termination, child recursion), `parseArray` /
  `parseTypedArray` (post-7000 tag+size+encoding+payload, DEFLATE via
  `Inflate.inflate`) / `parseMultivalueArray` (pre-7000 concatenated-scalar
  fallback), `parseScalarValues`, `convert`/`normalize`/`normalizeSrc`/
  `elemSize` (dst-type conversion helpers built on `FBXArrayValue`'s
  `as*Array()` family).
- **AsciiTokenizer.swift** — streaming lexer for text FBX. `AsciiTokenKind`
  (token category bytes), `AsciiToken` (type/data/i64/f64/negative),
  `AsciiTokenizer` class: `nextToken()` (main grammar), `current`/`previous`
  lookahead, version/`foundVersion`/`parseAsF32`/`isBlenderAscii` state,
  `skipWhitespace()` (also sniffs the `; FBX ?.?.?` magic comment and the
  Blender-ASCII marker), `skipUntil(_:)`, `tryIgnoreString()` (used to drop
  an ignored `Content` string after a leading comma), `appendEscape` (XML-like
  `&quot;`/`&cr;`/`&lf;` entities only — no `&amp;`).
- **AsciiParser.swift** — ASCII grammar driver → the same `FBXDocNode` tree
  as BinaryParser. `AsciiParser.parseAsciiDocument(_:...)` (entry point:
  primes the tokenizer, resolves `sureFbx`/default version 7400, drives
  `parseNode` over top-level nodes). `ParseOptions` (mirrors BinaryParser's
  classifier gates). Internals: `parseNode` (`Name:` + comma-separated value
  list + optional `{ ... }` children, `*N { a: ... }` post-7000 array
  syntax), `finalizeArray`, `makeStringValue` (raw-vs-sanitized per
  `ParseState.isRawString`), `decodeBase64`/`base64Table` (Content values;
  failures collected in `warnings: [FBXWarning]` — **not** surfaced through
  `FBXDocument`, only via the instance API).
- **DocumentParser.swift** — top-level driver: `FBXDocument.parse(data:
  options:)` (`public extension`). Resource/source-size validation, empty-file
  check, then binary-magic sniff
  via `BinaryParser.parseBinaryDocument` (returns `nil` without consuming
  bytes if not binary), else falls through to
  `AsciiParser.parseAsciiDocument`. No section-specific logic (header ext,
  objects, connections, …) — that's `Loader/ElementReader.swift` etc.

## Business rules & invariants

- **`ParseState.arrayInfo` must be resolved before any payload byte is
  consumed** — both parsers classify a node by (parent state, name) *first*,
  then branch their read loop on the result. Getting this ordering wrong
  desyncs the byte cursor (binary) or the token stream (ASCII).
- **Binary record header size is version-gated**: `< 7500` → 13 bytes (u32
  end_offset, u32 num_values, u32 values_len, u8 name_len); `>= 7500` → 25
  bytes (same fields as u64, u8 name_len at byte 24). Getting this wrong on a
  7500+ file misreads every subsequent node. A record with `end_offset == 0
  && name_len == 0` is the NULL sentinel terminating a sibling list — files
  always end in a full zero-filled header of the size implied by their
  version.
- **PAD_BEGIN** (`ArrayFlags.padBegin`): geometry-ish real/index arrays
  (`Vertices`, `Normals`, UV/tangent/binormal/color/crease arrays,
  `TextureUV`/`TextureUVVerticeIndex`) get 4 zero elements prefixed so a
  downstream index of `-1`..`-4` reads as zero instead of underflowing. This
  is encoded in `ArrayInfo.flags` but **not yet materialized as an actual
  prefix in this port's array storage** (`FBXArrayValue` holds it as
  metadata resolved at classification time) — if a later wave needs the
  physical zero-prefix, that is a change to how the readers consume
  `FBXDocNode.array`, not a change to this directory's array construction. Do
  not remove or reinterpret the `padBegin` flag without checking every
  consumer.
- **Array dst-type conversion is saturating for float→int, truncating for
  int narrow/widen, non-saturating for anything→float/double** — see
  `FBXArrayValue.asInt32Array`/`asInt64Array` (call `FBXValue.f64ToI32`/
  `f64ToI64`) vs `asFloatArray`/`asDoubleArray` (plain `Float.init`/
  `Double.init`, no clamping). This exactly mirrors
  `ufbxi_binary_convert_array` (ufbx.c:8672–8760) and applies identically
  whether the array came from the binary typed-array path or the ASCII
  numeric-literal path.
- **`f64ToI64` uses a strict `<` against `9223372036854775808.0` (2^63), not
  `<=`** (Value.swift:64–80) — `Double(Int64.max)` rounds up to exactly 2^63,
  so a `<=` guard would let a value of exactly 2^63 through and
  `Int64(2^63)` traps in Swift (unlike C's UB wraparound). Do not "simplify"
  this back to `<=`.
- **7500+ uses 64-bit values throughout the binary header AND the endianness
  applies to every multi-byte field** — `bigEndian` is a per-document flag
  set once from `detectHeader` and threaded through `DataReader`/
  `readSourceArray`; array element byte-swapping must use the same flag as
  the top-level header did, not be re-derived.
- **Bool arrays are a post-process step, not a wire type**: `ArrayType.bool`
  is a *destination* tag; the actual wire/storage form is bytes ('c'), and
  `arrType == .bool` triggers `arr = .bool(arr.asBoolArray())` (non-zero
  test) after the raw typed/multivalue/empty read completes — both in
  `BinaryParser.parseArray` and in `AsciiParser.finalizeArray` (`case 0x62`).
- **Pre-7000 binary "multivalue" arrays**: when the wire array tag byte isn't
  one of `c b i l f d`, the array is actually a run of individually-typed
  scalar records concatenated (`parseMultivalueArray`) — this is the legacy
  6100 encoding, not a corrupt file. String/content dst types read
  'S'/'R'-tagged length-prefixed records instead of raw scalars.
- **`KeyAttrDataFloat` (AnimationCurve) is version- and origin-gated**:
  ASCII with `version < 7200` needs bit-exact `Float` parsing
  (`ArrayFlags.accurateF32`, which flips `AsciiTokenizer.parseAsF32`), because
  those files store raw f32 bit patterns as decimal text that must round-trip
  exactly; `version >= 7200` (any origin) stores the same slot as `.int32`
  because some of those elements aren't actually floats. Do not merge these
  branches — they produce different `FBXArrayValue` cases.
- **ASCII negative-zero dual view**: a literal `-0` int token (`val == 0 &&
  t.negative`) is stored as `.double(-0.0)`, not `.int64(0)`, both for
  scalar values and for `f`/`d` array elements (`fsign`/`dsign` in
  AsciiParser.swift) — this reproduces ufbx's `v->f = (double)(v->i = val) *
  fsign` dual-storage trick (ufbx.c:10466–10469) so `asInt64` still reads `0`
  but `asDouble` reads `-0.0`. Losing the sign here changes golden output on
  any file with a literal `-0` scale/translation component.
- **Pre-7200 vs `>=`7200 plain int/float rules** are entangled with the
  `KeyAttrDataFloat` rule above and with `ParseContext.fromAscii` — always
  gate on `(c.fromAscii, c.version)` together, never just one.
- **ASCII raw strings**: `ParseState.isRawString` decides byte-preserving vs
  UTF-8-sanitized storage *per (parent state, node name)* — e.g. everything
  under `.objects` is raw, `Connections`/`Relations` are raw only pre-7000
  (they hold `"Name\x00\x01Type"` pairs). Both parsers must call the exact
  same table; do not special-case one parser's string handling independently
  of the other.
- **`isRawString`'s `valueIndex` parameter is accepted but unused** — kept
  only for signature parity with ufbx's `ufbxi_is_raw_string`, which also
  ignores it. Don't be tempted to "fix" this by wiring it up; that would be a
  behavior change, not a bug fix.
- **Hardened size/offset checks must never be weakened** — these exist
  because malformed/fuzzed input reaches them directly:
  - `BinaryParser.parseNode`: `values_end_offset = position + values_len`
    computed with wrapping add (`&+`) on purpose (mirrors C uint64
    wraparound), then rejected by the `offset > valuesEndOffset` check; the
    trailing skip-distance conversion uses `Int(exactly:)` and throws
    `.truncatedFile` rather than trapping on an out-of-`Int`-range delta.
  - `parseTypedArray`: `elemSize(srcType) * size` uses
    `multipliedReportingOverflow` before allocating; DEFLATE output size is
    bounded by `compressed.count * 1032 + 64` (max possible DEFLATE
    expansion) before allocating the zero-filled output buffer — both guard
    against OOM/timeout from a crafted `size`/`decodedSize`, not just
    correctness.
  - Binary and ASCII arrays claim aggregate decoded bytes and elements from a
    shared per-document budget before payload allocation or accumulator growth.
  - `parseMultivalueArray`: `reserve = min(size, reader.remaining)` caps
    pre-allocation so an untrusted `size` can't reserve gigabytes before the
    read loop hits EOF and throws.
  - `parseScalarValues`: positional values are capped at 8 and pre-allocation
    is additionally capped by the unread source byte count.
  - Node depth is capped at `maxNodeDepth == 32` in both parsers
    (`UFBXI_MAX_NODE_DEPTH`), throwing `.nodeDepthLimit` — this is a
    recursion-guard against stack overflow on adversarial input, not a
    format limit to relax.
  - `MalformedInputTests` and the fuzz corpus in
    `Tests/SwiftFBXTests/Resources/malformed/` exist specifically to catch
    regressions in these checks; a "fix" that removes or loosens a bounds
    check to make a test pass is backwards — the check is the point.

## Swift tips for this code

- `FBXValue`/`FBXArrayValue` are enums, not classes — coercions
  (`asInt32`, `asDoubleArray`, …) are computed properties/methods, not stored
  state. Don't add caching; freeze rule (see parent AGENTS.md) forbids mutable
  memoization on these types anyway, and they're value types so there'd be
  nowhere to put it.
- `FBXDocNode`/`FBXDocument` are `final class ... @unchecked Sendable` with
  `internal(set) var` storage — safe only because nothing mutates them after
  `parse` returns. Do not add a public mutating API.
- Both parsers build `FBXDocNode.array` as one shot at the end (`node.array =
  arr`), never incrementally — keep that shape; readers elsewhere assume an
  `FBXDocNode` is either fully array or fully scalar-values, never a mix.
- `BinaryParser` is a `struct` holding a `DataReader` by value + `mutating
  func`s; `AsciiParser`/`AsciiTokenizer` are `final class`es holding cursor
  state by reference. This asymmetry is intentional (mirrors how each side's
  original C code manages its cursor) — don't "unify" them into the same
  shape.
- Byte constants throughout are written as hex literals matching ASCII (e.g.
  `0x7D` for `'}'`, `0x2C` for `','`) rather than character literals — grep
  the hex value against an ASCII table if a branch's meaning isn't obvious
  from its comment.
- `FloatParse.parseDouble`/`parseInt64` (Core/FloatParse.swift) are the only
  sanctioned numeric parsers here — do not swap in `Double(String)` /
  `Int64(String)` for hot paths; ufbx's locale-independent parser has
  different edge-case behavior (hex floats, `inf`/`nan` spellings) that
  `Double.init(String)` does not replicate.
- `Data.map { Double.init($0) }` style conversions on `.raw` array storage
  read the bytes as **unsigned** 8-bit values (ufbx's `uint8_t` source rows)
  — don't reach for `Int8`.

## Dependencies & boundaries

- May import: `Foundation`, `Core/DataReader.swift`, `Core/Inflate.swift`,
  `Core/FloatParse.swift`, `Core/Errors.swift` (all in `SwiftFBX/Core`).
- Must NOT import or reference anything under `Scene/`, `Loader/`,
  `Evaluate/`, or `Geometry/` — this directory has no concept of FBX objects,
  properties, connections, or elements. `Loader/ElementReader.swift` and
  siblings are the only consumers of `FBXDocument`/`FBXDocNode`.
- Public surface other modules rely on: `FBXDocument.parse(data:options:)`,
  `FBXDocument.{version,format,bigEndian,root}`, `FBXDocNode` (name/values/
  array/children + all the `at:`/`as*Array()` accessors). `ParseState`,
  `ArrayType`, `ArrayFlags`, `ArrayInfo`, `ParseContext`, `BinaryParser`,
  `AsciiParser`, `AsciiTokenizer` are internal — only the `Document.swift`
  contract above is public API.

## Testing

```
swift test --filter BinaryParserTests
swift test --filter AsciiParserTests
swift test --filter MalformedInputTests   # fuzz corpus + hardened-check regressions
swift test --filter GoldenTests           # end-to-end parity; any Document-layer
                                           # regression usually shows up here first
```

- `Tests/SwiftFBXTests/BinaryParserTests.swift` / `AsciiParserTests.swift`
  exercise this directory directly (record layouts, array typing, tokenizer
  quirks).
- `Tests/SwiftFBXTests/MalformedInputTests.swift` runs the fuzzed/truncated
  files under `Tests/SwiftFBXTests/Resources/malformed/` (all derived from
  `maya_cube_7500_binary.fbx`) — this is the regression suite for the
  hardened checks listed above; every file there must parse-and-throw
  `FBXError` cleanly, never crash.
- `GoldenTests` (44 fbx/golden pairs) is the strongest signal: any change to
  array typing, raw-string decisions, or numeric coercion here shows up as a
  structural diff several layers downstream. If you touch `ParseState.swift`,
  always run the full golden suite, not just the Document unit tests.

## Rules for the model

- Any behavior change here must keep `GoldenTests` at its current pass count
  (44/44) — run the full golden suite, not a subset, before considering a
  change to `ParseState.swift`/`BinaryParser.swift`/`AsciiParser.swift` done.
- Never weaken a bounds/overflow check (Int(exactly:), overflow-reporting
  multiply, node-depth cap, reserve-capacity clamp) to make a test pass —
  these exist because `MalformedInputTests`/the fuzz corpus target them
  specifically; if a legitimate file trips one, the fix is to understand why
  ufbx's original check didn't trip (re-read ufbx.c at the cited line), not
  to loosen the Swift check.
- Before changing `ParseState.update`/`arrayInfo`/`isRawString`, re-read
  `docs/ufbx-notes/02-binary-parse.md` (record layout, array conversion
  matrix) and `docs/ufbx-notes/03-ascii-parse.md` (tokenizer/grammar quirks,
  negative-zero, base64) — these tables are large, order-sensitive
  transcriptions of `ufbx.c:7909–8605`; a "cleanup" that reorders or
  collapses cases can silently change classification for a name that hits a
  later case in the original but an earlier one after reordering.
- Before changing top-level format/version detection, re-read
  `docs/ufbx-notes/04-parse-driver.md` (the eager-vs-lazy top-level cache
  simplification is deliberate and documented there — do not "restore" ufbx's
  streaming lazy-parse machinery, it would be dead complexity given this port
  always holds the whole file in memory).
- Keep `BinaryParser` and `AsciiParser` both routed through the *same*
  `ParseState`/`ArrayInfo`/`isRawString` calls — do not let one parser grow
  parallel classification logic that could drift from the other; that
  duplication is exactly what golden parity is designed to catch, but it's
  cheaper to just not introduce it.
- `FBXDocument` has no warnings channel by design (`AsciiParser.warnings` is
  collected but dropped by the top-level `parse`); if a future change needs
  to surface base64-decode warnings end-to-end, that's a `Loader`-level
  contract change (see DESIGN.md's "ONE warnings location" rule), not a fix
  to make here in isolation.
