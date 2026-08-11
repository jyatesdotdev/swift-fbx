// `ufbx_mesh` (ufbx.h:1257-1378) and its geometry value types: the indexed
// vertex-attribute layer (`ufbx_vertex_attrib` + typed twins, ufbx.h:1007-1073),
// UV/color sets, faces, edges, mesh parts and face groups. All arrays follow
// ufbx's invariant `indices.count == num_indices` when the attribute `exists`.

import Foundation

// MARK: - Vertex attribute

/// Mirrors `ufbx_vertex_attrib` and its typed twins (ufbx.h:1007-1073). One
/// deduplicated `values` pool plus one `indices` entry per mesh corner (length
/// `mesh.numIndices` when `exists`). `NO_INDEX` (0xFFFFFFFF) marks an unused
/// corner. `valueReals` is the component count; `uniquePerVertex` enables the
/// `vertexFirstIndex` fast path; `valuesW` is the optional 4th component.
public struct FBXVertexAttribute<Value: Sendable>: Sendable {
    public var exists: Bool
    public var values: [Value]
    public var indices: [UInt32]
    public var valueReals: Int
    public var uniquePerVertex: Bool
    public var valuesW: [Double]

    public init(
        exists: Bool = false,
        values: [Value] = [],
        indices: [UInt32] = [],
        valueReals: Int = 0,
        uniquePerVertex: Bool = false,
        valuesW: [Double] = []
    ) {
        self.exists = exists
        self.values = values
        self.indices = indices
        self.valueReals = valueReals
        self.uniquePerVertex = uniquePerVertex
        self.valuesW = valuesW
    }
}

public typealias FBXVertexReal = FBXVertexAttribute<Double>
public typealias FBXVertexVec2 = FBXVertexAttribute<FBXVec2>
public typealias FBXVertexVec3 = FBXVertexAttribute<FBXVec3>
public typealias FBXVertexVec4 = FBXVertexAttribute<FBXVec4>

// MARK: - Layers

/// Mirrors `ufbx_uv_set` (ufbx.h:1076-1084). The first set duplicates
/// `mesh.vertexUV/vertexTangent/vertexBitangent`.
public struct FBXUVSet: Sendable {
    public var name: String
    public var index: Int
    public var vertexUV: FBXVertexVec2
    public var vertexTangent: FBXVertexVec3
    public var vertexBitangent: FBXVertexVec3

    public init(
        name: String = "",
        index: Int = 0,
        vertexUV: FBXVertexVec2 = .init(),
        vertexTangent: FBXVertexVec3 = .init(),
        vertexBitangent: FBXVertexVec3 = .init()
    ) {
        self.name = name
        self.index = index
        self.vertexUV = vertexUV
        self.vertexTangent = vertexTangent
        self.vertexBitangent = vertexBitangent
    }
}

/// Mirrors `ufbx_color_set` (ufbx.h:1087-1093). The first set duplicates
/// `mesh.vertexColor`.
public struct FBXColorSet: Sendable {
    public var name: String
    public var index: Int
    public var vertexColor: FBXVertexVec4

    public init(name: String = "", index: Int = 0, vertexColor: FBXVertexVec4 = .init()) {
        self.name = name
        self.index = index
        self.vertexColor = vertexColor
    }
}

// MARK: - Topology value types

/// Mirrors `ufbx_face` (ufbx.h:1113-1116): a contiguous run of mesh indices.
/// `numIndices` may be < 3 (degenerate empty/point/line face) — ufbx does not
/// filter these at load time.
public struct FBXFace: Sendable, Equatable {
    public var indexBegin: UInt32
    public var numIndices: UInt32
    public init(indexBegin: UInt32 = 0, numIndices: UInt32 = 0) {
        self.indexBegin = indexBegin
        self.numIndices = numIndices
    }
}

/// Mirrors `ufbx_edge` (ufbx.h:1099-1104): a pair of *mesh index* values (into
/// the flat index stream), NOT vertex ids.
public struct FBXEdge: Sendable, Equatable {
    public var a: UInt32
    public var b: UInt32
    public init(a: UInt32 = 0, b: UInt32 = 0) {
        self.a = a
        self.b = b
    }
}

/// Mirrors `ufbx_face_group` (ufbx.h:1142-1145).
public struct FBXFaceGroup: Sendable {
    public var id: Int32
    public var name: String
    public init(id: Int32 = 0, name: String = "") {
        self.id = id
        self.name = name
    }
}

/// Mirrors `ufbx_mesh_part` (ufbx.h:1121-1138): a subset of faces sharing a
/// material or face group.
public struct FBXMeshPart: Sendable {
    public var index: Int
    public var numFaces: Int
    public var numTriangles: Int
    public var numEmptyFaces: Int
    public var numPointFaces: Int
    public var numLineFaces: Int
    /// Indices into `mesh.faces[]` (length `numFaces`).
    public var faceIndices: [UInt32]

    public init(
        index: Int = 0, numFaces: Int = 0, numTriangles: Int = 0,
        numEmptyFaces: Int = 0, numPointFaces: Int = 0, numLineFaces: Int = 0,
        faceIndices: [UInt32] = []
    ) {
        self.index = index
        self.numFaces = numFaces
        self.numTriangles = numTriangles
        self.numEmptyFaces = numEmptyFaces
        self.numPointFaces = numPointFaces
        self.numLineFaces = numLineFaces
        self.faceIndices = faceIndices
    }
}

/// Mirrors `ufbx_subdivision_display_mode` (ufbx.h:1181-1190).
public enum FBXSubdivisionDisplayMode: Int, Sendable {
    case disabled = 0
    case hull = 1
    case hullAndSmooth = 2
    case smooth = 3
}

/// Mirrors `ufbx_subdivision_boundary` (ufbx.h:1192-1207).
public enum FBXSubdivisionBoundary: Int, Sendable {
    case `default` = 0
    case legacy = 1
    case sharpCorners = 2
    case sharpNone = 3
    case sharpBoundary = 4
    case sharpInterior = 5
}

// MARK: - Mesh

public final class FBXMesh: FBXElement, @unchecked Sendable {

    /// `NO_INDEX` sentinel (`UFBX_NO_INDEX`, ufbx.h:396): unused vertex / corner.
    public static let noIndex: UInt32 = 0xFFFF_FFFF

    // MARK: Counts
    public internal(set) var numVertices: Int = 0
    public internal(set) var numIndices: Int = 0
    public internal(set) var numFaces: Int = 0
    public internal(set) var numTriangles: Int = 0
    public internal(set) var numEdges: Int = 0
    public internal(set) var maxFaceTriangles: Int = 0
    public internal(set) var numEmptyFaces: Int = 0
    public internal(set) var numPointFaces: Int = 0
    public internal(set) var numLineFaces: Int = 0

    // MARK: Per-face arrays (sized numFaces when present, else empty)
    public internal(set) var faces: [FBXFace] = []
    public internal(set) var faceSmoothing: [Bool] = []
    /// Per-face index into `materials[]` / `node.materials[]`.
    public internal(set) var faceMaterial: [UInt32] = []
    /// Per-face index into `faceGroups[]`.
    public internal(set) var faceGroup: [UInt32] = []
    public internal(set) var faceHole: [Bool] = []

    // MARK: Per-edge arrays (sized numEdges)
    public internal(set) var edges: [FBXEdge] = []
    public internal(set) var edgeSmoothing: [Bool] = []
    public internal(set) var edgeCrease: [Double] = []
    public internal(set) var edgeVisibility: [Bool] = []

    // MARK: Logical vertices
    public internal(set) var vertexIndices: [UInt32] = []
    public internal(set) var vertices: [FBXVec3] = []
    /// First index referencing each vertex, `noIndex` if unused.
    public internal(set) var vertexFirstIndex: [UInt32] = []

    // MARK: Vertex attributes (first UV/color set mirrored here)
    public internal(set) var vertexPosition: FBXVertexVec3 = .init()
    public internal(set) var vertexNormal: FBXVertexVec3 = .init()
    public internal(set) var vertexUV: FBXVertexVec2 = .init()
    public internal(set) var vertexTangent: FBXVertexVec3 = .init()
    public internal(set) var vertexBitangent: FBXVertexVec3 = .init()
    public internal(set) var vertexColor: FBXVertexVec4 = .init()
    public internal(set) var vertexCrease: FBXVertexReal = .init()

    public internal(set) var uvSets: [FBXUVSet] = []
    public internal(set) var colorSets: [FBXColorSet] = []

    // MARK: Materials / groups (element_ids for materials)
    /// Mesh-level materials (`element_id`s). Prefer `node.materials` for
    /// per-instance correctness.
    public internal(set) var materialIDs: [Int32] = []
    public internal(set) var faceGroups: [FBXFaceGroup] = []
    public internal(set) var materialParts: [FBXMeshPart] = []
    public internal(set) var faceGroupParts: [FBXMeshPart] = []
    public internal(set) var materialPartUsageOrder: [UInt32] = []

    // MARK: Skinned geometry
    public internal(set) var skinnedIsLocal: Bool = true
    public internal(set) var skinnedPosition: FBXVertexVec3 = .init()
    public internal(set) var skinnedNormal: FBXVertexVec3 = .init()

    // MARK: Deformers (element_ids)
    public internal(set) var skinDeformerIDs: [Int32] = []
    public internal(set) var blendDeformerIDs: [Int32] = []
    public internal(set) var cacheDeformerIDs: [Int32] = []
    public internal(set) var allDeformerIDs: [Int32] = []

    // MARK: Subdivision passthrough
    public internal(set) var subdivisionPreviewLevels: Int = 0
    public internal(set) var subdivisionRenderLevels: Int = 0
    public internal(set) var subdivisionDisplayMode: FBXSubdivisionDisplayMode = .disabled
    public internal(set) var subdivisionBoundary: FBXSubdivisionBoundary = .default
    public internal(set) var subdivisionUVBoundary: FBXSubdivisionBoundary = .default

    // MARK: Flags
    public internal(set) var reversedWinding: Bool = false
    public internal(set) var generatedNormals: Bool = false
    public internal(set) var fromTessellatedNurbs: Bool = false

    // MARK: Legacy 6x00 per-material texture layers (internal; not dumped)
    // Mirrors `ufbxi_tmp_mesh_texture` (ufbx.c:6334/13675). Populated by the mesh
    // reader from `LayerElementTexture` / `LayerElement<Prop>Textures` blocks and
    // consumed by the linker's legacy material-texture patch (ufbx.c:22364).
    struct LegacyTextureLayer: Sendable {
        var propName: String       // e.g. "Diffuse", "Emissive", "Specular"
        var allSame: Bool
        var faceTexture: [UInt32]  // per-face texture indices (into the mesh's fetched textures)
    }
    var legacyTextureLayers: [LegacyTextureLayer] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .mesh, fbxID: fbxID)
    }

    // MARK: Typed accessors
    public var materials: FBXMaterialList { FBXMaterialList(scene: scene, elementIDs: materialIDs) }
    public var skinDeformers: FBXSkinDeformerList { FBXSkinDeformerList(scene: scene, elementIDs: skinDeformerIDs) }
    public var blendDeformers: FBXBlendDeformerList { FBXBlendDeformerList(scene: scene, elementIDs: blendDeformerIDs) }
}
