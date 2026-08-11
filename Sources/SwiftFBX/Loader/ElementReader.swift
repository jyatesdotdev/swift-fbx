// Turns the parsed DOM (`FBXDocument.root` children) into typed scene elements:
// header extension + exporter detection, property templates, the `Objects`
// dispatch (split `Type::Name`, per-class element creation), `Connections`, and
// `GlobalSettings`. Port of `ufbxi_read_root`'s FBX branch and the readers it
// drives (ufbx.c:11764-12652, 14837-15310, 15844-15936; notes 05).
//
// Mesh/Shape geometry goes to `GeometryReader`; materials/textures/videos/
// deformers/animation objects to `AnimationReader`; pre-7000 Takes to
// `TakesReader` (driven by `Loader`, after this file). This file only APPENDS —
// it never resolves a connection or cross-reference.

import Foundation

enum ElementReader {

    // MARK: - Entry point (ufbxi_read_root FBX branch, ufbx.c:15844-15936)

    static func readDocument(_ ctx: LoadContext) throws {
        let root = ctx.doc.root

        // FBXHeaderExtension: creator, KTime unit, SceneInfo metadata (optional).
        if let header = root.child("FBXHeaderExtension") {
            readHeaderExtension(ctx, header)
        }

        // ufbx reads a top-level `Creator` for Blender ASCII exports whose header
        // has none (ufbx.c:15851-15856). We can't observe the ASCII tokenizer's
        // Blender detection, so fall back whenever the header left creator empty.
        if ctx.scene.metadata.creator.isEmpty, let creator = root.child("Creator")?.string(at: 0) {
            ctx.scene.metadata.creator = creator
        }

        // Detect exporter (quirk gating) from the resolved creator string.
        matchExporter(ctx)

        // Root id: post-7000 from `Documents`, pre-7000 the interned "Model::Scene".
        if ctx.version >= 7000 {
            if let documents = root.child("Documents") {
                readDocumentRoot(ctx, documents)
            }
        } else {
            let rootName = ctx.fromAscii ? "Model::Scene" : "Scene\u{0}\u{1}Model"
            ctx.rootID = ctx.syntheticID(for: rootName)
        }

        // Nameless root node (`ufbxi_setup_root_node`, ufbx.c:15827): identity
        // transform, `is_root`. Must be element 0 / nodes[0].
        let rootNode = ctx.makeElement(.node, name: "", fbxID: ctx.rootID) as! FBXNode
        rootNode.isRoot = true

        // Definitions: property templates (optional; pre-7000 has none).
        if let definitions = root.child("Definitions") {
            readDefinitions(ctx, definitions)
        }

        // Objects: the actual scene data.
        if let objects = root.child("Objects") {
            for child in objects.children {
                try readObject(ctx, child)
            }
        }

        // Connections: raw OO/OP/PO/PP edges.
        if let connections = root.child("Connections") {
            readConnections(ctx, connections)
        }

        // Top-level GlobalSettings that the Objects pass skimmed over.
        if let settings = root.child("GlobalSettings") {
            ctx.settingsProps = readProperties(ctx, settings)
        }

        // Version5: pre-6000 (and some 6100 3ds Max exports) keep frame-rate/time
        // settings under a top-level `Version5 > Settings` block instead of (or in
        // addition to) GlobalSettings (ufbxi_read_root, ufbx.c:15921-15928).
        if let version5 = root.child("Version5"),
           let settings = version5.child("Settings") {
            readLegacySettings(ctx, settings)
        }
    }

    // ufbx: `ufbxi_read_legacy_settings` (ufbx.c:15766). Reads a `FrameRate` child
    // (as a double, or a string that fully parses as one); if positive, synthesizes
    // `CustomFrameRate` + `TimeMode = CUSTOM` and merges them into the scene
    // settings props (prepended, then sorted + deduplicated keeping the last of
    // each name — so any existing GlobalSettings prop of the same name wins).
    private static func readLegacySettings(_ ctx: LoadContext, _ node: FBXDocNode) {
        guard let frameRate = node.child("FrameRate") else { return }
        var fps = 0.0
        if let d = frameRate.double(at: 0) {
            fps = d
        } else if let s = frameRate.string(at: 0) {
            let bytes = Array(s.utf8)
            let r = FloatParse.parseDouble(bytes)
            if r.consumed > 0 && r.consumed == bytes.count { fps = r.value }
        }
        guard fps > 0.0 else { return }

        // ufbx: `UFBX_TIME_MODE_CUSTOM` == 14; both props carry SYNTHETIC|VALUE_REAL
        // and `value_int = (int64)value` (ufbxi_init_synthetic_real_prop, 12465).
        let newProps = [
            FBXProp(name: "CustomFrameRate", type: .number, flags: [.synthetic, .valueReal],
                    valueInt: Int64(fps), valueVec4: FBXVec4(fps, 0, 0, 0)),
            FBXProp(name: "TimeMode", type: .integer, flags: [.synthetic, .valueReal],
                    valueInt: Int64(FBXTimeMode.custom.rawValue),
                    valueVec4: FBXVec4(Double(FBXTimeMode.custom.rawValue), 0, 0, 0)),
        ]

        // Prepend new props, stable-sort by name, dedup keeping the last of each run.
        let merged = newProps + ctx.settingsProps.props
        let order = Array(merged.indices).sorted { a, b in
            if FBXProp.less(merged[a], merged[b]) { return true }
            if FBXProp.less(merged[b], merged[a]) { return false }
            return a < b
        }
        let sorted = order.map { merged[$0] }
        var deduped: [FBXProp] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].name == sorted[i].name { j += 1 }
            deduped.append(sorted[j])   // keep-last (ufbxi_deduplicate_properties, 11885)
            i = j + 1
        }
        ctx.settingsProps = FBXProps(props: deduped, defaults: ctx.settingsProps.defaults)
    }

    // MARK: - Header extension (ufbxi_read_header_extension, ufbx.c:11981)

    private static func readHeaderExtension(_ ctx: LoadContext, _ node: FBXDocNode) {
        var hasTCDefinition = false
        var tcDefinition: Int32 = 0
        var headerVersion: Int32 = 0

        for child in node.children {
            switch child.name {
            case "Creator":
                if let creator = child.string(at: 0) {
                    ctx.scene.metadata.creator = creator
                }
            case "FBXHeaderVersion":
                if let v = child.int32(at: 0) { headerVersion = v }
            case "OtherFlags":
                if let tc = child.child("TCDefinition")?.int32(at: 0) {
                    tcDefinition = tc
                    hasTCDefinition = true
                }
            case "SceneInfo":
                readSceneInfo(ctx, child)
            default:
                break
            }
            // ufbx also folds a pre-6000 `FBXVersion` into `uc->version` here
            // (ufbx.c:11996-12003); out of scope — v1 handles >= 6100 only.
        }

        // FBX 8000+ changed KTime units, opt-in via TCDefinition (ufbx.c:12021).
        var useV7KTime = ctx.version < 8000
        if headerVersion >= 1004 && hasTCDefinition {
            useV7KTime = tcDefinition == 127
        }
        ctx.ktimeSec = useV7KTime ? 46_186_158_000 : 141_120_000
        ctx.ktimeSecDouble = Double(ctx.ktimeSec)
    }

    private static func readSceneInfo(_ ctx: LoadContext, _ node: FBXDocNode) {
        ctx.sceneInfoProps = readProperties(ctx, node)
        // Embedded Thumbnail is not needed for the scene model (skipped).
    }

    // MARK: - Exporter detection (ufbxi_match_exporter, ufbx.c:12084)

    private static func matchExporter(_ ctx: LoadContext) {
        let creator = Array(ctx.scene.metadata.creator.utf8)

        if let v = matchVersionString("blender-- ?.?.?", creator) {
            ctx.exporter = .blenderBinary
            ctx.exporterVersion = packVersion(v[0], v[1], v[2])
        } else if let v = matchVersionString("blender- ?.?", creator) {
            ctx.exporter = .blenderBinary
            ctx.exporterVersion = packVersion(v[0], v[1], 0)
        } else if let v = matchVersionString("blender version ?.?", creator) {
            ctx.exporter = .blenderAscii
            ctx.exporterVersion = packVersion(v[0], v[1], 0)
        } else if let v = matchVersionString("fbx sdk/fbx plugins version ?.?", creator) {
            ctx.exporter = .fbxSDK
            ctx.exporterVersion = packVersion(v[0], v[1], 0)
        } else if let v = matchVersionString("fbx sdk/fbx plugins build ?", creator) {
            ctx.exporter = .fbxSDK
            ctx.exporterVersion = packVersion(v[0] / 10000, v[0] / 100 % 100, v[0] % 100)
        } else if let v = matchVersionString("motionbuilder version ?.?", creator) {
            ctx.exporter = .motionBuilder
            ctx.exporterVersion = packVersion(v[0], v[1], 0)
        } else if let v = matchVersionString("motionbuilder/mocap/online version ?.?", creator) {
            ctx.exporter = .motionBuilder
            ctx.exporterVersion = packVersion(v[0], v[1], 0)
        } else if matchVersionString("ufbx_write", creator) != nil {
            ctx.exporter = .ufbxWrite
            ctx.exporterVersion = packVersion(0, 0, 1)
        }

        // ufbx: Blender binary exports store full skin weights (ufbx.c:12123).
        if ctx.exporter == .blenderBinary {
            ctx.blenderFullWeights = true
        }
    }

    private static func packVersion(_ major: UInt32, _ minor: UInt32, _ patch: UInt32) -> UInt32 {
        major &* 1_000_000 &+ minor &* 1_000 &+ patch
    }

    // ufbx: `ufbxi_match_version_string` (ufbx.c:12035) — lowercase letters match
    // case-insensitively, ' ' skips whitespace, '-' skips to the next hyphen,
    // ./()_ are literals, '?' greedily consumes a decimal into `version[]`.
    private static func matchVersionString(_ fmt: String, _ str: [UInt8]) -> [UInt32]? {
        var version: [UInt32] = [0, 0, 0]
        var numIx = 0
        var pos = 0
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")

        for c in fmt.utf8 {
            if c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z") {
                if pos >= str.count { return nil }
                let s = str[pos]
                if s != c && Int(s) + 32 != Int(c) { return nil }
                pos += 1
            } else if c == UInt8(ascii: " ") {
                while pos < str.count {
                    let s = str[pos]
                    if s != UInt8(ascii: " ") && s != UInt8(ascii: "\t") { break }
                    pos += 1
                }
            } else if c == UInt8(ascii: "-") {
                while pos < str.count && str[pos] != UInt8(ascii: "-") { pos += 1 }
                if pos >= str.count { return nil }
                pos += 1
            } else if c == UInt8(ascii: "/") || c == UInt8(ascii: ".") || c == UInt8(ascii: "(")
                || c == UInt8(ascii: ")") || c == UInt8(ascii: "_") {
                if pos >= str.count || str[pos] != c { return nil }
                pos += 1
            } else if c == UInt8(ascii: "?") {
                var num: UInt32 = 0
                var len = 0
                while pos < str.count, str[pos] >= zero, str[pos] <= nine {
                    num = num &* 10 &+ UInt32(str[pos] - zero)
                    pos += 1
                    len += 1
                }
                if len == 0 { return nil }
                if numIx < version.count { version[numIx] = num }
                numIx += 1
            }
        }
        return version
    }

    // MARK: - Documents root id (ufbxi_read_document, ufbx.c:12130)

    private static func readDocumentRoot(_ ctx: LoadContext, _ node: FBXDocNode) {
        for child in node.children where child.name == "Document" {
            if let rootNode = child.child("RootNode")?.int64(at: 0) {
                ctx.rootID = UInt64(bitPattern: rootNode)
                return
            }
        }
    }

    // MARK: - Definitions / templates (ufbxi_read_definitions, ufbx.c:12151)

    private static func readDefinitions(_ ctx: LoadContext, _ node: FBXDocNode) {
        for object in node.children where object.name == "ObjectType" {
            guard let className = object.string(at: 0) else { continue }

            var subType = ""
            var props = FBXProps()
            // Pre-7000 has no PropertyTemplate — just counts.
            if let propTemplate = object.child("PropertyTemplate") {
                var st = propTemplate.string(at: 0) ?? ""
                if st.utf8.count > 3, st.hasPrefix("Fbx") {
                    st = String(st.dropFirst(3))
                    // HACK: Definitions spell it FbxLODGroup, Objects FbxLodGroup.
                    if st == "LODGroup" { st = "LodGroup" }
                }
                subType = st
                props = readProperties(ctx, propTemplate)
            }
            ctx.registerTemplate(className: className, subType: subType, props: props)
        }
    }

    // MARK: - Object dispatch (ufbxi_read_object, ufbx.c:14947)

    private static func readObject(_ ctx: LoadContext, _ node: FBXDocNode) throws {
        // GlobalSettings has no identity tuple — handle before parsing one.
        if node.name == "GlobalSettings" {
            ctx.settingsProps = readProperties(ctx, node)
            return
        }

        // Identity tuple. Parse failure is a soft skip (weird objects appear).
        let fbxID: UInt64
        let typeAndName: String
        var subType: String
        if ctx.version >= 7000 {
            guard let rawID = node.int64(at: 0),
                  let tan = node.string(at: 1),
                  let st = node.string(at: 2) else { return }
            fbxID = ctx.validateFbxID(UInt64(bitPattern: rawID))
            typeAndName = tan
            subType = st
        } else {
            guard let tan = node.string(at: 0),
                  let st = node.string(at: 1) else { return }
            fbxID = ctx.syntheticID(for: tan)
            typeAndName = tan
            subType = st
        }

        subType = stripFbxPrefix(subType)
        let (typeStr, name) = splitTypeAndName(typeAndName, fromAscii: ctx.fromAscii)

        let props = readProperties(ctx, node)
        props.defaults = ctx.findTemplate(className: node.name, subType: subType)

        var info = ObjectInfo(fbxID: fbxID, name: name, className: typeStr, subType: subType, props: props)
        let superType = node.name

        switch superType {
        case "Model":
            // Pre-7000 Model may embed its attribute (mesh/light/…) + geometry.
            if ctx.version < 7000 {
                try readSyntheticAttribute(ctx, node, &info, superType: superType)
            }
            readModel(ctx, info)

        case "NodeAttribute":
            try readNodeAttribute(ctx, node, info, superType: superType)

        case "Geometry":
            switch info.subType {
            case "Mesh":  try GeometryReader.readGeometry(ctx, node, info)
            case "Shape": try GeometryReader.readShape(ctx, node, info)
            default:      readUnknown(ctx, info, superType: superType)
            }

        case "SceneInfo":
            readSceneInfo(ctx, node)

        default:
            // Materials, textures, videos, deformers, animation objects, poses,
            // selection/display layers. Returns false only for classes it doesn't
            // own, which then fall through to a first-class unknown element.
            if try AnimationReader.readObject(ctx, node, info, fbxClass: superType) {
                return
            }
            readUnknown(ctx, info, superType: superType)
        }
    }

    // MARK: - Model (ufbxi_read_model, ufbx.c:12601)

    private static func readModel(_ ctx: LoadContext, _ info: ObjectInfo) {
        let node = ctx.makeElement(.node, name: info.name, fbxID: info.fbxID) as! FBXNode
        node.props = info.props

        // InheritType → original inherit mode. NOT ordinal: 0 = componentwise
        // scale ("RrSs"), 2 = ignore-parent-scale ("Rrs"), anything else
        // (incl. default 1 / unset -1) stays NORMAL (ufbx.c:12608-12617).
        let inheritType = info.props.findInt("InheritType", -1)
        switch inheritType {
        case 0: node.originalInheritMode = .componentwiseScale
        case 2: node.originalInheritMode = .ignoreParentScale
        default: break
        }
        // Default inherit_mode_handling = PRESERVE → effective = original.
        node.inheritMode = node.originalInheritMode

        // visibility / rotation order / euler are derived from props by the
        // finalizer's `update_node` (ufbx.c:22955, notes 10), not here.
    }

    // MARK: - NodeAttribute dispatch (ufbxi_read_object NodeAttribute branch)

    private static func readNodeAttribute(_ ctx: LoadContext, _ node: FBXDocNode, _ info: ObjectInfo, superType: String) throws {
        switch info.subType {
        case "Light":  makeAttribute(ctx, .light, info)
        case "Camera": makeAttribute(ctx, .camera, info)
        case "LimbNode", "Limb", "Root": readBone(ctx, info, subType: info.subType)
        case "Null", "Marker": makeAttribute(ctx, .empty, info)
        case "CameraStereo": makeAttribute(ctx, .stereoCamera, info)
        case "CameraSwitcher": makeAttribute(ctx, .cameraSwitcher, info)
        case "FKEffector", "IKEffector": makeAttribute(ctx, .marker, info)
        case "LodGroup": makeAttribute(ctx, .lodGroup, info)
        default: readUnknown(ctx, info, superType: superType)
        }
    }

    // MARK: - Pre-7000 synthetic attribute (ufbxi_read_synthetic_attribute, ufbx.c:14837)

    // Legacy (≤6100) Model nodes carry their attribute (mesh/light/camera/…) and,
    // for meshes, the geometry itself inline. Split the attribute out into its own
    // synthetic element, redirect non-node/non-user props to it, and OO-connect.
    private static func readSyntheticAttribute(_ ctx: LoadContext, _ node: FBXDocNode, _ info: inout ObjectInfo, superType: String) throws {
        var subType = info.subType
        let typeStr = info.className

        // 6100 mesh Models have no sub_type — detect from geometry children.
        if subType.isEmpty, node.child("Vertices") != nil, node.child("PolygonVertexIndex") != nil {
            subType = "Mesh"
        }

        // Plain model: no attribute.
        if (subType.isEmpty || subType == "Model") && typeStr == "Model" {
            return
        }

        var attribInfo = info
        attribInfo.fbxID = ctx.nextSyntheticID()

        // Prefer NodeAttributeName's type/name + its id if unique and unused.
        if let attrTypeAndName = node.child("NodeAttributeName")?.string(at: 0) {
            let (_, attribName) = splitTypeAndName(attrTypeAndName, fromAscii: ctx.fromAscii)
            if !attribName.isEmpty {
                attribInfo.name = attribName
                let attribID = ctx.syntheticID(for: attrTypeAndName)
                if info.fbxID != attribID && ctx.fbxIDMap[attribID] == nil {
                    attribInfo.fbxID = attribID
                }
            }
        }

        // 6x00: node → attribute link so connections can be redirected later.
        ctx.fbxAttrMap[info.fbxID] = attribInfo.fbxID

        // Split properties: non-node-property AND non-user-defined → attribute.
        var nodeProps: [FBXProp] = []
        var attribProps: [FBXProp] = []
        for prop in info.props.props {
            if !nodePropertyNames.contains(prop.name) && !prop.flags.contains(.userDefined) {
                attribProps.append(prop)
            } else {
                nodeProps.append(prop)
            }
        }
        attribInfo.props = FBXProps(props: attribProps, defaults: info.props.defaults)
        info.props.props = nodeProps

        switch subType {
        case "Mesh":   try GeometryReader.readGeometry(ctx, node, attribInfo)
        case "Light":  makeAttribute(ctx, .light, attribInfo)
        case "Camera": makeAttribute(ctx, .camera, attribInfo)
        case "LimbNode", "Limb", "Root": readBone(ctx, attribInfo, subType: subType)
        case "Null", "Marker": makeAttribute(ctx, .empty, attribInfo)
        case "CameraStereo": makeAttribute(ctx, .stereoCamera, attribInfo)
        case "CameraSwitcher": makeAttribute(ctx, .cameraSwitcher, attribInfo)
        case "FKEffector", "IKEffector": makeAttribute(ctx, .marker, attribInfo)
        case "LodGroup": makeAttribute(ctx, .lodGroup, attribInfo)
        default:
            // NURBS/Line data readers are out of v1 scope → opaque unknown.
            readUnknown(ctx, attribInfo, superType: superType)
        }

        // attribute → node (OO).
        ctx.tmpConnections.append(TmpConnection(srcID: attribInfo.fbxID, srcProp: "", dstID: info.fbxID, dstProp: ""))
    }

    // MARK: - Concrete node-attribute readers

    private static func makeAttribute(_ ctx: LoadContext, _ type: FBXElementType, _ info: ObjectInfo) {
        let element = ctx.makeElement(type, name: info.name, fbxID: info.fbxID)
        element.props = info.props
    }

    // ufbxi_read_bone (ufbx.c:13965): only sets `is_root` for the Root sub-type;
    // radius/relative_length come from props in the finalizer.
    private static func readBone(_ ctx: LoadContext, _ info: ObjectInfo, subType: String) {
        let bone = ctx.makeElement(.bone, name: info.name, fbxID: info.fbxID) as! FBXBone
        bone.props = info.props
        if subType == "Root" { bone.isRoot = true }
    }

    // MARK: - Unknown element (ufbxi_read_unknown, ufbx.c:12637)

    private static func readUnknown(_ ctx: LoadContext, _ info: ObjectInfo, superType: String) {
        let unknown = ctx.makeElement(.unknown, name: info.name, fbxID: info.fbxID) as! FBXUnknownElement
        unknown.props = info.props
        unknown.fbxType = info.className
        unknown.subType = info.subType
        unknown.superType = superType
    }

    // MARK: - Connections (ufbxi_read_connections, ufbx.c:15236)

    private static func readConnections(_ ctx: LoadContext, _ node: FBXDocNode) {
        for conn in node.children {
            guard let type = conn.string(at: 0) else { continue }

            var srcID: UInt64 = 0
            var dstID: UInt64 = 0
            var srcProp = ""
            var dstProp = ""

            if ctx.version < 7000 {
                // Pre-7000: Type::Name string pairs resolved via synthetic ids.
                guard let src = conn.string(at: 1) else { continue }
                switch type {
                case "OO":
                    guard let dst = conn.string(at: 2) else { continue }
                    srcID = ctx.syntheticID(for: src)
                    dstID = ctx.syntheticID(for: dst)
                case "OP":
                    guard let dst = conn.string(at: 2) else { continue }
                    srcID = ctx.syntheticID(for: src)
                    dstID = ctx.syntheticID(for: dst)
                    dstProp = conn.string(at: 3) ?? ""
                case "PO":
                    guard let dst = conn.string(at: 3) else { continue }
                    srcID = ctx.syntheticID(for: src)
                    srcProp = conn.string(at: 2) ?? ""
                    dstID = ctx.syntheticID(for: dst)
                case "PP":
                    guard let dst = conn.string(at: 3) else { continue }
                    srcID = ctx.syntheticID(for: src)
                    srcProp = conn.string(at: 2) ?? ""
                    dstID = ctx.syntheticID(for: dst)
                    dstProp = conn.string(at: 4) ?? ""
                default:
                    continue
                }
            } else {
                // Post-7000: unique 64-bit ids.
                switch type {
                case "OO":
                    guard let src = conn.int64(at: 1), let dst = conn.int64(at: 2) else { continue }
                    srcID = ctx.validateFbxID(UInt64(bitPattern: src))
                    dstID = ctx.validateFbxID(UInt64(bitPattern: dst))
                case "OP":
                    guard let src = conn.int64(at: 1), let dst = conn.int64(at: 2) else { continue }
                    srcID = ctx.validateFbxID(UInt64(bitPattern: src))
                    dstID = ctx.validateFbxID(UInt64(bitPattern: dst))
                    dstProp = conn.string(at: 3) ?? ""
                case "PO":
                    guard let src = conn.int64(at: 1), let dst = conn.int64(at: 3) else { continue }
                    srcID = ctx.validateFbxID(UInt64(bitPattern: src))
                    srcProp = conn.string(at: 2) ?? ""
                    dstID = ctx.validateFbxID(UInt64(bitPattern: dst))
                case "PP":
                    guard let src = conn.int64(at: 1), let dst = conn.int64(at: 3) else { continue }
                    srcID = ctx.validateFbxID(UInt64(bitPattern: src))
                    srcProp = conn.string(at: 2) ?? ""
                    dstID = ctx.validateFbxID(UInt64(bitPattern: dst))
                    dstProp = conn.string(at: 4) ?? ""
                default:
                    continue
                }
            }

            ctx.tmpConnections.append(TmpConnection(srcID: srcID, srcProp: srcProp, dstID: dstID, dstProp: dstProp))
        }
    }

    // MARK: - Properties (ufbxi_read_properties, ufbx.c:11903)

    static func readProperties(_ ctx: LoadContext, _ parent: FBXDocNode) -> FBXProps {
        var version = 70
        var node = parent.child("Properties70")
        if node == nil {
            node = parent.child("Properties60")
            if node == nil { return FBXProps() }
            version = 60
        }

        var props = node!.children.map { readProperty($0, version: version) }
        props = stableSortProps(props)
        props = deduplicateProps(props)
        return FBXProps(props: props)
    }

    // ufbxi_read_property (ufbx.c:11798). Positional values:
    // name(S), type(C)[, subtype(C) v70], flags(S), int(L), reals(R×≤4), string(S).
    private static func readProperty(_ node: FBXDocNode, version: Int) -> FBXProp {
        var prop = FBXProp(name: node.string(at: 0) ?? "")
        let typeStr = node.string(at: 1)

        var valIx = 2
        var subtypeStr: String? = nil
        if version == 70 {
            subtypeStr = node.string(at: valIx)
            valIx += 1
        }

        var flags: FBXPropFlags = []
        if let flagsStr = node.string(at: valIx) {
            parseFlags(flagsStr, into: &flags)
        }
        valIx += 1 // advances regardless (ufbx: `val_ix++` in the condition).

        if let t = typeStr, let pt = propTypeTable[t] {
            prop.type = pt
        }
        if prop.type == .unknown, let st = subtypeStr, let pt = propTypeTable[st] {
            prop.type = pt
        }

        if let value = node.int64(at: valIx) {
            prop.valueInt = value
            flags.insert(.valueInt)
        }

        var reals: [Double] = [0, 0, 0, 0]
        var realCount = 0
        while realCount < 4 {
            guard let r = node.double(at: valIx + realCount) else { break }
            reals[realCount] = r
            realCount += 1
        }
        if realCount > 0 {
            prop.valueVec4 = FBXVec4(reals[0], reals[1], reals[2], reals[3])
            // VALUE_REAL << (n-1): REAL / VEC2 / VEC3 / VEC4 for 1..4 reals.
            flags.insert(FBXPropFlags(rawValue: FBXPropFlags.valueReal.rawValue << (realCount - 1)))
        }

        // Skip one slot forward if it isn't a string, so a mixed number+string
        // tuple (e.g. a Distance with a unit, an Enum with a value list) reads
        // its trailing string correctly (ufbx.c:11842-11848).
        if !isStringValue(node, valIx) {
            valIx += 1
        }

        if let str = node.string(at: valIx) {
            prop.valueString = str
            if !str.isEmpty {
                prop.valueBlob = node.rawString(at: valIx) ?? Data()
            }
            flags.insert(.valueStr)
        } else {
            prop.valueString = ""
        }

        // Rare: embedded BinaryData child (non-standard exporters).
        if !node.children.isEmpty {
            if let binary = node.child("BinaryData") {
                prop.valueBlob = readEmbeddedBlob(binary)
            }
            flags.insert(.valueBlob)
        }

        prop.flags = flags
        return prop
    }

    // ufbxi_read_property flags string (ufbx.c:11812-11822).
    private static func parseFlags(_ s: String, into flags: inout FBXPropFlags) {
        let bytes = Array(s.utf8)
        let zero = Int(UInt8(ascii: "0"))
        for i in bytes.indices {
            let next = i + 1 < bytes.count ? Int(bytes[i + 1]) : zero
            switch bytes[i] {
            case UInt8(ascii: "A"): flags.insert(.animatable)
            case UInt8(ascii: "U"): flags.insert(.userDefined)
            case UInt8(ascii: "H"): flags.insert(.hidden)
            case UInt8(ascii: "L"): flags.insert(FBXPropFlags(rawValue: UInt32((next - zero) & 0xf) << 4))
            case UInt8(ascii: "M"): flags.insert(FBXPropFlags(rawValue: UInt32((next - zero) & 0xf) << 8))
            default: break
            }
        }
    }

    private static func isStringValue(_ node: FBXDocNode, _ index: Int) -> Bool {
        guard node.values.indices.contains(index) else { return false }
        switch node.values[index] {
        case .string, .raw: return true
        default: return false
        }
    }

    // ufbxi_read_embedded_blob (ufbx.c:11764): concatenate the 'C' string parts.
    private static func readEmbeddedBlob(_ node: FBXDocNode) -> Data {
        if let raw = node.array?.asRawData { return raw }
        var data = Data()
        for value in node.values {
            if let bytes = value.asRawData { data.append(bytes) }
        }
        return data
    }

    // Stable sort by (name key, then raw name bytes) — Swift's sort isn't stable,
    // so tie-break on original index (DESIGN).
    private static func stableSortProps(_ props: [FBXProp]) -> [FBXProp] {
        props.enumerated().sorted { a, b in
            if FBXProp.less(a.element, b.element) { return true }
            if FBXProp.less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map { $0.element }
    }

    // ufbxi_deduplicate_properties (ufbx.c:11885): among a run of equal names,
    // keep the LAST (document-order) one.
    private static func deduplicateProps(_ props: [FBXProp]) -> [FBXProp] {
        guard props.count >= 2 else { return props }
        var result: [FBXProp] = []
        result.reserveCapacity(props.count)
        var i = 0
        while i < props.count {
            if i + 1 < props.count && props[i].name == props[i + 1].name {
                i += 1
            } else {
                result.append(props[i])
                i += 1
            }
        }
        return result
    }

    // MARK: - String helpers

    // ufbxi_split_type_and_name (ufbx.c:12271): first 2-byte separator splits the
    // packed pair; ASCII is `Type::Name`, binary is `Name\0\1Type` (order swaps).
    static func splitTypeAndName(_ combined: String, fromAscii: Bool) -> (type: String, name: String) {
        let bytes = Array(combined.utf8)
        let sep0: UInt8 = fromAscii ? 0x3A : 0x00 // ':' or NUL
        let sep1: UInt8 = fromAscii ? 0x3A : 0x01 // ':' or SOH

        var sepAt = -1
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == sep0 && bytes[i + 1] == sep1 { sepAt = i; break }
            i += 1
        }

        guard sepAt >= 0 else { return ("", combined) }
        let first = String(decoding: bytes[0..<sepAt], as: UTF8.self)
        let second = String(decoding: bytes[(sepAt + 2)...], as: UTF8.self)
        return fromAscii ? (first, second) : (second, first)
    }

    // ufbx: strip a leading "Fbx" only when something follows (length > 3), so a
    // bare "Fbx" survives (ufbx.c:12172, 14974).
    private static func stripFbxPrefix(_ s: String) -> String {
        guard s.utf8.count > 3, s.hasPrefix("Fbx") else { return s }
        return String(s.dropFirst(3))
    }

    // ufbxi_get_prop_type table (ufbx.c:11436).
    private static let propTypeTable: [String: FBXPropType] = [
        "Boolean": .boolean, "bool": .boolean, "Bool": .boolean,
        "Integer": .integer, "int": .integer, "enum": .integer, "Enum": .integer,
        "Visibility": .integer, "Visibility Inheritance": .integer, "KTime": .integer,
        "Number": .number, "double": .number, "Real": .number, "Float": .number, "Intensity": .number,
        "Vector": .vector, "Vector3D": .vector,
        "Color": .color, "ColorRGB": .color, "ColorAndAlpha": .colorWithAlpha,
        "String": .string, "KString": .string, "object": .string,
        "DateTime": .dateTime,
        "Lcl Translation": .translation, "Lcl Rotation": .rotation, "Lcl Scaling": .scaling,
        "Distance": .distance, "Compound": .compound, "Blob": .blob, "Reference": .reference,
    ]

    // ufbxi_node_prop_names (ufbx.c:11645): properties that stay on the node (not
    // the attribute) during pre-7000 synthetic-attribute prop splitting.
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
