// Shared parse-state machine tables for the binary and ASCII FBX parsers.
//
// Direct port of ufbx's coarse structural classifier (ufbx.c:7909–8605):
//   - `ufbxi_parse_state`         → `ParseState`               (ufbx.c:7915–7968)
//   - `ufbxi_array_flags`         → `ArrayFlags`               (ufbx.c:7970–7975)
//   - `ufbxi_array_info`          → `ArrayInfo`                (ufbx.c:7977–7980)
//   - `ufbxi_update_parse_state`  → `ParseState.update`        (ufbx.c:7982–8090)
//   - `ufbxi_is_array_node`       → `ParseState.arrayInfo`     (ufbx.c:8092–8506)
//   - `ufbxi_is_raw_string`       → `ParseState.isRawString`   (ufbx.c:8508–8605)
//
// As the file is read we track which node path we are under so array info
// (destination element type, buffer padding, bit-exact float parsing, raw
// string handling) can be resolved BEFORE any payload bytes are consumed —
// exactly as ufbx does. This module is consumed by BOTH parsers; keep the
// type codes here consistent with the mesh/skin/blend/animation builders.

/// Where in the document tree the reader currently is. Mirrors
/// `ufbxi_parse_state` entry-for-entry (ufbx.c:7915–7968). OBJ-only states do
/// not exist in ufbx's enum (OBJ has a separate parser), so none are skipped.
enum ParseState {
    case root
    case fbxHeaderExtension
    case sceneInfo
    case thumbnail
    case definitions
    case objects
    case connections
    case relations
    case takes
    case fbxVersion
    case model
    case geometry
    case nodeAttribute
    case legacyModel
    case legacyMedia
    case legacyVideo
    case legacySwitcher
    case legacyScenePersistence
    case references
    case reference
    case animationCurve
    case deformer
    case associateModel
    case legacyLink
    case pose
    case poseNode
    case texture
    case video
    case layeredTexture
    case selectionNode
    case collection
    case audio
    case unknownObject
    case layerElementNormal
    case layerElementBinormal
    case layerElementTangent
    case layerElementUV
    case layerElementColor
    case layerElementVertexCrease
    case layerElementEdgeCrease
    case layerElementSmoothing
    case layerElementVisibility
    case layerElementPolygonGroup
    case layerElementHole
    case layerElementMaterial
    case layerElementOther
    case geometryUVInfo
    case shape
    case take
    case takeObject
    case channel
    case unknown
}

/// FBX array element destination type. Raw value is the ASCII code ufbx uses in
/// `ufbxi_array_info.type` so parsers can recover the wire/normalize char
/// directly (ufbx.c:7977–7980, type sizes at ufbx.c:7694). `real` ('r') is
/// resolved to `float`/`double` by the reader depending on `ufbx_real` width;
/// `bool` ('b') keeps its tag for the bool post-process pass; `ignore` ('-')
/// means the payload is parsed-and-discarded uniformly.
enum ArrayType: UInt8 {
    case real = 0x72              // 'r' — ufbx_real (→ 'f' or 'd')
    case bool = 0x62             // 'b' — bool tag (post-processed to 0/1)
    case uint8 = 0x63           // 'c' — raw byte storage
    case int32 = 0x69            // 'i'
    case int64 = 0x6C            // 'l'
    case float = 0x66            // 'f'
    case double = 0x64           // 'd'
    case string = 0x73           // 's' — interned string
    case stringSanitized = 0x53  // 'S' — sanitized string
    case content = 0x43          // 'C' — content/blob (embedded / base64)
    case ignore = 0x2D           // '-' — parse and discard
}

/// Combination of `ufbxi_array_flags` (ufbx.c:7970–7975).
struct ArrayFlags: OptionSet {
    let rawValue: UInt8
    /// Allocate from the result buffer / retain in the DOM.
    static let result       = ArrayFlags(rawValue: 0x1)
    /// Allocate from the long-term temporary buffer.
    static let tmpBuf       = ArrayFlags(rawValue: 0x2)
    /// Prepend 4 zero elements to guard invalid `-1` (up to `-4`) index reads.
    static let padBegin     = ArrayFlags(rawValue: 0x4)
    /// Must be parsed as bit-accurate 32-bit floats.
    static let accurateF32  = ArrayFlags(rawValue: 0x8)
}

/// Result of classifying a node as an array (`ufbxi_array_info`, ufbx.c:7977).
struct ArrayInfo {
    var type: ArrayType
    var flags: ArrayFlags
}

/// The version/option gates the classifier tables branch on. Mirrors the fields
/// of `ufbxi_context`/`ufbx_load_opts` consulted by `ufbxi_is_array_node` and
/// `ufbxi_is_raw_string`. Defaults match ufbx's zero-initialized options.
struct ParseContext {
    var version: Int
    var fromAscii: Bool
    var ignoreGeometry: Bool = false
    var ignoreAnimation: Bool = false
    var ignoreEmbedded: Bool = false
    var retainDom: Bool = false
    var retainVertexW: Bool = false
    var blenderFullWeights: Bool = false

    init(version: Int, fromAscii: Bool,
         ignoreGeometry: Bool = false, ignoreAnimation: Bool = false,
         ignoreEmbedded: Bool = false, retainDom: Bool = false,
         retainVertexW: Bool = false, blenderFullWeights: Bool = false) {
        self.version = version
        self.fromAscii = fromAscii
        self.ignoreGeometry = ignoreGeometry
        self.ignoreAnimation = ignoreAnimation
        self.ignoreEmbedded = ignoreEmbedded
        self.retainDom = retainDom
        self.retainVertexW = retainVertexW
        self.blenderFullWeights = blenderFullWeights
    }
}

extension ParseState {

    // MARK: - ufbxi_update_parse_state (ufbx.c:7982–8090)

    /// Compute the child parse state from the parent state and the child node
    /// name. Names ufbx compares by interned pointer become plain `==`; names
    /// it compares by `strcmp` (rare legacy names) are the same equality here.
    static func update(parent: ParseState, name: String) -> ParseState {
        switch parent {

        case .root:
            if name == "FBXHeaderExtension" { return .fbxHeaderExtension }
            if name == "Definitions" { return .definitions }
            if name == "Objects" { return .objects }
            if name == "Connections" { return .connections }
            if name == "Takes" { return .takes }
            if name == "Model" { return .legacyModel }
            if name == "References" { return .references }
            if name == "Relations" { return .relations }
            if name == "Media" { return .legacyMedia }
            if name == "Switcher" { return .legacySwitcher }
            if name == "SceneGenericPersistence" { return .legacyScenePersistence }

        case .fbxHeaderExtension:
            if name == "FBXVersion" { return .fbxVersion }
            if name == "SceneInfo" { return .sceneInfo }

        case .sceneInfo:
            if name == "Thumbnail" { return .thumbnail }

        case .objects:
            if name == "Model" { return .model }
            if name == "Geometry" { return .geometry }
            if name == "NodeAttribute" { return .nodeAttribute }
            if name == "AnimationCurve" { return .animationCurve }
            if name == "Deformer" { return .deformer }
            if name == "Pose" { return .pose }
            if name == "Texture" { return .texture }
            if name == "Video" { return .video }
            if name == "LayeredTexture" { return .layeredTexture }
            if name == "SelectionNode" { return .selectionNode }
            if name == "Collection" { return .collection }
            if name == "Audio" { return .audio }
            // ufbx: unrecognized Objects children → UNKNOWN_OBJECT, not UNKNOWN
            return .unknownObject

        case .model, .geometry:
            // ufbx guards these with name[0]=='L'; the string equality subsumes it.
            if name == "LayerElementNormal" { return .layerElementNormal }
            if name == "LayerElementBinormal" { return .layerElementBinormal }
            if name == "LayerElementTangent" { return .layerElementTangent }
            if name == "LayerElementUV" { return .layerElementUV }
            if name == "LayerElementColor" { return .layerElementColor }
            if name == "LayerElementVertexCrease" { return .layerElementVertexCrease }
            if name == "LayerElementEdgeCrease" { return .layerElementEdgeCrease }
            if name == "LayerElementSmoothing" { return .layerElementSmoothing }
            if name == "LayerElementVisibility" { return .layerElementVisibility }
            if name == "LayerElementPolygonGroup" { return .layerElementPolygonGroup }
            if name == "LayerElementHole" { return .layerElementHole }
            if name == "LayerElementMaterial" { return .layerElementMaterial }
            if name.hasPrefix("LayerElement") { return .layerElementOther }
            if name == "Shape" { return .shape }

        case .deformer:
            if name == "AssociateModel" { return .associateModel }

        case .legacyMedia:
            if name == "Video" { return .legacyVideo }

        case .legacyVideo:
            return .video

        case .legacyModel:
            if name == "GeometryUVInfo" { return .geometryUVInfo }
            if name == "Link" { return .legacyLink }
            if name == "Channel" { return .channel }
            if name == "Shape" { return .shape }

        case .pose:
            if name == "PoseNode" { return .poseNode }

        case .takes:
            if name == "Take" { return .take }

        case .take:
            return .takeObject

        case .takeObject:
            if name == "Channel" { return .channel }

        case .channel:
            if name == "Channel" { return .channel }

        case .references:
            return .reference

        default:
            break
        }

        return .unknown
    }

    // MARK: - ufbxi_is_array_node (ufbx.c:8092–8506)

    /// Classify a child node as an array under `parent`, returning its
    /// destination type and flags, or `nil` when the node is not an array
    /// (then it is parsed as scalar values). Faithful to ufbx including the
    /// `ignore_*`/`retain_dom` option gates and version-dependent branches.
    static func arrayInfo(parent: ParseState, name: String, context c: ParseContext) -> ArrayInfo? {
        // ufbx: retain_dom forces RESULT on every array so the DOM keeps them.
        // Branches that assign flags with `=` overwrite this; `|=` preserves it.
        let base: ArrayFlags = c.retainDom ? .result : []

        func geom(_ t: ArrayType) -> ArrayType { c.ignoreGeometry ? .ignore : t }

        switch parent {

        case .thumbnail:
            if name == "ImageData" {
                return ArrayInfo(type: .uint8, flags: .result)
            }

        case .geometry, .model:
            if name == "Vertices" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "PolygonVertexIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "Edges" {
                return ArrayInfo(type: geom(.int32), flags: base)
            } else if name == "Indexes" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "Points" {
                return ArrayInfo(type: geom(.real), flags: .result)
            } else if name == "KnotVector" {
                return ArrayInfo(type: geom(.real), flags: .result)
            } else if name == "KnotVectorU" {
                return ArrayInfo(type: geom(.real), flags: .result)
            } else if name == "KnotVectorV" {
                return ArrayInfo(type: geom(.real), flags: .result)
            } else if name == "PointsIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "Normals" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            }

        case .legacyModel:
            if name == "Vertices" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "Normals" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "Materials" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "PolygonVertexIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "Children" {
                return ArrayInfo(type: .string, flags: base)
            }

        case .animationCurve:
            if name == "KeyTime" {
                return ArrayInfo(type: c.ignoreAnimation ? .ignore : .int64, flags: base)
            } else if name == "KeyValueFloat" {
                return ArrayInfo(type: c.ignoreAnimation ? .ignore : .real, flags: base)
            } else if name == "KeyAttrFlags" {
                return ArrayInfo(type: c.ignoreAnimation ? .ignore : .int32, flags: base)
            } else if name == "KeyAttrDataFloat" {
                // ufbx: keyframe attribute float data is stored as integers in
                // versions >= 7200 because some elements aren't actually floats;
                // pre-7200 ASCII needs bit-exact f32 parsing (ufbx.c:8188–8196).
                var type: ArrayType = (c.fromAscii && c.version >= 7200) ? .int32 : .float
                if c.ignoreAnimation { type = .ignore }
                var flags = base
                if c.fromAscii && c.version < 7200 { flags.insert(.accurateF32) }
                return ArrayInfo(type: type, flags: flags)
            } else if name == "KeyAttrRefCount" {
                return ArrayInfo(type: c.ignoreAnimation ? .ignore : .int32, flags: base)
            }

        case .texture:
            if name == "ModelUVTranslation" || name == "ModelUVScaling" || name == "Cropping" {
                return ArrayInfo(type: c.retainDom ? .real : .ignore, flags: base)
            }

        case .video:
            if name == "Content" {
                return ArrayInfo(type: c.ignoreEmbedded ? .ignore : .content, flags: base)
            }

        case .layeredTexture:
            if name == "BlendModes" {
                return ArrayInfo(type: .int32, flags: base.union(.tmpBuf))
            } else if name == "Alphas" {
                return ArrayInfo(type: .real, flags: base.union(.tmpBuf))
            }

        case .selectionNode:
            if name == "VertexIndexArray" {
                return ArrayInfo(type: .int32, flags: .result)
            } else if name == "EdgeIndexArray" {
                return ArrayInfo(type: .int32, flags: .result)
            } else if name == "PolygonIndexArray" {
                return ArrayInfo(type: .int32, flags: .result)
            }

        case .layerElementNormal:
            if name == "Normals" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "NormalsIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "NormalsW" {
                return ArrayInfo(type: c.retainVertexW ? .real : .ignore, flags: [.result, .padBegin])
            }

        case .layerElementBinormal:
            if name == "Binormals" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "BinormalsIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "BinormalsW" {
                return ArrayInfo(type: c.retainVertexW ? .real : .ignore, flags: [.result, .padBegin])
            }

        case .layerElementTangent:
            if name == "Tangents" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "TangentsIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "TangentsW" {
                return ArrayInfo(type: c.retainVertexW ? .real : .ignore, flags: [.result, .padBegin])
            }

        case .layerElementUV:
            if name == "UV" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "UVIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            }

        case .layerElementColor:
            if name == "Colors" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "ColorIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            }

        case .layerElementVertexCrease:
            if name == "VertexCrease" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "VertexCreaseIndex" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            }

        case .layerElementEdgeCrease:
            if name == "EdgeCrease" {
                return ArrayInfo(type: geom(.real), flags: .result)
            }

        case .layerElementSmoothing:
            if name == "Smoothing" {
                return ArrayInfo(type: c.ignoreGeometry ? .ignore : .bool, flags: .result)
            }

        case .layerElementVisibility:
            if name == "Visibility" {
                return ArrayInfo(type: c.ignoreGeometry ? .ignore : .bool, flags: .result)
            }

        case .layerElementPolygonGroup:
            if name == "PolygonGroup" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            }

        case .layerElementHole:
            if name == "Hole" {
                return ArrayInfo(type: c.ignoreGeometry ? .ignore : .bool, flags: .result)
            }

        case .layerElementMaterial:
            if name == "Materials" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            }

        case .layerElementOther:
            if name == "TextureId" {
                return ArrayInfo(type: geom(.int32), flags: base.union(.tmpBuf))
            } else if name == "UV" {
                return ArrayInfo(type: c.retainDom ? .real : .ignore, flags: base)
            } else if name == "UVIndex" {
                return ArrayInfo(type: c.retainDom ? .int32 : .ignore, flags: base)
            }

        case .geometryUVInfo:
            if name == "TextureUV" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            } else if name == "TextureUVVerticeIndex" {
                return ArrayInfo(type: geom(.int32), flags: [.result, .padBegin])
            }

        case .shape:
            if name == "Indexes" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            }
            if name == "Vertices" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            }
            if name == "Normals" {
                return ArrayInfo(type: geom(.real), flags: [.result, .padBegin])
            }

        case .deformer:
            if name == "Transform" {
                return ArrayInfo(type: .real, flags: base)
            } else if name == "TransformLink" {
                return ArrayInfo(type: .real, flags: base)
            } else if name == "Indexes" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "Weights" {
                return ArrayInfo(type: geom(.real), flags: .result)
            } else if name == "BlendWeights" {
                return ArrayInfo(type: geom(.real), flags: .result)
            } else if name == "FullWeights" {
                // ufbx: Blender exports full weights meant to be retained (RESULT);
                // otherwise they go to the long-term temp buffer (ufbx.c:8442).
                return ArrayInfo(type: .real, flags: base.union(c.blenderFullWeights ? .result : .tmpBuf))
            } else if name == "TransformAssociateModel" {
                return ArrayInfo(type: c.retainDom ? .real : .ignore, flags: base)
            }

        case .associateModel:
            if name == "Transform" {
                return ArrayInfo(type: c.retainDom ? .real : .ignore, flags: base)
            }

        case .legacyLink:
            if name == "Transform" {
                return ArrayInfo(type: .real, flags: base)
            } else if name == "TransformLink" {
                return ArrayInfo(type: .real, flags: base)
            } else if name == "Indexes" {
                return ArrayInfo(type: geom(.int32), flags: .result)
            } else if name == "Weights" {
                return ArrayInfo(type: geom(.real), flags: .result)
            }

        case .poseNode:
            if name == "Matrix" {
                return ArrayInfo(type: .real, flags: base)
            }

        case .channel:
            if name == "Key" {
                return ArrayInfo(type: c.ignoreAnimation ? .ignore : .double, flags: base)
            }

        case .audio:
            if name == "Content" {
                return ArrayInfo(type: c.ignoreEmbedded ? .ignore : .content, flags: base)
            }

        default:
            // ufbx: any node named BinaryData in an unhandled state is content.
            if name == "BinaryData" {
                return ArrayInfo(type: c.ignoreEmbedded ? .ignore : .content, flags: base)
            }
        }

        return nil
    }

    // MARK: - ufbxi_is_raw_string (ufbx.c:8508–8605)

    /// Decide whether a string value under `parent`/`name` must be stored raw
    /// (bytes preserved, not UTF-8 sanitized). `valueIndex` is accepted for
    /// signature parity but, as in ufbx, is unused.
    static func isRawString(parent: ParseState, name: String, valueIndex: Int, version: Int) -> Bool {
        switch parent {

        case .root:
            if name == "Model" { return true }
            if name == "FileId" { return true }

        case .fbxHeaderExtension:
            if name == "SceneInfo" { return true }

        case .objects:
            // ufbx: under Objects ALL strings are raw.
            return true

        case .connections, .relations:
            // ufbx: pre-7000 needs raw strings for "Name\x00\x01Type" pairs.
            return version < 7000

        case .model:
            if name == "NodeAttributeName" { return true }
            if name == "Name" { return true }

        case .video:
            if name == "Content" { return true }

        case .texture:
            if name == "TextureName" { return true }
            if name == "Media" { return true }

        case .geometry:
            if name == "NodeAttributeName" { return true }
            if name == "Name" { return true }

        case .nodeAttribute:
            if name == "NodeAttributeName" { return true }
            if name == "Name" { return true }

        case .poseNode:
            if name == "Node" { return true }

        case .selectionNode:
            if name == "Node" { return true }

        case .unknownObject:
            if name == "NodeAttributeName" { return true }
            if name == "Name" { return true }

        case .collection:
            if name == "Member" { return true }

        case .audio:
            if name == "Content" { return true }

        case .legacyModel:
            if name == "Material" { return true }
            if name == "Link" { return true }
            if name == "Name" { return true }

        case .legacySwitcher:
            if name == "CameraIndexName" { return true }

        case .legacyScenePersistence:
            if name == "SceneInfo" { return true }

        case .reference:
            if name == "Object" { return true }

        case .take:
            if name == "Model" { return true }

        default:
            break
        }

        return false
    }
}
