// Node attribute elements: `ufbx_light` (ufbx.h:1424), `ufbx_camera`
// (ufbx.h:1567), `ufbx_bone` (ufbx.h:1635), `ufbx_empty` (ufbx.h:1656), plus
// `ufbx_pose`/`ufbx_bone_pose` (ufbx.h:3444-3475) and their enums.

import Foundation

// MARK: - Light

/// Mirrors `ufbx_light_type` (ufbx.h:1381-1400).
public enum FBXLightType: Int, Sendable {
    case point = 0
    case directional = 1
    case spot = 2
    case area = 3
    case volume = 4
}

/// Mirrors `ufbx_light_decay` (ufbx.h:1403-1412).
public enum FBXLightDecay: Int, Sendable {
    case none = 0
    case linear = 1
    case quadratic = 2
    case cubic = 3
}

/// Mirrors `ufbx_light_area_shape` (ufbx.h:1414-1421).
public enum FBXLightAreaShape: Int, Sendable {
    case rectangle = 0
    case sphere = 1
}

public final class FBXLight: FBXElement, @unchecked Sendable {
    public internal(set) var color: FBXVec3 = .zero
    /// Already scaled by 1/100 from the raw `"Intensity"` property (ufbx quirk).
    public internal(set) var intensity: Double = 0
    /// Local-space aim direction (usually -Y).
    public internal(set) var localDirection: FBXVec3 = FBXVec3(0, -1, 0)
    public internal(set) var lightType: FBXLightType = .point
    public internal(set) var decay: FBXLightDecay = .none
    public internal(set) var areaShape: FBXLightAreaShape = .rectangle
    public internal(set) var innerAngle: Double = 0
    public internal(set) var outerAngle: Double = 0
    public internal(set) var castLight: Bool = true
    public internal(set) var castShadows: Bool = false

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .light, fbxID: fbxID)
    }
}

// MARK: - Camera

/// Mirrors `ufbx_projection_mode` (ufbx.h:1453-1461).
public enum FBXProjectionMode: Int, Sendable {
    case perspective = 0
    case orthographic = 1
}

/// Mirrors `ufbx_aspect_mode` (ufbx.h:1467-1480).
public enum FBXAspectMode: Int, Sendable {
    case windowSize = 0
    case fixedRatio = 1
    case fixedResolution = 2
    case fixedWidth = 3
    case fixedHeight = 4
}

/// Mirrors `ufbx_aperture_mode` (ufbx.h:1486-1497).
public enum FBXApertureMode: Int, Sendable {
    case horizontalAndVertical = 0
    case horizontal = 1
    case vertical = 2
    case focalLength = 3
}

/// Mirrors `ufbx_gate_fit` (ufbx.h:1503-1519).
public enum FBXGateFit: Int, Sendable {
    case none = 0
    case vertical = 1
    case horizontal = 2
    case fill = 3
    case overscan = 4
    case stretch = 5
}

/// Mirrors `ufbx_aperture_format` (ufbx.h:1525-1540).
public enum FBXApertureFormat: Int, Sendable {
    case custom = 0
    case theatrical16mm = 1
    case super16mm = 2
    case academy35mm = 3
    case tvProjection35mm = 4
    case fullAperture35mm = 5
    case projection185_35mm = 6
    case anamorphic35mm = 7
    case projection70mm = 8
    case vistaVision = 9
    case dynaVision = 10
    case imax = 11
}

public final class FBXCamera: FBXElement, @unchecked Sendable {
    public internal(set) var projectionMode: FBXProjectionMode = .perspective
    public internal(set) var resolutionIsPixels: Bool = false
    public internal(set) var resolution: FBXVec2 = .zero
    public internal(set) var fieldOfViewDeg: FBXVec2 = .zero
    public internal(set) var fieldOfViewTan: FBXVec2 = .zero
    public internal(set) var orthographicExtent: Double = 0
    public internal(set) var orthographicSize: FBXVec2 = .zero
    public internal(set) var projectionPlane: FBXVec2 = .zero
    public internal(set) var aspectRatio: Double = 0
    public internal(set) var nearPlane: Double = 0
    public internal(set) var farPlane: Double = 0
    public internal(set) var projectionAxes: FBXCoordinateAxes = .init()

    // Advanced (raw) inputs used to compute the above
    public internal(set) var aspectMode: FBXAspectMode = .windowSize
    public internal(set) var apertureMode: FBXApertureMode = .horizontalAndVertical
    public internal(set) var gateFit: FBXGateFit = .none
    public internal(set) var apertureFormat: FBXApertureFormat = .custom
    public internal(set) var focalLengthMm: Double = 0
    public internal(set) var filmSizeInch: FBXVec2 = .zero
    public internal(set) var apertureSizeInch: FBXVec2 = .zero
    public internal(set) var squeezeRatio: Double = 0

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .camera, fbxID: fbxID)
    }
}

// MARK: - Bone

public final class FBXBone: FBXElement, @unchecked Sendable {
    public internal(set) var radius: Double = 0
    public internal(set) var relativeLength: Double = 0
    public internal(set) var isRoot: Bool = false

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .bone, fbxID: fbxID)
    }
}

// MARK: - Empty

/// Mirrors `ufbx_empty` (ufbx.h:1656-1664): a marker/locator/Null with no data
/// of its own beyond the element base.
public final class FBXEmpty: FBXElement, @unchecked Sendable {
    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .empty, fbxID: fbxID)
    }
}

// MARK: - Pose

/// Mirrors `ufbx_bone_pose` (ufbx.h:3444-3457). `boneNodeID` is an `element_id`;
/// `boneToParent` is approximated from the parent's current world transform
/// (FBX only stores world-space bind matrices).
public struct FBXBonePose: Sendable {
    public var boneNodeID: Int32
    public var boneToWorld: FBXMatrix
    public var boneToParent: FBXMatrix
    public init(boneNodeID: Int32 = -1, boneToWorld: FBXMatrix = .identity, boneToParent: FBXMatrix = .identity) {
        self.boneNodeID = boneNodeID
        self.boneToWorld = boneToWorld
        self.boneToParent = boneToParent
    }
}

/// Mirrors `ufbx_pose` (ufbx.h:3461-3475). `bonePoses` sorted by node `typedID`.
public final class FBXPose: FBXElement, @unchecked Sendable {
    public internal(set) var isBindPose: Bool = false
    public internal(set) var bonePoses: [FBXBonePose] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .pose, fbxID: fbxID)
    }
}
