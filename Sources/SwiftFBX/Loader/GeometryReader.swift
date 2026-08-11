// Geometry reading: meshes (`ufbxi_read_mesh`, ufbx.c:13434-13811), the generic
// per-vertex layer-element reader (`ufbxi_read_vertex_element`, ufbx.c:12741-12926),
// index sanitization (`ufbxi_fix_index`/`ufbxi_check_indices`, ufbx.c:12666-12728),
// truncated per-face/edge arrays (`ufbxi_read_truncated_array`, ufbx.c:12928-12960),
// blend-shape deltas (`ufbxi_read_shape`, ufbx.c:13010-13075) and the pre-7100
// inline blend shapes (`ufbxi_read_synthetic_blend_shapes`, ufbx.c:13077-13137).
// Notes: docs/ufbx-notes/05-read-objects-1.md sections 12-19.
//
// The same `readGeometry` entry decodes both a `Geometry` object node and a 6100
// `Model` node with inline geometry — ElementReader passes whichever node carries
// the `Vertices`/`PolygonVertexIndex` children.

import Foundation

enum GeometryReader {

    // MARK: - FBX node/name constants (interned strings ufbx compares by pointer)

    private static let nVertices = "Vertices"
    private static let nPolygonVertexIndex = "PolygonVertexIndex"
    private static let nIndexes = "Indexes"
    private static let nEdges = "Edges"
    private static let nNormals = "Normals"
    private static let nMappingInformationType = "MappingInformationType"
    private static let nName = "Name"
    private static let nTypedIndex = "TypedIndex"
    private static let nType = "Type"
    private static let nLayer = "Layer"
    private static let nLayerElement = "LayerElement"
    private static let nShape = "Shape"
    private static let nDeformPercent = "DeformPercent"

    // Mapping modes (exact spellings, incl. the legacy `ByVertice` synonym).
    private static let mByPolygonVertex = "ByPolygonVertex"
    private static let mByVertex = "ByVertex"
    private static let mByVertice = "ByVertice"
    private static let mByPolygon = "ByPolygon"
    private static let mByEdge = "ByEdge"
    private static let mAllSame = "AllSame"

    // ufbx: W attribs (tangent/normal 4th component) are read only when
    // `opts.retain_vertex_attrib_w` is set (ufbx.c:12912). v1 `FBXLoadOptions`
    // exposes no such flag, so W is never retained — matching ufbx's default.
    private static let retainVertexAttribW = false

    // ufbx: `retain_mesh_parts = !ignore_geometry && !skip_mesh_parts`
    // (ufbx.c:25272); under default v1 options this is always true.
    private static let retainMeshParts = true

    // MARK: - Mesh (ufbxi_read_mesh, ufbx.c:13434)

    static func readGeometry(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) throws {
        let mesh = ctx.makeElement(.mesh, name: info.name, props: info.props, fbxID: info.fbxID) as! FBXMesh

        // In FBX <= 7100 blend shapes are inline `Shape` children of the geometry.
        if ctx.version <= 7100 {
            try readSyntheticBlendShapes(ctx, node, info)
        }

        // "Sometimes there are empty meshes in FBX files" — element kept, no geometry.
        guard let verticesNode = node.child(nVertices) else { return }
        guard let flatVertices = verticesNode.asDoubleArray() else {
            throw FBXError(.corruptData, "Vertices is not an array")
        }
        guard flatVertices.count % 3 == 0 else {
            throw FBXError(.corruptData, "Vertices size not divisible by 3")
        }
        let numVertices = flatVertices.count / 3

        var indexData: [UInt32] = []
        if let indicesNode = node.child(nPolygonVertexIndex) {
            guard let ia = indicesNode.asInt32Array() else {
                throw FBXError(.corruptData, "PolygonVertexIndex is not an array")
            }
            indexData = ia.map { UInt32(bitPattern: $0) }
        }
        let numIndices = indexData.count

        let edgeData: [UInt32]? = readUInt32Array(node.child(nEdges))

        let vertices = packVec3(flatVertices)
        mesh.numVertices = numVertices
        mesh.numIndices = numIndices
        mesh.vertices = vertices

        // ufbx: tolerate a final face missing its negative terminator (non-strict).
        if numIndices > 0, Int32(bitPattern: indexData[numIndices - 1]) >= 0 {
            indexData[numIndices - 1] = ~indexData[numIndices - 1]
        }

        // Edges — decoded BEFORE un-negating indices (relies on the sign bits).
        if let edgeData {
            var edges: [FBXEdge] = []
            edges.reserveCapacity(edgeData.count)
            for raw in edgeData {
                var indexIx = Int(raw)
                if indexIx >= numIndices { continue } // non-strict: drop OOB edge
                let a = UInt32(indexIx)
                if Int32(bitPattern: indexData[indexIx]) < 0 {
                    // `a` is the last corner: rewind to the polygon's first corner.
                    while indexIx > 0 && Int32(bitPattern: indexData[indexIx - 1]) >= 0 {
                        indexIx -= 1
                    }
                } else {
                    indexIx += 1 // next corner in the same polygon
                }
                guard indexIx < numIndices else {
                    throw FBXError(.corruptData, "Edge index out of bounds")
                }
                edges.append(FBXEdge(a: a, b: UInt32(indexIx)))
            }
            mesh.edges = edges
            mesh.numEdges = edges.count
        }

        // Decode faces + un-negate terminators in place (ufbxi_process_indices).
        var faces: [FBXFace] = []
        var numTriangles = 0
        var maxFaceTriangles = 0
        var numBad = [0, 0, 0]
        var faceBegin = 0
        var i = 0
        while i < numIndices {
            var ix = indexData[i]
            if Int32(bitPattern: ix) < 0 {
                ix = ~ix // ufbx: bitwise complement, not arithmetic negation
                indexData[i] = ix
                let n = i - faceBegin + 1
                faces.append(FBXFace(indexBegin: UInt32(faceBegin), numIndices: UInt32(n)))
                if n >= 3 {
                    numTriangles += n - 2
                    maxFaceTriangles = max(maxFaceTriangles, n - 2)
                } else {
                    numBad[n] += 1 // n is 1 (point) or 2 (line)
                }
                faceBegin = i + 1
            }
            guard Int(ix) < numVertices else {
                throw FBXError(.corruptData, "Vertex index out of bounds")
            }
            i += 1
        }
        mesh.faces = faces
        mesh.numFaces = faces.count
        mesh.numTriangles = numTriangles
        mesh.maxFaceTriangles = maxFaceTriangles
        mesh.numEmptyFaces = numBad[0]
        mesh.numPointFaces = numBad[1]
        mesh.numLineFaces = numBad[2]

        var vertexFirstIndex = [UInt32](repeating: FBXMesh.noIndex, count: numVertices)
        for ix in 0..<numIndices {
            let vx = Int(indexData[ix])
            if vx < numVertices {
                if vertexFirstIndex[vx] == FBXMesh.noIndex {
                    vertexFirstIndex[vx] = UInt32(ix)
                }
            } else {
                // Unreachable for well-formed data (already hard-checked above).
                indexData[ix] = try fixIndex(ctx, indexData[ix], numVertices)
            }
        }
        mesh.vertexFirstIndex = vertexFirstIndex
        mesh.vertexIndices = indexData

        var vpos = FBXVertexVec3()
        vpos.exists = true
        vpos.values = vertices
        vpos.indices = indexData
        vpos.uniquePerVertex = true
        vpos.valueReals = 3
        mesh.vertexPosition = vpos

        // Per-vertex layer elements + per-face/edge data.
        var bitangents: [(index: Int, elem: FBXVertexVec3)] = []
        var tangents: [(index: Int, elem: FBXVertexVec3)] = []

        for c in node.children {
            guard c.name.hasPrefix("L") else { continue } // cheap pre-filter

            if c.name == "LayerElementNormal" {
                if mesh.vertexNormal.exists { continue } // first-wins
                mesh.vertexNormal = try readVertexVec3(ctx, mesh, c, nNormals, "NormalsIndex", "NormalsW")

            } else if c.name == "LayerElementBinormal" {
                let idx = Int(c.int32(at: 0) ?? 0)
                let elem = try readVertexVec3(ctx, mesh, c, "Binormals", "BinormalsIndex", "BinormalsW")
                if elem.exists { bitangents.append((idx, elem)) }

            } else if c.name == "LayerElementTangent" {
                let idx = Int(c.int32(at: 0) ?? 0)
                let elem = try readVertexVec3(ctx, mesh, c, "Tangents", "TangentsIndex", "TangentsW")
                if elem.exists { tangents.append((idx, elem)) }

            } else if c.name == "LayerElementUV" {
                let idx = Int(c.int32(at: 0) ?? 0)
                let name = c.child(nName)?.string(at: 0) ?? ""
                var set = FBXUVSet(name: name, index: idx)
                set.vertexUV = try readVertexVec2(ctx, mesh, c, "UV", "UVIndex", nil)
                if set.vertexUV.exists { mesh.uvSets.append(set) }

            } else if c.name == "LayerElementColor" {
                let idx = Int(c.int32(at: 0) ?? 0)
                let name = c.child(nName)?.string(at: 0) ?? ""
                var set = FBXColorSet(name: name, index: idx)
                set.vertexColor = try readVertexVec4(ctx, mesh, c, "Colors", "ColorIndex", nil)
                if set.vertexColor.exists { mesh.colorSets.append(set) }

            } else if c.name == "LayerElementVertexCrease" {
                mesh.vertexCrease = try readVertexReal(ctx, mesh, c, "VertexCrease", "VertexCreaseIndex", nil)

            } else if c.name == "LayerElementEdgeCrease" {
                let mapping = c.child(nMappingInformationType)?.string(at: 0) ?? ""
                if mapping == mByEdge {
                    if !mesh.edgeCrease.isEmpty { continue }
                    if let arr = truncatedDoubleArray(ctx, c, "EdgeCrease", size: mesh.numEdges) {
                        mesh.edgeCrease = arr
                    }
                } else {
                    warnMapping(ctx, "EdgeCrease", mapping)
                }

            } else if c.name == "LayerElementSmoothing" {
                let mapping = c.child(nMappingInformationType)?.string(at: 0) ?? ""
                if mapping == mByEdge {
                    if !mesh.edgeSmoothing.isEmpty { continue }
                    if let arr = truncatedBoolArray(ctx, c, "Smoothing", size: mesh.numEdges) {
                        mesh.edgeSmoothing = arr
                    }
                } else if mapping == mByPolygon {
                    if !mesh.faceSmoothing.isEmpty { continue }
                    if let arr = truncatedBoolArray(ctx, c, "Smoothing", size: mesh.numFaces) {
                        mesh.faceSmoothing = arr
                    }
                } else {
                    warnMapping(ctx, "Smoothing", mapping)
                }

            } else if c.name == "LayerElementVisibility" {
                let mapping = c.child(nMappingInformationType)?.string(at: 0) ?? ""
                if mapping == mByEdge {
                    if !mesh.edgeVisibility.isEmpty { continue }
                    if let arr = truncatedBoolArray(ctx, c, "Visibility", size: mesh.numEdges) {
                        mesh.edgeVisibility = arr
                    }
                } else {
                    warnMapping(ctx, "Visibility", mapping)
                }

            } else if c.name == "LayerElementMaterial" {
                if !mesh.faceMaterial.isEmpty { continue }
                let mapping = c.child(nMappingInformationType)?.string(at: 0) ?? ""
                if mapping == mByPolygon {
                    if let arr = truncatedUInt32Array(ctx, c, "Materials", size: mesh.numFaces) {
                        mesh.faceMaterial = arr
                    }
                } else if mapping == mAllSame {
                    guard let raw = c.child("Materials")?.asInt32Array(), raw.count >= 1 else {
                        throw FBXError(.corruptData, "AllSame material has no value")
                    }
                    // ufbx uses the zero sentinel when the value is 0; a constant
                    // fill is semantically identical for any material index.
                    mesh.faceMaterial = [UInt32](repeating: UInt32(bitPattern: raw[0]), count: mesh.numFaces)
                } else {
                    warnMapping(ctx, "Materials", mapping)
                }

            } else if c.name == "LayerElementPolygonGroup" {
                if !mesh.faceGroup.isEmpty { continue }
                guard let mapping = c.child(nMappingInformationType)?.string(at: 0) else {
                    throw FBXError(.corruptData, "PolygonGroup missing MappingInformationType")
                }
                if mapping == mByPolygon {
                    if let arr = truncatedUInt32Array(ctx, c, "PolygonGroup", size: mesh.numFaces) {
                        mesh.faceGroup = arr
                    }
                }

            } else if c.name == "LayerElementHole" {
                // ufbx quirk (ufbx.c:13664): guards on `face_group`, not `face_hole`.
                if !mesh.faceGroup.isEmpty { continue }
                guard let mapping = c.child(nMappingInformationType)?.string(at: 0) else {
                    throw FBXError(.corruptData, "Hole missing MappingInformationType")
                }
                if mapping == mByPolygon {
                    if let arr = truncatedBoolArray(ctx, c, "Hole", size: mesh.numFaces) {
                        mesh.faceHole = arr
                    }
                }

            } else if c.name.hasPrefix("LayerElement") {
                // ufbx.c:13670-13705 — 6x00 stores per-material textures inside the
                // mesh geometry: "LayerElementTexture" (→ Diffuse) and
                // "LayerElement<Prop>Textures" (e.g. "LayerElementSpecularTextures").
                if let layer = readLegacyTextureLayer(c) {
                    mesh.legacyTextureLayers.append(layer)
                }
            }
        }

        // Every mesh gets a face_material array (dropped later if no materials).
        if mesh.faceMaterial.isEmpty {
            mesh.faceMaterial = [UInt32](repeating: 0, count: mesh.numFaces)
        }

        // Cross-link tangent/bitangent layers to their owning UV set via `Layer`
        // children (done before the uv_sets sort, matching ufbx order).
        for layerNode in node.children where layerNode.name == nLayer {
            var uvSetIdx: Int? = nil
            var bitangent: FBXVertexVec3? = nil
            var tangent: FBXVertexVec3? = nil
            for le in layerNode.children where le.name == nLayerElement {
                guard let index = le.child(nTypedIndex)?.int32(at: 0) else { continue }
                guard let type = le.child(nType)?.string(at: 0) else { continue }
                let idx = Int(index)
                if type == "LayerElementUV" {
                    if let found = mesh.uvSets.firstIndex(where: { $0.index == idx }) { uvSetIdx = found }
                } else if type == "LayerElementBinormal" {
                    if let l = bitangents.first(where: { $0.index == idx }) { bitangent = l.elem }
                } else if type == "LayerElementTangent" {
                    if let l = tangents.first(where: { $0.index == idx }) { tangent = l.elem }
                }
            }
            if let uvSetIdx {
                if let bitangent { mesh.uvSets[uvSetIdx].vertexBitangent = bitangent }
                if let tangent { mesh.uvSets[uvSetIdx].vertexTangent = tangent }
            }
        }

        mesh.skinnedIsLocal = true
        mesh.skinnedPosition = mesh.vertexPosition
        mesh.skinnedNormal = mesh.vertexNormal
        mesh.skinnedPosition.valueReals = 3
        mesh.skinnedNormal.valueReals = 3

        if !mesh.faceGroup.isEmpty && mesh.faceGroups.isEmpty {
            assignFaceGroups(mesh, retainParts: retainMeshParts)
        }

        // Consumers expect UV/color sets in ascending `index` order (file order
        // may differ); stable sort so equal indices keep file order.
        mesh.uvSets = stableSort(mesh.uvSets) { $0.index }
        mesh.colorSets = stableSort(mesh.colorSets) { $0.index }

        // Subdivision passthrough (evaluation itself is out of v1 scope).
        if let v = node.child("PreviewDivisionLevels")?.int32(at: 0) {
            mesh.subdivisionPreviewLevels = Int(v)
        }
        if let v = node.child("RenderDivisionLevels")?.int32(at: 0) {
            mesh.subdivisionRenderLevels = Int(v)
        }
        if let s = node.child("Smoothness")?.int32(at: 0), s >= 0, s <= 3,
           let m = FBXSubdivisionDisplayMode(rawValue: Int(s)) {
            mesh.subdivisionDisplayMode = m
        }
        // ufbx: raw BoundaryRule maps to enum `raw + 1`, range-checked
        // [0, SHARP_CORNERS-1] i.e. raw 0/1 -> legacy/sharpCorners (ufbx.c:13805).
        if let b = node.child("BoundaryRule")?.int32(at: 0), b >= 0, b <= 1,
           let m = FBXSubdivisionBoundary(rawValue: Int(b) + 1) {
            mesh.subdivisionBoundary = m
        }
    }

    // ufbx: `ufbxi_read_mesh` legacy-texture branch (ufbx.c:13675-13704). Derives
    // the material property name from the LayerElement node name and reads the
    // `TextureId` array + `MappingInformationType`. Returns nil for non-texture
    // LayerElements (those handled above) or ones without a MappingInformationType.
    private static func readLegacyTextureLayer(_ node: FBXDocNode) -> FBXMesh.LegacyTextureLayer? {
        let name = node.name
        var propName = ""
        // "LayerElement<Prop>Textures": strip 12-char "LayerElement" prefix and
        // 8-char "Textures" suffix, then a trailing '_' (ufbx.c:13678-13683).
        if name.count > 20, name.hasSuffix("Textures") {
            let start = name.index(name.startIndex, offsetBy: 12)
            let end = name.index(name.endIndex, offsetBy: -8)
            propName = String(name[start..<end])
            if propName.hasSuffix("_") { propName.removeLast() }
        } else if name == "LayerElementTexture" {
            propName = "Diffuse"
        }
        guard !propName.isEmpty else { return nil }

        // Only counted when a MappingInformationType is present (ufbx.c:13692).
        guard node.child(nMappingInformationType)?.string(at: 0) != nil else { return nil }
        let mapping = node.child(nMappingInformationType)!.string(at: 0)!

        // `TextureId` is classified as an int32 array by the parser (ParseState);
        // absent → empty (an all_same layer then resolves to texture id 0).
        let faceTexture = (node.child("TextureId")?.asInt32Array() ?? []).map { UInt32(bitPattern: $0) }
        return FBXMesh.LegacyTextureLayer(propName: propName,
                                          allSame: mapping == mAllSame,
                                          faceTexture: faceTexture)
    }

    // MARK: - Blend shape geometry (ufbxi_read_shape, ufbx.c:13010)

    static func readShape(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) throws {
        let verticesNode = node.child(nVertices)
        let indicesNode = node.child(nIndexes)
        let normalsNode = node.child(nNormals)
        // No element is created when the delta geometry is absent (ufbx.c:13015).
        guard let verticesNode, let indicesNode else { return }

        let shape = ctx.makeElement(.blendShape, name: info.name, props: info.props, fbxID: info.fbxID) as! FBXBlendShape

        guard let flatVerts = verticesNode.asDoubleArray() else {
            throw FBXError(.corruptData, "Shape Vertices is not an array")
        }
        guard let rawIdx = indicesNode.asInt32Array() else {
            throw FBXError(.corruptData, "Shape Indexes is not an array")
        }
        guard flatVerts.count % 3 == 0 else {
            throw FBXError(.corruptData, "Shape Vertices size not divisible by 3")
        }
        guard rawIdx.count == flatVerts.count / 3 else {
            throw FBXError(.corruptData, "Shape Indexes/Vertices length mismatch")
        }

        let numOffsets = rawIdx.count
        var offsetVertices = rawIdx.map { UInt32(bitPattern: $0) }
        var positionOffsets = packVec3(flatVerts)
        var normalOffsets: [FBXVec3] = []
        if let normalsNode {
            guard let flatN = normalsNode.asDoubleArray(), flatN.count == flatVerts.count else {
                throw FBXError(.corruptData, "Shape Normals length mismatch")
            }
            normalOffsets = packVec3(flatN)
        }

        // Re-sort deltas by target vertex ascending only if not already sorted.
        var sorted = true
        if numOffsets > 1 {
            for j in 1..<numOffsets where offsetVertices[j - 1] > offsetVertices[j] {
                sorted = false
                break
            }
        }
        if !sorted {
            let order = (0..<numOffsets).sorted { a, b in
                offsetVertices[a] != offsetVertices[b] ? offsetVertices[a] < offsetVertices[b] : a < b
            }
            offsetVertices = order.map { offsetVertices[$0] }
            positionOffsets = order.map { positionOffsets[$0] }
            if !normalOffsets.isEmpty { normalOffsets = order.map { normalOffsets[$0] } }
        }

        shape.numOffsets = numOffsets
        shape.offsetVertices = offsetVertices
        shape.positionOffsets = positionOffsets
        shape.normalOffsets = normalOffsets
    }

    // MARK: - Pre-7100 inline blend shapes (ufbxi_read_synthetic_blend_shapes)

    private static func readSyntheticBlendShapes(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo) throws {
        var deformerFbxID: UInt64 = 0
        var deformerCreated = false

        for n in node.children where n.name == nShape {
            let name = n.string(at: 0) ?? ""

            if !deformerCreated {
                let sid = ctx.nextSyntheticID()
                _ = ctx.makeElement(.blendDeformer, name: name, props: FBXProps(), fbxID: sid) as! FBXBlendDeformer
                deformerFbxID = sid
                deformerCreated = true
                connectOO(ctx, sid, info.fbxID)
            }

            // Channel carries a single synthetic `DeformPercent`; the initial
            // value comes from a same-named numeric prop on the mesh, if any.
            var value = 0.0
            var drivenByMeshProp = false
            if let selfProp = info.props.find(name),
               selfProp.type == .number || selfProp.type == .integer {
                value = selfProp.valueReal
                drivenByMeshProp = true
            }
            let deformProp = FBXProp(name: nDeformPercent, type: .number,
                                     valueVec4: FBXVec4(value, 0, 0, 0))
            let channelSid = ctx.nextSyntheticID()
            _ = ctx.makeElement(.blendChannel, name: name,
                                props: FBXProps(props: [deformProp]), fbxID: channelSid) as! FBXBlendChannel
            // ufbx pushes one (empty) FullWeights list per synthetic channel,
            // kept in lockstep with `scene.blendChannels` for the finalizer.
            ctx.tmpFullWeights.append([])

            if drivenByMeshProp {
                connectPP(ctx, info.fbxID, channelSid, name, nDeformPercent)
            } else if ctx.version < 6000 {
                // ufbx: pre-6000 files always drive shapes through the mesh prop.
                connectPP(ctx, info.fbxID, channelSid, name, nDeformPercent)
            }

            let shapeSid = ctx.nextSyntheticID()
            let shapeInfo = ObjectInfo(fbxID: shapeSid, name: name, className: "",
                                       subType: "", props: FBXProps())
            try readShape(ctx, n, shapeInfo)

            connectOO(ctx, channelSid, deformerFbxID)
            connectOO(ctx, shapeSid, channelSid)
        }
    }

    // MARK: - Generic layer-element reader (ufbxi_read_vertex_element)

    private static func readVertexReal(_ ctx: LoadContext, _ mesh: FBXMesh, _ node: FBXDocNode,
                                       _ dataName: String, _ indexName: String, _ wName: String?) throws -> FBXVertexReal {
        try readVertexElement(ctx, mesh, node, dataName, indexName, wName, numComponents: 1, pack: packReal)
    }
    private static func readVertexVec2(_ ctx: LoadContext, _ mesh: FBXMesh, _ node: FBXDocNode,
                                       _ dataName: String, _ indexName: String, _ wName: String?) throws -> FBXVertexVec2 {
        try readVertexElement(ctx, mesh, node, dataName, indexName, wName, numComponents: 2, pack: packVec2)
    }
    private static func readVertexVec3(_ ctx: LoadContext, _ mesh: FBXMesh, _ node: FBXDocNode,
                                       _ dataName: String, _ indexName: String, _ wName: String?) throws -> FBXVertexVec3 {
        try readVertexElement(ctx, mesh, node, dataName, indexName, wName, numComponents: 3, pack: packVec3)
    }
    private static func readVertexVec4(_ ctx: LoadContext, _ mesh: FBXMesh, _ node: FBXDocNode,
                                       _ dataName: String, _ indexName: String, _ wName: String?) throws -> FBXVertexVec4 {
        try readVertexElement(ctx, mesh, node, dataName, indexName, wName, numComponents: 4, pack: packVec4)
    }

    private static func readVertexElement<V>(
        _ ctx: LoadContext, _ mesh: FBXMesh, _ node: FBXDocNode,
        _ dataName: String, _ indexName: String, _ wName: String?,
        numComponents: Int, pack: ([Double]) -> [V]
    ) throws -> FBXVertexAttribute<V> {
        var attrib = FBXVertexAttribute<V>()

        // Missing data array => attribute absent (non-strict, ufbx.c:12749).
        guard let flat = node.child(dataName)?.asDoubleArray() else { return attrib }
        guard flat.count % numComponents == 0 else {
            throw FBXError(.corruptData, "\(dataName) size not divisible by \(numComponents)")
        }
        let numElems = flat.count / numComponents
        // ufbx HACK: empty data array => attribute absent, not zero-length.
        if numElems == 0 { return attrib }

        attrib.exists = true
        attrib.valueReals = numComponents
        attrib.values = pack(flat)

        let numIndices = mesh.numIndices
        let mapping = node.child(nMappingInformationType)?.string(at: 0) ?? ""
        let indexArr: [UInt32]? = readUInt32Array(node.child(indexName))

        // ufbx: some exporters use ByPolygon to mean ByPolygonVertex; detected by
        // the index array (or value count) matching the per-corner count.
        var effectiveMapping = mapping
        if mapping == mByPolygon {
            let n = indexArr?.count ?? numElems
            if n == numIndices { effectiveMapping = mByPolygonVertex }
        }

        if let indexArr {
            // Reference mode: IndexToDirect (an index array is present).
            if effectiveMapping == mByPolygonVertex {
                attrib.indices = try checkIndices(ctx, indexArr, numIndexers: numIndices, numElems: numElems)

            } else if effectiveMapping == mByVertex || effectiveMapping == mByVertice {
                var newIx = [UInt32](repeating: 0, count: numIndices)
                for k in 0..<numIndices {
                    let vx = Int(mesh.vertexIndices[k])
                    if vx < indexArr.count {
                        newIx[k] = indexArr[vx]
                    } else {
                        newIx[k] = try fixIndex(ctx, mesh.vertexIndices[k], numElems)
                    }
                }
                attrib.indices = try checkIndices(ctx, newIx, numIndexers: numIndices, numElems: numElems)
                attrib.uniquePerVertex = true

            } else if effectiveMapping == mByPolygon {
                var newIx = [UInt32](repeating: 0, count: numIndices)
                for faceIx in 0..<mesh.numFaces {
                    let face = mesh.faces[faceIx]
                    var index: UInt32 = FBXMesh.noIndex
                    if faceIx < indexArr.count { index = indexArr[faceIx] }
                    if Int(index) >= numElems { index = try fixIndex(ctx, index, numElems) }
                    for k in 0..<Int(face.numIndices) {
                        newIx[Int(face.indexBegin) + k] = index
                    }
                }
                attrib.indices = newIx // direct-assigned (already sanitized per-face)

            } else if effectiveMapping == mAllSame {
                attrib.indices = [UInt32](repeating: 0, count: numIndices)
                attrib.uniquePerVertex = true

            } else {
                warnMapping(ctx, dataName, mapping)
                return FBXVertexAttribute<V>() // cleared/disabled
            }
        } else {
            // Reference mode: Direct (values used positionally).
            if effectiveMapping == mByPolygonVertex {
                var consec = [UInt32](repeating: 0, count: numIndices)
                for k in 0..<numIndices { consec[k] = UInt32(k) }
                if numElems >= numIndices {
                    attrib.indices = consec
                } else {
                    attrib.indices = try checkIndices(ctx, consec, numIndexers: numIndices, numElems: numElems)
                }

            } else if effectiveMapping == mByVertex || effectiveMapping == mByVertice {
                attrib.indices = try checkIndices(ctx, mesh.vertexIndices, numIndexers: numIndices, numElems: numElems)
                attrib.uniquePerVertex = true

            } else if effectiveMapping == mByPolygon {
                var newIx = [UInt32](repeating: 0, count: numIndices)
                for faceIx in 0..<mesh.numFaces {
                    let face = mesh.faces[faceIx]
                    for k in 0..<Int(face.numIndices) {
                        newIx[Int(face.indexBegin) + k] = UInt32(faceIx)
                    }
                }
                attrib.indices = try checkIndices(ctx, newIx, numIndexers: numIndices, numElems: numElems)

            } else if effectiveMapping == mAllSame {
                attrib.indices = [UInt32](repeating: 0, count: numIndices)
                attrib.uniquePerVertex = true

            } else {
                warnMapping(ctx, dataName, mapping)
                return FBXVertexAttribute<V>()
            }
        }

        if retainVertexAttribW, let wName {
            if let w = node.child(wName)?.asDoubleArray() {
                if w.count == numElems {
                    attrib.valuesW = w
                } else {
                    warn(ctx, .badVertexWAttribute,
                         "Bad W array size \(wName)=\(w.count), \(dataName)=\(numElems)")
                }
            }
        }

        return attrib
    }

    // MARK: - Index sanitization (ufbxi_fix_index / ufbxi_check_indices)

    private static func fixIndex(_ ctx: LoadContext, _ index: UInt32, _ onePastMax: Int) throws -> UInt32 {
        // ufbx default = UFBX_INDEX_ERROR_HANDLING_CLAMP (no v1 option override).
        guard onePastMax > 0 else {
            throw FBXError(.badIndex, "Bad index \(index) (max 0)")
        }
        warn(ctx, .indexClamped, "Clamped index")
        return UInt32(onePastMax - 1)
    }

    private static func checkIndices(_ ctx: LoadContext, _ src: [UInt32],
                                     numIndexers: Int, numElems: Int) throws -> [UInt32] {
        var indices = src
        if indices.count < numIndexers {
            // Truncated: pad with NO_INDEX; normalization then fixes them.
            indices.append(contentsOf: repeatElement(FBXMesh.noIndex, count: numIndexers - indices.count))
        } else if indices.count > numIndexers {
            indices.removeLast(indices.count - numIndexers)
        }
        var k = 0
        while k < indices.count {
            if Int(indices[k]) >= numElems {
                indices[k] = try fixIndex(ctx, indices[k], numElems)
            }
            k += 1
        }
        return indices
    }

    // MARK: - Truncated per-face/edge value arrays (ufbxi_read_truncated_array)

    private static func truncatedDoubleArray(_ ctx: LoadContext, _ node: FBXDocNode, _ name: String, size: Int) -> [Double]? {
        guard let raw = node.child(name)?.asDoubleArray() else {
            warn(ctx, .missingGeometryData, "Missing geometry data: \(name)")
            return nil
        }
        return extendArray(ctx, raw, size: size, zero: 0.0, name: name)
    }
    private static func truncatedBoolArray(_ ctx: LoadContext, _ node: FBXDocNode, _ name: String, size: Int) -> [Bool]? {
        guard let raw = node.child(name)?.asBoolArray() else {
            warn(ctx, .missingGeometryData, "Missing geometry data: \(name)")
            return nil
        }
        return extendArray(ctx, raw, size: size, zero: false, name: name)
    }
    private static func truncatedUInt32Array(_ ctx: LoadContext, _ node: FBXDocNode, _ name: String, size: Int) -> [UInt32]? {
        guard let raw = readUInt32Array(node.child(name)) else {
            warn(ctx, .missingGeometryData, "Missing geometry data: \(name)")
            return nil
        }
        return extendArray(ctx, raw, size: size, zero: 0, name: name)
    }

    /// An `'i'` array from an optional node, reinterpreted as `UInt32` (ufbx
    /// treats FBX int32 indices as unsigned). `nil` when the node is missing or
    /// not an array.
    private static func readUInt32Array(_ node: FBXDocNode?) -> [UInt32]? {
        guard let arr = node?.asInt32Array() else { return nil }
        return arr.map { UInt32(bitPattern: $0) }
    }

    /// ufbx: value arrays repeat their LAST element when short (index arrays pad
    /// with NO_INDEX instead — see `checkIndices`). Longer arrays are truncated.
    private static func extendArray<T>(_ ctx: LoadContext, _ raw: [T], size: Int, zero: T, name: String) -> [T] {
        if raw.count == size { return raw }
        if raw.count > size { return Array(raw.prefix(size)) }
        warn(ctx, .truncatedArray, "Truncated array: \(name)")
        var result = raw
        let pad = raw.last ?? zero
        result.append(contentsOf: repeatElement(pad, count: size - raw.count))
        return result
    }

    // MARK: - Face groups (ufbxi_assign_face_groups)

    private static func assignFaceGroups(_ mesh: FBXMesh, retainParts: Bool) {
        let numFaces = mesh.numFaces
        guard numFaces > 0 else { return }

        // ufbx orders group ids as signed int32 (ufbxi_less_int32).
        let signedIds = mesh.faceGroup.map { Int32(bitPattern: $0) }
        let uniqueSorted = Array(Set(signedIds)).sorted()
        mesh.faceGroups = uniqueSorted.map { FBXFaceGroup(id: $0, name: "") }

        // Single-group fast path: everything maps to group 0.
        if uniqueSorted.count == 1 {
            mesh.faceGroup = [UInt32](repeating: 0, count: numFaces)
            if retainParts {
                var p = FBXMeshPart()
                p.index = 0
                p.numFaces = numFaces
                p.numTriangles = mesh.numTriangles
                p.numEmptyFaces = mesh.numEmptyFaces
                p.numPointFaces = mesh.numPointFaces
                p.numLineFaces = mesh.numLineFaces
                p.faceIndices = (0..<numFaces).map { UInt32($0) }
                mesh.faceGroupParts = [p]
            }
            return
        }

        var idToIndex = [Int32: Int](minimumCapacity: uniqueSorted.count)
        for (i, id) in uniqueSorted.enumerated() { idToIndex[id] = i }

        var parts: [FBXMeshPart] = retainParts ? uniqueSorted.map { _ in FBXMeshPart() } : []
        var newFaceGroup = [UInt32](repeating: 0, count: numFaces)
        for f in 0..<numFaces {
            let gi = idToIndex[signedIds[f]]!
            newFaceGroup[f] = UInt32(gi)
            if retainParts { addFaceToPart(&parts[gi], numIndices: Int(mesh.faces[f].numIndices)) }
        }
        mesh.faceGroup = newFaceGroup

        if retainParts {
            for i in 0..<parts.count {
                parts[i].index = i
                parts[i].faceIndices.reserveCapacity(parts[i].numFaces)
            }
            for f in 0..<numFaces {
                parts[Int(newFaceGroup[f])].faceIndices.append(UInt32(f))
            }
            mesh.faceGroupParts = parts
        }
    }

    private static func addFaceToPart(_ part: inout FBXMeshPart, numIndices: Int) {
        part.numFaces += 1
        if numIndices >= 3 {
            part.numTriangles += numIndices - 2
        } else if numIndices == 2 {
            part.numLineFaces += 1
        } else if numIndices == 1 {
            part.numPointFaces += 1
        } else {
            part.numEmptyFaces += 1
        }
    }

    // MARK: - Small helpers

    private static func packReal(_ f: [Double]) -> [Double] { f }

    private static func packVec2(_ f: [Double]) -> [FBXVec2] {
        var r = [FBXVec2](); r.reserveCapacity(f.count / 2)
        for i in stride(from: 0, to: f.count, by: 2) { r.append(FBXVec2(f[i], f[i + 1])) }
        return r
    }
    private static func packVec3(_ f: [Double]) -> [FBXVec3] {
        var r = [FBXVec3](); r.reserveCapacity(f.count / 3)
        for i in stride(from: 0, to: f.count, by: 3) { r.append(FBXVec3(f[i], f[i + 1], f[i + 2])) }
        return r
    }
    private static func packVec4(_ f: [Double]) -> [FBXVec4] {
        var r = [FBXVec4](); r.reserveCapacity(f.count / 4)
        for i in stride(from: 0, to: f.count, by: 4) { r.append(FBXVec4(f[i], f[i + 1], f[i + 2], f[i + 3])) }
        return r
    }

    /// Stable sort by an integer key (Swift's `sort` is not stable — tie-break on
    /// original position, per DESIGN.md).
    private static func stableSort<T>(_ arr: [T], by key: (T) -> Int) -> [T] {
        arr.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map { $0.element }
    }

    // MARK: - Connections / warnings

    private static func connectOO(_ ctx: LoadContext, _ src: UInt64, _ dst: UInt64) {
        ctx.tmpConnections.append(TmpConnection(srcID: src, srcProp: "", dstID: dst, dstProp: ""))
    }
    private static func connectPP(_ ctx: LoadContext, _ src: UInt64, _ dst: UInt64, _ srcProp: String, _ dstProp: String) {
        ctx.tmpConnections.append(TmpConnection(srcID: src, srcProp: srcProp, dstID: dst, dstProp: dstProp))
    }
    private static func warn(_ ctx: LoadContext, _ kind: FBXWarning.Kind, _ info: String) {
        ctx.warnings.append(FBXWarning(kind: kind, info: info))
    }
    private static func warnMapping(_ ctx: LoadContext, _ dataName: String, _ mapping: String) {
        warn(ctx, .missingPolygonMapping, "Ignoring geometry '\(dataName)' with bad mapping mode '\(mapping)'")
    }
}
