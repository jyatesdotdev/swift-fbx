# Binary Parse + Parse State Machine (ufbx.c 7684–9404)

## Purpose
This subsystem turns raw FBX bytes into a lightweight, in-memory node tree (`ufbxi_node`)
whose values are either a small list of scalar/string values or a single typed array.
It covers: FBX binary header/magic detection and version parsing, the recursive
binary node reader, all scalar/array type codes and their conversions, DEFLATE/plain
array decoding, and a *parse state machine* that (before reading any array bytes) decides
per node-path which children are arrays, what destination element type each array should
have, and whether strings must be kept raw (un-sanitized). It is the shared low-level
reader for both binary and ASCII paths (ASCII implements the same `ufbxi_node` shape).

## Key data structures

- **`ufbxi_node`** (6197): the coarse DOM node.
  - `name` (interned/pooled `const char*`; compare by pointer `==` against `ufbxi_*`
    string constants), `name_len` (uint8), `num_children` (uint32).
  - `value_type_mask` (uint16): if `== UFBXI_VALUE_ARRAY` (value 3) the node is an array
    and the `array` union member is valid; otherwise it packs up to 8 values, 2 bits each
    from LSB: `(mask >> (ix*2)) & 0x3` yields a `ufbxi_value_type`.
  - union `{ ufbxi_value_array *array; ufbxi_value *vals; }` + `ufbxi_node *children`.
- **`ufbxi_value_type`** (6179): `NONE=0, NUMBER=1, STRING=2, ARRAY=3`.
- **`ufbxi_value`** (6186): union of `{ double f; int64_t i; }` (NUMBER — both filled, see
  below) and `ufbxi_sanitized_string s` (STRING).
- **`ufbxi_value_array`** (6191): `void *data`, `size_t size`, `char type` (b/i/l/f/d — the
  *normalized* type, 'b' kept distinct from 'c' for bool post-processing).
- **`ufbxi_sanitized_string`** (4912): `raw_data` (const char*), `raw_length` (u32),
  `utf8_length` (u32). If `utf8_length > 0`, sanitized UTF-8 bytes live at
  `raw_data + raw_length + 1`. `utf8_length == UINT32_MAX` is a sentinel = "raw but invalid
  UTF-8" (no valid UTF-8 form). `utf8_length == 0` means the raw string is already valid.
- **`ufbxi_parse_state`** (7915): enum of ~60 states naming *where in the document tree*
  we are (ROOT, OBJECTS, MODEL, GEOMETRY, LAYER_ELEMENT_*, ANIMATION_CURVE, DEFORMER,
  TAKE/CHANNEL, legacy states, …). Drives array-type and raw-string decisions.
- **`ufbxi_array_info`** (7977): `char type` (FBX type code, or `'r'`=ufbx_real, `'-'`=ignore,
  `'s'/'S'/'C'`=string/content), `uint8_t flags` (`ufbxi_array_flags`).
- **`ufbxi_array_flags`** (7970): `RESULT=0x1` (alloc from result buffer), `TMP_BUF=0x2`
  (long-term temp buffer), `PAD_BEGIN=0x4` (prepend 4 zero elements to guard `-1` index
  accesses), `ACCURATE_F32=0x8` (must parse as bit-exact f32).
- **`ufbxi_deflate_task`** (8904): threaded-decode job (encoded/decoded/dst pointers, sizes,
  src/dst/arr types, inflate retain). Threading is OUT of v1 scope.

## Control flow / algorithms

### FBX value accessors (7684–7867)
- `ufbxi_normalize_array_type(type, bool_type)` (7686): `'r'` → `'f'` or `'d'` depending on
  `sizeof(ufbx_real)`; `'b'` → the passed `bool_type` (either `'c'` for storage or `'b'` to
  keep the bool tag); anything else unchanged.
- `ufbxi_array_type_size(type)` (7694): byte size per element. r=sizeof(ufbx_real), b=bool,
  c=1, i=4, l=8, f=4, d=8, s/S/C=sizeof(ufbx_string), default=1.
- `ufbxi_find_child` (7713) / `ufbxi_find_child_strcmp` (7869): linear scan of children.
  The first compares interned name *pointers* (`c->name == name`); the `_strcmp` variant is
  for names not guaranteed interned (compares leading char then `strcmp`).
- `ufbxi_get_val_at(node, ix, fmt, v)` (7731): reads value `ix` under a format char. Format
  chars: NUMBER family `I,L,F,D,R,B,Z` read from `vals[ix].i`/`.f` (type must be NUMBER;
  `Z`=size_t rejects negatives); STRING family `S,C` return sanitized UTF-8 (fail if
  `utf8_length==UINT32_MAX`), `s,c` return raw bytes, `b` returns a blob; `_` ignores.
  Because NUMBER stores *both* `.i` and `.f`, any numeric read works regardless of the wire
  type. Returns 0 on type mismatch (soft failure). `ufbxi_get_val1..5`, `ufbxi_find_val1/2`,
  `ufbxi_find_array` are thin wrappers.
- `ufbxi_get_array(node, fmt)` (7794): returns the array only if `value_type_mask` is ARRAY
  and (unless `fmt=='?'`) the normalized array type matches.
- Element-extra allocation (7881–7907): side table keyed by element id; not core to parse.

### Parse state machine (7909–8605)
- `ufbxi_update_parse_state(parent, name)` (7982): big switch mapping (parent state, child
  node name) → new child state. Name comparisons mostly by interned-pointer `==` against
  `ufbxi_*` constants, a few by `strcmp` for rarely-seen legacy names. Under OBJECTS,
  unrecognized names fall to `UFBXI_PARSE_UNKNOWN_OBJECT` (8022); some containers (TAKE,
  REFERENCES) map *any* child to a fixed state. Default → `UFBXI_PARSE_UNKNOWN`.
- `ufbxi_is_array_node(uc, parent, name, info)` (8092): given the parent state and child
  name, decides whether this node's payload is an *array* and fills `info->type`/`flags`.
  This is the master table that assigns destination element types **at load time** so data
  can be decoded straight into final memory. Highlights:
  - `retain_dom` forces `RESULT` flag on every array so the DOM keeps them (8097).
  - Geometry arrays (Vertices, Normals, UV, Colors, Tangents, Binormals, VertexCrease,
    TextureUV…) → `'r'` with `RESULT | PAD_BEGIN`; their `*Index` siblings → `'i'` with
    `RESULT` (8111–8419). `ignore_geometry` swaps the type to `'-'` (ignore) but still marks
    it an array so the bytes get skipped uniformly.
  - Index-only elements (EdgeCrease, Materials, PolygonGroup) get `RESULT` but *no*
    PAD_BEGIN. Smoothing/Visibility/Hole → `'b'` (bool) with `RESULT`.
  - AnimationCurve (8178): KeyTime→'l', KeyValueFloat→'r', KeyAttrFlags→'i',
    KeyAttrRefCount→'i'. **KeyAttrDataFloat** is the tricky one (see Quirks).
  - Deformer (8421): Transform/TransformLink/FullWeights→'r'; Indexes→'i'; Weights/
    BlendWeights→'r'. `FullWeights` goes to RESULT vs TMP_BUF based on `blender_full_weights`.
  - Video/Audio `Content` and default `BinaryData` → `'C'` (content/blob) unless
    `ignore_embedded` (→'-') (8210, 8489, 8497). Thumbnail `ImageData` → `'c'` RESULT.
  - LayeredTexture BlendModes→'i', Alphas→'r', both TMP_BUF (8217).
  - Returns false when the node is *not* an array (then it's parsed as scalar values).
- `ufbxi_is_raw_string(uc, parent, name, index)` (8508): decides whether a string value must
  be stored **raw** (bytes preserved, not UTF-8-sanitized). Under OBJECTS *all* strings are
  raw (8523). CONNECTIONS/RELATIONS are raw only when `version < 7000` (the pre-7000
  `Name\x00\x01Type` connection encoding, 8526). Many Name/NodeAttributeName/Content/Media
  fields are raw. This feeds the string-pool sanitize decision in the reader.

### Binary reading primitives (8607–8668)
- `ufbxi_swap_endian(uc, src, count, elem_size)` (8609): byte-reverses each element into a
  reused scratch buffer `uc->swap_arr`; supports elem_size 2/4/8. Only used when
  `file_big_endian != local_big_endian`.
- `ufbxi_swap_endian_array` (8648): swap a lowercase array by type (i/f→4, l/d→8, else
  passthrough). `ufbxi_swap_endian_value` (8658): swap one scalar's fixed prefix; note for
  the array-header case (`i l f d b`) it swaps **3 dwords** = size/encoding/encoded_size.

### Array type conversion (8672–8873)
- `ufbxi_binary_convert_array(uc, src_type, dst_type, src, dst, size)` (8672): converts a
  decoded array from wire type to destination type. If `src_type==dst_type` it's only
  called to fix endianness (asserts endianness differs). Otherwise a big
  dst×src switch of tight loops using `ufbxi_read_i16/i32/i64/f32/f64`. Float→int uses the
  saturating `ufbxi_f64_to_i32`/`_i64`. Commented-out identity cases mark the fast paths that
  never need conversion.
- `ufbxi_binary_parse_multivalue_array(uc, dst_type, dst, size, tmp_buf)` (8767): pre-7000
  path — the array is a *sequence of individually-typed scalar records*, concatenated into
  one array. String arrays (dst `s/S/C`) read each `'S'/'R'` record (u32 length + bytes);
  `C` copies bytes into result/tmp buffer, `s`/`S` push through the string pool. Numeric
  arrays have a fast path (little-endian, homogeneous type `I/L/F/D`) and a slow per-element
  switch accepting mixed `C/B/Y/I/L/F/D` records with saturating float→int casts.

### The core reader: `ufbxi_binary_parse_node` (8964–9398)
Recursion bounded by `depth < UFBXI_MAX_NODE_DEPTH` (=32) checked first (8970).
1. **Header** (8972–8997): `header_size = version>=7500 ? 25 : 13`. Read that many bytes
   (peek/consume via `ufbxi_read_bytes`). Fields, in order:
   - pre-7500: u32 `end_offset`, u32 `num_values`, u32 `values_len`, u8 `name_len`.
   - >=7500: u64 `end_offset`, u64 `num_values`, u64 `values_len`, u8 `name_len` (byte 24).
   Big-endian swaps the first 3 words (as 8- or 4-byte). `num_values` must fit u32 (8999).
2. **NULL sentinel** (9004): if `end_offset==0 && name_len==0`, set `*p_end=true`, return —
   this terminates a sibling list. (This is why files must end in a full 13/25-byte zero
   record; the reader relies on being able to peek 13 bytes safely, 9048.)
3. Push a zeroed `ufbxi_node` onto `tmp_stack` (9016). Read `name_len` bytes and intern into
   the string pool (9020). Compute `values_end_offset = read_offset + values_len` (9027).
4. **Array vs scalar** (9032): call `ufbxi_is_array_node`.
   - **Array branch** (9033–9254):
     - `dst_type = normalize(info.type, 'c')` (bool→'c' for storage); allocate an
       `ufbxi_value_array`; `arr->type = normalize(info.type, 'b')` (keeps 'b' tag).
     - Peek 13 bytes; `c = data[0]` is the wire array type tag. Overrides: if `num_values==0`
       set `c='0'` (empty); if `dst_type=='-'` set `c='-'` (ignore) (9059).
     - If `c ∈ {c,b,i,l,f,d}` (real post-7000 array, 9064): parse the **array header** that
       follows the 1 tag byte — u32 `size`, u32 `encoding`, u32 `encoded_size` (big-endian
       swaps these 3 dwords), then `consume 13` bytes total (1 tag + 12 header). Normalize
       `src_type` (except `'r'` left alone to fail later if mismatched); compute
       `decoded_data_size = src_elem_size * size`. Allocate `arr_data` via
       `ufbxi_push_array_data`.
       - Pick a decode target: read straight into `arr_data` when
         `src_type==dst_type` and endianness matches; else decode into `uc->tmp_arr` then
         convert (9140).
       - `encoding==0`: plain bytes; assert `encoded_size==decoded_data_size`. If the bytes
         are already in the read buffer and we need a separate conversion buffer anyway, it
         *aliases the read buffer directly* (zero-copy, with a yield-threshold fixup,
         9155–9164); otherwise `ufbxi_read_to`.
       - `encoding==1`: DEFLATE via `ufbx_inflate` into `decoded_data`; must return exactly
         `decoded_data_size` else "Bad DEFLATE data" (9223). Handles the case where the
         compressed data spans past the buffered region by wiring `read_fn`/`read_buffer`
         into the inflate input (9203).
       - Else "Bad array encoding" (9226).
       - If decoded into a scratch buffer, `ufbxi_binary_convert_array` into `arr_data`
         (9231). Set `arr->data/size`.
     - If `c=='0'` or `c=='-'` (9237): empty/ignored — `arr->data` points at a shared zero
       buffer (`ufbxi_zero_size_buffer + 32`), size 0, type set to `'-'` for ignore.
     - Else (9242, pre-7000): allocate `num_values` elements and call
       `ufbxi_binary_parse_multivalue_array`; size = num_values.
     - **Bool post-process** (9252): if `info.type=='b'`, run `ufbxi_postprocess_bool_array`
       (maps each byte to 0/1) — unless deferred to a thread.
   - **Scalar branch** (9256–9357): `num_values = min(num_values, 8)` (UFBXI_MAX_NON_ARRAY_
     VALUES). Push `num_values` `ufbxi_value`. Loop, peek 13, `type=data[0]`, `value=data+1`
     (big-endian swaps the value prefix). Per type code:
     - `C/B/Z`: 1-byte, stored as unsigned byte → both `.i` and `.f`; consume 2.
     - `Y`: i16 → consume 3. `I`: i32 → consume 5. `L`: i64 → consume 9.
     - `F`: f32 → `.f`, `.i = f64_to_i64(.f)` → consume 5. `D`: f64 → consume 9.
     - `S`/`R`: u32 length + bytes (consume 5 then read `length`). Empty string → shared
       empty. Otherwise hash + ASCII check; `raw = !non_ascii || is_raw_string(...)`;
       push sanitized; if `non_ascii && raw`, set `utf8_length=UINT32_MAX` (invalid-UTF-8
       sentinel). Type STRING.
     - `c/b/i/l/f/d` (an array appearing where a scalar is expected): skip it — read
       encoded_size at `value+8`, consume 13, `ufbxi_skip_bytes(encoded_size)` (9342).
     - default → "Bad value type".
     - Store `value_type_mask = type_mask`.
5. **Trailing skip** (9359): if current offset < `values_end_offset`, skip the difference
   (handles truncated value lists and values after an array). Assert we didn't overrun.
6. **Recursion** (9367): if `recursive`, compute child parse state via
   `ufbxi_update_parse_state`, loop reading children until `current_offset >= end_offset`
   (assert exact match, or `end_offset==0`) or a NULL sentinel returns `end`. Pop the
   children off `tmp_stack` into a contiguous array. If not recursive, just set
   `uc->has_next_child = (current_offset < end_offset)` — this drives the lazy top-level
   reader `ufbxi_parse_toplevel` (11253, outside span).

### Header / version detection: `ufbxi_begin_parse` (11193, just outside span)
Peek `UFBXI_BINARY_HEADER_SIZE`=27 bytes. If it starts with the 22-byte binary magic:
byte 22 = endianness (nonzero ⇒ big-endian), bytes 23–26 = u32 version (endian-swapped if
needed), consume 27, set `sure_fbx`. Else treat as ASCII: default `version=7400` when not
otherwise found (unless `strict`).

## Format details
- **Binary magic** (9402): `"Kaydara FBX Binary  \x00\x1a"` — exactly 22 bytes
  (`UFBXI_BINARY_MAGIC_SIZE`=22); note the **two ASCII spaces** before `\x00\x1a`.
  Full header size `UFBXI_BINARY_HEADER_SIZE`=27 = 22 magic + 1 endian byte + 4 version.
- **Endian byte**: header[22]; `!= 0` ⇒ big-endian file. (Real FBX files are little-endian;
  big-endian support is defensive.)
- **Version**: u32 at header[23..26]. Thresholds that change behavior:
  - `>= 7500`: node header uses 64-bit end_offset/num_values/values_len (header 25 bytes,
    name_len at byte 24). Below: 32-bit (header 13 bytes, name_len at byte 12).
  - `>= 7200` (ASCII only): `KeyAttrDataFloat` array stored as `'i'` integers not floats.
  - `< 7200` (ASCII): `KeyAttrDataFloat` needs `ACCURATE_F32` flag (bit-exact f32 parse).
  - `< 7000`: Connections/Relations strings are raw (`Name\x00\x01Type` pairs); also selects
    the multivalue (concatenated-scalar) array path in general.
  - ASCII default when unknown/non-strict: 7400.
- **Node header layout** (post-7500 → pre-7500):
  `end_offset` (u64/u32), `num_values` (u64/u32), `values_len` (u64/u32), `name_len` (u8),
  then `name_len` name bytes, then the value records, then children, then a NULL record.
- **Scalar value type codes** (in the value stream): `Y`=i16(3B total), `C`/`B`=1-byte
  bool/char(2B), `Z` (size_t, 1-byte here), `I`=i32(5B), `L`=i64(9B), `F`=f32(5B),
  `D`=f64(9B), `S`=string, `R`=raw string (both: u32 len + bytes).
- **Array wire type codes**: lowercase `c`(u8/bool bytes), `b`(bool), `i`(i32), `l`(i64),
  `f`(f32), `d`(f64). Array record = 1 tag byte + u32 length + u32 encoding + u32
  encoded_size + encoded bytes.
- **Array encoding**: `0` = raw/plain (encoded_size must equal size*elem_size); `1` =
  zlib/DEFLATE (inflated size must equal size*elem_size). Any other = error.
- **NULL sentinel record**: all-zero header (13 or 25 bytes); `end_offset==0 && name_len==0`.
- **Shared zero buffer**: `ufbxi_zero_size_buffer` (3619) — 4096 bytes (64 in some builds);
  empty arrays point at `+ 32` into it.
- **Limits**: `UFBXI_MAX_NON_ARRAY_VALUES`=8 (51), `UFBXI_MAX_NODE_DEPTH`=32 (52).

## Quirks & edge cases
- **KeyAttrDataFloat mixed-type hack** (8188–8196): "float data … represented as integers
  in versions >= 7200 as some of the elements aren't actually floats(!)". So for
  ASCII+`version>=7200` the destination type is `'i'`, not `'f'`; and for ASCII+`<7200` the
  `ACCURATE_F32` flag forces bit-exact 32-bit float parsing. Miss this and animation tangent
  flags corrupt.
- **PAD_BEGIN guard** (7973, 8879–8892): position-like arrays get 4 zero elements prepended
  so a stray `-1` (or up to -4) index doesn't read out of bounds. The returned pointer is
  advanced past the padding; consumers index from 0 normally. Applies to Vertices, Normals,
  UV, Colors, Tangents, Binormals, VertexCrease, W-arrays, TextureUV, TextureUVVerticeIndex.
- **`num_values==0` overrides wire tag to `'0'`** (9059) and **`dst_type=='-'` overrides to
  `'-'`** so empty/ignored arrays are handled without touching payload bytes.
- **Zero-copy plain-array aliasing** (9155–9164): when an uncompressed array is fully inside
  the current read buffer *and* a conversion buffer is needed, ufbx points `decoded_data`
  straight at the buffer and just consumes bytes — a performance trick, not semantics. It
  also nudges the yield threshold. Swift can just copy.
- **`'r'` src_type left un-normalized** (9081): if a wire array literally used `'r'` (should
  never happen) it stays 'r' so a later mismatch fails loudly rather than silently.
- **Saturating float→int** (`ufbxi_f64_to_i32/_i64`, 1112/1121): out-of-range doubles clamp
  to INT*_MAX/MIN instead of UB. Used in every float→int array/scalar conversion.
- **Both `.i` and `.f` filled for numbers** (9282+): every numeric scalar stores integer and
  double forms so `ufbxi_get_val_at` can satisfy any numeric format request without knowing
  the wire type. `F`/`D` set `.i` via the saturating cast.
- **Raw-string sentinel** `utf8_length==UINT32_MAX` (9334): marks a string kept raw that has
  no valid UTF-8 form; `S`/`C` accessors reject it (return 0) while `s`/`c` still return raw
  bytes.
- **Endian swap of array header swaps 3 dwords** (8665, 9068): size+encoding+encoded_size
  are swapped together; easy to get wrong if you only swap one.
- **Bool arrays**: wire type may be `c` or `b`; stored as bytes, then
  `ufbxi_postprocess_bool_array` normalizes every byte to exactly 0/1 (9252, 8897). The
  `arr->type` retains `'b'` to trigger this even though storage element is 1 byte.
- **Values-after-array / truncated values** (9359): the reader trusts `values_len` to skip
  to the real end, tolerating extra or missing value bytes.
- **end_offset==0 tolerance in child loop** (9376): allows a node whose children run to the
  parent's end without a recorded end_offset.
- **`ignore_geometry`/`ignore_animation`/`ignore_embedded`** flip the destination type to
  `'-'` so bytes are parsed-and-discarded uniformly (arrays still consumed, never left in
  the stream). `retain_dom` forces RESULT allocation on all arrays and keeps some otherwise-
  dropped DOM arrays (e.g. Texture ModelUV*, LayerElementOther UV, 8204/8382).
- **Legacy (pre-7000) arrays are heterogeneous scalar sequences** (8767) — a completely
  different code path from post-7000 typed arrays. Must be ported for FBX 6100 support.
- **Threading** (`parse_threaded`, 9097; `ufbxi_deflate_task`) — OUT of v1 scope; ignore the
  `deferred` branches and decode inline.

## Port guidance
- **Port faithfully**: the parse state machine (`ufbxi_update_parse_state`,
  `ufbxi_is_array_node`, `ufbxi_is_raw_string`) is *the* semantic table — replicate every
  entry, including `ignore_*`/`retain_dom` behavior and the version-dependent branches.
  Also port faithfully: node header layout & version thresholds, all type-code sizes/consume
  amounts, saturating float→int, PAD_BEGIN, bool post-processing, the raw-string sentinel,
  and encoding 0/1 handling.
- **Swift shapes**:
  - `ufbxi_node` → a class or struct with an enum payload:
    `enum NodePayload { case values([FBXValue]); case array(FBXArray) }` where
    `enum FBXValue { case number(i: Int64, f: Double); case string(SanitizedString) }`.
    Keep both int+double in `.number` to preserve the "any numeric read works" property, or
    store the wire scalar and convert on demand.
  - `FBXArray` → hold a typed Swift storage (`[Int32]`, `[Int64]`, `[Float]`, `[Double]`,
    `[UInt8]`) — an enum-of-arrays maps cleanly onto the `b/i/l/f/d` type char.
  - Type codes → a `ScalarTypeCode`/`ArrayTypeCode` enum; the `ufbxi_get_val_at` format
    chars become typed accessor methods (`node.int32(at:)`, `node.string(at:)`) that throw
    or return optionals instead of the 0/1 convention.
  - `ufbxi_parse_state` → a Swift enum, driven by a `switch` identical in structure. Replace
    interned-pointer name comparisons with a small interned-name enum or a `StaticString`
    keyed dictionary; note some comparisons intentionally use `strcmp` for un-interned names.
  - Errors → throw instead of the `ufbxi_check` 0/1 return protocol; "Bad DEFLATE data",
    "Bad array encoding", "Bad value type", "Bad multivalue array type" become error cases.
- **Replace with Swift idioms**: buffer/yield/zero-copy machinery (`ufbxi_peek_bytes`,
  `read_to`, buffer aliasing at 9155) → read from `Data`/a cursor; the "shared zero buffer"
  → an empty Swift array. Skip: threading (`ufbxi_deflate_task`, `parse_threaded`),
  progress callbacks, custom allocators/IO, DOM retention option (`retain_dom`) beyond what
  the low-level DOM API needs.
- **Big-endian**: real files are LE; can keep a swap path but it's low priority. Decide once
  and reuse across the array/scalar readers.
- **Cross-subsystem dependencies**:
  - FEEDS scene construction: the parse state machine's array-type/flag decisions (positions
    as PAD_BEGIN 'r', indices as 'i', bool layer arrays) are exactly what the mesh/skin/
    blend-shape/animation builders consume. Keep type chars consistent with those builders.
  - DEPENDS ON DEFLATE (`ufbx_inflate`) for encoding==1 arrays (separate subsystem).
  - DEPENDS ON the string pool / `ufbxi_push_sanitized_string` + `ufbxi_is_raw_string` for
    string handling and the UTF-8 sentinel.
  - SHARED WITH ASCII parser: both produce `ufbxi_node`; `ufbxi_update_parse_state`,
    `ufbxi_is_array_node`, `ufbxi_is_raw_string`, and the value accessors are used by both,
    and `KeyAttrDataFloat` logic keys off `from_ascii`.
  - CALLED BY `ufbxi_parse_toplevel` / `ufbxi_begin_parse` (11193/11253) which own header
    detection and the lazy top-level node cache (`has_next_child`, `top_nodes`).
```
