// Shared mutable state for the read → link → finalize pipeline, mirroring the
// per-load `ufbxi_context` fields the reader/linker/finalizer touch (ufbx.c:6293
// element_info, 6322 template, 12220-12414 id machinery, notes 05). Readers only
// APPEND elements/props/connections and register ids — nothing is resolved here;
// `SceneLinker`/`SceneFinalizer` (wave 4) consume `tmpConnections`/`fbxIDMap`.

import Foundation

// MARK: - Reader scratch types

/// A raw, unresolved connection edge (`ufbxi_tmp_connection`, ufbx.c:6300).
/// `src`/`dst` are FBX ids (real 64-bit for ≥7000, synthetic for <7000);
/// `SceneLinker` resolves them to `element_id`s (dangling → dropped).
struct TmpConnection {
    var srcID: UInt64
    var srcProp: String
    var dstID: UInt64
    var dstProp: String
}

/// Key into the property-template table (`ufbxi_template`, ufbx.c:6293): the FBX
/// class name (`Model`, `Material`, …) plus the `Fbx`-stripped sub-type.
struct TemplateKey: Hashable {
    var className: String
    var subType: String
}

/// The pre-typed bag of data every `ufbxi_read_*` element reader consumes
/// (`ufbxi_element_info`, ufbx.c:6322). `className` is the split `Type` half of
/// `Type::Name`; `subType` is the `Fbx`-stripped object sub-type.
struct ObjectInfo {
    var fbxID: UInt64
    var name: String
    var className: String
    var subType: String
    var props: FBXProps
}

/// Detected exporter, used only to gate quirks (`ufbx_exporter`, ufbx.h:3502).
/// Not part of the dump; kept on the context like ufbx's `uc->exporter`.
enum FBXExporter: Int, Sendable {
    case unknown = 0
    case fbxSDK = 1
    case blenderBinary = 2
    case blenderAscii = 3
    case motionBuilder = 4
    case ufbxWrite = 5
}

// MARK: - Load context

/// Owns the empty-up-front `FBXScene` arena plus every id map / scratch table the
/// load stages share. One instance per `load()` call, never escapes the loader.
final class LoadContext {
    let doc: FBXDocument
    let opts: FBXLoadOptions
    /// Created empty BEFORE any element so elements can capture `unowned scene`.
    let scene: FBXScene

    var version: Int { doc.version }
    /// `uc->from_ascii` — selects the `::` vs `\0\1` type/name separator etc.
    var fromAscii: Bool { doc.format == .ascii }

    // MARK: Id / connection tables (consumed by SceneLinker)

    /// fbx_id → element_id (`ufbxi_insert_fbx_id`, ufbx.c:12307).
    var fbxIDMap: [UInt64: Int32] = [:]
    /// node fbx_id → synthetic attribute fbx_id, pre-7000 only
    /// (`ufbxi_insert_fbx_attr`, ufbx.c:12336).
    var fbxAttrMap: [UInt64: UInt64] = [:]
    /// Raw OO/OP/PO/PP edges (`uc->tmp_connections`).
    var tmpConnections: [TmpConnection] = []
    /// Property templates keyed by (class, sub-type) — see `findTemplate`.
    var templates: [TemplateKey: FBXProps] = [:]

    // MARK: Reader outputs consumed by the finalizer (no scene field for these)

    /// The scene root's fbx id (`uc->root_id`); SceneLinker uses it to seed
    /// hierarchy.
    var rootID: UInt64 = 0
    /// `GlobalSettings` properties — `SceneFinalizer.updateSceneSettings` reads
    /// axes/units/fps/etc. from here (ufbx keeps these on `scene.settings.props`,
    /// which our `FBXSceneSettings` does not model — see report).
    var settingsProps = FBXProps()
    /// `SceneInfo` properties (`scene.metadata.scene_props`), for
    /// original/latest application metadata (not in the dump format).
    var sceneInfoProps = FBXProps()

    /// KTime ticks per second (`uc->ktime_sec`), chosen in the header extension;
    /// the Takes/anim-curve time decode divides by this.
    var ktimeSec: Int64 = 46_186_158_000
    var ktimeSecDouble: Double = 46_186_158_000.0

    /// One `FullWeights` list per blend channel, appended in `scene.blendChannels`
    /// creation order (`AnimationReader.readBlendChannel`); the finalizer builds
    /// per-channel blend keyframes from these in lockstep (notes 09).
    var tmpFullWeights: [[Double]] = []
    /// Unresolved pose bone matrices keyed by pose `element_id`
    /// (`AnimationReader.readPose`); the finalizer maps the raw fbx ids to nodes.
    var tmpBonePoses: [Int: [TmpBonePose]] = [:]

    // MARK: Exporter quirk gating

    var exporter: FBXExporter = .unknown
    var exporterVersion: UInt32 = 0
    /// `uc->blender_full_weights` — set for Blender binary exports; the skin
    /// finalizer keeps explicit zero weights when true (ufbx.c:12124, 21998).
    var blenderFullWeights = false

    // MARK: Warnings staging (copied to scene.warnings after finalize)

    var warnings: [FBXWarning] = []

    init(doc: FBXDocument, opts: FBXLoadOptions, scene: FBXScene) {
        self.doc = doc
        self.opts = opts
        self.scene = scene
    }

    // MARK: - Synthetic ids

    // ufbx: `ufbxi_push_synthetic_id` (ufbx.c:12229) counts up from
    // `UFBXI_SYNTHETIC_ID_START` (POINTER_ID_START + MAXIMUM_FAST_POINTER_ID =
    // 0xC000000000000000). Kept identical so synthetic ids never collide with the
    // string-derived (< 0x4000…) or real (< 0x8000…) id ranges.
    private var syntheticCounter: UInt64 = 0xC000_0000_0000_0000

    /// `ufbxi_push_synthetic_id`: a fresh id for a minted-from-nowhere element
    /// (helper nodes, pre-7100 blend shapes, Take stacks/layers/values/curves).
    func nextSyntheticID() -> UInt64 {
        syntheticCounter &+= 1
        return syntheticCounter
    }

    // ufbx: `ufbxi_synthetic_id_from_string` (ufbx.c:12250) returns the interned
    // string POINTER as the id — identical strings share a pointer, hence an id.
    // A Swift port cannot use pointers, so we intern by (sanitized) string value
    // to a small stable counter: same string → same id, which is all that the
    // object/connection matching relies on (values themselves are never ordered).
    private var syntheticStringMap: [String: UInt64] = [:]
    private var nextStringID: UInt64 = 1

    /// Stable per-name id for ALL version < 7000 objects and their connections.
    /// Callers MUST pass the same (sanitized) `Type::Name` string on both sides.
    func syntheticID(for name: String) -> UInt64 {
        if let id = syntheticStringMap[name] { return id }
        let id = nextStringID
        nextStringID &+= 1
        syntheticStringMap[name] = id
        return id
    }

    // ufbx: `ufbxi_validate_fbx_id` (ufbx.c:12260) — real ids in the reserved
    // pointer range (≥ 0x8000000000000000) are rehashed to synthetic ids so they
    // can't clash with pointer-derived ids. Consistent per source id.
    private var pointerIDMap: [UInt64: UInt64] = [:]

    func validateFbxID(_ id: UInt64) -> UInt64 {
        if id >= 0x8000_0000_0000_0000 {
            if let mapped = pointerIDMap[id] { return mapped }
            let mapped = nextSyntheticID()
            pointerIDMap[id] = mapped
            return mapped
        }
        return id
    }

    // MARK: - Element factory

    /// Create a typed element, append it to `scene.elements` (dense
    /// `element_id` order) and its typed array (dense `typed_id`), and register
    /// its fbx id. Props start empty; callers set `element.props` afterwards
    /// (mirrors ufbx, where readers fill props/data after the push).
    @discardableResult
    func makeElement(_ type: FBXElementType, name: String, fbxID: UInt64) -> FBXElement {
        makeElement(type, name: name, props: FBXProps(), fbxID: fbxID)
    }

    /// As above, seeding `props` up front (used by the object reader, which has
    /// already read+templated the properties).
    @discardableResult
    func makeElement(_ type: FBXElementType, name: String, props: FBXProps, fbxID: UInt64) -> FBXElement {
        let elementID = scene.elements.count
        let element: FBXElement

        switch type {
        case .node:
            let e = FBXNode(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.nodes.count, fbxID: fbxID)
            scene.nodes.append(e); element = e
        case .mesh:
            let e = FBXMesh(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.meshes.count, fbxID: fbxID)
            scene.meshes.append(e); element = e
        case .light:
            let e = FBXLight(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.lights.count, fbxID: fbxID)
            scene.lights.append(e); element = e
        case .camera:
            let e = FBXCamera(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.cameras.count, fbxID: fbxID)
            scene.cameras.append(e); element = e
        case .bone:
            let e = FBXBone(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.bones.count, fbxID: fbxID)
            scene.bones.append(e); element = e
        case .empty:
            let e = FBXEmpty(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.empties.count, fbxID: fbxID)
            scene.empties.append(e); element = e
        case .skinDeformer:
            let e = FBXSkinDeformer(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.skinDeformers.count, fbxID: fbxID)
            scene.skinDeformers.append(e); element = e
        case .skinCluster:
            let e = FBXSkinCluster(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.skinClusters.count, fbxID: fbxID)
            scene.skinClusters.append(e); element = e
        case .blendDeformer:
            let e = FBXBlendDeformer(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.blendDeformers.count, fbxID: fbxID)
            scene.blendDeformers.append(e); element = e
        case .blendChannel:
            let e = FBXBlendChannel(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.blendChannels.count, fbxID: fbxID)
            scene.blendChannels.append(e); element = e
        case .blendShape:
            let e = FBXBlendShape(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.blendShapes.count, fbxID: fbxID)
            scene.blendShapes.append(e); element = e
        case .material:
            let e = FBXMaterial(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.materials.count, fbxID: fbxID)
            scene.materials.append(e); element = e
        case .texture:
            let e = FBXTexture(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.textures.count, fbxID: fbxID)
            scene.textures.append(e); element = e
        case .video:
            let e = FBXVideo(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.videos.count, fbxID: fbxID)
            scene.videos.append(e); element = e
        case .animStack:
            let e = FBXAnimStack(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.animStacks.count, fbxID: fbxID)
            scene.animStacks.append(e); element = e
        case .animLayer:
            let e = FBXAnimLayer(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.animLayers.count, fbxID: fbxID)
            scene.animLayers.append(e); element = e
        case .animValue:
            let e = FBXAnimValue(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.animValues.count, fbxID: fbxID)
            scene.animValues.append(e); element = e
        case .animCurve:
            let e = FBXAnimCurve(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.animCurves.count, fbxID: fbxID)
            scene.animCurves.append(e); element = e
        case .pose:
            let e = FBXPose(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.poses.count, fbxID: fbxID)
            scene.poses.append(e); element = e
        default:
            // ufbx: unmodeled element types (marker, lodGroup, stereoCamera,
            // shader, constraint, …) — v1 has no dedicated class, so they land in
            // `unknowns` as a first-class-but-opaque element (never dropped).
            let e = FBXUnknownElement(scene: scene, name: name, props: props, elementID: elementID, typedID: scene.unknowns.count, fbxID: fbxID)
            scene.unknowns.append(e); element = e
        }

        scene.elements.append(element)
        insertFbxID(fbxID, elementID: Int32(elementID))
        return element
    }

    /// `ufbxi_insert_fbx_id` (ufbx.c:12307): first id wins; a collision warns
    /// (`UFBX_WARNING_DUPLICATE_OBJECT_ID`) and leaves the mapping unchanged.
    func insertFbxID(_ fbxID: UInt64, elementID: Int32) {
        if fbxIDMap[fbxID] != nil {
            warning(kind: .duplicateObjectID, info: "Duplicate object ID", elementID: elementID)
        } else {
            fbxIDMap[fbxID] = elementID
        }
    }

    // MARK: - Templates

    func registerTemplate(className: String, subType: String, props: FBXProps) {
        templates[TemplateKey(className: className, subType: subType)] = props
    }

    /// `ufbxi_find_template` (ufbx.c:12195): match class; sub-type must also match
    /// EXCEPT for Material/Model/AnimationStack/AnimationLayer, which take their
    /// class template regardless of sub-type. Empty templates → nil.
    func findTemplate(className: String, subType: String) -> FBXProps? {
        let wildcard = className == "Material" || className == "Model"
            || className == "AnimationStack" || className == "AnimationLayer"
        if wildcard {
            // One ObjectType per class in practice, so any match for this class.
            for (key, props) in templates where key.className == className {
                return props.props.isEmpty ? nil : props
            }
            return nil
        }
        guard let props = templates[TemplateKey(className: className, subType: subType)] else { return nil }
        return props.props.isEmpty ? nil : props
    }

    // MARK: - Warnings (ufbxi_vwarnf_imp dedup, ufbx.c:4833)

    // Deduplicated types (>= UFBX_WARNING_TYPE_FIRST_DEDUPLICATED = INDEX_CLAMPED,
    // ufbx.h:3587): consecutive warnings of the same type + element are coalesced
    // into a single entry with an incremented count.
    private func dedupSlot(_ kind: FBXWarning.Kind, hasElement: Bool) -> Int? {
        let base: Int
        switch kind {
        case .indexClamped: base = 0
        case .badUnicode: base = 1
        case .badBase64Content: base = 2
        case .badElementConnectedToRoot: base = 3
        case .duplicateObjectID: base = 4
        case .emptyFaceRemoved: base = 5
        default: return nil
        }
        return base * 2 + (hasElement ? 1 : 0)
    }
    private var prevWarningIndex: [Int: Int] = [:]

    func warning(kind: FBXWarning.Kind, info: String = "", elementID: Int32 = -1) {
        let hasElement = elementID != -1
        if let slot = dedupSlot(kind, hasElement: hasElement) {
            if let idx = prevWarningIndex[slot], warnings[idx].elementID == elementID {
                warnings[idx].count += 1
                return
            }
            warnings.append(FBXWarning(kind: kind, info: info, count: 1, elementID: elementID))
            prevWarningIndex[slot] = warnings.count - 1
        } else {
            warnings.append(FBXWarning(kind: kind, info: info, count: 1, elementID: elementID))
        }
    }
}
