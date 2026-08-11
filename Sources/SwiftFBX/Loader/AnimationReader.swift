// Reads the "leaf" object types from the parsed document into typed scene
// elements: materials, textures, layered textures, videos, skin/blend
// deformers, animation stacks/layers/values/curves, and poses — plus the
// selection/display "unknown-ok" collection objects. Ports the relevant slice
// of `ufbxi_read_object`'s dispatch and the per-type `ufbxi_read_*` readers
// (ufbx.c:13992–15099). This layer only extracts raw values into the generic
// property bag plus a handful of directly-stored fields; the "smart" derived
// data (FBX/PBR material maps, skin cluster geometry_to_bone, texture UV
// transforms, blend keyframes, resolved pose bone nodes) is computed later by
// SceneLinker/SceneFinalizer, which consume the raw data this reader produces.
//
// Connections are NOT read here — they come only from the `Connections`
// section (ElementReader). Poses are the sole exception ufbx models: they
// reference bones by raw FBX id/name, bypassing the connection graph
// (ufbx.c:14657), so this reader stashes those references for later resolution.

import Foundation

// MARK: - Transient bone-pose reference

/// One `PoseNode` binding before ids resolve to node elements — the Swift
/// equivalent of ufbx's `ufbxi_tmp_bone_pose` (ufbx.c:6329). SceneFinalizer
/// resolves `fbxID` → node `element_id` to build the real `FBXBonePose`
/// (notes 09, ufbx.c:21788-21824). Stored on `LoadContext.tmpBonePoses` keyed
/// by the owning pose's `element_id`.
struct TmpBonePose: Sendable {
    var fbxID: UInt64
    var boneToWorld: FBXMatrix
}

// MARK: - AnimationReader

/// Reads materials, textures, videos, deformers, animation objects and poses.
/// `readObject` returns `false` when `fbxClass` is not one of this reader's
/// types so the caller can dispatch elsewhere (or fall through to `unknown`).
enum AnimationReader {

    // MARK: Dispatch

    static func readObject(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo, fbxClass: String) throws -> Bool {
        switch fbxClass {
        case "Material":
            readMaterial(ctx, node, info)
        case "Texture":
            readTexture(ctx, node, info)
        case "LayeredTexture":
            readLayeredTexture(ctx, node, info)
        case "Video":
            readVideo(ctx, node, info)
        case "Deformer":
            try readDeformer(ctx, node, info, superType: fbxClass)
        case "AnimationStack":
            readAnimStack(ctx, info)
        case "AnimationLayer":
            _ = make(ctx, .animLayer, info)
        case "AnimationCurveNode":
            // ufbx: AnimationCurveNode → `ufbx_anim_value` (ufbx.c:15058). The
            // d|X/d|Y/d|Z defaults + component curves are wired later.
            _ = make(ctx, .animValue, info)
        case "AnimationCurve":
            try readAnimationCurve(ctx, node, info)
        case "Pose":
            readPose(ctx, node, info)
        case "Collection":
            // ufbx: only the SelectionSet subtype yields an element; any other
            // subtype is silently consumed (ufbx.c:15068-15072).
            if info.subType == "SelectionSet" { readUnknownElement(ctx, info, superType: fbxClass) }
        case "CollectionExclusive":
            if info.subType == "DisplayLayer" { readUnknownElement(ctx, info, superType: fbxClass) }
        case "SelectionNode":
            readUnknownElement(ctx, info, superType: fbxClass)
        default:
            return false
        }
        return true
    }

    // MARK: Element factory

    // ufbx: `ufbxi_push_element` — allocate the typed element, register its
    // fbx_id, append to `scene.elements` + the typed array. LoadContext owns the
    // factory; this wraps it so the (single) call convention is isolated.
    @inline(__always)
    private static func make(_ ctx: LoadContext, _ type: FBXElementType, _ info: ObjectInfo) -> FBXElement {
        ctx.makeElement(type, name: info.name, props: info.props, fbxID: info.fbxID)
    }

    /// SelectionSet / DisplayLayer / SelectionNode have no dedicated element
    /// type in v1 scope, so they become `FBXUnknownElement`s — preserving
    /// element-id parity and connection resolution (they are never dumped).
    private static func readUnknownElement(_ ctx: LoadContext, _ info: ObjectInfo, superType: String) {
        let u = make(ctx, .unknown, info) as! FBXUnknownElement
        u.fbxType = info.className
        u.subType = info.subType
        u.superType = superType
    }

    // MARK: Material (ufbx.c:14534-14546)

    private static func readMaterial(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) {
        let material = make(ctx, .material, info) as! FBXMaterial
        if let shadingModel = node.child("ShadingModel")?.string(at: 0) {
            material.shadingModelName = shadingModel
        }
        // shaderPropPrefix stays "" — filled later for prefixed shader props.
    }

    // MARK: Texture (ufbx.c:14548-14570)

    private static func readTexture(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) {
        let texture = make(ctx, .texture, info) as! FBXTexture
        texture.textureType = .file

        // ufbx probes both FBX spellings for absolute + relative names; the
        // later probe wins if present. `filename` itself is resolved later.
        texture.absoluteFilename = firstString(node, "FileName", "Filename", texture.absoluteFilename)
        texture.relativeFilename = firstString(node, "RelativeFileName", "RelativeFilename", texture.relativeFilename)
        texture.rawAbsoluteFilename = firstRaw(node, "FileName", "Filename", texture.rawAbsoluteFilename)
        texture.rawRelativeFilename = firstRaw(node, "RelativeFileName", "RelativeFilename", texture.rawRelativeFilename)
        // Note: `uv_set`, `wrap_u/v`, `has_content` etc. are derived by the
        // finalizer from props/connections — NOT set here (ufbx.c: read_texture).
    }

    // MARK: LayeredTexture (ufbx.c:14572-14599)

    private static func readLayeredTexture(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) {
        let texture = make(ctx, .texture, info) as! FBXTexture
        texture.textureType = .layered
        // ufbx stashes `Alphas`/`BlendModes` to build `texture.layers` later.
        // v1 scope does not dump layered-texture layers, so this is omitted
        // (see DEVIATIONS). Filenames stay empty (default) for layered textures.
    }

    // MARK: Video (ufbx.c:14601-14624)

    private static func readVideo(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) {
        let video = make(ctx, .video, info) as! FBXVideo
        video.absoluteFilename = firstString(node, "FileName", "Filename", video.absoluteFilename)
        video.relativeFilename = firstString(node, "RelativeFileName", "RelativeFilename", video.relativeFilename)
        video.rawAbsoluteFilename = firstRaw(node, "FileName", "Filename", video.rawAbsoluteFilename)
        video.rawRelativeFilename = firstRaw(node, "RelativeFileName", "RelativeFilename", video.rawRelativeFilename)
        video.content = readEmbeddedBlob(node.child("Content"))
    }

    // MARK: Deformer dispatch (ufbx.c:15032-15046)

    private static func readDeformer(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo, superType: String) throws {
        switch info.subType {
        case "Skin":
            readSkin(ctx, node, info)
        case "Cluster":
            try readSkinCluster(ctx, node, info)
        case "BlendShape":
            _ = make(ctx, .blendDeformer, info)
        case "BlendShapeChannel":
            readBlendChannel(ctx, node, info)
        default:
            // VertexCacheDeformer (cache deformer, out of v1 scope) and any
            // unrecognized subtype become unknown elements for id parity.
            readUnknownElement(ctx, info, superType: superType)
        }
    }

    // MARK: Skin (ufbx.c:13992-14022)

    private static func readSkin(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) {
        let skin = make(ctx, .skinDeformer, info) as! FBXSkinDeformer

        if let type = node.child("SkinningType")?.string(at: 0) {
            switch type {
            case "Rigid": skin.skinningMethod = .rigid
            case "Linear": skin.skinningMethod = .linear
            case "DualQuaternion": skin.skinningMethod = .dualQuaternion
            case "Blend": skin.skinningMethod = .blendedDQLinear
            default: break // absent/unrecognized keeps default .linear
            }
        }

        // ufbx: DQ blend override weights. Size mismatch is tolerated (truncate
        // to the shorter array) even in strict mode (ufbx.c:14012-14019).
        if let indices = node.child("Indexes")?.asInt32Array(),
           let weights = node.child("BlendWeights")?.asDoubleArray() {
            let n = Swift.min(indices.count, weights.count)
            skin.numDqWeights = n
            skin.dqVertices = indices.prefix(n).map { UInt32(bitPattern: $0) }
            skin.dqWeights = Array(weights.prefix(n))
        }
    }

    // MARK: Skin cluster (ufbx.c:14024-14052)

    private static func readSkinCluster(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) throws {
        let cluster = make(ctx, .skinCluster, info) as! FBXSkinCluster

        if let indices = node.child("Indexes")?.asInt32Array(),
           let weights = node.child("Weights")?.asDoubleArray() {
            // ufbx: cluster weights MUST match exactly (unlike skin above).
            guard indices.count == weights.count else {
                throw FBXError(.corruptData, "skin cluster Indexes/Weights size mismatch")
            }
            cluster.numWeights = indices.count
            cluster.vertices = indices.map { UInt32(bitPattern: $0) }
            cluster.weights = weights
        }

        if let transform = node.child("Transform")?.asDoubleArray(),
           let transformLink = node.child("TransformLink")?.asDoubleArray() {
            guard transform.count >= 16 else { throw FBXError(.corruptData, "cluster Transform < 16 reals") }
            guard transformLink.count >= 16 else { throw FBXError(.corruptData, "cluster TransformLink < 16 reals") }
            cluster.meshNodeToBone = readTransformMatrix(transform)
            cluster.bindToWorld = readTransformMatrix(transformLink)
        }
        // geometry_to_bone / geometry_to_world are computed by the finalizer.
    }

    // MARK: Blend channel (ufbx.c:14054-14086)

    private static func readBlendChannel(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) {
        let channel = make(ctx, .blendChannel, info) as! FBXBlendChannel

        // ufbx pushes one `FullWeights` list per channel, in creation order,
        // kept in lockstep with `scene.blendChannels` for the finalizer's
        // per-channel blend-keyframe build (notes 09, count asserted equal).
        let fullWeights = node.child("FullWeights")?.asDoubleArray() ?? []
        ctx.tmpFullWeights.append(fullWeights)

        // ufbx: Blender exports DeformPercent as a child VALUE, but animations
        // target the `DeformPercent` PROPERTY. Synthesize the property so the
        // anim-curve→property binding still resolves (ufbx.c:14067-14083).
        if channel.props.props.isEmpty, let deformPercent = node.child("DeformPercent") {
            let value = deformPercent.double(at: 0) ?? 100.0
            let prop = FBXProp(name: "DeformPercent", type: .number, valueVec4: FBXVec4(value))
            channel.props.props = [prop]
        }
    }

    // MARK: Anim stack (ufbx.c:14626-14643)

    private static func readAnimStack(_ ctx: LoadContext, _ info: ObjectInfo) {
        // ufbx registers each stack in `anim_stack_map` (name→stack, first wins)
        // for the ≥7000 Take time-range back-fill. TakesReader reconstructs that
        // map itself by scanning `scene.animStacks`, so we only create the
        // element here (no side table needed).
        _ = make(ctx, .animStack, info)
    }

    // MARK: Pose (ufbx.c:14645-14687)

    private static func readPose(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) {
        let pose = make(ctx, .pose, info) as! FBXPose
        pose.isBindPose = (info.subType == "BindPose")

        var tmp: [TmpBonePose] = []
        for child in node.children where child.name == "PoseNode" {
            // ufbx: bones are linked by raw FBX name/id, bypassing connections.
            let fbxID: UInt64
            if ctx.version < 7000 {
                guard let name = child.child("Node")?.string(at: 0) else { continue }
                fbxID = ctx.syntheticID(for: name)
            } else {
                guard let id = child.child("Node")?.int64(at: 0) else { continue }
                fbxID = UInt64(bitPattern: id)
            }

            guard let matrix = child.child("Matrix")?.asDoubleArray(), matrix.count >= 16 else { continue }
            tmp.append(TmpBonePose(fbxID: fbxID, boneToWorld: readTransformMatrix(matrix)))
        }
        // Resolved into `pose.bonePoses` by the finalizer once ids map to nodes.
        ctx.tmpBonePoses[pose.elementID] = tmp
    }

    // MARK: Animation curve (ufbx.c:14257-14532) — the tangent-decode core

    private static func readAnimationCurve(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) throws {
        let curve = make(ctx, .animCurve, info) as! FBXAnimCurve

        curve.preExtrapolation = readExtrapolation(node, "Pre_Extrapolation")
        curve.postExtrapolation = readExtrapolation(node, "Post_Extrapolation")

        // The five parallel arrays must all exist (ufbx aborts otherwise).
        guard let times = node.child("KeyTime")?.asInt64Array() else {
            throw FBXError(.corruptData, "AnimationCurve missing KeyTime")
        }
        guard let values = node.child("KeyValueFloat")?.asDoubleArray() else {
            throw FBXError(.corruptData, "AnimationCurve missing KeyValueFloat")
        }
        guard let attrFlags = node.child("KeyAttrFlags")?.asInt32Array() else {
            throw FBXError(.corruptData, "AnimationCurve missing KeyAttrFlags")
        }
        guard let attrsNode = node.child("KeyAttrDataFloat"), let words = attrWords(attrsNode) else {
            throw FBXError(.corruptData, "AnimationCurve missing KeyAttrDataFloat")
        }
        guard let refs = node.child("KeyAttrRefCount")?.asInt32Array() else {
            throw FBXError(.corruptData, "AnimationCurve missing KeyAttrRefCount")
        }

        // Time/value arrays are parallel; flags/attrs/refs are run-length coded
        // (4 attribute floats per distinct flags run).
        guard times.count == values.count else {
            throw FBXError(.corruptData, "AnimationCurve KeyTime/KeyValueFloat size mismatch")
        }
        guard attrFlags.count == refs.count else {
            throw FBXError(.corruptData, "AnimationCurve KeyAttrFlags/KeyAttrRefCount size mismatch")
        }
        guard words.count == refs.count * 4 else {
            throw FBXError(.corruptData, "AnimationCurve KeyAttrDataFloat size mismatch")
        }

        let numKeys = times.count
        var keys = [FBXKeyframe]()
        keys.reserveCapacity(numKeys)

        // The previous key defines the weight/slope of the left tangent.
        var slopeLeft: Float = 0.0
        var weightLeft: Float = 0.333333

        var prevTime = 0.0
        var nextTime = 0.0

        var refsLeft: Int32 = 0
        var refIdx = 0
        if numKeys > 0 {
            nextTime = Double(times[0]) / ctx.ktimeSecDouble
            if refIdx < refs.count { refsLeft = refs[refIdx] }
        }

        for i in 0..<numKeys {
            guard refsLeft > 0 else {
                throw FBXError(.corruptData, "AnimationCurve run-length underflow")
            }
            let attrBase = refIdx * 4

            let value = values[i]
            if i == 0 {
                curve.minValue = value
                curve.maxValue = value
            } else {
                curve.minValue = Swift.min(curve.minValue, value)
                curve.maxValue = Swift.max(curve.maxValue, value)
            }

            var key = FBXKeyframe()
            key.time = nextTime
            key.value = value

            if i + 1 < numKeys {
                nextTime = Double(times[i + 1]) / ctx.ktimeSecDouble
            }

            let flags = UInt32(bitPattern: attrFlags[refIdx])

            var slopeRight = Float(bitPattern: words[attrBase + 0])
            var weightRight: Float = 0.333333
            var nextSlopeLeft = Float(bitPattern: words[attrBase + 1])
            var nextWeightLeft: Float = 0.333333

            if flags & (KF.weightedRight | KF.weightedNextLeft) != 0 {
                // Weighted tangents: two 0.4 decimal fixed-point values packed
                // into 32 bits (bit-reinterpreted, not numerically converted).
                let packed = words[attrBase + 2]
                if flags & KF.weightedRight != 0 {
                    weightRight = Float(packed & 0xffff) * 0.0001
                }
                if flags & KF.weightedNextLeft != 0 {
                    nextWeightLeft = Float(packed >> 16) * 0.0001
                }
            }
            // Velocity data (p_attr[3]) is deliberately not applied — ufbx
            // found MotionBuilder already bakes it into the auto-bias math
            // (ufbx.c:14356-14372, 14459-14471, both `#if 0`).

            if flags & KF.interpolationConstant != 0 {
                // Constant: flat cubic tangents; CONSTANT_NEXT reuses bit 0x100.
                key.interpolation = (flags & KF.constantNext != 0) ? .constantNext : .constantPrev
                weightRight = 0.333333; nextWeightLeft = 0.333333
                slopeRight = 0.0; nextSlopeLeft = 0.0
            } else if flags & KF.interpolationCubic != 0 {
                key.interpolation = .cubic

                if flags & KF.tangentTCB != 0 {
                    var tcbSlopeLeft = 0.0
                    var tcbSlopeRight = 0.0
                    var tcbEdge = false
                    if i > 0 && key.time > prevTime {
                        tcbSlopeLeft = (key.value - values[i - 1]) / (key.time - prevTime)
                    } else {
                        tcbEdge = true
                    }
                    if i + 1 < numKeys && nextTime > key.time {
                        tcbSlopeRight = (values[i + 1] - key.value) / (nextTime - key.time)
                    } else {
                        tcbEdge = true
                    }
                    let tension = Double(Float(bitPattern: words[attrBase + 0]))
                    let continuity = Double(Float(bitPattern: words[attrBase + 1]))
                    let bias = Double(Float(bitPattern: words[attrBase + 2]))
                    (slopeLeft, slopeRight) = solveTCB(tension: tension, continuity: continuity, bias: bias,
                                                       slopeLeft: tcbSlopeLeft, slopeRight: tcbSlopeRight, edge: tcbEdge)
                    // TCB never propagates next-left info (ufbx.c:14410-14413).
                    nextSlopeLeft = 0.0; nextWeightLeft = 0.333333
                } else if flags & KF.tangentUser != 0 {
                    // User tangents: slopes come straight from the packed data.
                    // Broken tangents are independent slopes; "unified" (non-
                    // broken) tangents are NOT unified — ufbx leaves this as a
                    // TODO (ufbx.c:14420-14422). Ported bug-for-bug (see notes).
                    _ = flags & KF.tangentBroken
                } else {
                    // Auto tangents (TODO: 0x800 auto-break not distinguished).
                    if i > 0 && i + 1 < numKeys && key.time > prevTime && nextTime > key.time {
                        if abs(slopeLeft + slopeRight) <= 0.0001 {
                            let s = solveAutoTangent(prevTime, key.time, nextTime,
                                                     values[i - 1], key.value, values[i + 1],
                                                     weightLeft, weightRight, slopeRight, flags)
                            slopeLeft = s; slopeRight = s
                        } else {
                            slopeLeft = solveAutoTangent(prevTime, key.time, nextTime,
                                                         values[i - 1], key.value, values[i + 1],
                                                         weightLeft, weightRight, -slopeLeft, flags)
                            slopeRight = solveAutoTangent(prevTime, key.time, nextTime,
                                                          values[i - 1], key.value, values[i + 1],
                                                          weightLeft, weightRight, slopeRight, flags)
                        }
                    } else if i > 0 && key.time > prevTime {
                        let s = solveAutoTangentLeft(prevTime, key.time, values[i - 1], key.value,
                                                     weightLeft, -slopeLeft, flags)
                        slopeLeft = s; slopeRight = s
                    } else if i + 1 < numKeys && nextTime > key.time {
                        let s = solveAutoTangentRight(key.time, nextTime, key.value, values[i + 1],
                                                      weightRight, slopeRight, flags)
                        slopeLeft = s; slopeRight = s
                    } else {
                        slopeLeft = 0.0; slopeRight = 0.0
                    }
                }
            } else {
                // Linear / unknown: cubic tangents matching linear, weights 1/3.
                key.interpolation = .linear
                weightRight = 0.333333; nextWeightLeft = 0.333333

                if i + 1 < numKeys && nextTime > key.time {
                    let deltaTime = nextTime - key.time
                    if deltaTime > 0.0 {
                        let slope = Float((values[i + 1] - key.value) / deltaTime)
                        slopeRight = slope; nextSlopeLeft = slope
                    } else {
                        slopeRight = 0.0; nextSlopeLeft = 0.0
                    }
                } else {
                    slopeRight = 0.0; nextSlopeLeft = 0.0
                }
            }

            // Convert slope + weight into absolute tangent deltas. ufbx computes
            // `dx = (float)(weight * delta)` (product in double, one rounding to
            // float) then `dy = dx * slope` (float×float); dx/dy are float32
            // (`ufbx_tangent`) and widened into the Double-typed FBXTangent.
            if key.time > prevTime {
                let dx = Float(Double(weightLeft) * (key.time - prevTime))
                key.left = FBXTangent(dx: Double(dx), dy: Double(dx * slopeLeft))
            } else {
                key.left = FBXTangent(dx: 0, dy: 0)
            }

            if nextTime > key.time {
                let dx = Float(Double(weightRight) * (nextTime - key.time))
                key.right = FBXTangent(dx: Double(dx), dy: Double(dx * slopeRight))
            } else {
                key.right = FBXTangent(dx: 0, dy: 0)
            }

            keys.append(key)

            // Roll this key's right tangent forward into the next key's left.
            slopeLeft = nextSlopeLeft
            weightLeft = nextWeightLeft
            prevTime = key.time

            // Decrement the run refcount, advancing to the next run at zero.
            refsLeft -= 1
            if refsLeft == 0 {
                refIdx += 1
                if refIdx < refs.count { refsLeft = refs[refIdx] }
            }
        }

        curve.keyframes = keys
        // min_time/max_time are filled by the finalizer, not here (ufbx parity).
    }

    // MARK: Extrapolation (ufbx.c:14227-14255)

    private static func readExtrapolation(_ node: FBXDocNode, _ name: String) -> FBXExtrapolation {
        var mode: FBXExtrapolationMode = .constant
        var repeatCount: Int32 = -1

        if let child = node.child(name), let modeCh = child.child("Type")?.int32(at: 0) {
            switch modeCh {
            case 0x41: mode = .repeatRelative  // 'A'
            case 0x43: mode = .constant        // 'C'
            case 0x4B: mode = .slope           // 'K'
            case 0x4D: mode = .mirror          // 'M'
            case 0x52: mode = .repeat          // 'R'
            default: break
            }
            if let rep = child.child("Repetition")?.int32(at: 0) {
                repeatCount = rep < 0 ? -1 : rep
            }
        }

        return FBXExtrapolation(mode: mode, repeatCount: repeatCount)
    }

    // MARK: Tangent solvers (ufbx.c:14106-14225)

    private static let keyClampThreshold = 0.0 // ufbx default `key_clamp_threshold`

    private static func solveAutoTangent(
        _ prevTime: Double, _ time: Double, _ nextTime: Double,
        _ prevValue: Double, _ value: Double, _ nextValue: Double,
        _ weightLeft: Float, _ weightRight: Float, _ autoBias: Float, _ flags: UInt32
    ) -> Float {
        if flags & KF.clamp != 0 {
            if Swift.min(abs(prevValue - value), abs(nextValue - value)) <= keyClampThreshold {
                return 0.0
            }
        }

        // Time-independent base slope: the neighbor-to-neighbor secant.
        var slope = (nextValue - prevValue) / (nextTime - prevTime)

        if flags & KF.timeIndependent == 0 {
            let slopeLeft = (value - prevValue) / (time - prevTime)
            let slopeRight = (nextValue - value) / (nextTime - time)
            let delta = (time - prevTime) / (nextTime - prevTime)
            slope = slope * 0.5 + (slopeLeft * (1.0 - delta) + slopeRight * delta) * 0.5

            let biasWeight = abs(Double(autoBias)) / 100.0
            if biasWeight > 0.0001 {
                let biasTarget = Double(autoBias) > 0.0 ? slopeRight : slopeLeft
                let biasDelta = biasTarget - slope
                slope = slope * (1.0 - biasWeight) + biasTarget * biasWeight

                // Auto bias > 500 adds an absolute offset `((|bias|-500)/100)^2 * 40`.
                let absBiasWeight = biasWeight - 5.0
                if absBiasWeight > 0.0 {
                    var biasSign = abs(biasDelta) > 0.00001 ? biasDelta : Double(autoBias)
                    biasSign = biasSign > 0.0 ? 1.0 : -1.0
                    slope += absBiasWeight * absBiasWeight * biasSign * 40.0
                }
            }
        }

        if flags & KF.clampProgressive != 0 {
            let slopeSign = slope >= 0.0 ? 1.0 : -1.0
            var absSlope = slopeSign * slope
            let rangeLeft = Double(weightLeft) * (time - prevTime)
            let rangeRight = Double(weightRight) * (nextTime - time)
            var maxLeft = rangeLeft > 0.0 ? slopeSign * (value - prevValue) / rangeLeft : 0.0
            var maxRight = rangeRight > 0.0 ? slopeSign * (nextValue - value) / rangeRight : 0.0
            // Clamp negatives and NaNs to zero.
            if !(maxLeft > 0.0) { maxLeft = 0.0 }
            if !(maxRight > 0.0) { maxRight = 0.0 }
            if absSlope > maxLeft { absSlope = maxLeft }
            if absSlope > maxRight { absSlope = maxRight }
            slope = slopeSign * absSlope
        }

        return Float(slope)
    }

    private static func solveAutoTangentLeft(
        _ prevTime: Double, _ time: Double, _ prevValue: Double, _ value: Double,
        _ weightLeft: Float, _ autoBias: Float, _ flags: UInt32
    ) -> Float {
        if flags & KF.clampProgressive != 0 { return 0.0 }
        if flags & KF.clamp != 0 {
            if abs(prevValue - value) <= keyClampThreshold { return 0.0 }
        }

        var slope = (value - prevValue) / (time - prevTime)
        if flags & KF.timeIndependent == 0 {
            let absBiasWeight = abs(Double(autoBias)) / 100.0 - 5.0
            if absBiasWeight > 0.0 {
                let biasSign = Double(autoBias) > 0.0 ? 1.0 : -1.0
                slope += absBiasWeight * absBiasWeight * biasSign * 40.0
            }
        }
        return Float(slope)
    }

    private static func solveAutoTangentRight(
        _ time: Double, _ nextTime: Double, _ value: Double, _ nextValue: Double,
        _ weightRight: Float, _ autoBias: Float, _ flags: UInt32
    ) -> Float {
        if flags & KF.clampProgressive != 0 { return 0.0 }
        if flags & KF.clamp != 0 {
            if abs(nextValue - value) <= keyClampThreshold { return 0.0 }
        }

        var slope = (nextValue - value) / (nextTime - time)
        if flags & KF.timeIndependent == 0 {
            let absBiasWeight = abs(Double(autoBias)) / 100.0 - 5.0
            if absBiasWeight > 0.0 {
                let biasSign = Double(autoBias) > 0.0 ? 1.0 : -1.0
                slope += absBiasWeight * absBiasWeight * biasSign * 40.0
            }
        }
        return Float(slope)
    }

    /// Kochanek–Bartels TCB blend (ufbx.c:14215-14225).
    private static func solveTCB(
        tension: Double, continuity: Double, bias: Double,
        slopeLeft: Double, slopeRight: Double, edge: Bool
    ) -> (Float, Float) {
        let factor = edge ? 1.0 : 0.5
        let d00 = factor * (1.0 - tension) * (1.0 + bias) * (1.0 - continuity)
        let d01 = factor * (1.0 - tension) * (1.0 - bias) * (1.0 + continuity)
        let d10 = factor * (1.0 - tension) * (1.0 + bias) * (1.0 + continuity)
        let d11 = factor * (1.0 - tension) * (1.0 - bias) * (1.0 - continuity)
        let left = Float(d00 * slopeLeft + d01 * slopeRight)
        let right = Float(d10 * slopeLeft + d11 * slopeRight)
        return (left, right)
    }

    // MARK: Helpers

    /// ufbx's `ufbxi_read_transform_matrix` (ufbx.c:13957-13963): pick columns
    /// 0,1,2 (basis) and 3 (translation) from a 16-real column-major FBX matrix,
    /// dropping the implicit 4th row. Caller guarantees `data.count >= 16`.
    private static func readTransformMatrix(_ data: [Double]) -> FBXMatrix {
        FBXMatrix(cols: (
            FBXVec3(data[0], data[1], data[2]),
            FBXVec3(data[4], data[5], data[6]),
            FBXVec3(data[8], data[9], data[10]),
            FBXVec3(data[12], data[13], data[14])
        ))
    }

    /// Probe two FBX spellings of a string value, later wins if present
    /// (matches ufbx's sequential `ufbxi_find_val1` overwrite probes).
    private static func firstString(_ node: FBXDocNode, _ a: String, _ b: String, _ current: String) -> String {
        var result = current
        if let s = node.child(a)?.string(at: 0) { result = s }
        if let s = node.child(b)?.string(at: 0) { result = s }
        return result
    }

    private static func firstRaw(_ node: FBXDocNode, _ a: String, _ b: String, _ current: Data) -> Data {
        var result = current
        if let d = node.child(a)?.rawString(at: 0) { result = d }
        if let d = node.child(b)?.rawString(at: 0) { result = d }
        return result
    }

    /// Reads the 4 attribute floats (per run) as raw 32-bit words. ufbx reads
    /// `KeyAttrDataFloat` with the wildcard `'?'` type and reinterprets the
    /// bytes as `float*`; the parser stores it as `.float` (binary / ASCII<7200)
    /// or `.int32` (ASCII>=7200) — either way each element is one 32-bit word.
    private static func attrWords(_ node: FBXDocNode) -> [UInt32]? {
        guard let arr = node.array else { return nil }
        switch arr {
        case .float(let a): return a.map { $0.bitPattern }
        case .int32(let a): return a.map { UInt32(bitPattern: $0) }
        default: return nil
        }
    }

    /// ufbx's `ufbxi_read_embedded_blob` (ufbx.c:11764-11796): the parser has
    /// already concatenated multi-part / base64 content into one `.content`
    /// array, so the array payload is the blob. Falls back to concatenating
    /// scalar raw values if the node was not parsed as an array.
    private static func readEmbeddedBlob(_ node: FBXDocNode?) -> Data {
        guard let node = node else { return Data() }
        if let blob = node.asRawData() { return blob }
        var blob = Data()
        for value in node.values {
            if let d = value.asRawData { blob.append(d) }
        }
        return blob
    }
}

// MARK: - Keyframe attribute flags (ufbx.c:14088-14104)

/// Bit table decoded from each keyframe's `KeyAttrFlags` int32. `constantNext`
/// deliberately shares bit `0x100` with `tangentAuto` — they are disambiguated
/// by the mutually-exclusive top-level interpolation bits (never both set).
private enum KF {
    static let interpolationConstant: UInt32 = 0x2
    static let interpolationLinear: UInt32 = 0x4
    static let interpolationCubic: UInt32 = 0x8
    static let tangentAuto: UInt32 = 0x100
    static let tangentTCB: UInt32 = 0x200
    static let tangentUser: UInt32 = 0x400
    static let tangentBroken: UInt32 = 0x800
    static let constantNext: UInt32 = 0x100
    static let clamp: UInt32 = 0x1000
    static let timeIndependent: UInt32 = 0x2000
    static let clampProgressive: UInt32 = 0x4000
    static let weightedRight: UInt32 = 0x1000000
    static let weightedNextLeft: UInt32 = 0x2000000
    static let velocityRight: UInt32 = 0x10000000
    static let velocityNextLeft: UInt32 = 0x20000000
}
