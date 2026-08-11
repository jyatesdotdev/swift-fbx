// `ufbx_node` (ufbx.h:844-996): the transform-hierarchy node. Stores the raw
// FBX transform chain inputs (rotation order, euler angles, inherit mode) and
// the derived transforms/matrices the finalizer computes (notes 10), plus the
// axis/unit-conversion adjust factors ufbx folds into every transform.

import Foundation

/// Mirrors `ufbx_inherit_mode` (ufbx.h:802-826). NOTE: `InheritType` int → mode
/// is NOT ordinal — the reader maps `0 → componentwiseScale`, `2 →
/// ignoreParentScale`, everything else → `normal` (ufbx.c:12608-12622). These
/// raw values are the ufbx enum ordinals for dumping.
public enum FBXInheritMode: Int, Sendable {
    case normal = 0
    case ignoreParentScale = 1
    case componentwiseScale = 2
}

/// Mirrors `ufbx_mirror_axis` (ufbx.h:829-839).
public enum FBXMirrorAxis: Int, Sendable {
    case none = 0
    case x = 1
    case y = 2
    case z = 3
}

public final class FBXNode: FBXElement, @unchecked Sendable {

    // MARK: Hierarchy (element_ids, -1 = none)
    public internal(set) var parentID: Int32 = -1
    public internal(set) var childrenIDs: [Int32] = []

    // MARK: Attached attributes
    public internal(set) var meshID: Int32 = -1
    public internal(set) var lightID: Int32 = -1
    public internal(set) var cameraID: Int32 = -1
    public internal(set) var boneID: Int32 = -1
    /// First attached attribute (may equal one of the typed ids above).
    public internal(set) var attribID: Int32 = -1
    public internal(set) var attribType: FBXElementType = .unknown
    /// All attached attributes (rare multi-attribute case, `all_attribs`).
    public internal(set) var allAttribIDs: [Int32] = []

    // MARK: Synthetic helper links / inherit state
    public internal(set) var geometryTransformHelperID: Int32 = -1
    public internal(set) var scaleHelperID: Int32 = -1
    public internal(set) var inheritScaleNodeID: Int32 = -1
    public internal(set) var bindPoseID: Int32 = -1

    // MARK: Per-instance materials (`element_id`s; can differ from mesh.materials)
    public internal(set) var materialIDs: [Int32] = []

    // MARK: Transform inputs
    public internal(set) var inheritMode: FBXInheritMode = .normal
    public internal(set) var originalInheritMode: FBXInheritMode = .normal
    public internal(set) var rotationOrder: FBXRotationOrder = .xyz
    /// Raw Euler angles in degrees, applied in `rotationOrder` (ufbx.h:915-921).
    public internal(set) var eulerRotation: FBXVec3 = .zero

    // MARK: Derived transforms (finalizer output)
    public internal(set) var localTransform: FBXTransform = .identity
    public internal(set) var geometryTransform: FBXTransform = .identity
    /// Combined scale for COMPONENTWISE_SCALE; else `localTransform.scale`.
    public internal(set) var inheritScale: FBXVec3 = .one

    public internal(set) var nodeToParent: FBXMatrix = .identity
    public internal(set) var nodeToWorld: FBXMatrix = .identity
    public internal(set) var geometryToNode: FBXMatrix = .identity
    public internal(set) var geometryToWorld: FBXMatrix = .identity
    public internal(set) var unscaledNodeToWorld: FBXMatrix = .identity

    // MARK: Axis/unit-conversion adjust factors (ufbx.h:945-951)
    public internal(set) var adjustPreTranslation: FBXVec3 = .zero
    public internal(set) var adjustPreRotation: FBXQuat = .identity
    public internal(set) var adjustPreScale: Double = 1
    public internal(set) var adjustPostRotation: FBXQuat = .identity
    public internal(set) var adjustPostScale: Double = 1
    public internal(set) var adjustTranslationScale: Double = 1
    public internal(set) var adjustMirrorAxis: FBXMirrorAxis = .none

    // MARK: Flags / depth
    public internal(set) var visible: Bool = true
    public internal(set) var isRoot: Bool = false
    public internal(set) var hasGeometryTransform: Bool = false
    public internal(set) var useRotationSpace: Bool = false
    public internal(set) var hasAdjustTransform: Bool = false
    public internal(set) var hasRootAdjustTransform: Bool = false
    public internal(set) var isGeometryTransformHelper: Bool = false
    public internal(set) var isScaleHelper: Bool = false
    public internal(set) var isScaleCompensateParent: Bool = false
    /// Depth in the hierarchy: root = 0.
    public internal(set) var nodeDepth: Int = 0

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .node, fbxID: fbxID)
    }

    // MARK: Typed accessors
    public var parent: FBXNode? { typedElement(parentID) }
    public var children: FBXNodeList { FBXNodeList(scene: scene, elementIDs: childrenIDs) }
    public var mesh: FBXMesh? { typedElement(meshID) }
    public var light: FBXLight? { typedElement(lightID) }
    public var camera: FBXCamera? { typedElement(cameraID) }
    public var bone: FBXBone? { typedElement(boneID) }
    public var attrib: FBXElement? {
        guard attribID >= 0, Int(attribID) < scene.elements.count else { return nil }
        return scene.elements[Int(attribID)]
    }
    public var allAttribs: FBXElementList<FBXElement> {
        FBXElementList<FBXElement>(scene: scene, elementIDs: allAttribIDs)
    }
    public var geometryTransformHelper: FBXNode? { typedElement(geometryTransformHelperID) }
    public var scaleHelper: FBXNode? { typedElement(scaleHelperID) }
    public var inheritScaleNode: FBXNode? { typedElement(inheritScaleNodeID) }
    public var bindPose: FBXPose? { typedElement(bindPoseID) }
    public var materials: FBXMaterialList { FBXMaterialList(scene: scene, elementIDs: materialIDs) }
}
