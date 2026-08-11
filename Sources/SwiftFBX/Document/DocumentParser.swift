import Foundation

// Top-level document parse driver: format/version detection + eager
// top-level-section parsing. Port of `ufbxi_determine_format` +
// `ufbxi_begin_parse` (ufbx.c:11130-11240), which is the part of
// `ufbxi_load_imp` (ufbx.c:25286-25298) that turns a raw byte buffer into the
// coarse `ufbxi_node` tree later stages (header extension, definitions,
// objects, connections, takes, ...) walk by name. Those later stages live in
// `Loader/ElementReader.swift` etc. (wave 4) — this file's only job is
// producing a fully-populated `FBXDocument` (notes 04).
//
// The binary and ASCII tokenizer/parsers (`BinaryParser`, `AsciiParser`,
// notes 02/03) already expose convenience entry points
// (`parseBinaryDocument`/`parseAsciiDocument`) that detect their own header
// (magic/endianness/version for binary; magic-comment/`FBXVersion:` version
// for ASCII) and eagerly parse every top-level node into a synthetic root.
// That eager-everything-up-front shape is a deliberate simplification of
// ufbx's `ufbxi_parse_toplevel` name-keyed lazy/eager hybrid cache: ufbx
// avoids a second file pass over a *streamed* IO source by only parsing a
// requested section's children on demand, but since this port always holds
// the whole file in memory as `[UInt8]`, there is no streaming cost to avoid
// — parsing every top-level node once up front is behaviorally identical
// (notes 04, "top-level lazy/eager cache ... can likely be simplified") and
// is what feeds DOM retention drain in ufbx anyway (DOM retention itself is
// out of v1 scope). This file therefore reduces to: empty-file check, then
// binary-vs-ASCII dispatch by magic sniff.
public extension FBXDocument {
    /// Parse a complete in-memory FBX file (binary or ASCII, versions
    /// 6100-7700) into a low-level `FBXDocument`. Mirrors the format/version
    /// detection done by `ufbxi_determine_format` + `ufbxi_begin_parse`
    /// (ufbx.c:11130-11240); element-level reading (header extension,
    /// definitions, objects, connections, takes, global settings, ...)
    /// happens later, in the `Loader` stages.
    static func parse(data: Data, options: FBXLoadOptions = .init()) throws -> FBXDocument {
        try options.validateSourceByteCount(data.count)

        // ufbx: `ufbxi_determine_format` fails with "Empty file" before even
        // attempting content sniffing when its lookahead window comes back
        // with zero bytes (ufbx.c:11144-11145, `ufbxi_check_msg(data_size > 0,
        // "Empty file")`). v1 only supports the FBX container (no OBJ/MTL), so
        // there is nothing else `ufbxi_determine_format` would do here.
        guard !data.isEmpty else {
            throw FBXError(.unrecognizedFileFormat, "Empty file")
        }

        let bytes = [UInt8](data)
        let arrayBudget = FBXDecodedArrayBudget(options: options)

        // ufbx: `ufbxi_begin_parse` (ufbx.c:11193-11240) — binary iff the
        // first `UFBXI_BINARY_MAGIC_SIZE` (22) bytes equal
        // `"Kaydara FBX Binary  \x00\x1a"`; endianness is byte 22 (`0` =
        // little, nonzero = big) and the version is the little/big-endian
        // uint32 at bytes 23-26, byte-swapped per that flag
        // (`BinaryParser.detectHeader`, used internally by
        // `parseBinaryDocument`). `detectHeader` leaves the reader untouched
        // and returns `nil` when the magic doesn't match, so falling through
        // to the ASCII path on a `nil` result is always safe — no bytes are
        // consumed or otherwise observed by a failed binary sniff.
        if let doc = try BinaryParser.parseBinaryDocument(bytes, arrayBudget: arrayBudget) {
            return doc
        }

        // ufbx: anything not binary-magic-prefixed is handed to the ASCII
        // tokenizer/parser (`uc->from_ascii = true`, ufbx.c:11219). Version is
        // picked up live rather than from a fixed header: either from the
        // leading `; FBX 7.x.y project file` magic comment
        // (`AsciiTokenizer` version tracking, ufbx.c:9564-9577, ported in
        // `AsciiTokenizer.parseVersion`/`skipWhitespace`), or — if that magic
        // comment is absent or unrecognized — from an explicit `FBXVersion:`
        // integer node under `FBXHeaderExtension` encountered while parsing
        // (`AsciiParser.parseNode`'s `parseState == .fbxVersion` fallback,
        // ufbx.c:9568-9576 mirrored at binary ufbx.c:10460); with neither
        // present it defaults to version 7400 (v1 never runs in `opts.strict`
        // mode, ufbx.c:11234, matching `AsciiParser.parseAsciiDocument`).
        // A buffer that isn't "sure" FBX (no version found) *and* whose first
        // top-level token isn't a `Name:` throws `.unrecognizedFileFormat`
        // from inside `AsciiParser.parseNode` — the `sure_fbx` strictness gate
        // (ufbx.c:10305-10307) — which is this port's defense against
        // misidentifying arbitrary text as FBX (notes 04, "sure_fbx
        // strictness gate").
        return try AsciiParser.parseAsciiDocument(bytes, arrayBudget: arrayBudget)
    }
}
