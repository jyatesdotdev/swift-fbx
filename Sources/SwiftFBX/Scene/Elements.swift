// Element base "class", the element-type discriminator, the raw connection
// graph edge, and the generic typed element-list view. Mirrors `ufbx_element`
// (ufbx.h:763-774), `ufbx_element_type` (ufbx.h:694-744) and `ufbx_connection`
// (ufbx.h:749-754). See DESIGN.md "Ownership model" — every cross-reference is
// an `element_id` (index into `scene.elements`), -1 = none.

import Foundation

// MARK: - Element type

/// Mirrors `ufbx_element_type` (ufbx.h:694-744). Raw values match ufbx ordinals
/// and the enum ORDER is load-bearing (`FIRST_ATTRIB`/`LAST_ATTRIB` sub-range,
/// scene typed-array ordering).
public enum FBXElementType: Int, Sendable, CaseIterable {
    case unknown = 0
    case node = 1
    case mesh = 2
    case light = 3
    case camera = 4
    case bone = 5
    case empty = 6
    case lineCurve = 7
    case nurbsCurve = 8
    case nurbsSurface = 9
    case nurbsTrimSurface = 10
    case nurbsTrimBoundary = 11
    case proceduralGeometry = 12
    case stereoCamera = 13
    case cameraSwitcher = 14
    case marker = 15
    case lodGroup = 16
    case skinDeformer = 17
    case skinCluster = 18
    case blendDeformer = 19
    case blendChannel = 20
    case blendShape = 21
    case cacheDeformer = 22
    case cacheFile = 23
    case material = 24
    case texture = 25
    case video = 26
    case shader = 27
    case shaderBinding = 28
    case animStack = 29
    case animLayer = 30
    case animValue = 31
    case animCurve = 32
    case displayLayer = 33
    case selectionSet = 34
    case selectionNode = 35
    case character = 36
    case constraint = 37
    case audioLayer = 38
    case audioClip = 39
    case pose = 40
    case metadataObject = 41

    /// `UFBX_ELEMENT_TYPE_FIRST_ATTRIB` .. `LAST_ATTRIB` (mesh .. lodGroup):
    /// the contiguous range of types that can be a node's attached attribute.
    public static let firstAttrib = FBXElementType.mesh
    public static let lastAttrib = FBXElementType.lodGroup

    public var isAttribute: Bool {
        rawValue >= FBXElementType.firstAttrib.rawValue &&
        rawValue <= FBXElementType.lastAttrib.rawValue
    }
}

// MARK: - Connection

/// Mirrors `ufbx_connection` (ufbx.h:749-754). `src`/`dst` are `element_id`s;
/// `srcProp`/`dstProp` are empty for object-object (OO) connections.
public struct FBXConnection: Sendable {
    public let srcID: Int32
    public let dstID: Int32
    public let srcProp: String
    public let dstProp: String

    public init(srcID: Int32, dstID: Int32, srcProp: String = "", dstProp: String = "") {
        self.srcID = srcID
        self.dstID = dstID
        self.srcProp = srcProp
        self.dstProp = dstProp
    }
}

// MARK: - Element base

/// Shared base for every scene element, mirroring `ufbx_element` (ufbx.h:763).
/// Reference identity matters (cyclic graph, shared instancing), so elements
/// are classes owned by `scene.elements`. Frozen after load → `@unchecked
/// Sendable` (DESIGN freeze rule).
public class FBXElement: @unchecked Sendable {
    /// Arena that owns this element (created empty before any element).
    public unowned let scene: FBXScene
    public internal(set) var name: String
    public internal(set) var props: FBXProps
    /// Dense global index into `scene.elements`, in creation order.
    public let elementID: Int
    /// Index within this element's typed array (nodes reassigned at linearize).
    public internal(set) var typedID: Int
    public let type: FBXElementType

    /// File identity (real 64-bit FBX id, or a synthetic hash for < 7000).
    var fbxID: UInt64

    /// Slices into `scene.connections` / `scene.connectionsDstOrder`.
    var connectionsSrc: Range<Int> = 0..<0
    var connectionsDst: Range<Int> = 0..<0

    /// `element_id`s of the nodes that instance this element.
    public internal(set) var instanceIDs: [Int32] = []

    init(
        scene: FBXScene,
        name: String,
        props: FBXProps,
        elementID: Int,
        typedID: Int,
        type: FBXElementType,
        fbxID: UInt64
    ) {
        self.scene = scene
        self.name = name
        self.props = props
        self.elementID = elementID
        self.typedID = typedID
        self.type = type
        self.fbxID = fbxID
    }

    /// Nodes that reference this attribute element (`ufbx_element.instances`).
    public var instances: FBXNodeList {
        FBXNodeList(scene: scene, elementIDs: instanceIDs)
    }

    /// Downcast an `element_id` to a typed element, tolerating -1 / out of range.
    func typedElement<T: FBXElement>(_ id: Int32) -> T? {
        guard id >= 0, Int(id) < scene.elements.count else { return nil }
        return scene.elements[Int(id)] as? T
    }
}

// MARK: - Unknown element

/// Mirrors `ufbx_unknown` (ufbx.h:778-793): an element whose FBX object type
/// isn't specially modeled. Retains its raw FBX type strings.
public final class FBXUnknownElement: FBXElement, @unchecked Sendable {
    public internal(set) var fbxType: String = ""
    public internal(set) var superType: String = ""
    public internal(set) var subType: String = ""

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .unknown, fbxID: fbxID)
    }
}

// MARK: - Typed element list view

/// A `RandomAccessCollection` over a list of `element_id`s, downcasting each to
/// `T` on access (`ufbx_X_list` in ufbx). Value-type view; holds an `unowned`
/// reference to the owning scene (DESIGN.md list-views contract).
// @unchecked Sendable: a loaded scene is frozen (DESIGN freeze rule) and every
// element is `@unchecked Sendable`, so this value view over `unowned scene` +
// `[Int32]` is safe to share. Without it a sublist obtained from a Sendable
// `FBXScene` could not itself cross a concurrency boundary (Swift 6 diagnostic).
public struct FBXElementList<T: FBXElement>: RandomAccessCollection, @unchecked Sendable {
    public unowned let scene: FBXScene
    public let elementIDs: [Int32]

    @inlinable public init(scene: FBXScene, elementIDs: [Int32]) {
        self.scene = scene
        self.elementIDs = elementIDs
    }

    public typealias Index = Int
    public typealias Element = T

    // @inlinable: this is the primary scene-graph iteration path (node.children,
    // mesh.materials, ...); marking the collection members inlinable lets a
    // consumer in another module specialize the `as! T` downcast and bounds math
    // into its own loop instead of paying an out-of-module call per access.
    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { elementIDs.count }
    @inlinable public func index(after i: Int) -> Int { i + 1 }
    @inlinable public func index(before i: Int) -> Int { i - 1 }

    @inlinable public subscript(position: Int) -> T {
        scene.elements[Int(elementIDs[position])] as! T
    }
}

// MARK: - List typealiases

public typealias FBXNodeList = FBXElementList<FBXNode>
public typealias FBXMeshList = FBXElementList<FBXMesh>
public typealias FBXLightList = FBXElementList<FBXLight>
public typealias FBXCameraList = FBXElementList<FBXCamera>
public typealias FBXBoneList = FBXElementList<FBXBone>
public typealias FBXEmptyList = FBXElementList<FBXEmpty>
public typealias FBXMaterialList = FBXElementList<FBXMaterial>
public typealias FBXTextureList = FBXElementList<FBXTexture>
public typealias FBXVideoList = FBXElementList<FBXVideo>
public typealias FBXSkinDeformerList = FBXElementList<FBXSkinDeformer>
public typealias FBXSkinClusterList = FBXElementList<FBXSkinCluster>
public typealias FBXBlendDeformerList = FBXElementList<FBXBlendDeformer>
public typealias FBXBlendChannelList = FBXElementList<FBXBlendChannel>
public typealias FBXBlendShapeList = FBXElementList<FBXBlendShape>
public typealias FBXAnimStackList = FBXElementList<FBXAnimStack>
public typealias FBXAnimLayerList = FBXElementList<FBXAnimLayer>
public typealias FBXAnimValueList = FBXElementList<FBXAnimValue>
public typealias FBXAnimCurveList = FBXElementList<FBXAnimCurve>
public typealias FBXPoseList = FBXElementList<FBXPose>
