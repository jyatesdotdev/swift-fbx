// Pre-7000 "Take" based animation reader — port of `ufbxi_read_take*`
// (ufbx.c:15312-15764). Called for EVERY version after objects + connections:
//   - version >= 7000: Takes are legacy vestiges; we only harvest
//     LocalTime/ReferenceTime onto the already-existing (name-matched)
//     anim stack as a time-range fallback when it has no props of its own.
//   - version <  7000 (incl. 6100): each Take becomes a synthetic anim
//     stack + "BaseLayer" anim layer, and every Model's Channel tree is
//     decoded into synthetic anim values + curves wired by tmpConnections.
//
// The pre-6000 flat legacy object graph (`ufbxi_read_legacy_*`) is OUT of
// scope here (handled elsewhere); this file only ports the Take machinery,
// which is shared by all >= 3000 files.

import Foundation

enum TakesReader {

    // ufbx: for all files < 8000 the KTime unit is 46186158000 ticks/second
    // (ufbx.c:12021-12029, 16439). Takes are only *built* for version < 7000,
    // so this constant is always correct here.
    private static let ktimeSecDouble: Double = 46_186_158_000.0

    // MARK: - Entry point

    static func read(_ ctx: LoadContext) throws {
        guard let takes = ctx.doc.root.child("Takes") else { return }

        var stackByName: [String: FBXAnimStack] = [:]
        if ctx.version >= 7000 {
            // First inserted wins, mirroring ufbxi_map_find on anim_stack_map.
            for stack in ctx.scene.animStacks where stackByName[stack.name] == nil {
                stackByName[stack.name] = stack
            }
        }

        for take in takes.children where take.name == "Take" {
            try readTake(ctx, take, stackByName: stackByName)
        }
    }

    // MARK: - ufbxi_read_take (ufbx.c:15688-15749)

    private static func readTake(_ ctx: LoadContext, _ node: FBXDocNode, stackByName: [String: FBXAnimStack]) throws {
        // LocalTime / ReferenceTime -> up to 4 synthetic integer props.
        // Natural emit order (LocalStart, LocalStop, ReferenceStart,
        // ReferenceStop) is already sorted by FBXProp.less, so the props
        // array is directly usable by FBXProps.find.
        var props: [FBXProp] = []
        if let lt = node.child("LocalTime"), let start = lt.int64(at: 0), let stop = lt.int64(at: 1) {
            props.append(syntheticIntProp("LocalStart", start))
            props.append(syntheticIntProp("LocalStop", stop))
        }
        if let rt = node.child("ReferenceTime"), let start = rt.int64(at: 0), let stop = rt.int64(at: 1) {
            props.append(syntheticIntProp("ReferenceStart", start))
            props.append(syntheticIntProp("ReferenceStop", stop))
        }

        guard let name = node.string(at: 0) else {
            throw FBXError(.corruptData, "Take missing name")
        }

        // ufbx: post-7000 files may still carry Take blocks purely as a
        // time-range fallback for the real anim stack of the same name
        // (ufbx.c:15709-15723). Only applied if that stack has no props yet.
        if ctx.version >= 7000 {
            if let stack = stackByName[name], stack.props.props.isEmpty {
                stack.props.props = props
            }
            return
        }

        // Pre-7000: treat the Take as a first-class anim stack + BaseLayer.
        let stackID = ctx.nextSyntheticID()
        let stack = ctx.makeElement(.animStack, name: name, fbxID: stackID) as! FBXAnimStack
        stack.props.props = props

        let layerID = ctx.nextSyntheticID()
        _ = ctx.makeElement(.animLayer, name: "BaseLayer", fbxID: layerID) as! FBXAnimLayer

        // layer -> stack (OO)
        ctx.tmpConnections.append(TmpConnection(srcID: layerID, srcProp: "", dstID: stackID, dstProp: ""))

        for child in node.children where child.name == "Model" {
            try readTakeObject(ctx, child, layerFbxID: layerID)
        }
    }

    // MARK: - ufbxi_read_take_object (ufbx.c:15666-15686)

    private static func readTakeObject(_ ctx: LoadContext, _ node: FBXDocNode, layerFbxID: UInt64) throws {
        // Pre-7000 objects are identified by their interned Type::Name pair
        // (value index 0, format 'c'). syntheticID(for:) returns the SAME id
        // the object reader assigned that element, so the value->target
        // connection resolves.
        guard let typeAndName = node.string(at: 0) else {
            throw FBXError(.corruptData, "Take object missing Type::Name")
        }
        let targetFbxID = ctx.syntheticID(for: typeAndName)

        for child in node.children where child.name == "Channel" {
            guard let name = child.string(at: 0) else { continue }
            try readTakePropChannel(ctx, child, targetFbxID: targetFbxID, layerFbxID: layerFbxID, name: name)
        }
    }

    // MARK: - ufbxi_read_take_prop_channel (ufbx.c:15587-15664)

    private static func readTakePropChannel(
        _ ctx: LoadContext, _ node: FBXDocNode,
        targetFbxID: UInt64, layerFbxID: UInt64, name rawName: String
    ) throws {
        var name = rawName

        if name == "Transform" {
            // Pre-7000 nests the whole local transform:
            //   Transform { Channel:"T"{Channel:"X"..} Channel:"R".. Channel:"S".. }
            // Flatten each T/R/S sub-channel into a top-level Lcl-* channel.
            for child in node.children where child.name == "Channel" {
                guard let old = child.string(at: 0) else {
                    throw FBXError(.corruptData, "Transform channel missing component name")
                }
                let newName: String
                switch old {
                case "T": newName = "Lcl Translation"
                case "R": newName = "Lcl Rotation"
                case "S": newName = "Lcl Scaling"
                default: continue
                }
                // Recurses once; the recursion cannot re-enter this branch
                // because the new name is never "Transform".
                try readTakePropChannel(ctx, child, targetFbxID: targetFbxID, layerFbxID: layerFbxID, name: newName)
            }
            return
        }

        // Pre-6000 blend-shape channels carry a " (Shape)" suffix — strip it.
        if ctx.version < 6000 {
            let suffix = " (Shape)"
            if name.count > suffix.count && name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
        }

        // Gather 1-3 channel nodes that actually hold a Key or Default.
        var channelNodes: [FBXDocNode] = []
        var channelNames: [String] = []

        if node.child("Key") != nil || node.child("Default") != nil {
            // Single scalar curve on this node itself.
            channelNodes.append(node)
            channelNames.append(name)
        } else {
            for child in node.children where child.name == "Channel" {
                if child.child("Key") == nil && child.child("Default") == nil { continue }
                guard let cName = child.string(at: 0) else { continue }
                channelNodes.append(child)
                channelNames.append(cName)
                if channelNodes.count == 3 { break }
            }
        }

        // No valid channels found — not an error (ufbx.c:15649).
        if channelNodes.isEmpty { return }

        let valueID = ctx.nextSyntheticID()
        let value = ctx.makeElement(.animValue, name: name, fbxID: valueID) as! FBXAnimValue

        // value -> layer (OO), value -> target property (OP).
        ctx.tmpConnections.append(TmpConnection(srcID: valueID, srcProp: "", dstID: layerFbxID, dstProp: ""))
        ctx.tmpConnections.append(TmpConnection(srcID: valueID, srcProp: "", dstID: targetFbxID, dstProp: name))

        var defaults = FBXVec3.zero
        for i in 0..<channelNodes.count {
            let def = try readTakeAnimChannel(ctx, channelNodes[i], valueFbxID: valueID, name: channelNames[i])
            switch i {
            case 0: defaults.x = def
            case 1: defaults.y = def
            default: defaults.z = def
            }
        }
        value.defaultValue = defaults
    }

    // MARK: - ufbxi_read_take_anim_channel (ufbx.c:15323-15583)

    /// Decodes one Channel's `Key:` stream into a synthetic anim curve wired to
    /// `valueFbxID`. Returns the channel's `Default` value (0 if absent). No
    /// curve is created if there is no `Key` array.
    private static func readTakeAnimChannel(
        _ ctx: LoadContext, _ node: FBXDocNode, valueFbxID: UInt64, name: String
    ) throws -> Double {
        let defaultValue = node.child("Default")?.double(at: 0) ?? 0.0

        // Early return with only a default if there's no key array.
        guard let data = node.child("Key")?.asDoubleArray() else {
            return defaultValue
        }

        let curveID = ctx.nextSyntheticID()
        let curve = ctx.makeElement(.animCurve, name: name, fbxID: curveID) as! FBXAnimCurve

        // curve -> value (OP), dst prop = curve name (component letter or prop).
        ctx.tmpConnections.append(TmpConnection(srcID: curveID, srcProp: "", dstID: valueFbxID, dstProp: name))

        curve.preExtrapolation = readExtrapolation(node.child("Pre_Extrapolation"))
        curve.postExtrapolation = readExtrapolation(node.child("Post_Extrapolation"))

        // KeyVer selects among ad-hoc slope/weight encodings (ufbx.c:15342-15352).
        var keyVer = Int(node.child("KeyVer")?.int32(at: 0) ?? 0)
        if keyVer <= 0 {
            if ctx.version < 5000 { keyVer = 4003 }
            else if ctx.version < 6000 { keyVer = 4004 }
            else { keyVer = 4005 }
        }

        // ufbx reads KeyCount with the "Z" value format (ufbx.c:7743), which
        // rejects a negative count (`ufbxi_find_val1` returns 0 → `ufbxi_check`
        // fails → corrupt). Mirror that: a negative KeyCount is corrupt, not a
        // silent empty curve — and it also guards the `0..<numKeys` loop below
        // from trapping ("Range requires lowerBound <= upperBound") on a
        // byte-flipped negative count.
        guard let numKeys64 = node.child("KeyCount")?.int64(at: 0), numKeys64 >= 0 else {
            throw FBXError(.corruptData, "Take channel missing or negative KeyCount")
        }
        let numKeys = Int(numKeys64)

        var keys: [FBXKeyframe] = []
        // `numKeys` is an untrusted scalar (`KeyCount`); the read loop below is
        // bounded by `need()` against `data`, but the pre-allocation is not — a
        // huge `KeyCount` would reserve gigabytes (OOM/trap) before the loop can
        // reject it. Each key consumes at least three doubles from `data`, so
        // `data.count` is a safe upper bound for the reservation.
        keys.reserveCapacity(Swift.min(Swift.max(numKeys, 0), data.count))

        var slopeLeft: Float = 0.0
        var weightLeft: Float = 0.333333

        var nextTime = 0.0
        var nextValue = 0.0
        var prevTime = 0.0

        var minValue = 0.0
        var maxValue = 0.0

        // Flat heterogeneous cursor over the key stream (ufbx.c:15369).
        var p = 0
        func need(_ n: Int) throws {
            if p + n > data.count { throw FBXError(.corruptData, "Take key stream truncated") }
        }

        if numKeys > 0 {
            try need(2)
            nextTime = data[0] / ktimeSecDouble
            nextValue = data[1]
        }

        for i in 0..<numKeys {
            if i == 0 {
                minValue = nextValue
                maxValue = nextValue
            } else {
                minValue = min(minValue, nextValue)
                maxValue = max(maxValue, nextValue)
            }

            // First three: time, value, mode-char.
            try need(3)
            var key = FBXKeyframe()
            key.time = nextTime
            key.value = nextValue
            let mode = doubleToChar(data[p + 2])
            p += 3

            var slopeRight: Float = 0.0
            var weightRight: Float = 0.333333
            var nextSlopeLeft: Float = 0.0
            var nextWeightLeft: Float = 0.333333
            var autoSlope = false

            if mode == UInt8(ascii: "U") {
                key.interpolation = .cubic

                try need(1)
                let slopeMode = doubleToChar(data[p]); p += 1

                var numWeights = 1
                switch slopeMode {
                case UInt8(ascii: "s"), UInt8(ascii: "b"):
                    // Explicit two-sided slopes.
                    try need(2)
                    slopeRight = Float(data[p])
                    nextSlopeLeft = Float(data[p + 1])
                    p += 2
                    if keyVer == 4003 { numWeights = 0 }
                case UInt8(ascii: "a"):
                    autoSlope = true
                    if keyVer <= 4004 { numWeights = 0 }
                case UInt8(ascii: "p"):
                    autoSlope = true
                    try need(2); p += 2
                    numWeights = keyVer <= 4004 ? 1 : 2
                case UInt8(ascii: "q"):
                    autoSlope = true
                    try need(2); p += 2
                    numWeights = keyVer <= 4004 ? 1 : 2
                case UInt8(ascii: "t"):
                    autoSlope = true
                    try need(3); p += 3
                    numWeights = 0
                case UInt8(ascii: "d"):
                    autoSlope = true
                    try need(1); p += 1
                default:
                    throw FBXError(.corruptData, "Unknown slope mode")
                }

                while numWeights > 0 {
                    try need(1)
                    let weightMode = doubleToChar(data[p]); p += 1
                    switch weightMode {
                    case UInt8(ascii: "n"):
                        break // automatic weights
                    case UInt8(ascii: "a"):
                        try need(2)
                        weightRight = Float(data[p])
                        nextWeightLeft = Float(data[p + 1])
                        p += 2
                    case UInt8(ascii: "l"):
                        try need(1)
                        nextWeightLeft = Float(data[p]); p += 1
                    case UInt8(ascii: "r"):
                        try need(1)
                        weightRight = Float(data[p]); p += 1
                    case UInt8(ascii: "c"):
                        break // assumed automatic weights
                    default:
                        throw FBXError(.corruptData, "Unknown weight mode")
                    }
                    numWeights -= 1
                }
            } else if mode == UInt8(ascii: "L") {
                key.interpolation = .linear
            } else if mode == UInt8(ascii: "C") {
                if keyVer >= 4004 {
                    try need(1)
                    key.interpolation = doubleToChar(data[p]) == UInt8(ascii: "n") ? .constantNext : .constantPrev
                    p += 1
                } else {
                    key.interpolation = .constantPrev
                }
            } else {
                throw FBXError(.corruptData, "Unknown key mode")
            }

            // Prefetch next key's time/value (not advancing the cursor).
            if i + 1 < numKeys {
                try need(2)
                nextTime = data[p] / ktimeSecDouble
                nextValue = data[p + 1]
            }

            if autoSlope {
                if i > 0 {
                    let s = solveAutoTangent(
                        prevTime: prevTime, time: key.time, nextTime: nextTime,
                        prevValue: keys[i - 1].value, value: key.value, nextValue: nextValue,
                        weightLeft: weightLeft, weightRight: weightRight,
                        autoBias: 0.0, flags: keyClampProgressive | keyTimeIndependent)
                    slopeLeft = s
                    slopeRight = s
                } else {
                    slopeLeft = 0.0
                    slopeRight = 0.0
                }
            }

            // Linear keys always use a straight secant slope.
            if key.interpolation == .linear {
                if nextTime > key.time {
                    let slope = (nextValue - key.value) / (nextTime - key.time)
                    slopeRight = Float(slope)
                    nextSlopeLeft = Float(slope)
                } else {
                    slopeRight = 0.0
                    nextSlopeLeft = 0.0
                }
            }

            // (slope, weight) -> Bezier tangent deltas.
            if key.time > prevTime {
                let delta = key.time - prevTime
                let ldx = Float(Double(weightLeft) * delta)
                key.left = FBXTangent(dx: Double(ldx), dy: Double(ldx * slopeLeft))
            } else {
                key.left = FBXTangent(dx: 0, dy: 0)
            }

            if nextTime > key.time {
                let delta = nextTime - key.time
                let rdx = Float(Double(weightRight) * delta)
                key.right = FBXTangent(dx: Double(rdx), dy: Double(rdx * slopeRight))
            } else {
                key.right = FBXTangent(dx: 0, dy: 0)
            }

            keys.append(key)

            slopeLeft = nextSlopeLeft
            weightLeft = nextWeightLeft
            prevTime = key.time
        }

        // The per-mode byte counts must consume the stream exactly.
        guard p == data.count else {
            throw FBXError(.corruptData, "Take key stream not fully consumed")
        }

        curve.keyframes = keys
        curve.minValue = minValue
        curve.maxValue = maxValue

        return defaultValue
    }

    // MARK: - ufbxi_read_extrapolation (ufbx.c:14227-14255)

    private static func readExtrapolation(_ child: FBXDocNode?) -> FBXExtrapolation {
        var mode: FBXExtrapolationMode = .constant
        var repeatCount: Int32 = -1

        if let child, let modeCh = child.child("Type")?.int32(at: 0) {
            switch modeCh {
            case Int32(UInt8(ascii: "A")): mode = .repeatRelative
            case Int32(UInt8(ascii: "C")): mode = .constant
            case Int32(UInt8(ascii: "K")): mode = .slope
            case Int32(UInt8(ascii: "M")): mode = .mirror
            case Int32(UInt8(ascii: "R")): mode = .repeat
            default: break // unknown -> leave CONSTANT
            }
            if let rep = child.child("Repetition")?.int32(at: 0) {
                repeatCount = rep < 0 ? -1 : rep
            }
        }

        return FBXExtrapolation(mode: mode, repeatCount: repeatCount)
    }

    // MARK: - ufbxi_solve_auto_tangent (ufbx.c:14106-14167)

    // Key flags actually used by the legacy Take path (ufbx.c:14088-14104).
    private static let keyClamp: UInt32 = 0x1000
    private static let keyTimeIndependent: UInt32 = 0x2000
    private static let keyClampProgressive: UInt32 = 0x4000

    private static func solveAutoTangent(
        prevTime: Double, time: Double, nextTime: Double,
        prevValue: Double, value: Double, nextValue: Double,
        weightLeft: Float, weightRight: Float, autoBias: Float, flags: UInt32,
        keyClampThreshold: Double = 0.0
    ) -> Float {
        // Clamp to zero near either neighbouring key (not set for the Take path).
        if flags & keyClamp != 0 {
            if min(abs(prevValue - value), abs(nextValue - value)) <= keyClampThreshold {
                return 0.0
            }
        }

        var slope = (nextValue - prevValue) / (nextTime - prevTime)

        if flags & keyTimeIndependent == 0 {
            let slopeLeft = (value - prevValue) / (time - prevTime)
            let slopeRight = (nextValue - value) / (nextTime - time)
            let delta = (time - prevTime) / (nextTime - prevTime)
            slope = slope * 0.5 + (slopeLeft * (1.0 - delta) + slopeRight * delta) * 0.5

            let biasWeight = abs(Double(autoBias)) / 100.0
            if biasWeight > 0.0001 {
                let biasTarget = autoBias > 0.0 ? slopeRight : slopeLeft
                let biasDelta = biasTarget - slope
                slope = slope * (1.0 - biasWeight) + biasTarget * biasWeight

                let absBiasWeight = biasWeight - 5.0
                if absBiasWeight > 0.0 {
                    var biasSign = abs(biasDelta) > 0.00001 ? biasDelta : Double(autoBias)
                    biasSign = biasSign > 0.0 ? 1.0 : -1.0
                    slope += absBiasWeight * absBiasWeight * biasSign * 40.0
                }
            }
        }

        if flags & keyClampProgressive != 0 {
            let slopeSign = slope >= 0.0 ? 1.0 : -1.0
            var absSlope = slopeSign * slope

            let rangeLeft = Double(weightLeft) * (time - prevTime)
            let rangeRight = Double(weightRight) * (nextTime - time)
            var maxLeft = rangeLeft > 0.0 ? slopeSign * (value - prevValue) / rangeLeft : 0.0
            var maxRight = rangeRight > 0.0 ? slopeSign * (nextValue - value) / rangeRight : 0.0

            if !(maxLeft > 0.0) { maxLeft = 0.0 }
            if !(maxRight > 0.0) { maxRight = 0.0 }

            if absSlope > maxLeft { absSlope = maxLeft }
            if absSlope > maxRight { absSlope = maxRight }

            slope = slopeSign * absSlope
        }

        return Float(slope)
    }

    // MARK: - Helpers

    // ufbx: ufbxi_double_to_char (ufbx.c:15314-15321) — a mode/weight byte was
    // packed as a tiny int and cast to double; recover it, 0 if out of range.
    private static func doubleToChar(_ v: Double) -> UInt8 {
        if v >= 0.0 && v <= 127.0 { return UInt8(Int(v)) }
        return 0
    }

    // ufbx: ufbxi_init_synthetic_int_prop (ufbx.c:12451-12463).
    private static func syntheticIntProp(_ name: String, _ value: Int64) -> FBXProp {
        FBXProp(
            name: name,
            type: .integer,
            flags: [.synthetic, .valueReal, .valueInt],
            valueInt: value,
            valueVec4: FBXVec4(Double(value), 0, 0, 0))
    }
}
