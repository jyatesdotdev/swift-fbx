// Ports `ufbx_triangulate_face` / `ufbx_catch_triangulate_face` (ufbx.c:32391-
// 32468), its n-gon ear-clipping backend `ufbxi_triangulate_ngon` (ufbx.c:28471-
// 28688), and the Newell's-method branch of `ufbx_get_weighted_face_normal`
// (ufbx.c:32501-32532, only the `num_indices > 4` case is reachable from here)
// needed to build the triangulation's 2D projection basis. See
// docs/ufbx-notes/12-topology.md.
//
// The reference implementation accelerates the "is any reflex vertex inside
// this candidate ear triangle" query with a two-tier KD-tree (`ufbxi_kd_*`,
// ufbx.c:28274-28468) built purely to bound C recursion depth for adversarial/
// huge inputs. Per the notes' "Port guidance", that query is a pure existence
// test — "does any reflex corner (other than the candidate triangle's own 3
// corners) lie inside the projected triangle" — order of examination is
// irrelevant to the boolean result, so a linear scan over the (typically tiny)
// reflex-corner list gives an IDENTICAL answer to the KD-tree for every call,
// and therefore an identical sequence of ear choices / output triangle order.
// This is the one algorithmic simplification taken; everything else (quad
// split rule incl. winding-flip guard, reflex classification, ear-weight
// heuristic + tie-break order, splice bookkeeping, starvation fallback, output
// ordering) is a literal, order-preserving port.

import Foundation

extension FBXMesh {

    /// Mirrors `ufbx_catch_triangulate_face` (ufbx.c:32391-32468): triangulates
    /// `face` (a run in this mesh's corner arrays) into `indices`, growing it
    /// in place if it doesn't already hold at least `(face.numIndices - 2) * 3`
    /// `UInt32`s. Returns the number of triangles written (0 for a degenerate
    /// face with fewer than 3 corners — ufbx does not filter these at load
    /// time, see `FBXFace`). Written values are *mesh corner indices* (index
    /// into `vertexPosition.indices` / `vertexIndices` / etc, i.e. values in
    /// `face.indexBegin ..< face.indexBegin + face.numIndices`), not vertex
    /// ids — exactly like ufbx.
    ///
    /// Deviation from ufbx: the C entry point requires the caller to
    /// preallocate an exact-size buffer that it then also reuses internally as
    /// ear-clipping/KD scratch space (with an intricate "last 4 triangles"
    /// staging buffer to avoid the output write clobbering not-yet-read
    /// scratch in that shared buffer, ufbx.c:28660-28687). This port grows
    /// `indices` instead of requiring exact preallocation and uses separate
    /// internal scratch storage, sidestepping that aliasing hazard entirely;
    /// output triangle identity/order is unaffected and still matches ufbx.
    @discardableResult
    public func triangulateFace(_ face: FBXFace, into indices: inout [UInt32]) -> Int {
        let n = Int(face.numIndices)
        guard n >= 3 else { return 0 }

        let required = (n - 2) * 3
        if indices.count < required {
            indices.append(contentsOf: repeatElement(0, count: required - indices.count))
        }

        if n == 3 {
            // ufbx.c:32401-32406: fast path, corners copied verbatim.
            indices[0] = face.indexBegin + 0
            indices[1] = face.indexBegin + 1
            indices[2] = face.indexBegin + 2
            return 1
        }

        if n == 4 {
            triangulateQuad(face, into: &indices)
            return 2
        }

        return triangulateNgon(face, into: &indices)
    }

    /// Convenience wrapper returning a freshly-allocated triangle-index buffer
    /// (not part of ufbx's API shape, added for Swift ergonomics).
    public func triangulateFace(_ face: FBXFace) -> [UInt32] {
        var indices: [UInt32] = []
        _ = triangulateFace(face, into: &indices)
        return indices
    }

    @inline(__always)
    private func cornerPosition(_ corner: UInt32) -> FBXVec3 {
        let posIndex = vertexPosition.indices[Int(corner)]
        return vertexPosition.values[Int(posIndex)]
    }

    // MARK: - Quad split (ufbx.c:32407-32449)

    private func triangulateQuad(_ face: FBXFace, into indices: inout [UInt32]) {
        let i0 = face.indexBegin + 0
        let i1 = face.indexBegin + 1
        let i2 = face.indexBegin + 2
        let i3 = face.indexBegin + 3
        let v0 = cornerPosition(i0)
        let v1 = cornerPosition(i1)
        let v2 = cornerPosition(i2)
        let v3 = cornerPosition(i3)

        // Diagonal vectors for the two possible splits.
        let a = v2 - v0
        let b = v3 - v1

        // Triangle normals at the "wrong" corner for each candidate split.
        let na1 = a.cross(v1 - v0).normalized()
        let na3 = a.cross(v0 - v3).normalized()
        let nb0 = b.cross(v1 - v0).normalized()
        let nb2 = b.cross(v2 - v1).normalized()

        let dotAA = a.dot(a)
        let dotBB = b.dot(b)
        let dotNA = na1.dot(na3)
        let dotNB = nb0.dot(nb2)

        // Default: split along the shorter diagonal.
        var splitA = dotAA <= dotBB

        // ufbx: winding-flip guard (ufbx.c:32434-32436). A non-planar/bowtie
        // quad can make the naive "shorter diagonal" choice produce two
        // triangles whose normals disagree (that diagonal lies outside the
        // quad); when either candidate split is internally inconsistent like
        // that, override to whichever diagonal keeps agreeing triangle
        // normals instead.
        if dotNA < 0.0 || dotNB < 0.0 {
            splitA = dotNA >= dotNB
        }

        if splitA {
            indices[0] = i0; indices[1] = i1; indices[2] = i2
            indices[3] = i2; indices[4] = i3; indices[5] = i0
        } else {
            indices[0] = i1; indices[1] = i2; indices[2] = i3
            indices[3] = i3; indices[4] = i0; indices[5] = i1
        }
    }

    // MARK: - N-gon ear clipping (ufbx.c:28471-28688)

    private func triangulateNgon(_ face: FBXFace, into indices: inout [UInt32]) -> Int {
        let n = Int(face.numIndices)
        let begin = face.indexBegin

        // Projection basis (ufbx.c:28494-28517): area-weighted (Newell's
        // method) face normal — only that branch of
        // `ufbx_get_weighted_face_normal` is reachable here since n > 4 always
        // holds for the ngon path — normalized, degenerate (near-zero length,
        // e.g. all points colinear/coincident) falling back to +X so
        // triangulation always produces *some* valid-index result rather than
        // failing.
        var normal = FBXVec3.zero
        for i in 0..<n {
            let next = i + 1 < n ? i + 1 : 0
            let a = cornerPosition(begin + UInt32(i))
            let b = cornerPosition(begin + UInt32(next))
            normal = FBXVec3(
                normal.x + (a.y - b.y) * (a.z + b.z),
                normal.y + (a.z - b.z) * (a.x + b.x),
                normal.z + (a.x - b.x) * (a.y + b.y)
            )
        }
        let len = normal.length
        if len > fbxEpsilon {
            normal = normal * (1.0 / len)
        } else {
            normal = FBXVec3(1, 0, 0)
        }

        // Seed axis (+X unless the normal is close to +X, then +Y), Gram-
        // Schmidt'd against the normal to build an orthonormal in-plane basis.
        let seedAxis: FBXVec3 = normal.x * normal.x < 0.5 ? FBXVec3(1, 0, 0) : FBXVec3(0, 1, 0)
        let axis0 = seedAxis.cross(normal).normalized()
        let axis1 = normal.cross(axis0).normalized()

        var points = [FBXVec2](repeating: .zero, count: n)
        for i in 0..<n {
            let p = cornerPosition(begin + UInt32(i))
            points[i] = FBXVec2(axis0.dot(p), axis1.dot(p))
        }

        // Reflex corners (ufbx.c:28524-28540): corners that are NOT strictly
        // convex (`orient2d(prev, cur, next) <= 0`) given the polygon's
        // winding in this basis — exactly the vertices that could invalidate
        // a candidate ear.
        var reflex: [Int] = []
        reflex.reserveCapacity(n)
        do {
            var a = points[n - 1]
            var b = points[0]
            for i in 0..<n {
                let next = i + 1 < n ? i + 1 : 0
                let c = points[next]
                if Self.orient2d(a, b, c) <= 0.0 {
                    reflex.append(i)
                }
                a = b
                b = c
            }
        }

        // Doubly-linked ring over corners. `clip[corner]` records the
        // (prev, corner, next) triple a corner had at the moment it was
        // clipped as an ear tip, mirroring ufbx's "mark with the high bit,
        // splice neighbors" scheme (ufbx.c:28549-28656) without the in-place-
        // buffer-aliasing trick (irrelevant given separate Swift storage).
        var prevOf = [Int](repeating: 0, count: n)
        var nextOf = [Int](repeating: 0, count: n)
        for i in 0..<n {
            prevOf[i] = i > 0 ? i - 1 : n - 1
            nextOf[i] = i + 1 < n ? i + 1 : 0
        }
        var clip = [(Int, Int, Int)?](repeating: nil, count: n)

        var indicesLeft = n
        var pointIndices = [0, 1, 2, 3]
        var numSteps = 0

        while indicesLeft > 3 {
            let p0 = points[pointIndices[0]]
            let p1 = points[pointIndices[1]]
            let p2 = points[pointIndices[2]]
            let p3 = points[pointIndices[3]]

            let weight0 = Self.ngonTriWeight(p0, p1, p2)
            let weight1 = Self.ngonTriWeight(p1, p2, p3)

            // Prefer whichever of the two candidate ears is better-shaped
            // (higher weight), tried first; the other is tried only if the
            // first is blocked by a reflex vertex.
            let firstSide = weight1 > weight0 ? 1 : 0
            var clipped = false

            for sideIx in 0..<2 {
                let side = sideIx ^ firstSide
                let weight = side == 0 ? weight0 : weight1
                // Both sides were precomputed; if the better-weighted one is
                // invalid (<0, non-convex) the other is too, so stop trying.
                if !(weight >= 0.0) { break }

                let triPoints = side == 0 ? (p0, p1, p2) : (p1, p2, p3)
                let ia = pointIndices[side + 0]
                let ib = pointIndices[side + 1]
                let ic = pointIndices[side + 2]

                if !Self.reflexInsideTriangle(reflex: reflex, points: points, triPoints: triPoints, triIndices: (ia, ib, ic)) {
                    clip[ib] = (ia, ib, ic)

                    prevOf[ic] = ia
                    nextOf[ia] = ic

                    indicesLeft -= 1
                    // ufbx: resetting the step counter on every successful
                    // clip is an acknowledged (ufbx.c:28604) potential O(n^2)
                    // worst case, kept as-is for output parity.
                    numSteps = 0

                    if side == 1 {
                        pointIndices[2] = pointIndices[3]
                        pointIndices[3] = nextOf[pointIndices[3]]
                    } else {
                        pointIndices[1] = pointIndices[0]
                        pointIndices[0] = prevOf[pointIndices[0]]
                    }

                    clipped = true
                    break
                }
            }
            if clipped { continue }

            pointIndices[0] = pointIndices[1]
            pointIndices[1] = pointIndices[2]
            pointIndices[2] = pointIndices[3]
            pointIndices[3] = nextOf[pointIndices[3]]
            numSteps += 1

            // ufbx: ear-clip starvation guard (ufbx.c:28632) — a self-
            // intersecting/degenerate ngon can walk the whole ring without
            // finding a valid ear; bail to the unconditional fallback below
            // rather than loop forever.
            if numSteps >= n * 2 { break }
        }

        // Fallback (ufbx.c:28634-28655): guarantees termination and full
        // coverage for pathological/garbage input by cutting whatever corner
        // is current with zero further geometric validity checks.
        var ix = pointIndices[1]
        while indicesLeft > 3 {
            let prev = prevOf[ix]
            let next = nextOf[ix]
            clip[ix] = (prev, ix, next)
            prevOf[next] = prev
            nextOf[prev] = next
            indicesLeft -= 1
            ix = next
        }
        // The single remaining triangle.
        clip[ix] = (prevOf[ix], ix, nextOf[ix])

        // Expand adjacency to the final triangle list, walking corners in
        // ascending original-index order (ufbx.c:28657-28687 — the buffered
        // `last_triangles` staging there exists only to handle in-place-
        // buffer aliasing in C and has no Swift equivalent).
        var triangleCount = 0
        for corner in 0..<n {
            guard let (ia, ib, ic) = clip[corner] else { continue }
            let base = triangleCount * 3
            indices[base + 0] = begin + UInt32(ia)
            indices[base + 1] = begin + UInt32(ib)
            indices[base + 2] = begin + UInt32(ic)
            triangleCount += 1
        }

        return triangleCount
    }

    // MARK: - Geometry helpers (ufbx.c:28284-28287, 28474-28487, 28289-28406)

    @inline(__always)
    private static func orient2d(_ a: FBXVec2, _ b: FBXVec2, _ c: FBXVec2) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    @inline(__always)
    private static func distsq2(_ a: FBXVec2, _ b: FBXVec2) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// Matches `ufbxi_ngon_tri_weight` (ufbx.c:28474-28487): `-1` (reject) for
    /// a non-convex/degenerate (signed area `<= 0`) candidate triangle, else
    /// `2 - max(ab,bc,ca)` where each of `ab/bc/ca` is a law-of-cosines-
    /// derived edge-angle proxy for one vertex — prefers well-shaped (near-
    /// equilateral) ears over slivers — floored at `UFBX_EPSILON` so it's
    /// never non-positive for a valid convex corner.
    private static func ngonTriWeight(_ p0: FBXVec2, _ p1: FBXVec2, _ p2: FBXVec2) -> Double {
        let orient = orient2d(p0, p1, p2)
        if orient <= 0.0 { return -1.0 }

        let a = distsq2(p0, p1)
        let b = distsq2(p1, p2)
        let c = distsq2(p2, p0)
        let ab = (a + b - c) / (4.0 * a * b).squareRoot()
        let bc = (b + c - a) / (4.0 * b * c).squareRoot()
        let ca = (c + a - b) / (4.0 * c * a).squareRoot()
        return Swift.max(fbxEpsilon, 2.0 - Swift.max(Swift.max(ab, bc), ca))
    }

    /// Matches `ufbxi_kd_check` + `ufbxi_kd_check_point` (ufbx.c:28289-28406):
    /// "is any reflex corner (other than the candidate triangle's own 3
    /// corners) contained in the triangle" via 3 same-sign `orient2d` checks
    /// (standard barycentric-sign point-in-triangle test, boundary
    /// inclusive). Ported as a direct linear scan over `reflex` rather than
    /// the KD-tree (see file header) — identical boolean result for every
    /// call, since it's a pure existence query.
    private static func reflexInsideTriangle(
        reflex: [Int], points: [FBXVec2],
        triPoints: (FBXVec2, FBXVec2, FBXVec2), triIndices: (Int, Int, Int)
    ) -> Bool {
        for r in reflex {
            if r == triIndices.0 || r == triIndices.1 || r == triIndices.2 { continue }
            let p = points[r]
            let u = orient2d(p, triPoints.0, triPoints.1)
            let v = orient2d(p, triPoints.1, triPoints.2)
            let w = orient2d(p, triPoints.2, triPoints.0)
            if u <= 0.0 && v <= 0.0 && w <= 0.0 { return true }
            if u >= 0.0 && v >= 0.0 && w >= 0.0 { return true }
        }
        return false
    }
}
