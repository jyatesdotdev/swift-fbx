// Materials, textures and videos. Mirrors `ufbx_material` (ufbx.h:2638), the
// `ufbx_material_map` value-or-texture cell (ufbx.h:2288), the 20 legacy FBX
// maps + 55 PBR maps + 23 feature toggles, `ufbx_texture` (ufbx.h:2890) and
// `ufbx_video` (ufbx.h:2962). The FBX maps are populated by the finalizer's
// fetchMaps port (notes 09/14); PBR maps are stretch.

import Foundation

// MARK: - Material map

/// Mirrors `ufbx_material_map` (ufbx.h:2288-2320): a constant value and/or a
/// bound texture. `valueComponents` (0-4) says how many of `valueVec4`'s
/// components are meaningful; `hasValue` records whether the file specified a
/// value (a factor may carry a synthesized non-zero default with `hasValue ==
/// false` — see `ufbxi_update_factor`). `textureID` is an `element_id`, -1 none.
public struct FBXMaterialMap: Sendable {
    public var valueVec4: FBXVec4
    public var valueInt: Int64
    public var valueComponents: Int
    public var hasValue: Bool
    public var textureID: Int32
    public var textureEnabled: Bool
    public var featureDisabled: Bool

    public init(
        valueVec4: FBXVec4 = .init(),
        valueInt: Int64 = 0,
        valueComponents: Int = 0,
        hasValue: Bool = false,
        textureID: Int32 = -1,
        textureEnabled: Bool = false,
        featureDisabled: Bool = false
    ) {
        self.valueVec4 = valueVec4
        self.valueInt = valueInt
        self.valueComponents = valueComponents
        self.hasValue = hasValue
        self.textureID = textureID
        self.textureEnabled = textureEnabled
        self.featureDisabled = featureDisabled
    }

    public var valueReal: Double { valueVec4.x }
    public var valueVec2: FBXVec2 { FBXVec2(valueVec4.x, valueVec4.y) }
    public var valueVec3: FBXVec3 { FBXVec3(valueVec4.x, valueVec4.y, valueVec4.z) }
}

/// Mirrors `ufbx_material_feature_info` (ufbx.h:2323-2332).
public struct FBXMaterialFeatureInfo: Sendable {
    public var enabled: Bool
    public var isExplicit: Bool
    public init(enabled: Bool = false, isExplicit: Bool = false) {
        self.enabled = enabled
        self.isExplicit = isExplicit
    }
}

/// Mirrors `ufbx_material_texture` (ufbx.h:2335-2342). `textureID` is an
/// `element_id`.
public struct FBXMaterialTexture: Sendable {
    public var materialProp: String
    public var shaderProp: String
    public var textureID: Int32
    public init(materialProp: String = "", shaderProp: String = "", textureID: Int32 = -1) {
        self.materialProp = materialProp
        self.shaderProp = shaderProp
        self.textureID = textureID
    }
}

// MARK: - FBX legacy maps

/// Mirrors `ufbx_material_fbx_maps` (ufbx.h:2513-2539): the 20 Lambert/Phong
/// channels, field order per the ufbx struct.
public struct FBXMaterialFBXMaps: Sendable {
    public var diffuseFactor = FBXMaterialMap()
    public var diffuseColor = FBXMaterialMap()
    public var specularFactor = FBXMaterialMap()
    public var specularColor = FBXMaterialMap()
    public var specularExponent = FBXMaterialMap()
    public var reflectionFactor = FBXMaterialMap()
    public var reflectionColor = FBXMaterialMap()
    public var transparencyFactor = FBXMaterialMap()
    public var transparencyColor = FBXMaterialMap()
    public var emissionFactor = FBXMaterialMap()
    public var emissionColor = FBXMaterialMap()
    public var ambientFactor = FBXMaterialMap()
    public var ambientColor = FBXMaterialMap()
    public var normalMap = FBXMaterialMap()
    public var bump = FBXMaterialMap()
    public var bumpFactor = FBXMaterialMap()
    public var displacementFactor = FBXMaterialMap()
    public var displacement = FBXMaterialMap()
    public var vectorDisplacementFactor = FBXMaterialMap()
    public var vectorDisplacement = FBXMaterialMap()

    public init() {}

    /// The 20 maps paired with their `ufbx_material_fbx_maps` snake_case names,
    /// in ufbx enum order — convenient for the dumper.
    public var allMaps: [(name: String, map: FBXMaterialMap)] {
        [
            ("diffuse_factor", diffuseFactor),
            ("diffuse_color", diffuseColor),
            ("specular_factor", specularFactor),
            ("specular_color", specularColor),
            ("specular_exponent", specularExponent),
            ("reflection_factor", reflectionFactor),
            ("reflection_color", reflectionColor),
            ("transparency_factor", transparencyFactor),
            ("transparency_color", transparencyColor),
            ("emission_factor", emissionFactor),
            ("emission_color", emissionColor),
            ("ambient_factor", ambientFactor),
            ("ambient_color", ambientColor),
            ("normal_map", normalMap),
            ("bump", bump),
            ("bump_factor", bumpFactor),
            ("displacement_factor", displacementFactor),
            ("displacement", displacement),
            ("vector_displacement_factor", vectorDisplacementFactor),
            ("vector_displacement", vectorDisplacement),
        ]
    }
}

// MARK: - PBR maps (stretch)

/// Mirrors `ufbx_material_pbr_maps` (ufbx.h:2541-2603): the ~55 normalized PBR
/// channels. Populated only if/when PBR fetch is implemented (stretch scope).
public struct FBXMaterialPBRMaps: Sendable {
    public var baseFactor = FBXMaterialMap()
    public var baseColor = FBXMaterialMap()
    public var roughness = FBXMaterialMap()
    public var metalness = FBXMaterialMap()
    public var diffuseRoughness = FBXMaterialMap()
    public var specularFactor = FBXMaterialMap()
    public var specularColor = FBXMaterialMap()
    public var specularIOR = FBXMaterialMap()
    public var specularAnisotropy = FBXMaterialMap()
    public var specularRotation = FBXMaterialMap()
    public var transmissionFactor = FBXMaterialMap()
    public var transmissionColor = FBXMaterialMap()
    public var transmissionDepth = FBXMaterialMap()
    public var transmissionScatter = FBXMaterialMap()
    public var transmissionScatterAnisotropy = FBXMaterialMap()
    public var transmissionDispersion = FBXMaterialMap()
    public var transmissionRoughness = FBXMaterialMap()
    public var transmissionExtraRoughness = FBXMaterialMap()
    public var transmissionPriority = FBXMaterialMap()
    public var transmissionEnableInAOV = FBXMaterialMap()
    public var subsurfaceFactor = FBXMaterialMap()
    public var subsurfaceColor = FBXMaterialMap()
    public var subsurfaceRadius = FBXMaterialMap()
    public var subsurfaceScale = FBXMaterialMap()
    public var subsurfaceAnisotropy = FBXMaterialMap()
    public var subsurfaceTintColor = FBXMaterialMap()
    public var subsurfaceType = FBXMaterialMap()
    public var sheenFactor = FBXMaterialMap()
    public var sheenColor = FBXMaterialMap()
    public var sheenRoughness = FBXMaterialMap()
    public var coatFactor = FBXMaterialMap()
    public var coatColor = FBXMaterialMap()
    public var coatRoughness = FBXMaterialMap()
    public var coatIOR = FBXMaterialMap()
    public var coatAnisotropy = FBXMaterialMap()
    public var coatRotation = FBXMaterialMap()
    public var coatNormal = FBXMaterialMap()
    public var coatAffectBaseColor = FBXMaterialMap()
    public var coatAffectBaseRoughness = FBXMaterialMap()
    public var thinFilmFactor = FBXMaterialMap()
    public var thinFilmThickness = FBXMaterialMap()
    public var thinFilmIOR = FBXMaterialMap()
    public var emissionFactor = FBXMaterialMap()
    public var emissionColor = FBXMaterialMap()
    public var opacity = FBXMaterialMap()
    public var indirectDiffuse = FBXMaterialMap()
    public var indirectSpecular = FBXMaterialMap()
    public var normalMap = FBXMaterialMap()
    public var tangentMap = FBXMaterialMap()
    public var displacementMap = FBXMaterialMap()
    public var matteFactor = FBXMaterialMap()
    public var matteColor = FBXMaterialMap()
    public var ambientOcclusion = FBXMaterialMap()
    public var glossiness = FBXMaterialMap()
    public var coatGlossiness = FBXMaterialMap()
    public var transmissionGlossiness = FBXMaterialMap()

    public init() {}
}

/// Mirrors `ufbx_material_features` (ufbx.h:2605-2634): 23 feature toggles.
public struct FBXMaterialFeatures: Sendable {
    public var pbr = FBXMaterialFeatureInfo()
    public var metalness = FBXMaterialFeatureInfo()
    public var diffuse = FBXMaterialFeatureInfo()
    public var specular = FBXMaterialFeatureInfo()
    public var emission = FBXMaterialFeatureInfo()
    public var transmission = FBXMaterialFeatureInfo()
    public var coat = FBXMaterialFeatureInfo()
    public var sheen = FBXMaterialFeatureInfo()
    public var opacity = FBXMaterialFeatureInfo()
    public var ambientOcclusion = FBXMaterialFeatureInfo()
    public var matte = FBXMaterialFeatureInfo()
    public var unlit = FBXMaterialFeatureInfo()
    public var ior = FBXMaterialFeatureInfo()
    public var diffuseRoughness = FBXMaterialFeatureInfo()
    public var transmissionRoughness = FBXMaterialFeatureInfo()
    public var thinWalled = FBXMaterialFeatureInfo()
    public var caustics = FBXMaterialFeatureInfo()
    public var exitToBackground = FBXMaterialFeatureInfo()
    public var internalReflections = FBXMaterialFeatureInfo()
    public var doubleSided = FBXMaterialFeatureInfo()
    public var roughnessAsGlossiness = FBXMaterialFeatureInfo()
    public var coatRoughnessAsGlossiness = FBXMaterialFeatureInfo()
    public var transmissionRoughnessAsGlossiness = FBXMaterialFeatureInfo()

    public init() {}
}

/// Mirrors `ufbx_shader_type` (ufbx.h:2347-2388).
public enum FBXShaderType: Int, Sendable {
    case unknown = 0
    case fbxLambert = 1
    case fbxPhong = 2
    case oslStandardSurface = 3
    case arnoldStandardSurface = 4
    case threeDSMaxPhysicalMaterial = 5
    case threeDSMaxPBRMetalRough = 6
    case threeDSMaxPBRSpecGloss = 7
    case gltfMaterial = 8
    case openPBRMaterial = 9
    case shaderFXGraph = 10
    case blenderPhong = 11
    case wavefrontMTL = 12
}

// MARK: - Material

public final class FBXMaterial: FBXElement, @unchecked Sendable {
    public internal(set) var fbx = FBXMaterialFBXMaps()
    public internal(set) var pbr = FBXMaterialPBRMaps()
    public internal(set) var features = FBXMaterialFeatures()
    public internal(set) var shaderType: FBXShaderType = .unknown
    /// `element_id` of the optional extended shader, -1 = none.
    public internal(set) var shaderID: Int32 = -1
    public internal(set) var shadingModelName: String = ""
    public internal(set) var shaderPropPrefix: String = ""
    /// All textures connected to any property, sorted by `materialProp`.
    public internal(set) var textures: [FBXMaterialTexture] = []

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .material, fbxID: fbxID)
    }
}

// MARK: - Texture

/// Mirrors `ufbx_texture_type` (ufbx.h:2673-2694).
public enum FBXTextureType: Int, Sendable {
    case file = 0
    case layered = 1
    case procedural = 2
    case shader = 3
}

/// Mirrors `ufbx_wrap_mode` (ufbx.h:2739-2746).
public enum FBXWrapMode: Int, Sendable {
    case `repeat` = 0
    case clamp = 1
}

/// Mirrors `ufbx_blend_mode` (ufbx.h:2700-2734): layered-texture compositing.
public enum FBXBlendMode: Int, Sendable {
    case translucent = 0
    case additive = 1
    case multiply = 2
    case multiply2X = 3
    case over = 4
    case replace = 5
    case dissolve = 6
    case darken = 7
    case colorBurn = 8
    case linearBurn = 9
    case darkerColor = 10
    case lighten = 11
    case screen = 12
    case colorDodge = 13
    case linearDodge = 14
    case lighterColor = 15
    case softLight = 16
    case hardLight = 17
    case vividLight = 18
    case linearLight = 19
    case pinLight = 20
    case hardMix = 21
    case difference = 22
    case exclusion = 23
    case subtract = 24
    case divide = 25
    case hue = 26
    case saturation = 27
    case color = 28
    case luminosity = 29
    case overlay = 30
}

/// Mirrors `ufbx_texture_layer` (ufbx.h:2749-2753). `textureID` is an `element_id`.
public struct FBXTextureLayer: Sendable {
    public var textureID: Int32
    public var blendMode: FBXBlendMode
    public var alpha: Double
    public init(textureID: Int32 = -1, blendMode: FBXBlendMode = .over, alpha: Double = 1) {
        self.textureID = textureID
        self.blendMode = blendMode
        self.alpha = alpha
    }
}

public final class FBXTexture: FBXElement, @unchecked Sendable {
    public internal(set) var textureType: FBXTextureType = .file

    // FILE: paths (UTF-8) and their raw byte variants
    public internal(set) var filename: String = ""
    public internal(set) var absoluteFilename: String = ""
    public internal(set) var relativeFilename: String = ""
    public internal(set) var rawFilename: Data = Data()
    public internal(set) var rawAbsoluteFilename: Data = Data()
    public internal(set) var rawRelativeFilename: Data = Data()

    /// Embedded content (raw image bytes). Presence surfaced as `hasContent`.
    public internal(set) var content: Data = Data()
    /// True if this texture resolves to embedded content (own or via video) —
    /// set by the finalizer's video-content resolution.
    public internal(set) var hasContent: Bool = false

    /// `element_id` of a connected `FBXVideo`, -1 = none.
    public internal(set) var videoID: Int32 = -1
    /// Index into `scene.textureFiles`, -1 = none (`UFBX_NO_INDEX`).
    public internal(set) var fileIndex: Int = -1
    public internal(set) var hasFile: Bool = false

    // LAYERED
    public internal(set) var layers: [FBXTextureLayer] = []
    // SHADER: `element_id` of a shader element, -1 = none
    public internal(set) var shaderID: Int32 = -1
    /// File textures representing this texture (always includes itself for FILE).
    public internal(set) var fileTextureIDs: [Int32] = []

    public internal(set) var uvSet: String = ""
    public internal(set) var wrapU: FBXWrapMode = .repeat
    public internal(set) var wrapV: FBXWrapMode = .repeat

    // UV transform (computed independently of the node transform system)
    public internal(set) var hasUVTransform: Bool = false
    public internal(set) var uvTransform: FBXTransform = .identity
    public internal(set) var textureToUV: FBXMatrix = .identity
    public internal(set) var uvToTexture: FBXMatrix = .identity

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .texture, fbxID: fbxID)
    }

    public var video: FBXVideo? { typedElement(videoID) }
    public var fileTextures: FBXTextureList { FBXTextureList(scene: scene, elementIDs: fileTextureIDs) }
}

// MARK: - Video

/// Mirrors `ufbx_video` (ufbx.h:2962-2994). Minimal passthrough; embedded
/// decoding is out of scope (only content presence matters).
public final class FBXVideo: FBXElement, @unchecked Sendable {
    public internal(set) var filename: String = ""
    public internal(set) var absoluteFilename: String = ""
    public internal(set) var relativeFilename: String = ""
    public internal(set) var rawFilename: Data = Data()
    public internal(set) var rawAbsoluteFilename: Data = Data()
    public internal(set) var rawRelativeFilename: Data = Data()
    public internal(set) var content: Data = Data()

    public init(
        scene: FBXScene, name: String, props: FBXProps,
        elementID: Int, typedID: Int, fbxID: UInt64
    ) {
        super.init(scene: scene, name: name, props: props,
                   elementID: elementID, typedID: typedID, type: .video, fbxID: fbxID)
    }
}
