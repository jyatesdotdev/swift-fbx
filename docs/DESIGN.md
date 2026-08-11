# SwiftFBX Design

A pure-Swift port of [ufbx](https://github.com/ufbx/ufbx) (vendored reference at
`tools/ufbx/`, see `tools/ufbx/VERSION` for the git revision). Subsystem port notes
live in `docs/ufbx-notes/` — implementers MUST read the notes for their module plus
the cited `ufbx.c` lines before writing code.

## Scope (v1)

- Binary FBX 7100–7700 (32/64-bit records, big-endian variants) and ASCII FBX 6100–7700.
- Pure-Swift DEFLATE decompression (port of `ufbx_inflate`) + locale-independent
  float parsing (port of `ufbxi_parse_double`).
- Low-level document API (node tree with typed values) — public.
- Scene graph: nodes (full FBX transform chain), meshes (all vertex attributes,
  edges, smoothing, material assignment), materials (FBX maps — the FBX-side
  `fetchMaps` port is REQUIRED in v1; PBR maps are stretch), textures, videos
  (content presence only), lights, cameras, bones, skin deformers, blend
  deformers, poses (data), anim stacks/layers/values/curves.
- Takes reading for ALL versions: pre-7000 it builds the whole animation; for
  ≥7000 it back-fills stack time ranges (`LocalTime`/`ReferenceTime` →
  `LocalStart`/`LocalStop`) when the stack has no props (ufbx.c:15913, notes 07).
- Animation evaluation: curve interpolation (constant/linear/cubic with
  tangents, Newton-Raphson bezier solve), layered prop evaluation, transform
  evaluation.
- NGON triangulation utility.
- Deterministic ordering identical to ufbx (verified by golden dumps).

Out of scope v1: OBJ/MTL, NURBS, subdivision, geometry caches, baking, axis/unit
conversion options (`target_axes` etc. — the *stages* exist as no-ops/skeletons),
progress callbacks, custom IO, threading, embedded texture decoding, PBR material
maps, legacy <6100 formats.

## Package layout

Single library target `SwiftFBX`, helper library `FBXDumpCore`, executable
`fbx-dump`, test target.

```
Sources/SwiftFBX/
  Math/Math.swift              FBXVec2/3/4, FBXQuat, FBXMatrix (3x4), FBXTransform,
                               euler conversion, matrix compose/invert
  Core/Errors.swift            FBXError, FBXErrorCode, FBXWarning(+types)
  Core/DataReader.swift        byte cursor over [UInt8]: LE/BE scalars, floats
  Core/Inflate.swift           DEFLATE (port of ufbx_inflate; notes 01)
  Core/FloatParse.swift        parseDouble/parseInt64 (notes 01)
  Document/Value.swift         FBXValue, FBXArrayValue
  Document/Document.swift      FBXDocument, FBXDocNode, FBXFormat
  Document/ParseState.swift    shared parse state machine + array/raw-string tables
                               (notes 02/03, ufbx.c:7982–8605) — used by BOTH parsers
  Document/BinaryParser.swift  binary records → FBXDocNode tree (notes 02)
  Document/AsciiTokenizer.swift
  Document/AsciiParser.swift   ASCII → FBXDocNode tree (notes 03)
  Document/DocumentParser.swift  format detect, version detect, drive parse (notes 04)
  Scene/Properties.swift       FBXProp, FBXPropType/Flags, FBXProps (notes 05)
  Scene/Elements.swift         FBXElement, FBXElementType, FBXConnection,
                               FBXElementList<T> + typealiases
  Scene/Node.swift             FBXNode
  Scene/Mesh.swift             FBXMesh, FBXVertexAttrib, FBXUVSet, FBXColorSet
  Scene/Material.swift         FBXMaterial, FBXMaterialMap, FBXMaterialFBXMaps,
                               FBXTexture, FBXVideo
  Scene/Attributes.swift       FBXLight, FBXCamera, FBXBone, FBXEmpty (+enums)
  Scene/Deformers.swift        FBXSkinDeformer/Cluster, FBXBlendDeformer/Channel/Shape
  Scene/Animation.swift        FBXAnimStack/Layer/Value/Curve, FBXAnimProp,
                               FBXKeyframe, FBXTangent, FBXAnim
  Scene/Scene.swift            FBXScene, FBXMetadata, FBXSceneSettings,
                               FBXCoordinateAxis/Axes, FBXTimeMode
  Loader/LoadOptions.swift     FBXLoadOptions
  Loader/LoadContext.swift     LoadContext, TmpConnection, TemplateKey (internal)
  Loader/Loader.swift          load driver assembling all stages
  Loader/ElementReader.swift   doc → elements: header ext, templates, object
                               dispatch, model/attrib readers (notes 05)
  Loader/GeometryReader.swift  mesh/vertex-attribute reading (notes 05)
  Loader/AnimationReader.swift materials/textures/videos/deformers/anim objects,
                               connections (notes 06)
  Loader/TakesReader.swift     Takes for all versions (notes 07)
  Loader/SceneLinker.swift     connection resolve, hierarchy, linearize,
                               fetch-wiring + sort comparators (notes 08, 09)
  Loader/SceneFinalizer.swift  update_* equivalents: props → fields, transform
                               chain, world matrices, material fetchMaps, mesh
                               parts, video content resolve (notes 09, 10)
  Evaluate/CurveEval.swift     keyframe interpolation (notes 11)
  Evaluate/AnimEval.swift      prop/transform evaluation, layer blending (notes 11)
  Geometry/Triangulate.swift   ngon triangulation (notes 12)
Sources/FBXDumpCore/SceneDump.swift  golden-format JSON builder (docs/DUMP_FORMAT.md):
                               `public enum SceneDump { public static func build(scene:filename:) -> [String: Any] }`
Sources/fbx-dump/main.swift    CLI wrapper: load file → SceneDump → JSON to stdout
Tests/SwiftFBXTests/
  JSONCompare.swift            tolerant structural JSON comparison (WRITTEN)
  GoldenTests.swift            fbx/*.fbx vs golden/*.json via SceneDump (WRITTEN)
  <Module>Tests.swift          unit tests per module
```

## API conventions

- All public types prefixed `FBX`. `Double` everywhere (`ufbx_real == double`),
  EXCEPT bit-exact float paths (ACCURATE_F32 / `KeyAttrDataFloat`) which round
  through `Float` (notes 02/03). Float→int conversion is SATURATING, not
  truncating (port `f64_to_i32/i64`).
- Math types are plain structs, `Sendable`, `Equatable`. `FBXMatrix` is ufbx's
  3×4 affine layout (`cols.0..3`, each an `FBXVec3`).
- Errors: `throws FBXError` — struct with `code: FBXErrorCode` (mirrors relevant
  `UFBX_ERROR_*`), `info: String`. Non-fatal issues → `scene.warnings:
  [FBXWarning]` (this is the ONE warnings location; nothing on metadata).
- Strings: decoded with `String(decoding:as: UTF8.self)` (invalid → U+FFFD, ufbx
  default). Raw-string paths (per `isRawString`) preserve bytes as `Data`.
- **Public-surface rule**: `FBXDumpCore` imports `SwiftFBX` WITHOUT `@testable`,
  so every value named in `docs/DUMP_FORMAT.md` MUST be reachable via `public`
  getters on the element types. When in doubt, `public internal(set)`.
- **Freeze rule**: nothing (elements, scene, doc nodes) is mutated after `load`
  returns. Do not add lazy/memoized `var`s to shared classes — that silently
  breaks the `@unchecked Sendable` promise.

## Ownership model (the one big Swift-specific decision)

FBX scenes are cyclic graphs (node ↔ mesh.instances, parent ↔ children). To
avoid ARC retain cycles and mirror ufbx's id design:

- `FBXScene` is the arena: it strongly owns every element (`elements:
  [FBXElement]` in element_id order, plus typed arrays `nodes`, `meshes`, … in
  ufbx order).
- Every element is a `final class` subclass of `FBXElement`, holding
  `unowned let scene: FBXScene`. The scene is constructed (empty) BEFORE any
  element, via an internal `init()`; `FBXMetadata()`/`FBXSceneSettings()` have
  empty/default initializers; `rootNode` starts nil.
- **Uniform id rule**: every stored cross-reference field named `*ID: Int32` is
  an **element_id** (index into `scene.elements`), −1 = none. Public accessors
  downcast: `scene.elements[Int(id)] as! FBXNode`. (`typedID` on each element
  gives its position in its typed array — that's what the dumper emits.)
- List views: `FBXElementList<T: FBXElement>: RandomAccessCollection` storing
  `(unowned scene, elementIDs: [Int32])`, subscript downcasts with `as! T`.
  `public typealias FBXNodeList = FBXElementList<FBXNode>` etc.
- Mutability: `scene`, `elementID`, `type`, `fbxID` are `let`; `name`, `props`,
  `typedID` and all data fields are `internal(set) var` (mutated during load,
  frozen after by convention).
- `FBXScene`, `FBXElement` subclasses, `FBXDocument`, `FBXDocNode`, `FBXProps`
  are `@unchecked Sendable` under the freeze rule.

## Load pipeline (mirrors ufbxi_load_imp, ufbx.c:25286–25369)

```
Data
 → detect format + version                                 DocumentParser (notes 04)
 → parse to FBXDocument                                    Binary/AsciiParser + ParseState
   (arrays inflated + converted per ParseState,              + Inflate (notes 01–03)
    PAD_BEGIN prefixes, saturating conversions)
 → read header extension, definitions/templates            ElementReader (notes 05)
 → read objects → typed elements + props + raw arrays      ElementReader/GeometryReader/
   + tmpConnections (never resolved here)                    AnimationReader (notes 05/06)
 → read Takes (6100: full anim; ≥7000: stack time-range    TakesReader (notes 07)
   back-fill by stack name when props empty)
 → pre-finalize (helper-node synthesis — v1: no-op under   SceneLinker (notes 08)
   default options, but instance counts etc. as needed)
 → finalize: resolve connections (dangling → dropped),     SceneLinker (notes 08/09)
   assign ids, linearize nodes (reassign node typedIDs),
   wire every cross-ref with ufbx's exact sort comparators
 → scene settings, axis/unit conversion (v1: no-op),       SceneFinalizer (notes 09/10)
   adjust transforms, update_* per element: props→fields,
   transform chain, world matrices, material fetchMaps,
   video content presence, mesh parts, stack time ranges
 → FBXScene
```

Implementation rule: **when in doubt, do what ufbx.c does** — including quirks,
default values, sort orders, and clamps. Golden tests compare against real ufbx
output; behavioral fidelity is the acceptance criterion. Cite the ufbx.c line
you ported in a comment ONLY where behavior is non-obvious (quirks, magic
defaults), formatted `// ufbx: <what/why>` — not for routine code.

Known fidelity traps (from review — implementers MUST honor):
- Synthetic fbx_ids are used for ALL `version < 7000` objects (includes 6100):
  no numeric id in the file → id = hash of interned `Type::Name` per notes 07/08.
- `InheritType` int → mode mapping is NOT ordinal: `0 → componentwiseScale`,
  `2 → ignoreParentScale`, everything else (incl. default 1 / unset) → `normal`
  (ufbx.c:12608–12622).
- Transform chain: `T·Roff·Rp·Rpre·R·Rpost⁻¹·Rp⁻¹·Soff·Sp·S·Sp⁻¹`, PostRotation
  INVERTED, Pre/Post always XYZ order, only Lcl Rotation uses `rotation_order`
  (notes 10).
- Swift `sort` is not stable — always tie-break (elementID) or sort an indexed
  projection.

## Internal contracts (implementation waves build against these — do not drift)

### Document layer

```swift
public enum FBXFormat: Sendable { case binary, ascii }     // Document/Document.swift

public enum FBXValue: Sendable {
    case bool(Bool), int32(Int32), int64(Int64), float(Float), double(Double)
    case string(String)                   // UTF-8 sanitized (U+FFFD replacement)
    case raw(Data)                        // raw-bytes strings (isRawString paths)
}
public enum FBXArrayValue: Sendable {
    case bool([Bool]), int32([Int32]), int64([Int64])
    case float([Float]), double([Double]), raw(Data)
}
public final class FBXDocNode: @unchecked Sendable {
    public let name: String
    public internal(set) var values: [FBXValue]
    public internal(set) var array: FBXArrayValue?   // set iff parsed as array node
    public internal(set) var children: [FBXDocNode]
    // helpers: child(_:), children(_:), int64(at:), int32(at:), double(at:),
    // string(at:), rawString(at:) — nil on missing/type mismatch, with the same
    // lenient numeric coercions as ufbxi_get_val* (notes 02)
}
public final class FBXDocument: @unchecked Sendable {
    public let version: Int               // e.g. 7500; 6100 for ASCII 6.1
    public let format: FBXFormat
    public let bigEndian: Bool
    public internal(set) var root: FBXDocNode   // synthetic root of top-level nodes
    public static func parse(data: Data, options: FBXLoadOptions = .init()) throws -> FBXDocument
}
```

`FBXLoadOptions` bounds hostile-input resource amplification. Its positive
`maximumSourceBytes`, `maximumDecodedArrayBytes`, and
`maximumDecodedArrayElements` values are enforced for both document and scene
entry points. The decoded limits cover aggregate document-array payloads;
temporary typed conversion buffers are a bounded multiple of each claimed
payload, while scalar/node/linker storage remains indirectly bounded by the
source byte limit.

Array nodes are converted at parse time to the destination type chosen by
`ParseState` (incl. PAD_BEGIN zero-prefixes and saturating float→int) — the
document stores what ufbx's `ufbxi_node` would (notes 02/03).

### Properties (Scene/Properties.swift)

```swift
public struct FBXProp: Sendable {
    public var name: String
    public var type: FBXPropType          // mirrors ufbx_prop_type
    public var flags: FBXPropFlags        // OptionSet
    public var valueString: String
    public var valueBlob: Data
    public var valueInt: Int64
    public var valueVec4: FBXVec4         // components beyond arity are 0
}
public final class FBXProps: @unchecked Sendable {
    public internal(set) var props: [FBXProp]     // sorted per ufbx order (notes 05)
    public internal(set) var defaults: FBXProps?  // template chain
    // find(_:) binary search; findVec3/Real/Int/String with default args
}
```

### Elements & scene (Scene/Elements.swift, Scene/Scene.swift)

```swift
public class FBXElement: @unchecked Sendable {
    public unowned let scene: FBXScene
    public internal(set) var name: String
    public internal(set) var props: FBXProps
    public let elementID: Int             // dense, creation order, all elements
    public internal(set) var typedID: Int // per-type; nodes reassigned at linearize
    public let type: FBXElementType
    var fbxID: UInt64                     // internal; file identity
    var connectionsSrc: Range<Int> = 0..<0   // slices into scene.connections
    var connectionsDst: Range<Int> = 0..<0   // (via connectionsDstOrder)
    public internal(set) var instanceIDs: [Int32] = []  // element_ids of nodes
    public var instances: FBXNodeList { get }           // referencing this attrib
}

public struct FBXConnection: Sendable {
    public let srcID: Int32               // element_id
    public let dstID: Int32               // element_id
    public let srcProp: String            // empty for OO
    public let dstProp: String
}

public final class FBXScene: @unchecked Sendable {
    public internal(set) var metadata: FBXMetadata = .init()
    public internal(set) var settings: FBXSceneSettings = .init()
    public internal(set) var elements: [FBXElement] = []
    public internal(set) var nodes: [FBXNode] = []     // [0] root, depth-sorted
    public internal(set) var meshes: [FBXMesh] = []    // creation order
    // … one typed array per element type (incl. videos, poses, animValues,
    //   animCurves, skinClusters, blendChannels, blendShapes), ufbx ordering
    public internal(set) var connections: [FBXConnection] = []  // sorted by src
    public internal(set) var connectionsDstOrder: [Int32] = []  // perm sorted by dst
    public internal(set) var rootNode: FBXNode!
    public internal(set) var warnings: [FBXWarning] = []
    init() {}                                           // internal: arena-first
    public static func load(contentsOf url: URL, options: FBXLoadOptions = .init()) throws -> FBXScene
    public static func load(data: Data, options: FBXLoadOptions = .init()) throws -> FBXScene
}

public struct FBXMetadata: Sendable {
    public var version: Int = 0
    public var ascii: Bool = false
    public var bigEndian: Bool = false
    public var creator: String = ""
    public var filename: String = ""      // basename; set by load(contentsOf:)
    public init() {}
}
public enum FBXCoordinateAxis: Int, Sendable {
    case positiveX, negativeX, positiveY, negativeY, positiveZ, negativeZ, unknown
}
public struct FBXCoordinateAxes: Sendable { public var up, front, right: FBXCoordinateAxis }
public enum FBXTimeMode: Int, Sendable { /* mirrors ufbx_time_mode, notes 15 */ }
public struct FBXSceneSettings: Sendable {
    public var axes: FBXCoordinateAxes    // defaults per ufbx
    public var unitMeters: Double = 1
    public var framesPerSecond: Double = 24
    public var originalUnitMeters: Double = 1
    public var originalAxisUp: FBXCoordinateAxis = .unknown
    public var timeMode: FBXTimeMode = .default
    public var ambientColor: FBXVec3 = .init()
    public var defaultCamera: String = ""
    public init() { ... }
}
```

The scene-model wave owns the COMPLETE stored-property list of every
`Scene/*.swift` file (derived from DUMP_FORMAT.md + notes 05/06/14/15 + the
`ufbx.h` structs). Later waves ASSIGN fields; they may only add storage to an
element file when the ownership map below gives them that file.

### Materials (Scene/Material.swift)

```swift
public struct FBXMaterialMap: Sendable {
    public var valueVec4: FBXVec4 = .init()
    public var valueInt: Int64 = 0
    public var valueComponents: Int = 0   // 0 = no value dumped
    public var hasValue: Bool = false
    public var textureID: Int32 = -1      // element_id; -1 = none
    public var textureEnabled: Bool = false
}
public struct FBXMaterialFBXMaps: Sendable {
    // exactly the 20 ufbx_material_fbx_maps fields: diffuseColor, diffuseFactor,
    // specularColor, specularFactor, specularExponent, reflectionColor,
    // reflectionFactor, transparencyColor, transparencyFactor, emissionColor,
    // emissionFactor, ambientColor, ambientFactor, normalMap, bump, bumpFactor,
    // displacement, displacementFactor, vectorDisplacement, vectorDisplacementFactor
}
```

`FBXMaterial.fbx: FBXMaterialFBXMaps` is populated by the finalizer's
`fetchMaps` port (FBX shading-model tables + factor handling, notes 09/14 —
`valueComponents`/`hasValue` come from the mapping tables, NOT prop arity).
`FBXVideo` is an element; the finalizer resolves connected video content into
`FBXTexture.hasContent` (embedded decoding stays out of scope).

### Animation (Scene/Animation.swift)

```swift
public struct FBXAnimProp: Sendable {
    public var elementID: Int32           // element_id of the animated element
    public var propName: String
    public var animValueID: Int32         // element_id of the FBXAnimValue
}
// FBXAnimLayer.animProps: [FBXAnimProp] — sorted (element_id, key, prop_name)
// FBXAnimValue.defaultValue: FBXVec3; curveIDs: [Int32] (3 entries, -1 = none)
// FBXAnimCurve.keyframes: [FBXKeyframe]
public struct FBXKeyframe: Sendable {
    public var time: Double
    public var value: Double
    public var interpolation: FBXInterpolation
    public var left: FBXTangent           // { dx, dy }
    public var right: FBXTangent
}
public struct FBXAnim: Sendable {         // descriptor, like ufbx_anim
    public internal(set) var layers: [FBXAnimLayer]
    public internal(set) var overrideLayerWeights: [Double] = []  // empty = layer.weight
}
extension FBXAnimStack { public var anim: FBXAnim { get } }
extension FBXAnimCurve { public func evaluate(time: Double, default: Double) -> Double }
extension FBXAnim {
    public func evaluateTransform(node: FBXNode, time: Double) -> FBXTransform
    public func evaluateProps(element: FBXElement, time: Double) -> FBXProps
}
```

### LoadContext (Loader/LoadContext.swift — internal)

```swift
struct TmpConnection { var srcID: UInt64; var srcProp: String; var dstID: UInt64; var dstProp: String }
struct TemplateKey: Hashable { var className: String; var subType: String }
final class LoadContext {
    let doc: FBXDocument
    let opts: FBXLoadOptions
    let scene: FBXScene                   // created empty up-front
    var version: Int { doc.version }
    var fbxIDMap: [UInt64: Int32] = [:]   // fbx_id → element_id
    var fbxAttrMap: [UInt64: UInt64] = [:]// node fbx_id → attribute fbx_id (pre-7000)
    var tmpConnections: [TmpConnection] = []
    var templates: [TemplateKey: FBXProps] = [:]
    var warnings: [FBXWarning] = []       // + dedup counting per ufbx
    // makeElement(_ type:, name:, fbxID:) appends to scene.elements + typed
    // array, registers fbxIDMap, returns the instance.
    // syntheticID(for interned "Type::Name") for ALL version < 7000 objects.
}
```

Readers only append elements/props/arrays/tmpConnections — never resolve
references. `SceneLinker` consumes `tmpConnections` (dangling → silently
dropped), builds sorted `connections` + `connectionsDstOrder`, derives
hierarchy, linearizes nodes depth-first (reassigning node `typedID`s), wires
every cross-ref list with ufbx's exact comparators. `SceneFinalizer` then runs
the `ufbxi_update_*` equivalents in ufbx's order.

## Implementation waves & file ownership

Each wave's agents own DISJOINT files (listed above per module). Later waves
read earlier waves' code. Element files (`Scene/*.swift`) belong to the
scene-model wave; reader/linker/finalizer waves get temporary append rights
only as noted in their task prompts, never concurrently with another agent
owning the same file.

## Verification strategy

1. **Golden dumps** (primary): 44 FBX files under `Tests/.../Resources/fbx/`
   with `golden/<name>.json` from real ufbx (`tools/ufbx_dump.c`, spec
   `docs/DUMP_FORMAT.md`). `SceneDump.build` (FBXDumpCore) produces the same
   JSON from a loaded scene; `GoldenTests` compares with tolerance
   `|a-b| <= 1e-6 + 1e-6*max(|a|,|b|)`.
2. **Unit tests** per module (inflate vectors under `Resources/inflate/`,
   parser edge cases, curve evaluation analytic cases).
3. **Robustness**: parsers must never crash/overread on malformed input —
   bounds checks throw `FBXError`. (Fuzz corpus pass in review phase.)

## Numeric & determinism rules

- Element ordering must match ufbx exactly (creation order + ufbx's sorts —
  notes 08/09 list every comparator).
- Array type conversions follow ufbx conversion paths (saturating, ACCURATE_F32).
- ASCII float parsing: port `ufbxi_parse_double` (notes 01); `Double(String)`
  as fallback only where ufbx uses strtod semantics identically.
- Angles: FBX stores degrees; conversion points must match ufbx (notes 10).
- Time: FBX ticks → seconds as `Double(ticks) / 46186158000.0`.
