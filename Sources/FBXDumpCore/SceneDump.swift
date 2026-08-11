// Golden-format scene dumper: converts a loaded `FBXScene` into the JSON-ready
// native-Foundation structure described by `docs/DUMP_FORMAT.md`. Mirrors
// `tools/ufbx_dump.c` field-for-field, order-for-order, condition-for-condition
// (the C file is the reference; this is a 1:1 port of its dump logic against
// the Swift scene model instead of `ufbx_scene`).
//
// FBXDumpCore has NO `@testable` access to SwiftFBX — everything used here is
// public API. Output uses native Foundation types only (`Int`, `Double`,
// `String`, `Bool`, `[Any]`, `[String: Any]`, `NSNull`) so `JSONSerialization`
// can consume it directly.

import Foundation
import SwiftFBX

public enum SceneDump {

    /// Builds the full DUMP_FORMAT document for `scene`. `filename` may be a
    /// full path; only its last path component (basename) is emitted, mirroring
    /// `ufbx_dump.c`'s `strrchr(argv[1], '/')` handling.
    public static func build(scene: FBXScene, filename: String) -> [String: Any] {
        var root: [String: Any] = [:]
        root["metadata"] = buildMetadata(scene, filename: filename)
        root["settings"] = buildSettings(scene)
        root["nodes"] = scene.nodes.map { buildNode(scene, $0) }
        root["meshes"] = scene.meshes.map { buildMesh(scene, $0) }
        root["materials"] = scene.materials.map { buildMaterial(scene, $0) }
        root["textures"] = scene.textures.map { buildTexture($0) }
        root["lights"] = scene.lights.map { buildLight($0) }
        root["cameras"] = scene.cameras.map { buildCamera($0) }
        root["bones"] = scene.bones.map { buildBone($0) }
        root["skin_deformers"] = scene.skinDeformers.map { buildSkinDeformer(scene, $0) }
        root["blend_deformers"] = scene.blendDeformers.map { buildBlendDeformer($0) }
        root["anim_stacks"] = scene.animStacks.map { buildAnimStack(scene, $0) }
        root["evaluate"] = buildEvaluate(scene)
        return root
    }

    // MARK: - Numeric / vector helpers

    /// Non-finite doubles are dumped as the strings "nan"/"inf"/"-inf" (DUMP_FORMAT).
    private static func num(_ v: Double) -> Any {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        return v
    }

    private static func arr(_ v: FBXVec2) -> [Any] { [num(v.x), num(v.y)] }
    private static func arr(_ v: FBXVec3) -> [Any] { [num(v.x), num(v.y), num(v.z)] }
    private static func arr(_ v: FBXVec4) -> [Any] { [num(v.x), num(v.y), num(v.z), num(v.w)] }
    private static func arr(_ q: FBXQuat) -> [Any] { [num(q.x), num(q.y), num(q.z), num(q.w)] }

    /// 12-number col-major dump of `ufbx_matrix` (cols[0..3], each xyz) per DUMP_FORMAT.
    private static func mat(_ m: FBXMatrix) -> [Any] {
        [
            num(m.cols.0.x), num(m.cols.0.y), num(m.cols.0.z),
            num(m.cols.1.x), num(m.cols.1.y), num(m.cols.1.z),
            num(m.cols.2.x), num(m.cols.2.y), num(m.cols.2.z),
            num(m.cols.3.x), num(m.cols.3.y), num(m.cols.3.z),
        ]
    }

    private static func transform(_ t: FBXTransform) -> [String: Any] {
        ["translation": arr(t.translation), "rotation": arr(t.rotation), "scale": arr(t.scale)]
    }

    /// Resolves an `element_id` cross-reference to the referenced element's
    /// `typedID` (the index the dump format uses), -1 when absent.
    private static func idx(_ scene: FBXScene, _ elementID: Int32) -> Int {
        scene.element(elementID)?.typedID ?? -1
    }

    // MARK: - Vertex attribute helper

    private static func flattenReal(_ v: Double) -> [Double] { [v] }
    private static func flattenVec2(_ v: FBXVec2) -> [Double] { [v.x, v.y] }
    private static func flattenVec3(_ v: FBXVec3) -> [Double] { [v.x, v.y, v.z] }
    private static func flattenVec4(_ v: FBXVec4) -> [Double] { [v.x, v.y, v.z, v.w] }

    /// Mirrors `dump_vertex_attrib`: nil (omitted) unless `attrib.exists`.
    /// `values` is the flat real pool (`values.count * arity` reals); `indices`
    /// maps `NO_INDEX` (0xFFFFFFFF) to -1.
    private static func vertexAttribDict<V>(
        _ attrib: FBXVertexAttribute<V>, _ flatten: (V) -> [Double]
    ) -> [String: Any]? {
        guard attrib.exists else { return nil }
        var values: [Any] = []
        values.reserveCapacity(attrib.values.count * 4)
        for v in attrib.values {
            for d in flatten(v) { values.append(num(d)) }
        }
        var indices: [Any] = []
        indices.reserveCapacity(attrib.indices.count)
        for i in attrib.indices {
            indices.append(i == FBXMesh.noIndex ? -1 : Int(i))
        }
        return ["values": values, "indices": indices]
    }

    // MARK: - Enum name mapping (mirrors ufbx_dump.c's *_name functions)

    private static func axisName(_ a: FBXCoordinateAxis) -> String {
        switch a {
        case .positiveX: return "positive_x"
        case .negativeX: return "negative_x"
        case .positiveY: return "positive_y"
        case .negativeY: return "negative_y"
        case .positiveZ: return "positive_z"
        case .negativeZ: return "negative_z"
        case .unknown: return "unknown"
        }
    }

    private static func timeModeName(_ m: FBXTimeMode) -> String {
        switch m {
        case .default: return "default"
        case .fps120: return "120_fps"
        case .fps100: return "100_fps"
        case .fps60: return "60_fps"
        case .fps50: return "50_fps"
        case .fps48: return "48_fps"
        case .fps30: return "30_fps"
        case .fps30Drop: return "30_fps_drop"
        case .ntscDropFrame: return "ntsc_drop_frame"
        case .ntscFullFrame: return "ntsc_full_frame"
        case .pal: return "pal"
        case .fps24: return "24_fps"
        case .fps1000: return "1000_fps"
        case .filmFullFrame: return "film_full_frame"
        case .custom: return "custom"
        case .fps96: return "96_fps"
        case .fps72: return "72_fps"
        case .fps59_94: return "59_94_fps"
        }
    }

    private static func rotationOrderName(_ o: FBXRotationOrder) -> String {
        switch o {
        case .xyz: return "xyz"
        case .xzy: return "xzy"
        case .yzx: return "yzx"
        case .yxz: return "yxz"
        case .zxy: return "zxy"
        case .zyx: return "zyx"
        case .spheric: return "spheric"
        }
    }

    private static func inheritModeName(_ m: FBXInheritMode) -> String {
        switch m {
        case .normal: return "normal"
        case .ignoreParentScale: return "ignore_parent_scale"
        case .componentwiseScale: return "componentwise_scale"
        }
    }

    private static func lightTypeName(_ t: FBXLightType) -> String {
        switch t {
        case .point: return "point"
        case .directional: return "directional"
        case .spot: return "spot"
        case .area: return "area"
        case .volume: return "volume"
        }
    }

    private static func lightDecayName(_ d: FBXLightDecay) -> String {
        switch d {
        case .none: return "none"
        case .linear: return "linear"
        case .quadratic: return "quadratic"
        case .cubic: return "cubic"
        }
    }

    private static func areaShapeName(_ s: FBXLightAreaShape) -> String {
        switch s {
        case .rectangle: return "rectangle"
        case .sphere: return "sphere"
        }
    }

    private static func projectionModeName(_ m: FBXProjectionMode) -> String {
        switch m {
        case .perspective: return "perspective"
        case .orthographic: return "orthographic"
        }
    }

    private static func aspectModeName(_ m: FBXAspectMode) -> String {
        switch m {
        case .windowSize: return "window_size"
        case .fixedRatio: return "fixed_ratio"
        case .fixedResolution: return "fixed_resolution"
        case .fixedWidth: return "fixed_width"
        case .fixedHeight: return "fixed_height"
        }
    }

    private static func textureTypeName(_ t: FBXTextureType) -> String {
        switch t {
        case .file: return "file"
        case .layered: return "layered"
        case .procedural: return "procedural"
        case .shader: return "shader"
        }
    }

    private static func wrapModeName(_ m: FBXWrapMode) -> String {
        switch m {
        case .repeat: return "repeat"
        case .clamp: return "clamp"
        }
    }

    private static func skinningMethodName(_ m: FBXSkinningMethod) -> String {
        switch m {
        case .linear: return "linear"
        case .rigid: return "rigid"
        case .dualQuaternion: return "dual_quaternion"
        case .blendedDQLinear: return "blended_dq_linear"
        }
    }

    private static func interpolationName(_ i: FBXInterpolation) -> String {
        switch i {
        case .constantPrev: return "constant_prev"
        case .constantNext: return "constant_next"
        case .linear: return "linear"
        case .cubic: return "cubic"
        }
    }

    private static func elementTypeName(_ t: FBXElementType) -> String {
        switch t {
        case .unknown: return "unknown"
        case .node: return "node"
        case .mesh: return "mesh"
        case .light: return "light"
        case .camera: return "camera"
        case .bone: return "bone"
        case .empty: return "empty"
        case .material: return "material"
        case .texture: return "texture"
        case .animStack: return "anim_stack"
        case .animLayer: return "anim_layer"
        case .animValue: return "anim_value"
        case .animCurve: return "anim_curve"
        case .skinDeformer: return "skin_deformer"
        case .skinCluster: return "skin_cluster"
        case .blendDeformer: return "blend_deformer"
        case .blendChannel: return "blend_channel"
        case .blendShape: return "blend_shape"
        default: return "element_\(t.rawValue)"
        }
    }

    // MARK: - metadata / settings

    private static func buildMetadata(_ scene: FBXScene, filename: String) -> [String: Any] {
        [
            "version": scene.metadata.version,
            "ascii": scene.metadata.ascii,
            "creator": scene.metadata.creator,
            "big_endian": scene.metadata.bigEndian,
            "filename": (filename as NSString).lastPathComponent,
        ]
    }

    private static func buildSettings(_ scene: FBXScene) -> [String: Any] {
        [
            "up_axis": axisName(scene.settings.axes.up),
            "front_axis": axisName(scene.settings.axes.front),
            "right_axis": axisName(scene.settings.axes.right),
            "unit_meters": num(scene.settings.unitMeters),
            "frames_per_second": num(scene.settings.framesPerSecond),
            "original_unit_meters": num(scene.settings.originalUnitMeters),
            "time_mode": timeModeName(scene.settings.timeMode),
            "default_camera": scene.settings.defaultCamera,
        ]
    }

    // MARK: - nodes

    private static func buildNode(_ scene: FBXScene, _ node: FBXNode) -> [String: Any] {
        [
            "name": node.name,
            "parent": idx(scene, node.parentID),
            "visible": node.visible,
            "rotation_order": rotationOrderName(node.rotationOrder),
            "inherit_mode": inheritModeName(node.inheritMode),
            "local_transform": transform(node.localTransform),
            "geometry_transform": transform(node.geometryTransform),
            "node_to_world": mat(node.nodeToWorld),
            "node_to_parent": mat(node.nodeToParent),
            "mesh": idx(scene, node.meshID),
            "light": idx(scene, node.lightID),
            "camera": idx(scene, node.cameraID),
            "bone": idx(scene, node.boneID),
            "is_root": node.isRoot,
        ]
    }

    // MARK: - meshes

    private static func buildMesh(_ scene: FBXScene, _ mesh: FBXMesh) -> [String: Any] {
        var d: [String: Any] = [:]
        d["name"] = mesh.name
        d["num_vertices"] = mesh.numVertices
        d["num_indices"] = mesh.numIndices
        d["num_faces"] = mesh.numFaces
        d["num_triangles"] = mesh.numTriangles
        d["num_edges"] = mesh.numEdges
        d["faces"] = mesh.faces.map { [Int($0.indexBegin), Int($0.numIndices)] }

        if let vp = vertexAttribDict(mesh.vertexPosition, flattenVec3) { d["vertex_position"] = vp }
        if let vn = vertexAttribDict(mesh.vertexNormal, flattenVec3) { d["vertex_normal"] = vn }
        if let vc = vertexAttribDict(mesh.vertexCrease, flattenReal) { d["vertex_crease"] = vc }

        d["uv_sets"] = mesh.uvSets.map { set -> [String: Any] in
            var s: [String: Any] = ["name": set.name]
            if let uv = vertexAttribDict(set.vertexUV, flattenVec2) { s["vertex_uv"] = uv }
            if let t = vertexAttribDict(set.vertexTangent, flattenVec3) { s["vertex_tangent"] = t }
            if let b = vertexAttribDict(set.vertexBitangent, flattenVec3) { s["vertex_bitangent"] = b }
            return s
        }
        d["color_sets"] = mesh.colorSets.map { set -> [String: Any] in
            var s: [String: Any] = ["name": set.name]
            if let c = vertexAttribDict(set.vertexColor, flattenVec4) { s["vertex_color"] = c }
            return s
        }

        if !mesh.edges.isEmpty {
            d["edges"] = mesh.edges.map { [Int($0.a), Int($0.b)] }
        }
        if !mesh.edgeSmoothing.isEmpty {
            d["edge_smoothing"] = mesh.edgeSmoothing
        }
        if !mesh.edgeCrease.isEmpty {
            d["edge_crease"] = mesh.edgeCrease.map { num($0) }
        }
        if !mesh.faceSmoothing.isEmpty {
            d["face_smoothing"] = mesh.faceSmoothing
        }
        if !mesh.faceMaterial.isEmpty {
            d["face_material"] = mesh.faceMaterial.map { Int($0) }
        }

        d["materials"] = mesh.materialIDs.map { idx(scene, $0) }
        d["skin_deformers"] = mesh.skinDeformerIDs.map { idx(scene, $0) }
        d["blend_deformers"] = mesh.blendDeformerIDs.map { idx(scene, $0) }
        d["instances"] = mesh.instanceIDs.map { idx(scene, $0) }
        return d
    }

    // MARK: - materials

    private static func buildMaterial(_ scene: FBXScene, _ material: FBXMaterial) -> [String: Any] {
        var fbx: [String: Any] = [:]

        func mapField(_ key: String, _ m: FBXMaterialMap) {
            // ufbx: dumped only when a value was set OR a texture is bound.
            guard m.hasValue || m.textureID != -1 else { return }
            var mm: [String: Any] = [:]
            if m.hasValue && m.valueComponents > 0 {
                let v4 = m.valueVec4
                let comps: [Double] = [v4.x, v4.y, v4.z, v4.w]
                mm["value"] = (0..<min(m.valueComponents, 4)).map { num(comps[$0]) }
            }
            if m.textureID != -1 { mm["texture"] = idx(scene, m.textureID) }
            fbx[key] = mm
        }

        mapField("diffuse_color", material.fbx.diffuseColor)
        mapField("diffuse_factor", material.fbx.diffuseFactor)
        mapField("specular_color", material.fbx.specularColor)
        mapField("specular_factor", material.fbx.specularFactor)
        mapField("specular_exponent", material.fbx.specularExponent)
        mapField("reflection_color", material.fbx.reflectionColor)
        mapField("reflection_factor", material.fbx.reflectionFactor)
        mapField("transparency_color", material.fbx.transparencyColor)
        mapField("transparency_factor", material.fbx.transparencyFactor)
        mapField("emission_color", material.fbx.emissionColor)
        mapField("emission_factor", material.fbx.emissionFactor)
        mapField("ambient_color", material.fbx.ambientColor)
        mapField("ambient_factor", material.fbx.ambientFactor)
        mapField("normal_map", material.fbx.normalMap)
        mapField("bump", material.fbx.bump)
        mapField("bump_factor", material.fbx.bumpFactor)
        mapField("displacement", material.fbx.displacement)
        mapField("displacement_factor", material.fbx.displacementFactor)
        mapField("vector_displacement", material.fbx.vectorDisplacement)
        mapField("vector_displacement_factor", material.fbx.vectorDisplacementFactor)

        return [
            "name": material.name,
            "shading_model_name": material.shadingModelName,
            "fbx": fbx,
        ]
    }

    // MARK: - textures

    private static func buildTexture(_ tex: FBXTexture) -> [String: Any] {
        [
            "name": tex.name,
            "type": textureTypeName(tex.textureType),
            "filename": tex.relativeFilename,
            "absolute_filename": tex.absoluteFilename,
            "uv_set": tex.uvSet,
            "wrap_u": wrapModeName(tex.wrapU),
            "wrap_v": wrapModeName(tex.wrapV),
            // ufbx: `tex->content.size > 0`; the finalizer's video-content
            // resolution already folds "own or via video" into `hasContent`.
            "has_content": tex.hasContent,
        ]
    }

    // MARK: - lights / cameras / bones

    private static func buildLight(_ light: FBXLight) -> [String: Any] {
        [
            "name": light.name,
            "type": lightTypeName(light.lightType),
            "color": arr(light.color),
            "intensity": num(light.intensity),
            "local_direction": arr(light.localDirection),
            "decay": lightDecayName(light.decay),
            "area_shape": areaShapeName(light.areaShape),
            "inner_angle": num(light.innerAngle),
            "outer_angle": num(light.outerAngle),
            "cast_light": light.castLight,
            "cast_shadows": light.castShadows,
        ]
    }

    private static func buildCamera(_ cam: FBXCamera) -> [String: Any] {
        [
            "name": cam.name,
            "projection_mode": projectionModeName(cam.projectionMode),
            "resolution_is_pixels": cam.resolutionIsPixels,
            "resolution": arr(cam.resolution),
            "field_of_view_deg": arr(cam.fieldOfViewDeg),
            "focal_length_mm": num(cam.focalLengthMm),
            "aspect_mode": aspectModeName(cam.aspectMode),
            "near_plane": num(cam.nearPlane),
            "far_plane": num(cam.farPlane),
            "orthographic_size": arr(cam.orthographicSize),
        ]
    }

    private static func buildBone(_ bone: FBXBone) -> [String: Any] {
        [
            "name": bone.name,
            "radius": num(bone.radius),
            "relative_length": num(bone.relativeLength),
            "is_root": bone.isRoot,
        ]
    }

    // MARK: - skin deformers

    private static func buildSkinDeformer(_ scene: FBXScene, _ skin: FBXSkinDeformer) -> [String: Any] {
        var d: [String: Any] = [:]
        d["name"] = skin.name
        d["skinning_method"] = skinningMethodName(skin.skinningMethod)
        d["clusters"] = skin.clusters.map { cluster -> [String: Any] in
            [
                "name": cluster.name,
                "bone_node": idx(scene, cluster.boneNodeID),
                "num_weights": cluster.numWeights,
                "vertices": cluster.vertices.map { Int($0) },
                "weights": cluster.weights.map { num($0) },
                "geometry_to_bone": mat(cluster.geometryToBone),
                "bind_to_world": mat(cluster.bindToWorld),
            ]
        }
        d["vertices"] = skin.vertices.map { v -> [String: Any] in
            ["weight_begin": Int(v.weightBegin), "num_weights": Int(v.numWeights)]
        }
        d["weights"] = skin.weights.map { w -> [String: Any] in
            ["cluster": Int(w.clusterIndex), "weight": num(w.weight)]
        }
        return d
    }

    // MARK: - blend deformers

    private static func buildBlendDeformer(_ blend: FBXBlendDeformer) -> [String: Any] {
        var d: [String: Any] = [:]
        d["name"] = blend.name
        d["channels"] = blend.channels.map { channel -> [String: Any] in
            var c: [String: Any] = [:]
            c["name"] = channel.name
            c["weight"] = num(channel.weight)
            c["keyframes"] = channel.keyframes.map { key -> [String: Any] in
                var k: [String: Any] = [:]
                k["target_weight"] = num(key.targetWeight)
                k["effective_weight"] = num(key.effectiveWeight)
                if let shape = channel.shape(for: key) {
                    var offs: [Any] = []
                    offs.reserveCapacity(shape.positionOffsets.count * 3)
                    for v in shape.positionOffsets {
                        offs.append(num(v.x)); offs.append(num(v.y)); offs.append(num(v.z))
                    }
                    k["shape"] = [
                        "name": shape.name,
                        "num_offsets": shape.numOffsets,
                        "offset_vertices": shape.offsetVertices.map { Int($0) },
                        "position_offsets": offs,
                    ] as [String: Any]
                }
                return k
            }
            return c
        }
        return d
    }

    // MARK: - anim stacks

    private static func buildAnimStack(_ scene: FBXScene, _ stack: FBXAnimStack) -> [String: Any] {
        [
            "name": stack.name,
            "time_begin": num(stack.timeBegin),
            "time_end": num(stack.timeEnd),
            "layers": stack.layers.map { buildAnimLayer(scene, $0) },
        ]
    }

    private static func buildAnimLayer(_ scene: FBXScene, _ layer: FBXAnimLayer) -> [String: Any] {
        [
            "name": layer.name,
            "weight": num(layer.weight),
            "additive": layer.additive,
            "compose_rotation": layer.composeRotation,
            "compose_scale": layer.composeScale,
            "anim_props": layer.animProps.map { buildAnimProp(scene, $0) },
        ]
    }

    private static func buildAnimProp(_ scene: FBXScene, _ aprop: FBXAnimProp) -> [String: Any] {
        let element = scene.element(aprop.elementID)
        let animValue = scene.element(aprop.animValueID) as? FBXAnimValue
        let curveIDs = animValue?.curveIDs ?? [-1, -1, -1]

        var curves: [Any] = []
        for i in 0..<3 {
            let cid = i < curveIDs.count ? curveIDs[i] : -1
            if let curve = scene.element(cid) as? FBXAnimCurve {
                curves.append(buildAnimCurve(curve))
            } else {
                curves.append(NSNull())
            }
        }

        return [
            "element_name": element?.name ?? "",
            "element_type": elementTypeName(element?.type ?? .unknown),
            "prop_name": aprop.propName,
            "default_value": arr(animValue?.defaultValue ?? .zero),
            "curves": curves,
        ]
    }

    private static func buildAnimCurve(_ curve: FBXAnimCurve) -> [String: Any] {
        [
            "num_keys": curve.keyframes.count,
            "keys": curve.keyframes.map { key -> [String: Any] in
                [
                    "time": num(key.time),
                    "value": num(key.value),
                    "interpolation": interpolationName(key.interpolation),
                    "left": ["dx": num(key.left.dx), "dy": num(key.left.dy)],
                    "right": ["dx": num(key.right.dx), "dy": num(key.right.dy)],
                ]
            },
        ]
    }

    // MARK: - evaluate

    /// Mirrors the `evaluate` block: samples `ufbx_evaluate_transform` at 8
    /// times per stack (1 time if `time_end <= time_begin`), skipping the root
    /// node, in `scene.nodes` order.
    private static func buildEvaluate(_ scene: FBXScene) -> [String: Any] {
        var stacks: [[String: Any]] = []
        for stack in scene.animStacks {
            let t0 = stack.timeBegin, t1 = stack.timeEnd
            let numTimes = t1 > t0 ? 8 : 1
            var times: [Double] = []
            times.reserveCapacity(numTimes)
            for t in 0..<numTimes {
                times.append(numTimes == 1 ? t0 : t0 + Double(t) * (t1 - t0) / 7.0)
            }

            var nodesArr: [[String: Any]] = []
            for node in scene.nodes {
                if node.isRoot { continue }
                var translations: [Any] = []
                var rotations: [Any] = []
                var scales: [Any] = []
                translations.reserveCapacity(numTimes)
                rotations.reserveCapacity(numTimes)
                scales.reserveCapacity(numTimes)
                for t in times {
                    let xf = stack.anim.evaluateTransform(node: node, time: t)
                    translations.append(arr(xf.translation))
                    rotations.append(arr(xf.rotation))
                    scales.append(arr(xf.scale))
                }
                nodesArr.append([
                    "node": node.typedID,
                    "translation": translations,
                    "rotation": rotations,
                    "scale": scales,
                ])
            }

            stacks.append([
                "name": stack.name,
                "times": times.map { num($0) },
                "nodes": nodesArr,
            ])
        }
        return ["stacks": stacks]
    }
}
