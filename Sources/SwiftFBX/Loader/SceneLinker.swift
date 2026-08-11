// The determinism core: resolves the raw `tmpConnections` into typed, sorted
// `FBXConnection` records, derives the node hierarchy, linearizes the node array
// depth-first (reassigning node `typedID`s), and wires every connection-derived
// cross-reference on each element with ufbx's EXACT comparators + stable sorts.
//
// Ports `ufbxi_pre_finalize_scene` (ufbx.c:18116 — a no-op under DEFAULT load
// options, helper-node synthesis is off) and the connection/linking half of
// `ufbxi_finalize_scene` (ufbx.c:21641), following ufbx's step order (notes 08/09,
// ufbx.c:18547-19370, 21641-22362). The `ufbxi_update_*` passes (props → fields,
// transform chains, world matrices, material fetchMaps, mesh parts, video content)
// are the SceneFinalizer's job — this file stops at connection wiring.
//
// Swift `sort` is NOT stable, so every sort here reproduces ufbx's comparator
// PLUS an explicit original-index tie-break (DESIGN determinism rule).

import Foundation

enum SceneLinker {

    // MARK: - Entry point (ufbxi_finalize_scene connection/link half, ufbx.c:21641)

    static func link(_ ctx: LoadContext) throws {
        preFinalize(ctx)                    // ufbx.c:18116 — no-op under default opts
        resolveConnections(ctx)             // ufbx.c:18665
        addConnectionsToElements(ctx)       // ufbx.c:18782
        try linearizeNodes(ctx)             // ufbx.c:18914
        setupNodes(ctx)                     // ufbx.c:21723
        linkPoses(ctx)                      // ufbx.c:21788
        setupInstances(ctx)                 // ufbx.c:21829
        try linkSkinDeformers(ctx)          // ufbx.c:21838
        linkBlendDeformers(ctx)             // ufbx.c:21955
        linkMeshes(ctx)                     // ufbx.c:22024
        linkAnim(ctx)                       // ufbx.c:22176
        linkMaterials(ctx)                  // ufbx.c:22316
        patchLegacyMeshTextures(ctx)        // ufbx.c:22364
    }

    // MARK: - Pre-finalize (ufbxi_pre_finalize_scene, ufbx.c:18116)

    // ufbx: gated behind non-default geometryTransformHandling / inheritModeHandling
    // / pivotHandling. All three default to *_PRESERVE / *_RETAIN, so `required`
    // is false and the whole helper-node / pivot-rewrite pass is skipped. The
    // provisional parent linked list + instance_counts it computes only feed
    // helper synthesis, so under default options node.parent stays nil (set by
    // linearize) and `has_geometry_transform_nodes`/`has_scale_helper_nodes`
    // remain false, keeping the remapping branches in resolve inert.
    private static func preFinalize(_ ctx: LoadContext) {
        // Default options → no-op. Helper-node synthesis is out of v1 scope.
    }

    // MARK: - Connection resolution (ufbxi_resolve_connections, ufbx.c:18665)

    private static func resolveConnections(_ ctx: LoadContext) {
        let scene = ctx.scene
        let version = ctx.version

        // Work on a mutable copy so pre-7000 endpoint redirection can rewrite ids.
        var tmp = ctx.tmpConnections

        // ufbx: pre-7000 property-connection redirection (18678). If a prop-carrying
        // endpoint's prop is not a known node property AND the target element lacks
        // it, redirect that endpoint's fbx_id to its attribute (routes geometry-level
        // animated props from the Model node to the geometry).
        if version > 0 && version < 7000 {
            for i in tmp.indices {
                if !tmp[i].srcProp.isEmpty && !nodePropertyNames.contains(tmp[i].srcProp) {
                    let src = element(forFbxID: tmp[i].srcID, ctx)
                    if src == nil || src!.props.find(tmp[i].srcProp) == nil {
                        tmp[i].srcID = ctx.fbxAttrMap[tmp[i].srcID] ?? tmp[i].srcID
                    }
                }
                if !tmp[i].dstProp.isEmpty && !nodePropertyNames.contains(tmp[i].dstProp) {
                    let dst = element(forFbxID: tmp[i].dstID, ctx)
                    if dst == nil || dst!.props.find(tmp[i].dstProp) == nil {
                        tmp[i].dstID = ctx.fbxAttrMap[tmp[i].dstID] ?? tmp[i].dstID
                    }
                }
            }
        }

        var resolved: [FBXConnection] = []
        resolved.reserveCapacity(tmp.count)

        for conn in tmp {
            guard let srcID = ctx.fbxIDMap[conn.srcID],
                  let dstID = ctx.fbxIDMap[conn.dstID] else { continue }  // dangling → dropped

            let src = scene.elements[Int(srcID)]
            var dst = scene.elements[Int(dstID)]

            // ufbx: drop arbitrary non-nodes wired to root; some exporters break
            // downstream code with these (18700, gated by !disable_quirks = default).
            if dst.type == .node && src.type != .node && (dst as! FBXNode).isRoot {
                ctx.warning(kind: .badElementConnectedToRoot,
                            info: "Non-node element connected to root", elementID: src.elementID.int32)
                continue
            }

            // ufbx: geometry-transform-helper / scale-helper remapping (18708-18747)
            // is inert under default options (no helper nodes synthesized) — skipped.

            // ufbx: pre-7000 deformer → geometry redirection (18751). A skin/cache
            // deformer connected to a Model node is re-pointed at the node's geometry.
            if version > 0 && version < 7000 && dst.type == .node {
                if src.type == .skinDeformer || src.type == .cacheDeformer {
                    let attrFbxID = ctx.fbxAttrMap[conn.dstID] ?? conn.dstID
                    if let attrID = ctx.fbxIDMap[attrFbxID] {
                        dst = scene.elements[Int(attrID)]
                    }
                }
            }

            resolved.append(FBXConnection(srcID: src.elementID.int32, dstID: dst.elementID.int32,
                                          srcProp: conn.srcProp, dstProp: conn.dstProp))
        }

        // ufbx: two globally-sorted arrays. `connections_dst` is a COPY of
        // `connections_src` taken while both are still in tmp/file order, and only
        // THEN is `connections_src` stable-sorted by src (index 0) and the copy
        // stable-sorted by dst (index 1) (ufbx.c:18768-18774). So the dst-sort's
        // tie-break preserves the ORIGINAL tmp/file order, not the src-sorted order
        // — this matters when several connections share (dst, dst_prop, src_prop),
        // e.g. 6100 textures OO-connected to a mesh's node (fetch order = file order).
        // Swift sort is unstable, so tie-break on the original resolved index.
        let n = resolved.count
        let srcPerm = Array(0..<n).sorted { a, b in
            if connectionLess(resolved[a], resolved[b], index: 0) { return true }
            if connectionLess(resolved[b], resolved[a], index: 0) { return false }
            return a < b
        }
        scene.connections = srcPerm.map { resolved[$0] }

        // Position of each resolved-index within the src-sorted `scene.connections`.
        var srcPos = [Int](repeating: 0, count: n)
        for (pos, ri) in srcPerm.enumerated() { srcPos[ri] = pos }

        // Dst order: stable-sort the ORIGINAL resolved order by dst, then map each
        // entry to its slot in `scene.connections` (what `connectionsDstOrder` indexes).
        let dstPerm = Array(0..<n).sorted { a, b in
            if connectionLess(resolved[a], resolved[b], index: 1) { return true }
            if connectionLess(resolved[b], resolved[a], index: 1) { return false }
            return a < b
        }
        scene.connectionsDstOrder = dstPerm.map { Int32(srcPos[$0]) }
    }

    // ufbx: `ufbxi_cmp_connection_less` (18638). Element pointers order == creation
    // order == element_id (elements laid out in element_id order), so compare by id.
    // index 0 (src sort): src elem, then src_prop, then dst_prop.
    // index 1 (dst sort): dst elem, then dst_prop, then src_prop.
    private static func connectionLess(_ a: FBXConnection, _ b: FBXConnection, index: Int) -> Bool {
        let aElem = index == 0 ? a.srcID : a.dstID
        let bElem = index == 0 ? b.srcID : b.dstID
        if aElem != bElem { return aElem < bElem }
        let aSame = index == 0 ? a.srcProp : a.dstProp
        let bSame = index == 0 ? b.srcProp : b.dstProp
        if aSame != bSame { return FBXProp.byteLess(aSame, bSame) }
        let aOpp = index == 0 ? a.dstProp : a.srcProp
        let bOpp = index == 0 ? b.dstProp : b.srcProp
        return FBXProp.byteLess(aOpp, bOpp)
    }

    // MARK: - Per-element connection slices + animated props (ufbxi_add_connections_to_elements, ufbx.c:18782)

    private static func addConnectionsToElements(_ ctx: LoadContext) {
        let scene = ctx.scene
        let conns = scene.connections
        let order = scene.connectionsDstOrder

        // Contiguous src slices (connections sorted by srcID).
        var i = 0
        while i < conns.count {
            let sid = conns[i].srcID
            var j = i
            while j < conns.count && conns[j].srcID == sid { j += 1 }
            scene.elements[Int(sid)].connectionsSrc = i..<j
            i = j
        }
        // Contiguous dst slices (connectionsDstOrder → conns sorted by dstID).
        i = 0
        while i < order.count {
            let did = conns[Int(order[i])].dstID
            var j = i
            while j < order.count && conns[Int(order[j])].dstID == did { j += 1 }
            scene.elements[Int(did)].connectionsDst = i..<j
            i = j
        }

        // Mark / synthesize animated + connected properties (18808-18905).
        for elem in scene.elements {
            markAnimatedProps(elem, ctx)
        }
    }

    // ufbx: scan an element's dst connections (dst-sorted) for animation edges,
    // OR the CONNECTED/ANIMATED flags into existing props, and synthesize a prop
    // for any animated name missing from the list (18814-18905).
    private static func markAnimatedProps(_ elem: FBXElement, _ ctx: LoadContext) {
        let scene = ctx.scene
        let dstConns = dstConnections(of: elem, scene)
        guard !dstConns.isEmpty else { return }

        // Collect animation groups in dst_prop order (one per distinct dst_prop).
        struct Group { var name: String; var flags: FBXPropFlags; var animValue: FBXAnimValue? }
        var groups: [Group] = []
        var ci = 0
        while ci < dstConns.count {
            let c = dstConns[ci]
            if c.dstProp.isEmpty { ci += 1; continue }
            let srcType = scene.elements[Int(c.srcID)].type
            // Animation edge = OP with a src prop (connected) or a src anim value.
            if c.srcProp.isEmpty && srcType != .animValue { ci += 1; continue }

            let name = c.dstProp
            var flags: FBXPropFlags = []
            var animValue: FBXAnimValue? = nil
            while ci < dstConns.count && dstConns[ci].dstProp == name {
                let cc = dstConns[ci]
                if !cc.srcProp.isEmpty {
                    flags.insert(.connected)
                } else if scene.elements[Int(cc.srcID)].type == .animValue {
                    animValue = scene.elements[Int(cc.srcID)] as? FBXAnimValue
                    flags.insert(.animated)
                }
                ci += 1
            }
            groups.append(Group(name: name, flags: flags, animValue: animValue))
        }
        guard !groups.isEmpty else { return }

        // Rebuild the (sorted) prop list, OR-ing flags into existing props and
        // inserting synthetics at their sorted gap — a forward merge, equivalent
        // to ufbx's copy_start / prop pointer walk but never reorders existing props.
        let props = elem.props.props
        var result: [FBXProp] = []
        result.reserveCapacity(props.count + groups.count)
        var pi = 0
        for g in groups {
            let key = FBXProp.nameKey(g.name)
            while pi < props.count && propKeyLess(props[pi], g.name, key) {
                result.append(props[pi]); pi += 1
            }
            if pi < props.count && props[pi].name == g.name {
                var p = props[pi]
                p.flags.formUnion(g.flags)
                result.append(p); pi += 1
            } else {
                result.append(makeSyntheticProp(name: g.name, key: key, groupFlags: g.flags,
                                                 animValue: g.animValue, elem: elem, ctx: ctx))
            }
        }
        while pi < props.count { result.append(props[pi]); pi += 1 }
        elem.props.props = result
    }

    // ufbx: seed a synthetic animated prop from template defaults, else from the
    // anim value (typing Lcl Translation/Rotation/Scaling; pre-6000 pulls the anim
    // value's default), else flag NO_VALUE (18857-18892).
    private static func makeSyntheticProp(name: String, key: UInt32, groupFlags: FBXPropFlags,
                                          animValue: FBXAnimValue?, elem: FBXElement, ctx: LoadContext) -> FBXProp {
        var flags = groupFlags
        var base: FBXProp? = nil

        if let defProp = elem.props.defaults?.find(name) {
            base = defProp
        } else if let av = animValue {
            var t: FBXPropType = .unknown
            var vec = FBXVec4()
            if name == "Lcl Translation" { t = .translation }
            else if name == "Lcl Rotation" { t = .rotation }
            else if name == "Lcl Scaling" { t = .scaling; vec = FBXVec4(1, 1, 1, 0) }
            if ctx.version < 6000 { vec = FBXVec4(av.defaultValue.x, av.defaultValue.y, av.defaultValue.z, 0) }
            base = FBXProp(name: name, type: t, valueVec4: vec)
        } else {
            flags.insert(.noValue)
        }

        var p = base ?? FBXProp(name: name)
        flags.formUnion(p.flags)                    // ufbx: flags |= new_prop->flags
        p.flags = [.animatable, .synthetic]
        p.flags.formUnion(flags)
        p.name = name
        p.valueString = ""
        p.valueBlob = Data()
        return p
    }

    // ufbx: `ufbxi_name_key_less` (11635) — (internal_key, name bytes) ordering.
    private static func propKeyLess(_ prop: FBXProp, _ name: String, _ key: UInt32) -> Bool {
        let pk = prop.internalKey
        if pk != key { return pk < key }
        return FBXProp.byteLess(prop.name, name)
    }

    // MARK: - Linearize nodes (ufbxi_linearize_nodes, ufbx.c:18914)

    private static func linearizeNodes(_ ctx: LoadContext) throws {
        let scene = ctx.scene
        // Node ptrs in creation order (tmp_node_ids); [0] is the reader's root node.
        let nodeList = scene.nodes
        guard let root = nodeList.first else { return }
        let numNodes = nodeList.count

        // Parenting (18936-18952): unparented → root (pre-6000 / default has no
        // out-of-root nodes), then each node's OO dst connections set src→parent
        // (last-wins per scan order).
        for node in nodeList {
            if node.parentID < 0 && node !== root {
                node.parentID = root.elementID.int32
            }
            for conn in dstConnections(of: node, scene) where conn.srcProp.isEmpty && conn.dstProp.isEmpty {
                let src = scene.elements[Int(conn.srcID)]
                if src.type == .node {
                    (src as! FBXNode).parentID = node.elementID.int32
                }
            }
        }

        // Depth computation with partial-depth caching to stay ~O(n) (18955-18975).
        for node in nodeList {
            var depth = 0
            var p = node.parent
            while let pp = p {
                depth += pp.nodeDepth + 1
                if pp.nodeDepth > 0 { break }
                if depth > numNodes { throw FBXError(.corruptData, "Cyclic node hierarchy") }
                p = pp.parent
            }
            node.nodeDepth = depth
            p = node.parent
            while let pp = p {
                depth -= 1
                if depth <= pp.nodeDepth { break }
                pp.nodeDepth = depth
                p = pp.parent
            }
        }

        // Sort: depth, then parent id, then geometry helpers, then scale helpers,
        // then element id — a strict total order (element_id is unique).
        let sorted = nodeList.sorted(by: nodeLess)
        scene.nodes = sorted
        for (i, node) in sorted.enumerated() {
            node.typedID = i
        }
        scene.rootNode = root
    }

    // ufbx: `ufbxi_cmp_node_less` (18592). Geometry-transform helpers sort first,
    // scale helpers next (both absent under default options).
    private static func nodeLess(_ a: FBXNode, _ b: FBXNode) -> Bool {
        if a.nodeDepth != b.nodeDepth { return a.nodeDepth < b.nodeDepth }
        if a.parentID >= 0 && b.parentID >= 0 && a.parentID != b.parentID {
            return a.parentID < b.parentID
        }
        if a.isGeometryTransformHelper != b.isGeometryTransformHelper {
            return a.isGeometryTransformHelper && !b.isGeometryTransformHelper
        }
        if a.isScaleHelper != b.isScaleHelper {
            return a.isScaleHelper && !b.isScaleHelper
        }
        return a.elementID < b.elementID
    }

    // MARK: - Node setup (ufbxi_finalize_scene, ufbx.c:21723-21785)

    private static func setupNodes(_ ctx: LoadContext) {
        let scene = ctx.scene

        for node in scene.nodes {
            if let parent = node.parent {
                parent.childrenIDs.append(node.elementID.int32)
                if node.isGeometryTransformHelper {
                    parent.geometryTransformHelperID = node.elementID.int32
                }
                // ufbx: force root's direct children to NORMAL inherit under the
                // DEFAULT space_conversion=TRANSFORM_ROOT + inherit_mode_handling=
                // PRESERVE so unit scaling works (21736 — both are the defaults).
                if parent.isRoot {
                    node.originalInheritMode = .normal
                    node.inheritMode = .normal
                }
                // Inherit-scale chain (21743): RrSs → immediate parent; Rrs → the
                // parent's own inherit_scale_node (may chain through several).
                if node.originalInheritMode == .componentwiseScale {
                    node.inheritScaleNodeID = parent.elementID.int32
                } else if node.originalInheritMode == .ignoreParentScale {
                    node.inheritScaleNodeID = parent.inheritScaleNodeID
                }
            }

            // Gather node attributes from OO dst connections whose src is an
            // attribute type; first becomes `attrib`, extras spill to `all_attribs`.
            var allAttribs: [Int32] = []
            for conn in dstConnections(of: node, scene) where conn.srcProp.isEmpty && conn.dstProp.isEmpty {
                let elem = scene.elements[Int(conn.srcID)]
                guard elem.type.isAttribute else { continue }
                if allAttribs.isEmpty {
                    node.attribID = elem.elementID.int32
                    node.attribType = elem.type
                }
                allAttribs.append(elem.elementID.int32)
                switch elem.type {
                case .mesh:   node.meshID = elem.elementID.int32
                case .light:  node.lightID = elem.elementID.int32
                case .camera: node.cameraID = elem.elementID.int32
                case .bone:   node.boneID = elem.elementID.int32
                default: break
                }
            }
            node.allAttribIDs = allAttribs

            // Per-instance materials (node-level; may differ from mesh.materials).
            node.materialIDs = fetchDstElements(node, prop: "", srcType: .material,
                                                searchNode: false, ignoreDuplicates: false, ctx: ctx)
        }
    }

    // MARK: - Pose linking (ufbxi_finalize_scene, ufbx.c:21788-21824)

    private static func linkPoses(_ ctx: LoadContext) {
        let scene = ctx.scene
        for pose in scene.poses {
            let tmp = ctx.tmpBonePoses[pose.elementID] ?? []
            var bonePoses: [(pose: FBXBonePose, order: Int)] = []
            bonePoses.reserveCapacity(tmp.count)

            for (idx, tb) in tmp.enumerated() {
                guard let elemID = ctx.fbxIDMap[tb.fbxID],
                      scene.elements[Int(elemID)].type == .node else { continue }
                let node = scene.elements[Int(elemID)] as! FBXNode
                bonePoses.append((FBXBonePose(boneNodeID: elemID, boneToWorld: tb.boneToWorld), idx))

                if pose.isBindPose {
                    if node.bindPoseID < 0 { node.bindPoseID = pose.elementID.int32 }
                    // Back-fill connected clusters' bind_to_world when still all-zero.
                    for conn in srcConnections(of: node, scene)
                    where conn.srcProp.isEmpty && conn.dstProp.isEmpty {
                        let dst = scene.elements[Int(conn.dstID)]
                        if dst.type == .skinCluster {
                            let cluster = dst as! FBXSkinCluster
                            if isMatrixAllZero(cluster.bindToWorld) {
                                cluster.bindToWorld = tb.boneToWorld
                            }
                        }
                    }
                }
            }

            // Sort by bone node typed_id (stable; typed_ids are unique post-linearize).
            bonePoses.sort { a, b in
                let ta = (scene.elements[Int(a.pose.boneNodeID)] as! FBXNode).typedID
                let tb = (scene.elements[Int(b.pose.boneNodeID)] as! FBXNode).typedID
                if ta != tb { return ta < tb }
                return a.order < b.order
            }
            pose.bonePoses = bonePoses.map { $0.pose }
        }
    }

    // MARK: - Attribute instances (ufbxi_finalize_scene, ufbx.c:21829-21834)

    private static func setupInstances(_ ctx: LoadContext) {
        let scene = ctx.scene
        for elem in scene.elements where elem.type.isAttribute {
            elem.instanceIDs = fetchSrcElements(elem, prop: "", dstType: .node,
                                                searchNode: false, ignoreDuplicates: true, ctx: ctx)
        }
    }

    // MARK: - Skin deformers (ufbxi_finalize_scene, ufbx.c:21838-21953)

    private static func linkSkinDeformers(_ ctx: LoadContext) throws {
        let scene = ctx.scene

        // Each cluster's bone node (the NODE connected OO to the cluster).
        for cluster in scene.skinClusters {
            cluster.boneNodeID = fetchDstElement(cluster, prop: "", srcType: .node,
                                                 searchNode: false, ctx: ctx) ?? -1
        }

        for skin in scene.skinDeformers {
            var clusterIDs = fetchDstElements(skin, prop: "", srcType: .skinCluster,
                                              searchNode: false, ignoreDuplicates: true, ctx: ctx)

            // ufbx: drop clusters with no bone node (connect_broken_elements off).
            clusterIDs = clusterIDs.filter { (scene.elements[Int($0)] as! FBXSkinCluster).boneNodeID >= 0 }
            skin.clusterIDs = clusterIDs

            let clusters = clusterIDs.map { scene.elements[Int($0)] as! FBXSkinCluster }
            let totalWeights = clusters.reduce(0) { $0 + $1.numWeights }

            // num_vertices = max over connected meshes (pads to the largest instance).
            var numVertices = 0
            for conn in srcConnections(of: skin, scene) where conn.srcProp.isEmpty && conn.dstProp.isEmpty {
                let dst = scene.elements[Int(conn.dstID)]
                var mesh: FBXMesh? = nil
                if dst.type == .mesh {
                    mesh = dst as? FBXMesh
                } else if dst.type == .node {
                    var node = dst as! FBXNode
                    if node.geometryTransformHelperID >= 0 {
                        node = scene.elements[Int(node.geometryTransformHelperID)] as! FBXNode
                    }
                    mesh = node.meshID >= 0 ? (scene.elements[Int(node.meshID)] as? FBXMesh) : nil
                }
                if let m = mesh { numVertices = max(numVertices, m.numVertices) }
            }

            // ufbx: default clean_skin_weights off → retain ALL weights incl. ≤ 0.
            let retainAll = true

            var vertices = [FBXSkinVertex](repeating: FBXSkinVertex(), count: numVertices)
            var weights = [FBXSkinWeight](repeating: FBXSkinWeight(), count: totalWeights)

            // Count weights per vertex.
            for cluster in clusters {
                for k in 0..<cluster.numWeights {
                    let v = Int(cluster.vertices[k])
                    if v < numVertices && (retainAll || cluster.weights[k] > 0.0) {
                        vertices[v].numWeights += 1
                    }
                }
            }

            // Prefix sum → weight_begin; seed default DQ weight; reset counters.
            let defaultDQ = skin.skinningMethod == .dualQuaternion ? 1.0 : 0.0
            var offset: UInt32 = 0
            var maxWeights: UInt32 = 0
            for v in 0..<numVertices {
                vertices[v].weightBegin = offset
                vertices[v].dqWeight = defaultDQ
                let nw = vertices[v].numWeights
                offset += nw
                vertices[v].numWeights = 0
                if nw > maxWeights { maxWeights = nw }
            }
            skin.maxWeightsPerVertex = Int(maxWeights)

            // Override DQ weights from the deformer-level DQ arrays.
            for k in 0..<skin.numDqWeights {
                let v = Int(skin.dqVertices[k])
                if v < numVertices { vertices[v].dqWeight = skin.dqWeights[k] }
            }

            // Scatter weights into the flat pool (cluster_index = index in clusters).
            var clusterIndex: UInt32 = 0
            for cluster in clusters {
                for k in 0..<cluster.numWeights {
                    let v = Int(cluster.vertices[k])
                    if v < numVertices && (retainAll || cluster.weights[k] > 0.0) {
                        let local = vertices[v].numWeights
                        vertices[v].numWeights += 1
                        let index = Int(vertices[v].weightBegin + local)
                        weights[index].clusterIndex = clusterIndex
                        weights[index].weight = cluster.weights[k]
                    }
                }
                clusterIndex += 1
            }

            // Sort each vertex's weight run by descending weight (stable → ties keep
            // cluster/scatter order); consumers assume weight[0] is dominant.
            for v in 0..<numVertices {
                let begin = Int(vertices[v].weightBegin)
                let count = Int(vertices[v].numWeights)
                if count <= 1 { continue }
                let run = Array(weights[begin..<begin + count])
                let perm = Array(0..<count).sorted { a, b in
                    if run[a].weight != run[b].weight { return run[a].weight > run[b].weight }
                    return a < b
                }
                for k in 0..<count { weights[begin + k] = run[perm[k]] }
            }

            skin.vertices = vertices
            skin.weights = weights
        }
    }

    // MARK: - Blend deformers (ufbxi_finalize_scene, ufbx.c:21955-22022)

    private static func linkBlendDeformers(_ ctx: LoadContext) {
        let scene = ctx.scene

        for blend in scene.blendDeformers {
            blend.channelIDs = fetchDstElements(blend, prop: "", srcType: .blendChannel,
                                                searchNode: false, ignoreDuplicates: true, ctx: ctx)
        }

        for channel in scene.blendChannels {
            // One keyframe per connected blend shape (fetch order = src element id).
            let shapeIDs = fetchDstElements(channel, prop: "", srcType: .blendShape,
                                            searchNode: false, ignoreDuplicates: false, ctx: ctx)
            var keyframes = shapeIDs.map { FBXBlendKeyframe(shapeID: $0) }

            // FullWeights list pushed per channel in creation order (== typedID).
            var fullWeights = ctx.tmpFullWeights.indices.contains(channel.typedID)
                ? ctx.tmpFullWeights[channel.typedID] : []

            for i in keyframes.indices {
                keyframes[i].targetWeight = 1.0
                guard i < fullWeights.count else { continue }
                if !ctx.blenderFullWeights {
                    keyframes[i].targetWeight = fullWeights[i] / 100.0
                } else {
                    let shape = scene.elements[Int(keyframes[i].shapeID)] as! FBXBlendShape
                    if fullWeights.count == shape.numOffsets {
                        // ufbx: Blender bakes per-vertex weights as offset_weights;
                        // the whole array is divided by 100 once (at i==0).
                        if i == 0 { for j in fullWeights.indices { fullWeights[j] /= 100.0 } }
                        shape.offsetWeights = fullWeights
                    }
                }
            }

            // Sort ascending by target_weight (stable → ties keep fetch order).
            let perm = Array(keyframes.indices).sorted { a, b in
                if keyframes[a].targetWeight != keyframes[b].targetWeight {
                    return keyframes[a].targetWeight < keyframes[b].targetWeight
                }
                return a < b
            }
            keyframes = perm.map { keyframes[$0] }
            channel.keyframes = keyframes
            if let last = keyframes.last { channel.targetShapeID = last.shapeID }
        }
    }

    // MARK: - Meshes (ufbxi_finalize_scene, ufbx.c:22024-22155)

    private static func linkMeshes(_ ctx: LoadContext) {
        let scene = ctx.scene
        let searchNode = ctx.version < 7000

        for mesh in scene.meshes {
            // Materials (search up to the node; stop at the first level with any).
            mesh.materialIDs = fetchMeshMaterials(mesh, ctx: ctx)

            // ufbx: extend an instance's material list with the mesh's tail when the
            // instance has fewer materials than the mesh (22083-22099).
            if !mesh.materialIDs.isEmpty && mesh.materialIDs[0] >= 0 {
                for nodeID in mesh.instanceIDs {
                    let node = scene.elements[Int(nodeID)] as! FBXNode
                    if node.materialIDs.count < mesh.materialIDs.count {
                        var mats = node.materialIDs
                        for i in node.materialIDs.count..<mesh.materialIDs.count {
                            mats.append(mesh.materialIDs[i])
                        }
                        node.materialIDs = mats
                    }
                }
            }

            // face_material fixup (ufbx.c:22108-22130). ufbxi_read_mesh always seeds
            // face_material with a full length-num_faces array (sentinel zeros if no
            // LayerElementMaterial), but ufbxi_finalize_scene overwrites it based on
            // how many materials the mesh actually resolves to:
            //   0 materials  → face_material cleared (dump omits it)
            //   1 material   → face_material = all zeros (uc->zero_indices)
            //   >1 materials → keep the per-face array read from the layer element
            //                  (ufbxi_finalize_mesh_material clamps out-of-range here).
            if mesh.materialIDs.count <= 1 {
                if mesh.materialIDs.count == 1 {
                    mesh.faceMaterial = [UInt32](repeating: 0, count: mesh.numFaces)
                } else {
                    mesh.faceMaterial = []
                }
            }

            // Deformer lists (pre-7000 deformers connect via the node → search_node).
            mesh.skinDeformerIDs = fetchDstElements(mesh, prop: "", srcType: .skinDeformer,
                                                    searchNode: searchNode, ignoreDuplicates: true, ctx: ctx)
            mesh.blendDeformerIDs = fetchDstElements(mesh, prop: "", srcType: .blendDeformer,
                                                     searchNode: searchNode, ignoreDuplicates: true, ctx: ctx)
            mesh.cacheDeformerIDs = fetchDstElements(mesh, prop: "", srcType: .cacheDeformer,
                                                     searchNode: searchNode, ignoreDuplicates: true, ctx: ctx)
            mesh.allDeformerIDs = fetchDeformers(mesh, searchNode: searchNode, ctx: ctx)
            // Mesh parts, face_material, canonical UV/color sets, generated normals
            // and the vertex-position fallback are the SceneFinalizer's job.
        }
    }

    // MARK: - Animation (ufbxi_finalize_scene, ufbx.c:22176-22298)

    private static func linkAnim(_ ctx: LoadContext) {
        let scene = ctx.scene

        // Anim stacks → layers + anim descriptor.
        for stack in scene.animStacks {
            stack.layerIDs = fetchDstElements(stack, prop: "", srcType: .animLayer,
                                              searchNode: false, ignoreDuplicates: true, ctx: ctx)
            let layers = stack.layerIDs.map { scene.elements[Int($0)] as! FBXAnimLayer }
            stack.anim = FBXAnim(layers: layers)   // time range back-filled by finalizer
        }

        // Anim layers → anim values + anim props + weight/blend/compose flags.
        for layer in scene.animLayers {
            layer.animValueIDs = fetchDstElements(layer, prop: "", srcType: .animValue,
                                                  searchNode: false, ignoreDuplicates: true, ctx: ctx)

            var props: [(prop: FBXAnimProp, key: UInt32, order: Int)] = []
            var order = 0
            for valueID in layer.animValueIDs {
                let value = scene.elements[Int(valueID)] as! FBXAnimValue
                for ac in srcConnections(of: value, scene) where ac.srcProp.isEmpty && !ac.dstProp.isEmpty {
                    let ap = FBXAnimProp(elementID: ac.dstID, propName: ac.dstProp, animValueID: valueID)
                    props.append((ap, FBXProp.nameKey(ac.dstProp), order))
                    order += 1
                }
            }
            // Sort by (element id, name key, prop name); stable for equal keys.
            props.sort { a, b in
                if a.prop.elementID != b.prop.elementID { return a.prop.elementID < b.prop.elementID }
                if a.key != b.key { return a.key < b.key }
                if a.prop.propName != b.prop.propName { return FBXProp.byteLess(a.prop.propName, b.prop.propName) }
                return a.order < b.order
            }
            layer.animProps = props.map { $0.prop }

            // BlendMode enum → (blended, additive) (22218).
            switch Int(layer.props.findInt("BlendMode", 0)) {
            case 0: layer.blended = true;  layer.additive = true   // Additive
            case 1: layer.blended = false; layer.additive = false  // Override
            case 2: layer.blended = true;  layer.additive = false  // Override Passthrough
            default: layer.blended = false; layer.additive = false
            }

            if let weightProp = layer.props.find("Weight") {
                var w = weightProp.valueReal / 100.0
                if w < 0.0 { w = 0.0 }
                if w > 0.99999 { w = 1.0 }
                layer.weight = w
                layer.weightIsAnimated = weightProp.flags.contains(.animated)
            } else {
                layer.weight = 1.0
                layer.weightIsAnimated = false
            }
            layer.composeRotation = layer.props.findInt("RotationAccumulationMode", 0) == 0
            layer.composeScale = layer.props.findInt("ScaleAccumulationMode", 0) == 0
        }

        // Anim values → default value + component curves (22263-22290).
        for value in scene.animValues {
            var dv = value.defaultValue
            dv.x = value.props.find("X")?.valueReal ?? dv.x
            dv.x = value.props.find("d|X")?.valueReal ?? dv.x
            dv.y = value.props.find("Y")?.valueReal ?? dv.y
            dv.y = value.props.find("d|Y")?.valueReal ?? dv.y
            dv.z = value.props.find("Z")?.valueReal ?? dv.z
            dv.z = value.props.find("d|Z")?.valueReal ?? dv.z

            var curveIDs: [Int32] = [-1, -1, -1]
            var dvArr = [dv.x, dv.y, dv.z]
            for conn in dstConnections(of: value, scene) {
                let src = scene.elements[Int(conn.srcID)]
                guard src.type == .animCurve && conn.srcProp.isEmpty else { continue }
                var index = 0
                let name = conn.dstProp
                if name == "Y" || name == "d|Y" { index = 1 }
                if name == "Z" || name == "d|Z" { index = 2 }
                if let prop = value.props.find(name) { dvArr[index] = prop.valueReal }
                curveIDs[index] = conn.srcID
            }
            value.defaultValue = FBXVec3(dvArr[0], dvArr[1], dvArr[2])
            value.curveIDs = curveIDs
        }

        // Anim curves → time range from first/last keyframe (22292-22298).
        for curve in scene.animCurves where !curve.keyframes.isEmpty {
            curve.minTime = curve.keyframes.first!.time
            curve.maxTime = curve.keyframes.last!.time
        }
    }

    // MARK: - Materials (ufbxi_finalize_scene, ufbx.c:22316-22362)

    private static func linkMaterials(_ ctx: LoadContext) {
        let scene = ctx.scene
        for material in scene.materials {
            // Connection-derived texture list (material_prop = shader_prop = dst_prop).
            // Left in fetch order; the finalizer sorts by material_prop before
            // fetchMaps fills the FBX map textureIDs.
            material.textures = fetchTextures(material, ctx: ctx)
            // shader_type (shading-model + ClassID tables) and fetchMaps are the
            // finalizer's material-subsystem work.
        }
    }

    // MARK: - Legacy mesh texture patch (ufbx.c:22364-22466)

    // Pre-7000 files store per-material textures as `LayerElement*Textures` blocks
    // inside the mesh geometry rather than as material→texture connections. This
    // port of the "Patch the textures from meshes" pass builds each material's
    // `textures` list from those blocks (only when the material has none from
    // direct connections), so the finalizer's `fetchMaps` can wire them into the
    // FBX map slots by material-property name.
    private static func patchLegacyMeshTextures(_ ctx: LoadContext) {
        let scene = ctx.scene
        for mesh in scene.meshes {
            let numMaterials = mesh.materialIDs.count
            if mesh.legacyTextureLayers.isEmpty { continue }
            if numMaterials == 0 { continue }

            // Textures connected to the mesh (searching up to its node), in file
            // order — `TextureId` values index into this list (ufbx.c:22376).
            let textures = fetchDstElements(mesh, prop: "", srcType: .texture,
                                            searchNode: true, ignoreDuplicates: false, ctx: ctx)

            // (materialIndex, textureIndex-into-`textures`, materialProp)
            var matTexs: [(material: Int32, texture: Int32, prop: String)] = []
            for layer in mesh.legacyTextureLayers {
                if layer.allSame {
                    let texID = layer.faceTexture.first.map { Int32(bitPattern: $0) } ?? 0
                    if texID >= 0 && Int(texID) < textures.count {
                        for i in 0..<numMaterials {
                            matTexs.append((Int32(i), texID, layer.propName))
                        }
                    }
                } else if !mesh.faceMaterial.isEmpty {
                    let numFaces = min(layer.faceTexture.count, mesh.numFaces)
                    var prevMaterial: Int32 = -1
                    var prevTexture: Int32 = -1
                    for i in 0..<numFaces {
                        let texID = Int32(bitPattern: layer.faceTexture[i])
                        let matID = Int32(bitPattern: mesh.faceMaterial[i])
                        if texID < 0 || Int(texID) >= textures.count { continue }
                        if matID < 0 || Int(matID) >= numMaterials { continue }
                        if matID == prevMaterial && texID == prevTexture { continue }
                        prevMaterial = matID
                        prevTexture = texID
                        matTexs.append((matID, texID, layer.propName))
                    }
                }
            }

            // Sort by (material, texture, prop) — stable via original-index tie-break
            // (ufbx.c:18620 `ufbxi_cmp_tmp_material_texture_less`).
            let order = Array(matTexs.indices).sorted { a, b in
                let x = matTexs[a], y = matTexs[b]
                if x.material != y.material { return x.material < y.material }
                if x.texture != y.texture { return x.texture < y.texture }
                if x.prop != y.prop { return FBXProp.byteLess(x.prop, y.prop) }
                return a < b
            }
            let sorted = order.map { matTexs[$0] }

            // Flush per material: dedup consecutive (texture, prop); assign to the
            // material only if it has no textures yet (ufbx.c:22429-22464).
            var i = 0
            while i < sorted.count {
                let matID = sorted[i].material
                var j = i
                var group: [FBXMaterialTexture] = []
                var prevTexture: Int32 = -1
                var prevProp: String? = nil
                while j < sorted.count && sorted[j].material == matID {
                    let entry = sorted[j]
                    if !(entry.texture == prevTexture && entry.prop == prevProp) {
                        prevTexture = entry.texture
                        prevProp = entry.prop
                        group.append(FBXMaterialTexture(materialProp: entry.prop,
                                                        shaderProp: entry.prop,
                                                        textureID: textures[Int(entry.texture)]))
                    }
                    j += 1
                }
                if matID >= 0 && Int(matID) < numMaterials && !group.isEmpty {
                    let material = scene.elements[Int(mesh.materialIDs[Int(matID)])] as! FBXMaterial
                    if material.textures.isEmpty {
                        material.textures = group
                    }
                }
                i = j
            }
        }
    }

    // MARK: - Fetch helpers (ufbxi_fetch_*, ufbx.c:19035-19239)

    // ufbx: `ufbxi_get_element_node` (19035). For an attribute → its first instance
    // node; for a geometry-transform-helper node → its parent; else nil.
    private static func elementNode(_ elem: FBXElement, _ scene: FBXScene) -> FBXElement? {
        if elem.type == .node {
            let node = elem as! FBXNode
            if node.isGeometryTransformHelper { return node.parent }
            return nil
        }
        return elem.instanceIDs.first.map { scene.elements[Int($0)] }
    }

    // Generic dst fetch: collect srcs of `srcType` from OO (prop=="") or OP dst
    // connections, optionally walking to the element's node (`ufbxi_fetch_dst_elements`).
    private static func fetchDstElements(_ element: FBXElement, prop: String, srcType: FBXElementType,
                                         searchNode: Bool, ignoreDuplicates: Bool, ctx: LoadContext) -> [Int32] {
        let scene = ctx.scene
        var result: [Int32] = []
        var visited = Set<Int32>()
        var cur: FBXElement? = element
        while let elem = cur {
            for conn in dstConnections(of: elem, scene)
            where conn.dstProp == prop && conn.srcProp.isEmpty {
                let src = scene.elements[Int(conn.srcID)]
                guard src.type == srcType else { continue }
                if ignoreDuplicates {
                    if visited.contains(conn.srcID) {
                        ctx.warning(kind: .duplicateConnection,
                                    info: "Duplicate connection to \(element.elementID)", elementID: conn.srcID)
                        continue
                    }
                    visited.insert(conn.srcID)
                }
                result.append(conn.srcID)
            }
            cur = searchNode ? elementNode(elem, scene) : nil
        }
        return result
    }

    private static func fetchDstElement(_ element: FBXElement, prop: String, srcType: FBXElementType,
                                        searchNode: Bool, ctx: LoadContext) -> Int32? {
        let scene = ctx.scene
        var cur: FBXElement? = element
        while let elem = cur {
            for conn in dstConnections(of: elem, scene)
            where conn.dstProp == prop && conn.srcProp.isEmpty {
                let src = scene.elements[Int(conn.srcID)]
                if src.type == srcType { return conn.srcID }
            }
            cur = searchNode ? elementNode(elem, scene) : nil
        }
        return nil
    }

    // Generic src fetch: collect dsts of `dstType` from OO/OP src connections
    // (`ufbxi_fetch_src_elements`).
    private static func fetchSrcElements(_ element: FBXElement, prop: String, dstType: FBXElementType,
                                         searchNode: Bool, ignoreDuplicates: Bool, ctx: LoadContext) -> [Int32] {
        let scene = ctx.scene
        var result: [Int32] = []
        var visited = Set<Int32>()
        var cur: FBXElement? = element
        while let elem = cur {
            for conn in srcConnections(of: elem, scene)
            where conn.srcProp == prop && conn.dstProp.isEmpty {
                let dst = scene.elements[Int(conn.dstID)]
                guard dst.type == dstType else { continue }
                if ignoreDuplicates {
                    if visited.contains(conn.dstID) {
                        ctx.warning(kind: .duplicateConnection,
                                    info: "Duplicate connection to \(element.elementID)", elementID: conn.dstID)
                        continue
                    }
                    visited.insert(conn.dstID)
                }
                result.append(conn.dstID)
            }
            cur = searchNode ? elementNode(elem, scene) : nil
        }
        return result
    }

    // ufbx: `ufbxi_fetch_mesh_materials` (19175) — OO MATERIAL srcs; stop searching
    // up the node chain as soon as one level yields any material.
    private static func fetchMeshMaterials(_ mesh: FBXMesh, ctx: LoadContext) -> [Int32] {
        let scene = ctx.scene
        var result: [Int32] = []
        var cur: FBXElement? = mesh
        while let elem = cur {
            for conn in dstConnections(of: elem, scene)
            where conn.dstProp.isEmpty && conn.srcProp.isEmpty {
                let src = scene.elements[Int(conn.srcID)]
                if src.type == .material { result.append(conn.srcID) }
            }
            if !result.isEmpty { break }
            cur = elementNode(elem, scene)     // search_node = true for meshes
        }
        return result
    }

    // ufbx: `ufbxi_fetch_deformers` (19199) — SKIN/BLEND/CACHE srcs, src_prop empty.
    private static func fetchDeformers(_ element: FBXElement, searchNode: Bool, ctx: LoadContext) -> [Int32] {
        let scene = ctx.scene
        var result: [Int32] = []
        var cur: FBXElement? = element
        while let elem = cur {
            for conn in dstConnections(of: elem, scene) where conn.srcProp.isEmpty {
                let t = scene.elements[Int(conn.srcID)].type
                if t == .skinDeformer || t == .blendDeformer || t == .cacheDeformer {
                    result.append(conn.srcID)
                }
            }
            cur = searchNode ? elementNode(elem, scene) : nil
        }
        return result
    }

    // ufbx: `ufbxi_fetch_textures` (19151) — TEXTURE srcs (src_prop empty) keyed by
    // dst_prop (material_prop = shader_prop). Not deduplicated; not searched up node.
    private static func fetchTextures(_ material: FBXMaterial, ctx: LoadContext) -> [FBXMaterialTexture] {
        let scene = ctx.scene
        var result: [FBXMaterialTexture] = []
        for conn in dstConnections(of: material, scene) where conn.srcProp.isEmpty {
            let src = scene.elements[Int(conn.srcID)]
            if src.type == .texture {
                result.append(FBXMaterialTexture(materialProp: conn.dstProp,
                                                 shaderProp: conn.dstProp, textureID: conn.srcID))
            }
        }
        return result
    }

    // MARK: - Connection slice accessors

    // An element's dst connections in dst-sorted order (via connectionsDstOrder).
    private static func dstConnections(of elem: FBXElement, _ scene: FBXScene) -> [FBXConnection] {
        elem.connectionsDst.map { scene.connections[Int(scene.connectionsDstOrder[$0])] }
    }

    // An element's src connections in src-sorted order (a slice of scene.connections).
    private static func srcConnections(of elem: FBXElement, _ scene: FBXScene) -> ArraySlice<FBXConnection> {
        scene.connections[elem.connectionsSrc]
    }

    // MARK: - Misc helpers

    private static func element(forFbxID fbxID: UInt64, _ ctx: LoadContext) -> FBXElement? {
        ctx.fbxIDMap[fbxID].map { ctx.scene.elements[Int($0)] }
    }

    private static func isMatrixAllZero(_ m: FBXMatrix) -> Bool {
        let c = m.cols
        return c.0.x == 0 && c.0.y == 0 && c.0.z == 0
            && c.1.x == 0 && c.1.y == 0 && c.1.z == 0
            && c.2.x == 0 && c.2.y == 0 && c.2.z == 0
            && c.3.x == 0 && c.3.y == 0 && c.3.z == 0
    }

    // ufbx: `ufbxi_node_prop_names` (11645) — props that live on the node (not the
    // attribute) during pre-7000 connection redirection. Mirrors ElementReader's set.
    private static let nodePropertyNames: Set<String> = [
        "AxisLen", "DefaultAttributeIndex", "Freeze",
        "GeometricRotation", "GeometricScaling", "GeometricTranslation", "InheritType",
        "LODBox", "Lcl Rotation", "Lcl Scaling", "Lcl Translation", "LookAtProperty",
        "MaxDampRangeX", "MaxDampRangeY", "MaxDampRangeZ",
        "MaxDampStrengthX", "MaxDampStrengthY", "MaxDampStrengthZ",
        "MinDampRangeX", "MinDampRangeY", "MinDampRangeZ",
        "MinDampStrengthX", "MinDampStrengthY", "MinDampStrengthZ",
        "NegativePercentShapeSupport", "PostRotation", "PreRotation",
        "PreferedAngleX", "PreferedAngleY", "PreferedAngleZ",
        "QuaternionInterpolate", "RotationActive",
        "RotationMax", "RotationMaxX", "RotationMaxY", "RotationMaxZ",
        "RotationMin", "RotationMinX", "RotationMinY", "RotationMinZ",
        "RotationOffset", "RotationOrder", "RotationPivot", "RotationSpaceForLimitOnly",
        "RotationStiffnessX", "RotationStiffnessY", "RotationStiffnessZ",
        "ScalingActive", "ScalingMax", "ScalingMaxX", "ScalingMaxY", "ScalingMaxZ",
        "ScalingMin", "ScalingMinX", "ScalingMinY", "ScalingMinZ",
        "ScalingOffset", "ScalingPivot", "Show",
        "TranslationActive", "TranslationMax", "TranslationMaxX", "TranslationMaxY", "TranslationMaxZ",
        "TranslationMin", "TranslationMinX", "TranslationMinY", "TranslationMinZ",
        "UpVectorProperty", "Visibility Inheritance", "Visibility", "notes",
    ]
}

// MARK: - Int → Int32 convenience

private extension Int {
    var int32: Int32 { Int32(self) }
}
