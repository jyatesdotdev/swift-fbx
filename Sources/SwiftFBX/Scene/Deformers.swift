// Deformers: skin (`ufbx_skin_deformer`/`ufbx_skin_cluster`, ufbx.h:1982/2011)
// and blend shapes (`ufbx_blend_deformer`/`ufbx_blend_channel`/`ufbx_blend_shape`,
// ufbx.h:2050/2078/2098). Cross-refs are `element_id`s; per-vertex slices index
// into flat pools.

import Foundation

// MARK: - Skin

/// Mirrors `ufbx_skinning_method` (ufbx.h:1936-1949).
public enum FBXSkinningMethod: Int, Sendable {
    case linear = 0
    case rigid = 1
    case dualQuaternion = 2
    case blendedDQLinear = 3
}

/// Mirrors `ufbx_skin_vertex` (ufbx.h:1954-1967): a slice into
/// `skinDeformer.weights[]`; weights are pre-sorted descending, not normalized.
public struct FBXSkinVertex: Sendable {
    public var weightBegin: UInt32
    public var numWeights: UInt32
    public var dqWeight: Double
    public init(weightBegin: UInt32 = 0, numWeights: UInt32 = 0, dqWeight: Double = 0) {
        self.weightBegin = weightBegin
        self.numWeights = numWeights
        self.dqWeight = dqWeight
    }
}

/// Mirrors `ufbx_skin_weight` (ufbx.h:1972-1975): a single cluster weight.
public struct FBXSkinWeight: Sendable {
    public var clusterIndex: UInt32
    public var weight: Double
    public init(clusterIndex: UInt32 = 0, weight: Double = 0) {
        self.clusterIndex = clusterIndex
        self.weight = weight
    }
}

public final class FBXSkinDeformer: FBXElement, @unchecked Sendable {
    public internal(set) var skinningMethod: FBXSkinningMethod = .linear
    /// `element_id`s of the clusters (one per bone).
    public internal(set) var clusterIDs: [Int32] = []
    /// Per-mesh-vertex weight info (count == mesh vertex count).
    public internal(set) var vertices: [FBXSkinVertex] = []
    /// Flat weight pool referenced by `vertices[i].weightBegin/numWeights`.
    public internal(set) var weights: [FBXSkinWeight] = []
    public internal(set) var maxWeightsPerVertex: Int = 0

    // Deformer-level DQ blend arrays (may be out of bounds for a given mesh).
    public internal(set) var numDqWeights: Int = 0
    public internal(set) var dqVertices: [UInt32] = []
    public internal(set) var dqWeights: [Double] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .skinDeformer, fbxID: fbxID)
    }

    public var clusters: FBXSkinClusterList { FBXSkinClusterList(scene: scene, elementIDs: clusterIDs) }
}

public final class FBXSkinCluster: FBXElement, @unchecked Sendable {
    /// `element_id` of the bound bone node, -1 = none.
    public internal(set) var boneNodeID: Int32 = -1
    public internal(set) var geometryToBone: FBXMatrix = .identity
    public internal(set) var meshNodeToBone: FBXMatrix = .identity
    public internal(set) var bindToWorld: FBXMatrix = .identity
    /// Precomputed `bone.node_to_world * geometry_to_bone`.
    public internal(set) var geometryToWorld: FBXMatrix = .identity
    public internal(set) var geometryToWorldTransform: FBXTransform = .identity

    /// Raw per-*vertex* weights (may be out of bounds for a given mesh).
    public internal(set) var numWeights: Int = 0
    public internal(set) var vertices: [UInt32] = []
    public internal(set) var weights: [Double] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .skinCluster, fbxID: fbxID)
    }

    public var boneNode: FBXNode? { typedElement(boneNodeID) }
}

// MARK: - Blend shapes

public final class FBXBlendDeformer: FBXElement, @unchecked Sendable {
    /// `element_id`s of the deformer's channels.
    public internal(set) var channelIDs: [Int32] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .blendDeformer, fbxID: fbxID)
    }

    public var channels: FBXBlendChannelList { FBXBlendChannelList(scene: scene, elementIDs: channelIDs) }
}

/// Mirrors `ufbx_blend_keyframe` (ufbx.h:2063-2072). `shapeID` is an `element_id`.
public struct FBXBlendKeyframe: Sendable {
    public var shapeID: Int32
    public var targetWeight: Double
    public var effectiveWeight: Double
    public init(shapeID: Int32 = -1, targetWeight: Double = 0, effectiveWeight: Double = 0) {
        self.shapeID = shapeID
        self.targetWeight = targetWeight
        self.effectiveWeight = effectiveWeight
    }
}

public final class FBXBlendChannel: FBXElement, @unchecked Sendable {
    public internal(set) var weight: Double = 0
    public internal(set) var keyframes: [FBXBlendKeyframe] = []
    /// `element_id` of the final target shape, -1 = none.
    public internal(set) var targetShapeID: Int32 = -1

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .blendChannel, fbxID: fbxID)
    }

    public var targetShape: FBXBlendShape? { typedElement(targetShapeID) }
    /// Resolve the shape referenced by a keyframe (keyframes are value types).
    public func shape(for keyframe: FBXBlendKeyframe) -> FBXBlendShape? {
        typedElement(keyframe.shapeID)
    }
}

public final class FBXBlendShape: FBXElement, @unchecked Sendable {
    public internal(set) var numOffsets: Int = 0
    /// Indices into `mesh.vertices[]` (may be out of bounds for a given mesh).
    public internal(set) var offsetVertices: [UInt32] = []
    public internal(set) var positionOffsets: [FBXVec3] = []
    /// Empty if not specified.
    public internal(set) var normalOffsets: [FBXVec3] = []
    /// Non-standard FBX; only written by Blender.
    public internal(set) var offsetWeights: [Double] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .blendShape, fbxID: fbxID)
    }
}
