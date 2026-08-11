# Sources/SwiftFBX/Core

See ../AGENTS.md (and the root AGENTS.md) for project-wide conventions.

## Purpose

Dependency-free primitives that everything else in the parser sits on: the
error/warning taxonomy, a bounds-checked byte cursor, a pure-Swift DEFLATE
decompressor, and a bit-exact locale-independent decimal float parser. Nothing
here imports any other `SwiftFBX` module — these are leaves in the dependency
graph.

## Files

- **Errors.swift** — `FBXError` (`Error, Sendable, CustomStringConvertible`):
  `code: FBXError.Code` + `info: String`. `FBXError.Code` mirrors the subset of
  `ufbx_error_type` this port needs (`.io`, `.fileNotFound`, `.truncatedFile`,
  `.unrecognizedFileFormat`, `.unsupportedVersion`, `.corruptData`,
  `.badDeflate`, `.asciiSyntax`, `.badIndex`, `.nodeDepthLimit`,
  `.invalidOptions`, `.resourceLimit`, `.unknown`).
  `FBXErrorCode` is a `public typealias` for `FBXError.Code` — DESIGN.md's
  contract text spells the type `error.code: FBXErrorCode`; the alias exists
  purely so both spellings compile, don't "clean it up" to one or the other.
  Also defines `FBXWarning` (`Sendable, Equatable`): `kind: FBXWarning.Kind`,
  `info: String`, `count: Int` (dedup occurrence counter), `elementID: Int32`
  (`-1` = none) — mirrors `ufbx_warning`.
- **DataReader.swift** — `struct DataReader`: bounds-checked byte cursor over
  `[UInt8]` (`bytes`, `position`, `bigEndian`). Used by both the binary
  document parser and `Inflate`'s stored-block path. Read family: `readUInt8/16/32/64`,
  `readInt8/16/32/64`, `readFloat`/`readDouble` (bit-pattern reinterpretation,
  not textual conversion), `readBytes(_:) -> ArraySlice<UInt8>`,
  `peekByte`/`peekBytes`, `skip`/`skipClamped`. Every throwing read has a
  `tryRead*` non-throwing sibling that swallows the error and returns `nil`
  (`try?` wrapper — don't hand-roll these, add via the same pattern).
  `bigEndian` is a **mutable var**, not a generic parameter or init-only
  constant: a single document parse can flip byte order mid-stream per
  `FBXDocument.bigEndian`, so callers toggle it on the same reader instance.
- **Inflate.swift** — `enum Inflate` (namespace, no state). Port of
  `ufbx_inflate` (ufbx.c:1849-3280). Entry point:
  `Inflate.inflate(_ input: ArraySlice<UInt8>, into output: inout [UInt8], noHeader: Bool = false, noChecksum: Bool = false) throws -> Int`.
  `output.count` must already equal the known decompressed capacity; the
  return value is the number of bytes actually produced. Also exposes
  `Inflate.buildTable(_:count:) throws -> HuffTable` and `Inflate.adler32(_:) -> UInt32`
  at internal visibility (used directly by `InflateTests.swift`). Internals:
  `HuffTable` (single-level canonical Huffman table — collapses ufbx's
  two-level fast+long+sorted tables into one equivalent per-symbol lookup),
  `BitReader` (LSB-first, 64-bit refill buffer), `buildDynamicTrees`,
  `inflateBlock`.
- **FloatParse.swift** — `enum FloatParse` (namespace). Port of
  `ufbxi_parse_double` / `ufbxi_parse_inf_nan` / `ufbxi_parse_int64`
  (ufbx.c:1349-1846). Entry points:
  `parseDouble(bytes:maxLength:flags:) -> (value: Double, consumed: Int)`,
  convenience overloads `parseDouble(_ slice: ArraySlice<UInt8>, flags:)` and
  `parseDouble(_ bytes: [UInt8], flags:)`, and
  `parseInt64(bytes:maxLength:) -> (value: Int64, consumed: Int)?` /
  `parseInt64(_ slice:)` (nil = no digits or the 30-digit cap was hit — mirrors
  ufbx returning a NULL end pointer). `Flags: OptionSet` has `.allowFastPath`
  and `.asBinary32` (the ACCURATE_F32 mode). Private `BigInt` (fixed-capacity
  little-limb-endian bignum) + `bigintMad`/`bigintMulPow5`/`bigintShiftLeft`/
  `bigintDiv`/`bigintExtractHigh` implement the Grisu-less exact big-integer
  division path ufbx uses when the fast f64-multiply path isn't exact.

## Business rules & invariants

- **Never trap on untrusted input.** All four files treat every byte in the
  input buffer as attacker-controlled. `DataReader` bounds-checks every read
  and throws `FBXError(.truncatedFile, …)` rather than trapping — no `bytes[i]`
  without a preceding `checkAvailable`. `Inflate` throws `FBXError(.badDeflate, …)`
  for every malformed-stream condition (bad zlib header, over/under-subscribed
  Huffman tree, distance-too-far-back, output overflow, checksum mismatch,
  bit-stream underrun). Do not weaken or remove a bounds check to make a test
  pass — fix the caller instead.
- **Adler-32**: `Inflate.adler32` uses modulus 65521 with the standard
  5552-byte chunking (chunk size chosen so `a`/`b` can't overflow `UInt32`
  before a `%=`). The trailer in `inflate(...)` is read big-endian
  (`(b0<<24)|(b1<<16)|(b2<<8)|b3`) — FBX's zlib streams are always big-endian
  Adler-32 regardless of the enclosing document's `bigEndian` flag; don't wire
  `DataReader.bigEndian` into this path.
- **Overlapping DEFLATE matches**: `inflateBlock`'s copy loop is deliberately
  byte-by-byte (`out[outPos] = out[src]; outPos+=1; src+=1`), never
  `memcpy`/`replaceSubrange` — when `distance < length` the source and
  destination ranges overlap and run-length patterns (e.g. RLE zero-fill) rely
  on reading bytes the same loop just wrote. Comment at Inflate.swift:368
  cites this explicitly; preserve it if you ever "optimize" this loop.
  `distance > outPos` is a hard error (`"distance too far back"`), not
  clamped.
- **Huffman table construction**: `buildTable` allows an under-subscribed
  ("incomplete") tree only when there's exactly one non-zero-length code
  (`left > 0 && nonzero > 1` throws) — this is the RFC 1951 single-symbol-tree
  exception ufbx also special-cases. Over-subscription (`left < 0`) always
  throws.
- **Float parser is bit-exact with ufbx, not merely "close enough."** It must
  reproduce ufbx's exact IEEE-754 rounding (round-half-to-even) including its
  fast-path shortcuts (`decExponent` in `[-22, 22]` and mantissa `< 2^53`) and
  its slow bignum path. The 18-digit accumulation threshold
  (`numDigits >= 18`) and the `maxLimbs == 14` cap on `bigMantissa` are copied
  verbatim from ufbx's constants — changing either changes rounding behavior
  on inputs that hit the boundary.
- **MSVC legacy float spellings**: `parseInfNan` recognizes `1.#INF`,
  `1.#IND`, `1.#NAN` (case-insensitive) in addition to standard `inf`/`nan`
  forms, because real ASCII FBX exporters (old Autodesk/MSVC toolchains) emit
  them. Don't remove this path even though it looks like dead legacy code —
  golden files exercise it.
- **`.asBinary32` (ACCURATE_F32) contract**: when this flag is set, the
  returned `Double` is guaranteed to be exactly representable as a `Float`
  (rounding is done at 24-bit mantissa precision internally, then widened) —
  callers may do `Float(value)` and it is lossless, never a second rounding
  step. This backs `KeyAttrDataFloat` (ASCII animation-curve tangent data,
  notes 02/03) where ufbx parses as `float` directly rather than round-tripping
  through `double`.
- **`parseInt64` 30-digit cap**: mirrors ufbx's fixed-size local buffer — a
  run of 30+ digit characters returns `nil` (parse failure) rather than
  overflowing or silently truncating. A leading `+`/`-` counts against
  `initLen`, not against the 30-digit budget check's start.
- **`DataReader.readFloat`/`readDouble` are bit-reinterpretation, not decimal
  parsing** — they read raw IEEE-754 bytes (binary FBX property values).
  Decimal text parsing is a completely separate code path (`FloatParse`, used
  only by the ASCII tokenizer). Don't conflate the two when tracing a "wrong
  float value" bug — check which parser is actually on the call path first.

## Swift tips for this code

- `Inflate` and `FloatParse` are stateless `enum` namespaces (no cases) — add
  new helpers as `static func`, don't add instance state.
- Hot loops use `UnsafePointer<UInt8>`/`UnsafeMutableBufferPointer<UInt8>` via
  `withUnsafeBufferPointer`/`withUnsafeMutableBufferPointer` closures rather
  than subscripting `[UInt8]`/`ArraySlice` directly — this is intentional for
  performance (every float and every big array in a scene goes through these
  paths); keep new hot-path code inside the existing pointer scopes rather
  than reintroducing `Array` subscript overhead.
  `FloatParse.parseDouble(bytes:maxLength:)` takes a raw pointer + length, not
  an `ArraySlice`/`Data`, so it composes with `DataReader`'s own unsafe reads;
  the `ArraySlice`/`[UInt8]` overloads are thin `withUnsafeBufferPointer`
  wrappers — extend those, not the pointer-taking core.
- `DataReader.checkAvailable` guards against `position < 0` too — arithmetic
  elsewhere (e.g. `bytes.count - n`) can underflow if `n` is negative or huge,
  so the check is `n < 0 || position < 0 || position > bytes.count - n`, not
  just `position + n > bytes.count`. Keep this form if you touch it; the
  naive form can wrap on `Int` overflow for adversarial `n`.
  All arithmetic in `Inflate`'s bigint/bit-reader code uses `&+`/`&-`/`&*`
  (wrapping operators) deliberately where ufbx relies on `uint32_t`/`uint64_t`
  wraparound semantics — do not "fix" these to trapping operators; that would
  diverge from ufbx on legal (if unusual) inputs and would also just crash on
  malformed ones instead of throwing.
- `readUInt8`/`readInt8` bypass the generic `readInteger<T>` LE/BE machinery
  (single byte has no endianness) — don't route single-byte reads through
  `loadLE`/`loadBE`, it's dead weight and the existing direct-index form is
  the pattern to follow for any new byte-sized accessor.
- `FloatParse`'s `BigInt` is fixed-capacity (`capacity: 42` limbs at all
  three call sites) with no growth/reallocation — it mirrors ufbx's
  stack-allocated array. If you ever need a larger intermediate, resize the
  `capacity:` argument at the allocation site rather than adding dynamic
  growth (dynamic growth would change performance characteristics ufbx never
  has and isn't needed — 42 limbs already covers the full double/float range
  ufbx supports).
- `Inflate.HuffTable`, `BitReader` are `private`/file-scoped structs — if a
  future subsystem needs raw Huffman decoding (unlikely), extend this file's
  public surface rather than duplicating the table-building logic.

## Dependencies & boundaries

- Imports only `Foundation` (for `Data` bridging in `DataReader`'s second
  initializer). No dependency on `Document/`, `Scene/`, `Loader/`, `Evaluate/`,
  `Geometry/`, or `Math/` — and nothing in those directories should leak back
  into `Core/`.
- Public surface consumed elsewhere: `Document/BinaryParser.swift` calls
  `Inflate.inflate(compressed, into: &out)` to decompress binary-FBX
  "compressed property" array blocks (zlib streams, binary FBX ≥ 6100).
  `Document/AsciiTokenizer.swift` and `Document/AsciiParser.swift` call
  `FloatParse.parseDouble`/`parseInt64` while tokenizing ASCII numeric
  literals. `DataReader` is used by `Document/BinaryParser.swift` and
  `Loader/ElementReader.swift`. `FBXError`/`FBXWarning` are used throughout
  the whole library (they're the sole error/warning vocabulary — see
  DESIGN.md's "Errors" convention: `throws FBXError`, non-fatal issues go to
  `scene.warnings: [FBXWarning]`).
- `DataReader` is `internal` (`struct`, no `public`), `Inflate`/`FloatParse`
  are `internal enum`s — none of these three are part of the public API
  surface. `FBXError`/`FBXWarning` (and `FBXErrorCode`) ARE public — they're
  the only public types in this directory.

## Testing

- `swift test --filter DataReaderTests` — LE/BE scalar round-trips,
  bit-pattern preservation for float/double, bounds-check throw coverage
  (`testSkipPastEndThrows`, `testReadUInt8PastEndThrows`,
  `testReadUInt32TruncatedThrows`, `testReadInt64TruncatedThrows`,
  `testReadBytesPastEndThrows`).
- `swift test --filter InflateTests` — stored/fixed/dynamic block decoding,
  fixture-based fixtures under `Tests/SwiftFBXTests/Resources/inflate/`.
- No standalone `FloatParseTests.swift` or `ErrorsTests.swift` exist yet —
  float-parser correctness is currently exercised indirectly through
  `AsciiParserTests.swift`/`BinaryParserTests.swift` and end-to-end through
  the golden suite (any regression in decimal parsing shows up as a numeric
  property mismatch in a golden diff). If you touch `FloatParse.swift`,
  prefer adding direct unit tests over relying solely on golden coverage.
- `swift test --filter GoldenTests` is the ultimate arbiter for both
  `Inflate` (every binary-FBX golden fixture with compressed arrays exercises
  it) and `FloatParse` (every ASCII golden fixture exercises it) — see
  `docs/DUMP_FORMAT.md` and `README.md` (`swift test` includes the golden
  parity suite).
- `MalformedInputTests.swift` / the fuzz corpus pass (DESIGN.md: "bounds
  checks throw `FBXError`") is the crash-safety net for all four files —
  never let a change here turn a caught `FBXError` into a Swift trap on
  adversarial input.

## Rules for the model

- Any behavior change in `Inflate.swift` or `FloatParse.swift` must keep
  `GoldenTests` at full parity (44/44) — these are bit-exact ports, not
  "close enough" reimplementations; re-run the golden suite after any edit.
- Before changing DEFLATE behavior, re-read
  `docs/ufbx-notes/01-inflate.md` (cites ufbx.c:1849-3280) and cross-check
  against `tools/ufbx/ufbx.c` at the cited lines — do not "fix" divergences
  from ufbx without confirming ufbx's behavior first, even if it looks like a
  bug (e.g. the byte-by-byte overlap-copy, the wrapping arithmetic).
- Before changing float-parsing behavior, re-read the "Float parsing" section
  of `docs/ufbx-notes/01-inflate.md` (same file covers both subsystems) and
  check the fast-path/bignum-path boundary constants against ufbx.c:1349-1846
  before touching them.
- Never replace a `throws FBXError` bounds/format check with a trap
  (`fatalError`, force-unwrap, unchecked subscript) to "simplify" code —
  every byte in these four files is attacker-controlled input; a trap here is
  a crash-safety regression, not a cleanup.
- Keep `FBXError.Code`/`FBXErrorCode` and `FBXWarning.Kind` as the two
  spellings/cases already present; if ufbx has an error/warning kind this port
  doesn't yet surface, add a new `case` rather than overloading `.unknown`
  with an `info` string that encodes the real kind.
- `DataReader`, `Inflate`, `FloatParse` must stay `Foundation`-only and free
  of any import from `Document/`, `Scene/`, `Loader/`, `Evaluate/`, or
  `Geometry/` — if a change here seems to need scene/document knowledge, that
  logic belongs in the calling layer, not in `Core/`.
