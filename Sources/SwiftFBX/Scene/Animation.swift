// Animation model: `ufbx_anim` (ufbx.h:3064), `ufbx_anim_stack`/`_layer`/
// `_value`/`_curve` (ufbx.h:3090-3236), `ufbx_anim_prop`, `ufbx_keyframe` and
// `ufbx_extrapolation`. `FBXInterpolation`/`FBXTangent` live in Math/Math.swift.

import Foundation

// MARK: - Anim prop / descriptor

/// Mirrors `ufbx_anim_prop` (ufbx.h:3105-3112): binds a property name on an
/// element to an `FBXAnimValue`. All refs are `element_id`s.
public struct FBXAnimProp: Sendable {
    /// `element_id` of the animated element.
    public var elementID: Int32
    public var propName: String
    /// `element_id` of the `FBXAnimValue`.
    public var animValueID: Int32
    public init(elementID: Int32 = -1, propName: String = "", animValueID: Int32 = -1) {
        self.elementID = elementID
        self.propName = propName
        self.animValueID = animValueID
    }
}

/// Mirrors `ufbx_anim` (ufbx.h:3064-3088): the descriptor evaluated against.
/// Holds strong references to its layers. `overrideLayerWeights` empty ⇒ use
/// each layer's own `weight`.
public struct FBXAnim: Sendable {
    public var layers: [FBXAnimLayer]
    public var overrideLayerWeights: [Double]
    public var timeBegin: Double
    public var timeEnd: Double
    public var ignoreConnections: Bool

    public init(
        layers: [FBXAnimLayer] = [],
        overrideLayerWeights: [Double] = [],
        timeBegin: Double = 0,
        timeEnd: Double = 0,
        ignoreConnections: Bool = false
    ) {
        self.layers = layers
        self.overrideLayerWeights = overrideLayerWeights
        self.timeBegin = timeBegin
        self.timeEnd = timeEnd
        self.ignoreConnections = ignoreConnections
    }
}

// MARK: - Keyframe / extrapolation

/// Mirrors `ufbx_keyframe` (ufbx.h:3203-3209). Interpolation of a span is
/// decided by the *previous* key's `interpolation`.
public struct FBXKeyframe: Sendable {
    public var time: Double
    public var value: Double
    public var interpolation: FBXInterpolation
    public var left: FBXTangent
    public var right: FBXTangent

    public init(
        time: Double = 0,
        value: Double = 0,
        interpolation: FBXInterpolation = .cubic,
        left: FBXTangent = .init(),
        right: FBXTangent = .init()
    ) {
        self.time = time
        self.value = value
        self.interpolation = interpolation
        self.left = left
        self.right = right
    }
}

/// Mirrors `ufbx_extrapolation_mode` (ufbx.h:3165-3173).
public enum FBXExtrapolationMode: Int, Sendable {
    case constant = 0
    case `repeat` = 1
    case mirror = 2
    case slope = 3
    case repeatRelative = 4
}

/// Mirrors `ufbx_extrapolation` (ufbx.h:3177-3183). Negative `repeatCount` means
/// infinite.
public struct FBXExtrapolation: Sendable {
    public var mode: FBXExtrapolationMode
    public var repeatCount: Int32
    public init(mode: FBXExtrapolationMode = .constant, repeatCount: Int32 = 0) {
        self.mode = mode
        self.repeatCount = repeatCount
    }
}

// MARK: - Anim stack

public final class FBXAnimStack: FBXElement, @unchecked Sendable {
    public internal(set) var timeBegin: Double = 0
    public internal(set) var timeEnd: Double = 0
    /// `element_id`s of the stack's layers.
    public internal(set) var layerIDs: [Int32] = []
    /// Descriptor for evaluating this stack (built by the finalizer).
    public internal(set) var anim: FBXAnim = FBXAnim()

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .animStack, fbxID: fbxID)
    }

    public var layers: FBXAnimLayerList { FBXAnimLayerList(scene: scene, elementIDs: layerIDs) }
}

// MARK: - Anim layer

public final class FBXAnimLayer: FBXElement, @unchecked Sendable {
    public internal(set) var weight: Double = 1
    public internal(set) var weightIsAnimated: Bool = false
    public internal(set) var blended: Bool = false
    public internal(set) var additive: Bool = false
    public internal(set) var composeRotation: Bool = true
    public internal(set) var composeScale: Bool = true

    /// `element_id`s of the layer's anim values.
    public internal(set) var animValueIDs: [Int32] = []
    /// Sorted by `(element_id, prop_name)` (DESIGN / ufbx contract).
    public internal(set) var animProps: [FBXAnimProp] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .animLayer, fbxID: fbxID)
    }

    public var animValues: FBXAnimValueList { FBXAnimValueList(scene: scene, elementIDs: animValueIDs) }

    /// Per-layer descriptor (`ufbx_anim_layer.anim`). Computed to avoid a
    /// self-referential retain cycle (`anim.layers == [self]`).
    public var anim: FBXAnim { FBXAnim(layers: [self]) }
}

// MARK: - Anim value

public final class FBXAnimValue: FBXElement, @unchecked Sendable {
    public internal(set) var defaultValue: FBXVec3 = .zero
    /// `element_id`s of up to 3 component curves; -1 = missing component.
    public internal(set) var curveIDs: [Int32] = [-1, -1, -1]

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .animValue, fbxID: fbxID)
    }

    /// The (up to 3) component curves; entry is nil for a missing component.
    /// Convenience view for external callers — allocates a fresh array per access,
    /// so the animation-eval hot path uses `curve(_:)` instead.
    public var curves: [FBXAnimCurve?] {
        curveIDs.map { typedElement($0) }
    }

    /// The component curve at `i` (0…2), or nil if absent — the allocation-free
    /// accessor used on the evaluation hot path (avoids materializing `curves`).
    public func curve(_ i: Int) -> FBXAnimCurve? {
        (i >= 0 && i < curveIDs.count) ? typedElement(curveIDs[i]) : nil
    }
}

// MARK: - Anim curve

public final class FBXAnimCurve: FBXElement, @unchecked Sendable {
    public internal(set) var keyframes: [FBXKeyframe] = []
    public internal(set) var preExtrapolation: FBXExtrapolation = .init()
    public internal(set) var postExtrapolation: FBXExtrapolation = .init()
    public internal(set) var minValue: Double = 0
    public internal(set) var maxValue: Double = 0
    public internal(set) var minTime: Double = 0
    public internal(set) var maxTime: Double = 0

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .animCurve, fbxID: fbxID)
    }
}
