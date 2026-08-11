// `ufbx_scene` (ufbx.h:3935) and its `ufbx_metadata`/`ufbx_scene_settings`
// (ufbx.h:3754/3901). The scene is the arena: it strongly owns every element in
// `elements` (element_id order) plus a typed array per element type in ufbx
// order. Constructed empty up-front so elements can hold `unowned let scene`.

import Foundation

// MARK: - Coordinate axes

/// Mirrors `ufbx_coordinate_axis` (ufbx.h:1544-1554).
public enum FBXCoordinateAxis: Int, Sendable {
    case positiveX = 0
    case negativeX = 1
    case positiveY = 2
    case negativeY = 3
    case positiveZ = 4
    case negativeZ = 5
    case unknown = 6
}

/// Mirrors `ufbx_coordinate_axes` (ufbx.h:1560-1564). NOTE: `front` is the
/// *opposite* of forward.
public struct FBXCoordinateAxes: Sendable {
    public var up: FBXCoordinateAxis
    public var front: FBXCoordinateAxis
    public var right: FBXCoordinateAxis

    public init(
        up: FBXCoordinateAxis = .positiveY,
        front: FBXCoordinateAxis = .positiveZ,
        right: FBXCoordinateAxis = .positiveX
    ) {
        self.up = up
        self.front = front
        self.right = right
    }
}

// MARK: - Time enums

/// Mirrors `ufbx_time_mode` (ufbx.h:3854-3877), in order.
public enum FBXTimeMode: Int, Sendable {
    case `default` = 0
    case fps120 = 1
    case fps100 = 2
    case fps60 = 3
    case fps50 = 4
    case fps48 = 5
    case fps30 = 6
    case fps30Drop = 7
    case ntscDropFrame = 8
    case ntscFullFrame = 9
    case pal = 10
    case fps24 = 11
    case fps1000 = 12
    case filmFullFrame = 13
    case custom = 14
    case fps96 = 15
    case fps72 = 16
    case fps59_94 = 17
}

/// Mirrors `ufbx_time_protocol` (ufbx.h:3879-3885).
public enum FBXTimeProtocol: Int, Sendable {
    case smpte = 0
    case frameCount = 1
    case `default` = 2
}

/// Mirrors `ufbx_snap_mode` (ufbx.h:3889-3896).
public enum FBXSnapMode: Int, Sendable {
    case none = 0
    case snap = 1
    case play = 2
    case snapAndPlay = 3
}

// MARK: - Metadata

/// Mirrors the load-diagnostic subset of `ufbx_metadata` (ufbx.h:3754) that the
/// dump format needs. Warnings live on `FBXScene.warnings`, NOT here (DESIGN).
public struct FBXMetadata: Sendable {
    public var version: Int = 0
    public var ascii: Bool = false
    public var bigEndian: Bool = false
    public var creator: String = ""
    /// Basename only; set by `load(contentsOf:)`.
    public var filename: String = ""

    public init() {}
}

// MARK: - Scene settings

/// Mirrors `ufbx_scene_settings` (ufbx.h:3901-3933). `axes`/`unitMeters` are the
/// *original* file values (v1 does no axis/unit conversion).
public struct FBXSceneSettings: Sendable {
    public var axes: FBXCoordinateAxes = .init()
    /// Meters per world unit (finalizer sets it from `UnitScaleFactor / 100`).
    public var unitMeters: Double = 1
    public var framesPerSecond: Double = 24
    public var originalUnitMeters: Double = 1
    public var originalAxisUp: FBXCoordinateAxis = .unknown
    public var timeMode: FBXTimeMode = .default
    public var timeProtocol: FBXTimeProtocol = .default
    public var snapMode: FBXSnapMode = .none
    public var ambientColor: FBXVec3 = .zero
    public var defaultCamera: String = ""

    public init() {}
}

// MARK: - Scene

public final class FBXScene: @unchecked Sendable {
    public internal(set) var metadata: FBXMetadata = .init()
    public internal(set) var settings: FBXSceneSettings = .init()

    /// Every element, in `element_id` (creation) order — the arena.
    public internal(set) var elements: [FBXElement] = []

    // Typed arrays, one per implemented element type, in ufbx ordering.
    public internal(set) var unknowns: [FBXUnknownElement] = []
    public internal(set) var nodes: [FBXNode] = []          // [0] root, depth-sorted
    public internal(set) var meshes: [FBXMesh] = []
    public internal(set) var lights: [FBXLight] = []
    public internal(set) var cameras: [FBXCamera] = []
    public internal(set) var bones: [FBXBone] = []
    public internal(set) var empties: [FBXEmpty] = []
    public internal(set) var skinDeformers: [FBXSkinDeformer] = []
    public internal(set) var skinClusters: [FBXSkinCluster] = []
    public internal(set) var blendDeformers: [FBXBlendDeformer] = []
    public internal(set) var blendChannels: [FBXBlendChannel] = []
    public internal(set) var blendShapes: [FBXBlendShape] = []
    public internal(set) var materials: [FBXMaterial] = []
    public internal(set) var textures: [FBXTexture] = []
    public internal(set) var videos: [FBXVideo] = []
    public internal(set) var animStacks: [FBXAnimStack] = []
    public internal(set) var animLayers: [FBXAnimLayer] = []
    public internal(set) var animValues: [FBXAnimValue] = []
    public internal(set) var animCurves: [FBXAnimCurve] = []
    public internal(set) var poses: [FBXPose] = []

    /// The raw connection graph, sorted by src (with `connectionsDstOrder` a
    /// permutation sorted by dst).
    public internal(set) var connections: [FBXConnection] = []
    public internal(set) var connectionsDstOrder: [Int32] = []

    /// The implicit root node (`nodes[0]`).
    public internal(set) var rootNode: FBXNode!

    /// Default animation descriptor (all layers).
    public internal(set) var anim: FBXAnim = FBXAnim()

    /// The ONE warnings location (nothing on metadata) — DESIGN.
    public internal(set) var warnings: [FBXWarning] = []

    /// Internal, arena-first: the scene is created empty before any element so
    /// elements can capture `unowned let scene`.
    init() {}

    /// Fetch an element by `element_id`, tolerating -1 / out of range.
    public func element(_ id: Int32) -> FBXElement? {
        guard id >= 0, Int(id) < elements.count else { return nil }
        return elements[Int(id)]
    }

    public static func load(contentsOf url: URL, options: FBXLoadOptions = .init()) throws -> FBXScene {
        try Loader.load(contentsOf: url, options: options)
    }

    public static func load(data: Data, options: FBXLoadOptions = .init()) throws -> FBXScene {
        try Loader.load(data: data, options: options)
    }
}
