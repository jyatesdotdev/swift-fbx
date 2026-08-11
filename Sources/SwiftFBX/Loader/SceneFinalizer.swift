// The `ufbxi_update_*` half of the load pipeline: turns each element's interned
// `props` into its final interpreted fields. Ports `ufbxi_update_scene_settings`
// (ufbx.c:23903), `ufbxi_update_adjust_transforms` (23676, default-scoped),
// `ufbxi_modify_geometry`'s tail (21351), and `ufbxi_update_scene` (23806) with
// its per-element helpers — the full FBX transform chain (`ufbxi_get_transform`
// 22836), inherit-mode world composition (`ufbxi_update_node` 22955), lights,
// cameras, bones, skin clusters/poses, blend channels, textures, and material
// `ufbxi_fetch_maps` (20124, FBX-side maps only). Runs after `SceneLinker`, in
// ufbx's `ufbxi_load_imp` order (ufbx.c:25325-25353).
//
// Everything here is scoped to DEFAULT load options: axis/unit/space conversion
// is off (target axes invalid, target unit 0, space_conversion == TRANSFORM_ROOT),
// so `axis_matrix` is all-zero, `unit_scale` is 1, `mirror_axis` is NONE, and every
// node's `adjust_*` compensation is identity. The call structure of the conversion
// stages is preserved but their bodies collapse to no-ops (DESIGN.md scope).

import Foundation

enum SceneFinalizer {

    // Per-load scalars ufbx keeps on `scene.metadata` that our `FBXMetadata` does
    // not model (they are not dumped): set at the tail of `ufbxi_finalize_scene`
    // (ufbx.c:22605-22621), `ufbxi_update_adjust_transforms` (23736-23744), and
    // `ufbxi_modify_geometry` (21351). Threaded into the per-element updates.
    private struct Meta {
        var geometryScale = 1.0
        var rootScale = 1.0
        var rootRotation = FBXQuat.identity
        var mirrorAxis = FBXMirrorAxis.none
        var orthoSizeUnit = 30.0
        var bonePropSizeUnit = 100.0 / 3.0
        var bonePropLimbLengthRelative = true
        var ktimeSecond = 46_186_158_000.0
    }

    // MARK: - Entry point (ufbxi_load_imp, ufbx.c:25325-25353)

    static func finalize(_ ctx: LoadContext) throws {
        updateSceneSettings(ctx)                 // ufbx.c:25327
        // ufbx.c:25333/25338 axis + unit conversion: no-op under default options.
        let meta = makeMeta(ctx)                 // finalize-tail + adjust + modify_geometry scalars
        updateAdjustTransforms(ctx)              // ufbx.c:25343 (default-scoped)
        // ufbx.c:25345/25346 modify_geometry / postprocess: no-op under default options.
        updateScene(ctx, meta)                   // ufbx.c:25348 (initial = true)
    }

    // MARK: - Version/exporter scalars (ufbxi_finalize_scene tail + adjust + modify_geometry)

    private static func makeMeta(_ ctx: LoadContext) -> Meta {
        var m = Meta()
        m.ktimeSecond = ctx.ktimeSecDouble

        // ufbx: bone Size unit — Maya uses 100/3, Blender binary exactly 33, ASCII
        // (and pre-6000) 1.0 (ufbx.c:22608-22621).
        if ctx.version < 6000 {
            m.bonePropSizeUnit = 1.0
        } else if ctx.exporter == .blenderBinary {
            m.bonePropSizeUnit = 33.0
        } else if ctx.exporter == .blenderAscii {
            m.bonePropSizeUnit = 1.0
        } else {
            m.bonePropSizeUnit = 100.0 / 3.0
        }
        m.bonePropLimbLengthRelative = ctx.exporter != .blenderAscii

        // ufbx: geometry_scale/root_scale = 1, root_rotation = identity under default
        // (axis_matrix all-zero, unit_scale 1, TRANSFORM_ROOT — ufbx.c:23678-23744).
        m.geometryScale = 1.0
        m.rootScale = 1.0
        m.rootRotation = .identity
        m.mirrorAxis = .none

        // ufbx: ortho_size_unit (ufbx.c:21351) — Blender binary 1/geometry_scale, else 30.
        m.orthoSizeUnit = ctx.exporter == .blenderBinary ? 1.0 / m.geometryScale : 30.0
        return m
    }

    // MARK: - Scene settings (ufbxi_update_scene_settings, ufbx.c:23903)

    private static func updateSceneSettings(_ ctx: LoadContext) {
        let props = ctx.settingsProps
        var s = ctx.scene.settings

        let unitScaleFactor = props.findReal("UnitScaleFactor", 1.0)
        let originalUnitScaleFactor = props.findReal("OriginalUnitScaleFactor", unitScaleFactor)

        s.axes.up = findAxis(props, "UpAxis", "UpAxisSign")
        s.axes.front = findAxis(props, "FrontAxis", "FrontAxisSign")
        s.axes.right = findAxis(props, "CoordAxis", "CoordAxisSign")
        // ufbx: FBX default unit is cm; snap the *0.01 result to a clean power of ten.
        s.unitMeters = roundIfNear(unitScaleFactor * 0.01)
        s.originalUnitMeters = roundIfNear(originalUnitScaleFactor * 0.01)
        s.framesPerSecond = props.findReal("CustomFrameRate", 24.0)
        s.ambientColor = props.findVec3("AmbientColor", .zero)
        s.originalAxisUp = findAxis(props, "OriginalUpAxis", "OriginalUpAxisSign")
        s.defaultCamera = props.find("DefaultCamera")?.valueString ?? ""

        let tm = findEnum(props, "TimeMode", 11, 17)      // def 24_FPS(11), max 59_94_FPS(17)
        s.timeMode = FBXTimeMode(rawValue: tm) ?? .default
        s.timeProtocol = FBXTimeProtocol(rawValue: findEnum(props, "TimeProtocol", 2, 2)) ?? .default
        s.snapMode = FBXSnapMode(rawValue: findEnum(props, "SnapOnFrameMode", 0, 3)) ?? .none

        // ufbx: any non-CUSTOM time mode overrides fps from the fixed table.
        if s.timeMode != .custom {
            s.framesPerSecond = timeModeFps[tm]
        }
        ctx.scene.settings = s
    }

    // ufbx: `ufbxi_find_axis` (ufbx.c:23621) — axis int default 3 → UNKNOWN,
    // sign int default 2 → positive.
    private static func findAxis(_ props: FBXProps, _ axisName: String, _ signName: String) -> FBXCoordinateAxis {
        let axis = props.findInt(axisName, 3)
        let sign = props.findInt(signName, 2)
        switch axis {
        case 0: return sign > 0 ? .positiveX : .negativeX
        case 1: return sign > 0 ? .positiveY : .negativeY
        case 2: return sign > 0 ? .positiveZ : .negativeZ
        default: return .unknown
        }
    }

    private static let pow10Targets: [Double] = [
        0.0, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1,
        1e+0, 1e+1, 1e+2, 1e+3, 1e+4, 1e+5, 1e+6, 1e+7, 1e+8, 1e+9,
    ]

    // ufbx: `ufbxi_round_if_near` (ufbx.c:23889) — snap to a clean power of ten
    // within a relative tolerance (float noise like 0.99999994 → 1.0).
    private static func roundIfNear(_ value: Double) -> Double {
        for target in pow10Targets {
            var error = target * 9.5367431640625e-7
            if error < 0.0 { error = -error }
            if error < 7.52316384526264005e-37 { error = 7.52316384526264005e-37 }
            if value >= target - error && value <= target + error { return target }
        }
        return value
    }

    // ufbx: `ufbxi_time_mode_fps` (ufbx.c:23634). NTSC=29.97, PAL=25, FILM=23.976.
    private static let timeModeFps: [Double] = [
        30.0, 120.0, 100.0, 60.0, 50.0, 48.0, 30.0, 30.0, 29.97,
        29.97, 25.0, 24.0, 1000.0, 23.976, 24.0, 96.0, 72.0, 59.94,
    ]

    // MARK: - Adjust transforms (ufbxi_update_adjust_transforms, ufbx.c:23676)

    // Default-scoped: axis/unit/space conversion is off, so the only observable
    // effect is resetting every light's local_direction to the FBX default -Y
    // (ufbx.c:23723-23728). All node `adjust_*` fields keep their identity defaults.
    private static func updateAdjustTransforms(_ ctx: LoadContext) {
        for light in ctx.scene.lights {
            light.localDirection = FBXVec3(0, -1, 0)
        }
    }

    // MARK: - Scene update orchestrator (ufbxi_update_scene, ufbx.c:23806)

    private static func updateScene(_ ctx: LoadContext, _ meta: Meta) {
        let scene = ctx.scene

        // Order is load-bearing: nodes first (world matrices), then attributes that
        // read them, then clusters/poses, then textures before materials.
        for node in scene.nodes { updateNode(node) }
        for light in scene.lights { updateLight(light) }
        for camera in scene.cameras { updateCamera(camera, meta) }
        for bone in scene.bones { updateBone(bone, meta) }

        // initial == true: one-time skin/pose space setup.
        updateInitialClusters(ctx, meta)
        for pose in scene.poses { updatePose(pose, scene) }

        for cluster in scene.skinClusters { updateSkinCluster(cluster) }
        for channel in scene.blendChannels { updateBlendChannel(channel) }
        for texture in scene.textures { updateTexture(texture, scene) }
        for material in scene.materials { updateMaterial(material) }
        for stack in scene.animStacks { updateAnimStack(stack, meta) }

        // ufbx: `ufbxi_update_anim` (23490) — default anim = first stack's anim; else
        // the empty fallback pushed at finalize (ufbx.c:22601) keeps `scene.anim` non-nil.
        if let first = scene.animStacks.first {
            scene.anim = first.anim
        }
    }

    // MARK: - Node transform chain (ufbxi_update_node, ufbx.c:22955)

    private static func updateNode(_ node: FBXNode) {
        node.rotationOrder = FBXRotationOrder(rawValue: findEnum(node.props, "RotationOrder", 0, 6)) ?? .xyz
        node.eulerRotation = node.props.findVec3("Lcl Rotation", .zero)

        var unscaledNodeToParent = FBXMatrix.identity
        if !node.isRoot {
            let rotationActive = node.props.findInt("RotationActive", 1) != 0
            let rotationLimitOnly = node.props.findInt("RotationSpaceForLimitOnly", 0) != 0
            node.useRotationSpace = rotationActive && !rotationLimitOnly

            // ufbx: nested scale-helper translation scaling — nil under default (no
            // helper nodes synthesized).
            var translationScale: FBXVec3? = nil
            if let parent = node.parent, let sh = parent.scaleHelper {
                translationScale = sh.localTransform.scale
            }

            node.localTransform = TransformChain.getTransform(node.props, node.rotationOrder, node, translationScale)
            // ufbx: nested scale-helper chaining (22970) / transform overrides (22980)
            // are inert under default options.
            node.nodeToParent = node.localTransform.toMatrix()
            node.geometryTransform = getGeometryTransform(node.props, node)
            unscaledNodeToParent = node.localTransform.unscaled.toMatrix()
        } else {
            node.geometryTransform = .identity
        }

        node.inheritScale = node.localTransform.scale

        if let parent = node.parent {
            if node.inheritMode == .normal {
                node.nodeToWorld = parent.nodeToWorld * node.nodeToParent
                node.unscaledNodeToWorld = parent.nodeToWorld * unscaledNodeToParent
            } else {
                // ufbx: IGNORE_PARENT_SCALE and COMPONENTWISE_SCALE share this path;
                // they differ only in which ancestor `inherit_scale_node` points at.
                var transform = node.localTransform
                let parentScale = node.inheritScaleNode?.inheritScale ?? .one
                transform.scale = transform.scale * parentScale
                transform.translation = transform.translation * parent.inheritScale

                let nodeToUnscaledParent = transform.toMatrix()
                let unscaledNodeToUnscaledParent = transform.unscaled.toMatrix()
                node.inheritScale = transform.scale
                node.nodeToWorld = parent.unscaledNodeToWorld * nodeToUnscaledParent
                node.unscaledNodeToWorld = parent.unscaledNodeToWorld * unscaledNodeToUnscaledParent
            }
        } else {
            node.nodeToWorld = node.nodeToParent
            node.unscaledNodeToWorld = unscaledNodeToParent
        }

        if !isTransformIdentity(node.geometryTransform) {
            node.geometryToNode = node.geometryTransform.toMatrix()
            node.geometryToWorld = node.nodeToWorld * node.geometryToNode
            node.hasGeometryTransform = true
        } else {
            node.geometryToNode = .identity
            node.geometryToWorld = node.nodeToWorld
            node.hasGeometryTransform = false
        }

        node.visible = node.props.findInt("Visibility", 1) != 0
    }

    // ufbx: `ufbxi_get_geometry_transform` (ufbx.c:22758). M = T·R·S, no pivots,
    // rotation ALWAYS XYZ. Attribute-only (does not affect child nodes).
    private static func getGeometryTransform(_ props: FBXProps, _ node: FBXNode) -> FBXTransform {
        let translation = props.findVec3("GeometricTranslation", .zero)
        let rotation = props.findVec3("GeometricRotation", .zero)
        let scaling = props.findVec3("GeometricScaling", .one)

        var t = FBXTransform.identity
        TransformChain.mulScale(&t, scaling)
        TransformChain.mulRotate(&t, rotation, .xyz)
        TransformChain.addTranslate(&t, translation)

        if node.hasAdjustTransform {
            t.translation = t.translation * node.adjustTranslationScale
        }
        if node.adjustMirrorAxis != .none {
            TransformChain.mirrorTranslation(&t.translation, node.adjustMirrorAxis)
            TransformChain.mirrorRotation(&t.rotation, node.adjustMirrorAxis)
        }
        return t
    }

    // MARK: - Light (ufbxi_update_light, ufbx.c:23044)

    private static func updateLight(_ light: FBXLight) {
        // ufbx: FBX stores intensity 100× (Maya/Blender quirk), so divide by 100.
        light.intensity = light.props.findReal("Intensity", 100.0) / 100.0
        light.color = light.props.findVec3("Color", .one)
        light.lightType = FBXLightType(rawValue: findEnum(light.props, "LightType", 0, 4)) ?? .point
        light.decay = FBXLightDecay(rawValue: findEnum(light.props, "DecayType", 0, 3)) ?? .none
        light.areaShape = FBXLightAreaShape(rawValue: findEnum(light.props, "AreaLightShape", 0, 1)) ?? .rectangle
        // ufbx: each fallback default is the previous read's result (HotSpot → InnerAngle).
        light.innerAngle = light.props.findReal("HotSpot", 0)
        light.innerAngle = light.props.findReal("InnerAngle", light.innerAngle)
        light.outerAngle = light.props.findReal("Cone angle", 0)
        light.outerAngle = light.props.findReal("ConeAngle", light.outerAngle)
        light.outerAngle = light.props.findReal("OuterAngle", light.outerAngle)
        light.castLight = light.props.findInt("CastLight", 1) != 0
        light.castShadows = light.props.findInt("CastShadows", 0) != 0
    }

    // MARK: - Camera (ufbxi_update_camera, ufbx.c:23084)

    // 1/1000-inch film sizes per `ufbx_aperture_format` (ufbx.c:23069).
    private static let apertureFormats: [(Double, Double)] = [
        (1000, 1000), (404, 295), (493, 292), (864, 630), (816, 612), (980, 735),
        (825, 446), (864, 732), (2066, 906), (1485, 991), (2080, 1480), (2772, 2072),
    ]

    private static func updateCamera(_ camera: FBXCamera, _ meta: Meta) {
        let props = camera.props
        camera.projectionMode = FBXProjectionMode(rawValue: findEnum(props, "CameraProjectionType", 0, 1)) ?? .perspective
        camera.aspectMode = FBXAspectMode(rawValue: findEnum(props, "AspectRatioMode", 0, 4)) ?? .windowSize
        camera.apertureMode = FBXApertureMode(rawValue: findEnum(props, "ApertureMode", 2, 3)) ?? .vertical
        camera.apertureFormat = FBXApertureFormat(rawValue: findEnum(props, "ApertureFormat", 0, 11)) ?? .custom
        camera.gateFit = FBXGateFit(rawValue: findEnum(props, "GateFit", 0, 5)) ?? .none

        camera.nearPlane = props.findReal("NearPlane", 0)
        camera.farPlane = props.findReal("FarPlane", 0)

        // ufbx: probe both W/H and Width/Height spellings, preferring the latter.
        var aspectX = props.findReal("AspectW", 0)
        var aspectY = props.findReal("AspectH", 0)
        aspectX = props.findReal("AspectWidth", aspectX)
        aspectY = props.findReal("AspectHeight", aspectY)

        let fov = props.findReal("FieldOfView", 0)
        let fovX = props.findReal("FieldOfViewX", 0)
        let fovY = props.findReal("FieldOfViewY", 0)

        let focalLength = props.findReal("FocalLength", 0)
        var orthoExtent = meta.orthoSizeUnit * props.findReal("OrthoZoom", 1)

        let format = apertureFormats[camera.apertureFormat.rawValue]
        var filmSize = FBXVec2(format.0 * 0.001, format.1 * 0.001)
        var squeezeRatio = camera.apertureFormat == .anamorphic35mm ? 2.0 : 1.0

        filmSize.x = props.findReal("FilmWidth", filmSize.x)
        filmSize.y = props.findReal("FilmHeight", filmSize.y)
        squeezeRatio = props.findReal("FilmSqueezeRatio", squeezeRatio)

        // ufbx: back-fill the missing aspect dimension from the film-size ratio.
        if aspectX <= 0 && aspectY <= 0 {
            aspectX = filmSize.x > 0 ? filmSize.x : 1
            aspectY = filmSize.y > 0 ? filmSize.y : 1
        } else if aspectX <= 0 {
            aspectX = (filmSize.x > 0 && filmSize.y > 0) ? aspectY / filmSize.y * filmSize.x : aspectY
        } else if aspectY <= 0 {
            aspectY = (filmSize.x > 0 && filmSize.y > 0) ? aspectX / filmSize.x * filmSize.y : aspectX
        }

        filmSize.y *= squeezeRatio

        orthoExtent *= meta.geometryScale
        camera.nearPlane *= meta.geometryScale
        camera.farPlane *= meta.geometryScale

        camera.focalLengthMm = focalLength
        camera.filmSizeInch = filmSize
        camera.squeezeRatio = squeezeRatio
        camera.orthographicExtent = orthoExtent

        switch camera.aspectMode {
        case .windowSize, .fixedRatio:
            camera.resolutionIsPixels = false
            camera.resolution = FBXVec2(aspectX, aspectY)
        case .fixedResolution:
            camera.resolutionIsPixels = true
            camera.resolution = FBXVec2(aspectX, aspectY)
        case .fixedWidth:
            camera.resolutionIsPixels = true
            camera.resolution = FBXVec2(aspectX, aspectX * aspectY)
        case .fixedHeight:
            camera.resolutionIsPixels = true
            camera.resolution = FBXVec2(aspectY * aspectX, aspectY)
        }

        let aspectRatio = camera.resolution.x / camera.resolution.y
        let filmRatio = filmSize.x / filmSize.y
        camera.aspectRatio = aspectRatio

        // ufbx: FILL/OVERSCAN resolve to horizontal/vertical via opposite comparisons.
        var effectiveFit = camera.gateFit
        if effectiveFit == .fill {
            effectiveFit = aspectRatio > filmRatio ? .horizontal : .vertical
        } else if effectiveFit == .overscan {
            effectiveFit = aspectRatio < filmRatio ? .horizontal : .vertical
        }

        switch effectiveFit {
        case .vertical:
            camera.apertureSizeInch = FBXVec2(camera.filmSizeInch.y * aspectRatio, camera.filmSizeInch.y)
            camera.orthographicSize = FBXVec2(orthoExtent * aspectRatio, orthoExtent)
        case .horizontal:
            camera.apertureSizeInch = FBXVec2(camera.filmSizeInch.x, camera.filmSizeInch.x / aspectRatio)
            camera.orthographicSize = FBXVec2(orthoExtent, orthoExtent / aspectRatio)
        default: // none, fill, overscan, stretch
            camera.apertureSizeInch = camera.filmSizeInch
            camera.orthographicSize = FBXVec2(orthoExtent, orthoExtent)
        }

        let degToRadHalf = (Double.pi / 180.0) * 0.5
        let radToDeg = 180.0 / Double.pi
        let mmToInch = 0.0393700787

        switch camera.apertureMode {
        case .horizontalAndVertical:
            camera.fieldOfViewDeg = FBXVec2(fovX, fovY)
            camera.fieldOfViewTan = FBXVec2(tan(fovX * degToRadHalf), tan(fovY * degToRadHalf))
        case .horizontal:
            let tanX = tan(fov * degToRadHalf)
            let tanY = tanX / aspectRatio
            camera.fieldOfViewTan = FBXVec2(tanX, tanY)
            camera.fieldOfViewDeg = FBXVec2(fov, atan(tanY) * radToDeg * 2.0)
        case .vertical:
            let tanY = tan(fov * degToRadHalf)
            let tanX = tanY * aspectRatio
            camera.fieldOfViewTan = FBXVec2(tanX, tanY)
            camera.fieldOfViewDeg = FBXVec2(atan(tanX) * radToDeg * 2.0, fov)
        case .focalLength:
            let tanX = camera.apertureSizeInch.x / (camera.focalLengthMm * mmToInch) * 0.5
            let tanY = camera.apertureSizeInch.y / (camera.focalLengthMm * mmToInch) * 0.5
            camera.fieldOfViewTan = FBXVec2(tanX, tanY)
            camera.fieldOfViewDeg = FBXVec2(atan(tanX) * radToDeg * 2.0, atan(tanY) * radToDeg * 2.0)
        }

        camera.projectionPlane = camera.projectionMode == .perspective
            ? camera.fieldOfViewTan : camera.orthographicSize
    }

    // MARK: - Bone (ufbxi_update_bone, ufbx.c:23254)

    private static func updateBone(_ bone: FBXBone, _ meta: Meta) {
        let unit = meta.bonePropSizeUnit
        bone.radius = bone.props.findReal("Size", unit) / unit
        bone.relativeLength = meta.bonePropLimbLengthRelative ? bone.props.findReal("LimbLength", 1.0) : 1.0
    }

    // MARK: - Initial clusters + poses (ufbxi_update_initial_clusters, ufbx.c:23523)

    private static func updateInitialClusters(_ ctx: LoadContext, _ meta: Meta) {
        let scene = ctx.scene

        for cluster in scene.skinClusters {
            cluster.geometryToBone = cluster.meshNodeToBone
        }

        // ufbx: default (TRANSFORM_ROOT + mirror NONE) → world_to_units = root's
        // node_to_parent, translation_scale = 1 (ufbx.c:23538).
        let worldToUnits: FBXMatrix
        let translationScale: Double
        if meta.mirrorAxis == .none {
            worldToUnits = scene.rootNode.nodeToParent
            translationScale = 1.0
        } else {
            var rt = FBXTransform()
            rt.rotation = meta.rootRotation
            rt.scale = FBXVec3(meta.rootScale, meta.rootScale, meta.rootScale)
            worldToUnits = rt.toMatrix()
            translationScale = meta.geometryScale
        }

        for cluster in scene.skinClusters {
            var m = worldToUnits * cluster.bindToWorld
            m.cols.3 = m.cols.3 * translationScale
            TransformChain.mirrorMatrix(&m, meta.mirrorAxis)
            cluster.bindToWorld = m
        }
        for pose in scene.poses {
            for i in pose.bonePoses.indices {
                var m = worldToUnits * pose.bonePoses[i].boneToWorld
                m.cols.3 = m.cols.3 * translationScale
                TransformChain.mirrorMatrix(&m, meta.mirrorAxis)
                pose.bonePoses[i].boneToWorld = m
            }
        }

        // Patch each cluster's mesh_node_to_bone → geometry_to_bone.
        for cluster in scene.skinClusters {
            guard let skin = fetchSrcElement(cluster, .skinDeformer, scene) as? FBXSkinDeformer else { continue }

            var node = fetchSrcElement(skin, .node, scene) as? FBXNode
            if node == nil,
               let mesh = fetchSrcElement(skin, .mesh, scene) as? FBXMesh,
               let first = mesh.instances.first {
                node = first
            }
            guard var n = node else { continue }
            if n.isGeometryTransformHelper, let parent = n.parent { n = parent }

            if matrixAllZero(cluster.meshNodeToBone) {
                // ufbx: unspecified mesh_node_to_bone → derive from bind pose.
                cluster.meshNodeToBone = cluster.bindToWorld.inverted() * n.nodeToWorld
            } else {
                TransformChain.mirrorMatrix(&cluster.meshNodeToBone, meta.mirrorAxis)
                if meta.geometryScale != 1.0 {
                    cluster.meshNodeToBone.cols.3 = cluster.meshNodeToBone.cols.3 * meta.geometryScale
                }
            }

            // ufbx: account for geometry transforms via the helper node or geometry_to_node.
            if n.geometryTransformHelperID >= 0, let geoNode = n.geometryTransformHelper {
                cluster.geometryToBone = cluster.meshNodeToBone * geoNode.nodeToParent
            } else if n.hasGeometryTransform {
                cluster.geometryToBone = cluster.meshNodeToBone * n.geometryToNode
            } else {
                cluster.geometryToBone = cluster.meshNodeToBone
            }
        }
    }

    // ufbx: `ufbxi_update_pose` (ufbx.c:23271). bone_to_parent = invert(parent_to_world)
    // · bone_to_world, where parent_to_world is the parent's own bone_pose (if posed)
    // else the parent node's world matrix else identity.
    private static func updatePose(_ pose: FBXPose, _ scene: FBXScene) {
        for i in pose.bonePoses.indices {
            let bp = pose.bonePoses[i]
            guard bp.boneNodeID >= 0, let node = scene.element(bp.boneNodeID) as? FBXNode else { continue }

            var parentToWorld = FBXMatrix.identity
            if let parent = node.parent {
                if let pbp = getBonePose(pose, parent) {
                    parentToWorld = pbp.boneToWorld
                } else {
                    parentToWorld = parent.nodeToWorld
                }
            }
            pose.bonePoses[i].boneToParent = parentToWorld.inverted() * bp.boneToWorld
        }
    }

    // ufbx: `ufbx_get_bone_pose` (ufbx.c binary search by bone_node typed_id).
    private static func getBonePose(_ pose: FBXPose, _ node: FBXNode) -> FBXBonePose? {
        let arr = pose.bonePoses
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let bn = pose.scene.element(arr[mid].boneNodeID) as? FBXNode
            if let bn = bn, bn.typedID < node.typedID { lo = mid + 1 } else { hi = mid }
        }
        if lo < arr.count, let bn = pose.scene.element(arr[lo].boneNodeID) as? FBXNode, bn === node {
            return arr[lo]
        }
        return nil
    }

    // MARK: - Skin cluster world matrix (ufbxi_update_skin_cluster, ufbx.c:23289)

    private static func updateSkinCluster(_ cluster: FBXSkinCluster) {
        let base = cluster.boneNode?.nodeToWorld ?? cluster.bindToWorld
        cluster.geometryToWorld = base * cluster.geometryToBone
        cluster.geometryToWorldTransform = cluster.geometryToWorld.toTransform()
    }

    // MARK: - Blend channel (ufbxi_update_blend_channel, ufbx.c:23299)

    private static func updateBlendChannel(_ channel: FBXBlendChannel) {
        let weight = channel.props.findReal("DeformPercent", 0) * 0.01
        channel.weight = weight

        var keys = channel.keyframes
        let numKeys = keys.count
        guard numKeys > 0 else { return }

        // Reset effective weights and find the split around zero.
        var lastNegative = -1
        for i in 0..<numKeys {
            keys[i].effectiveWeight = 0
            if keys[i].targetWeight < 0 { lastNegative = i }
        }

        // ufbx: prev/next as pointers with a synthetic zero key (target 0). -1 = zero key.
        var prev = -1
        var next = -1
        if weight > 0 {
            if lastNegative >= 0 { prev = lastNegative }
            var i = lastNegative + 1
            while i < numKeys {
                prev = next
                next = i
                if keys[i].targetWeight > weight { break }
                i += 1
            }
        } else {
            if lastNegative + 1 < numKeys { prev = lastNegative + 1 }
            var i = lastNegative
            while i >= 0 {
                prev = next
                next = i
                if keys[i].targetWeight < weight { break }
                i -= 1
            }
        }

        func target(_ idx: Int) -> Double { idx < 0 ? 0 : keys[idx].targetWeight }
        let delta = target(next) - target(prev)
        if delta != 0 {
            let t = (weight - target(prev)) / delta
            if prev >= 0 { keys[prev].effectiveWeight = 1.0 - t }
            if next >= 0 { keys[next].effectiveWeight = t }
        }
        channel.keyframes = keys
    }

    // MARK: - Texture (finalize texture pass ufbx.c:22470 + ufbxi_update_texture 23351)

    private static func updateTexture(_ texture: FBXTexture, _ scene: FBXScene) {
        // Finalize texture pass: uv_set, connected video content.
        texture.uvSet = texture.props.find("UVSet")?.valueString ?? ""

        if let videoID = firstDstSrc(texture, .video, scene) {
            texture.videoID = videoID
            if let video = scene.element(videoID) as? FBXVideo {
                texture.content = video.content
            }
        }
        // ufbx dumps has_content as content.size > 0.
        texture.hasContent = !texture.content.isEmpty

        // ufbxi_update_texture: UV transform + wrap modes.
        let uv = getTextureTransform(texture.props)
        if !isTransformIdentity(uv) {
            texture.hasUVTransform = true
            texture.uvTransform = uv
            texture.textureToUV = uv.toMatrix()
            texture.uvToTexture = texture.textureToUV.inverted()
        } else {
            texture.hasUVTransform = false
            texture.uvTransform = .identity
            texture.textureToUV = .identity
            texture.uvToTexture = .identity
        }
        texture.wrapU = FBXWrapMode(rawValue: findEnum(texture.props, "WrapModeU", 0, 1)) ?? .repeat
        texture.wrapV = FBXWrapMode(rawValue: findEnum(texture.props, "WrapModeV", 0, 1)) ?? .repeat
    }

    // ufbx: `ufbxi_get_texture_transform` (ufbx.c:22907).
    private static func getTextureTransform(_ props: FBXProps) -> FBXTransform {
        let scalePivot = props.findVec3("TextureScalingPivot", .zero)
        let rotPivot = props.findVec3("TextureRotationPivot", .zero)
        let translation = props.findVec3("Translation", .zero)
        let rotation = props.findVec3("Rotation", .zero)
        let scaling = props.findVec3("Scaling", .one)

        var t = FBXTransform.identity
        TransformChain.subTranslate(&t, scalePivot)
        TransformChain.mulScale(&t, scaling)
        TransformChain.addTranslate(&t, scalePivot)

        TransformChain.subTranslate(&t, rotPivot)
        TransformChain.mulRotate(&t, rotation, .xyz)
        TransformChain.addTranslate(&t, rotPivot)

        TransformChain.addTranslate(&t, translation)

        // ufbx: UVSwap zeroes Y/Z scale then rotates -90° — ported faithfully.
        if props.findInt("UVSwap", 0) != 0 {
            TransformChain.mulScale(&t, FBXVec3(-1, 0, 0))
            TransformChain.mulRotate(&t, FBXVec3(0, 0, -90), .xyz)
        }
        return t
    }

    // MARK: - Material (ufbxi_update_material + finalize maps, ufbx.c:22316/22514/20124)

    private static func updateMaterial(_ material: FBXMaterial) {
        // Shading-model → shader type (FBX Lambert/Phong). Extended shader / 3ds-Max
        // ClassID selection needs SHADER elements (modeled as unknowns in v1) and PBR
        // tables, both out of scope — see DEVIATIONS.
        switch material.shadingModelName {
        case "lambert", "Lambert": material.shaderType = .fbxLambert
        case "phong", "Phong": material.shaderType = .fbxPhong
        default: break
        }

        // Sort connected textures by material_prop (stable) so `findPropTexture`'s
        // binary search holds, then fetch the FBX maps.
        material.textures = stableSortTextures(material.textures)
        fetchMaps(material)
    }

    // ufbx: `ufbxi_material_texture_less` (ufbx.c:19308) — byte-wise material_prop,
    // stable (ties keep fetch order).
    private static func stableSortTextures(_ textures: [FBXMaterialTexture]) -> [FBXMaterialTexture] {
        let perm = Array(textures.indices).sorted { a, b in
            let pa = textures[a].materialProp, pb = textures[b].materialProp
            if pa != pb { return FBXProp.byteLess(pa, pb) }
            return a < b
        }
        return perm.map { textures[$0] }
    }

    // Each FBX base-mapping entry: destination map slot + prop name + DEFAULT_W_1.
    // @unchecked Sendable: the stored WritableKeyPath is immutable table data.
    private struct FBXMapping: @unchecked Sendable {
        let keyPath: WritableKeyPath<FBXMaterialFBXMaps, FBXMaterialMap>
        let defaultW1: Bool
        let prop: String
    }

    // ufbx: `ufbxi_base_fbx_mapping` (ufbx.c:19445) — FBX-side table only (PBR skipped).
    private static let fbxBaseMapping: [FBXMapping] = [
        .init(keyPath: \.diffuseColor, defaultW1: true, prop: "Diffuse"),
        .init(keyPath: \.diffuseColor, defaultW1: true, prop: "DiffuseColor"),
        .init(keyPath: \.diffuseFactor, defaultW1: false, prop: "DiffuseFactor"),
        .init(keyPath: \.specularColor, defaultW1: true, prop: "Specular"),
        .init(keyPath: \.specularColor, defaultW1: true, prop: "SpecularColor"),
        .init(keyPath: \.specularFactor, defaultW1: false, prop: "SpecularFactor"),
        .init(keyPath: \.specularExponent, defaultW1: false, prop: "Shininess"),
        .init(keyPath: \.specularExponent, defaultW1: false, prop: "ShininessExponent"),
        .init(keyPath: \.reflectionColor, defaultW1: true, prop: "Reflection"),
        .init(keyPath: \.reflectionColor, defaultW1: true, prop: "ReflectionColor"),
        .init(keyPath: \.reflectionFactor, defaultW1: false, prop: "ReflectionFactor"),
        .init(keyPath: \.transparencyColor, defaultW1: true, prop: "Transparent"),
        .init(keyPath: \.transparencyColor, defaultW1: true, prop: "TransparentColor"),
        .init(keyPath: \.transparencyFactor, defaultW1: false, prop: "TransparentFactor"),
        .init(keyPath: \.transparencyFactor, defaultW1: false, prop: "TransparencyFactor"),
        .init(keyPath: \.emissionColor, defaultW1: true, prop: "Emissive"),
        .init(keyPath: \.emissionColor, defaultW1: true, prop: "EmissiveColor"),
        .init(keyPath: \.emissionFactor, defaultW1: false, prop: "EmissiveFactor"),
        .init(keyPath: \.ambientColor, defaultW1: true, prop: "Ambient"),
        .init(keyPath: \.ambientColor, defaultW1: true, prop: "AmbientColor"),
        .init(keyPath: \.ambientFactor, defaultW1: false, prop: "AmbientFactor"),
        .init(keyPath: \.normalMap, defaultW1: false, prop: "NormalMap"),
        .init(keyPath: \.bump, defaultW1: false, prop: "Bump"),
        .init(keyPath: \.bumpFactor, defaultW1: false, prop: "BumpFactor"),
        .init(keyPath: \.displacement, defaultW1: false, prop: "Displacement"),
        .init(keyPath: \.displacementFactor, defaultW1: false, prop: "DisplacementFactor"),
        .init(keyPath: \.vectorDisplacement, defaultW1: false, prop: "VectorDisplacement"),
        .init(keyPath: \.vectorDisplacementFactor, defaultW1: false, prop: "VectorDisplacementFactor"),
    ]

    // ufbx: `ufbxi_fetch_maps` (ufbx.c:20124) — FBX side. Resets the maps, fills each
    // value+texture from the base mapping table, then defaults the factor channels.
    private static func fetchMaps(_ material: FBXMaterial) {
        material.fbx = FBXMaterialFBXMaps()

        for mapping in fbxBaseMapping {
            var map = material.fbx[keyPath: mapping.keyPath]

            // Value fetch (skips REFERENCE props, mirroring ufbxi_fetch_mapping_maps).
            if let prop = material.props.find(mapping.prop), prop.type != .reference {
                map.valueVec4 = prop.valueVec4
                map.valueInt = prop.valueInt
                map.hasValue = true
                // ufbx: default alpha to 1 for color maps not stored as vec4.
                if mapping.defaultW1 && !prop.flags.contains(.valueVec4) {
                    map.valueVec4.w = 1.0
                }
                map.valueComponents = valueComponents(prop.flags)
            }

            // Texture fetch is independent of the value prop's presence.
            if let texID = findPropTexture(material, mapping.prop) {
                map.textureID = texID
                map.textureEnabled = true
            }

            material.fbx[keyPath: mapping.keyPath] = map
        }

        // ufbx: `ufbxi_update_factor` (20096) — a missing factor defaults to 1 when
        // the paired color is present and non-zero, else 0.
        updateFactor(&material.fbx.diffuseFactor, material.fbx.diffuseColor)
        updateFactor(&material.fbx.specularFactor, material.fbx.specularColor)
        updateFactor(&material.fbx.reflectionFactor, material.fbx.reflectionColor)
        updateFactor(&material.fbx.transparencyFactor, material.fbx.transparencyColor)
        updateFactor(&material.fbx.emissionFactor, material.fbx.emissionColor)
        updateFactor(&material.fbx.ambientFactor, material.fbx.ambientColor)
    }

    // ufbx: value_components from the prop's VALUE_* flags (NOT its arity).
    private static func valueComponents(_ flags: FBXPropFlags) -> Int {
        if flags.contains(.valueReal) { return 1 }
        if flags.contains(.valueVec2) { return 2 }
        if flags.contains(.valueVec3) { return 3 }
        if flags.contains(.valueVec4) { return 4 }
        return 0
    }

    private static func updateFactor(_ factor: inout FBXMaterialMap, _ color: FBXMaterialMap) {
        guard !factor.hasValue else { return }
        // ufbx: `ufbxi_is_vec4_zero` ignores the w (alpha) component.
        let colorNonZero = color.valueVec4.x != 0 || color.valueVec4.y != 0 || color.valueVec4.z != 0
        if color.hasValue && colorNonZero {
            factor.valueVec4.x = 1.0
            factor.valueInt = 1
        } else {
            factor.valueVec4.x = 0.0
            factor.valueInt = 0
        }
    }

    // ufbx: `ufbx_find_prop_texture_len` (ufbx.c:31414) — lower-bound on the sorted
    // material.textures by material_prop; returns the texture's element_id if equal.
    private static func findPropTexture(_ material: FBXMaterial, _ name: String) -> Int32? {
        let arr = material.textures
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if FBXProp.byteLess(arr[mid].materialProp, name) { lo = mid + 1 } else { hi = mid }
        }
        if lo < arr.count && arr[lo].materialProp == name { return arr[lo].textureID }
        return nil
    }

    // MARK: - Anim stack time range (ufbxi_update_anim_stack, ufbx.c:23371)

    private static func updateAnimStack(_ stack: FBXAnimStack, _ meta: Meta) {
        var begin = stack.props.find("LocalStart")
        var end = stack.props.find("LocalStop")
        if begin == nil || end == nil {
            begin = stack.props.find("ReferenceStart")
            end = stack.props.find("ReferenceStop")
        }
        if let b = begin, let e = end {
            stack.timeBegin = Double(b.valueInt) / meta.ktimeSecond
            stack.timeEnd = Double(e.valueInt) / meta.ktimeSecond
        }
        stack.anim.timeBegin = stack.timeBegin
        stack.anim.timeEnd = stack.timeEnd
    }

    // MARK: - Connection traversal (ufbxi_fetch_src/dst_element, ufbx.c OO edges)

    // ufbx: `ufbxi_fetch_src_element` — first DST of an OO src connection with `dstType`.
    private static func fetchSrcElement(_ elem: FBXElement, _ dstType: FBXElementType, _ scene: FBXScene) -> FBXElement? {
        for c in scene.connections[elem.connectionsSrc] where c.srcProp.isEmpty && c.dstProp.isEmpty {
            let dst = scene.elements[Int(c.dstID)]
            if dst.type == dstType { return dst }
        }
        return nil
    }

    // ufbx: `ufbxi_fetch_dst_element` — element_id of the first SRC of an OO dst
    // connection with `srcType`.
    private static func firstDstSrc(_ elem: FBXElement, _ srcType: FBXElementType, _ scene: FBXScene) -> Int32? {
        for idx in elem.connectionsDst {
            let c = scene.connections[Int(scene.connectionsDstOrder[idx])]
            guard c.dstProp.isEmpty && c.srcProp.isEmpty else { continue }
            if scene.elements[Int(c.srcID)].type == srcType { return c.srcID }
        }
        return nil
    }

    // MARK: - Enum + identity helpers

    // ufbx: `ufbxi_find_enum` (ufbx.c:11551) — returns `def` (NOT a clamp) when the
    // value is out of `[0, maxValue]` or the prop is absent.
    private static func findEnum(_ props: FBXProps, _ name: String, _ def: Int, _ maxValue: Int) -> Int {
        guard let p = props.find(name) else { return def }
        let v = Int(p.valueInt)
        return (v >= 0 && v <= maxValue) ? v : def
    }

    private static func isTransformIdentity(_ t: FBXTransform) -> Bool {
        TransformChain.isVec3Zero(t.translation) && TransformChain.isQuatIdentity(t.rotation)
            && t.scale.x == 1 && t.scale.y == 1 && t.scale.z == 1
    }

    private static func matrixAllZero(_ m: FBXMatrix) -> Bool {
        let c = m.cols
        return c.0.x == 0 && c.0.y == 0 && c.0.z == 0
            && c.1.x == 0 && c.1.y == 0 && c.1.z == 0
            && c.2.x == 0 && c.2.y == 0 && c.2.z == 0
            && c.3.x == 0 && c.3.y == 0 && c.3.z == 0
    }
}
