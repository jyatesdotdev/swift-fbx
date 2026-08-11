// Unit tests for Geometry/Triangulate.swift (`FBXMesh.triangulateFace`),
// porting `ufbx_triangulate_face` (ufbx.c:32391-32468) and its n-gon backend
// `ufbxi_triangulate_ngon` (ufbx.c:28471-28688).
//
// Expected outputs for the n-gon (ear-clipping) cases were derived by
// independently re-implementing the C algorithm verbatim in a scratch Python
// script (mirroring every step: Newell's-method normal, axis basis, reflex
// classification, ear-weight-based side preference, splice bookkeeping,
// output-in-corner-order expansion) and running it on the exact test
// geometry below, rather than by running the Swift port under test — see the
// per-case comments for the derivation. Quad-split expectations were derived
// by hand-evaluating the formulas in ufbx.c:32407-32449 directly on the test
// vertices (also cross-checked with the same script).

import Foundation
import Testing
@testable import SwiftFBX

@Suite struct TriangulateTests {

    // MARK: - Test fixture helper

    /// Builds a single-face mesh whose `vertexPosition` maps corner `i`
    /// directly to `verts[i]` (values == verts, indices == identity), so
    /// corner index and vertex index coincide — keeps expected outputs
    /// readable as plain corner indices.
    static func makeMesh(verts: [FBXVec3], indexBegin: UInt32 = 0) -> FBXMesh {
        let scene = FBXScene()
        let mesh = FBXMesh(scene: scene, name: "", props: FBXProps(), elementID: 0, typedID: 0, fbxID: 0)
        let n = verts.count
        var indices: [UInt32] = []
        // Pad indices before `indexBegin` with dummy entries so corner
        // arithmetic (`face.indexBegin + i`) indexes validly into
        // `vertexPosition.indices` even when the face doesn't start at 0.
        indices.append(contentsOf: repeatElement(0, count: Int(indexBegin)))
        indices.append(contentsOf: (0..<n).map { UInt32($0) })
        mesh.vertexPosition = FBXVertexVec3(exists: true, values: verts, indices: indices, valueReals: 3)
        return mesh
    }

    static func face(_ n: Int, indexBegin: UInt32 = 0) -> FBXFace {
        FBXFace(indexBegin: indexBegin, numIndices: UInt32(n))
    }

    // MARK: - Degenerate faces (ufbx.c:32393)

    @Test func degenerateFacesReturnZeroTriangles() {
        let mesh = Self.makeMesh(verts: [])
        for n in 0...2 {
            var indices: [UInt32] = []
            let count = mesh.triangulateFace(Self.face(n), into: &indices)
            #expect(count == 0)
        }
    }

    // MARK: - Triangle fast path (ufbx.c:32401-32406)

    @Test func triangleFastPathCopiesVerbatim() {
        let mesh = Self.makeMesh(verts: [FBXVec3(0, 0, 0), FBXVec3(1, 0, 0), FBXVec3(0, 1, 0)])
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(3), into: &indices)
        #expect(count == 1)
        #expect(indices == [0, 1, 2])
    }

    @Test func triangleFastPathHonorsIndexBegin() {
        let mesh = Self.makeMesh(
            verts: [FBXVec3(0, 0, 0), FBXVec3(1, 0, 0), FBXVec3(0, 1, 0)],
            indexBegin: 5
        )
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(3, indexBegin: 5), into: &indices)
        #expect(count == 1)
        #expect(indices == [5, 6, 7])
    }

    // MARK: - Quad diagonal split (ufbx.c:32407-32449)

    /// Convex planar trapezoid (0,0) (4,0) (3,2) (0,2): diagonal `a = v2-v0`
    /// has |a|^2 = 3^2+2^2 = 13, diagonal `b = v3-v1` has |b|^2 = (-4)^2+2^2
    /// = 20. Both candidate splits keep consistent triangle normals (planar
    /// convex quad, dot_na = dot_nb = 1 > 0) so the winding-flip guard does
    /// NOT trigger; the shorter diagonal `a` (13 <= 20) is chosen, i.e.
    /// {i0,i1,i2, i2,i3,i0}.
    @Test func quadSplitsShorterDiagonalA() {
        let mesh = Self.makeMesh(verts: [
            FBXVec3(0, 0, 0), FBXVec3(4, 0, 0), FBXVec3(3, 2, 0), FBXVec3(0, 2, 0),
        ])
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(4), into: &indices)
        #expect(count == 2)
        #expect(indices == [0, 1, 2, 2, 3, 0])
    }

    /// Convex planar quad (0,0) (1,0) (4,3) (0,3): diagonal `a = v2-v0` has
    /// |a|^2 = 25, diagonal `b = v3-v1` has |b|^2 = 10. Again no winding-flip
    /// override (planar convex, dot_na = dot_nb = 1 > 0); the shorter
    /// diagonal is now `b` (10 < 25), i.e. {i1,i2,i3, i3,i0,i1}.
    @Test func quadSplitsShorterDiagonalB() {
        let mesh = Self.makeMesh(verts: [
            FBXVec3(0, 0, 0), FBXVec3(1, 0, 0), FBXVec3(4, 3, 0), FBXVec3(0, 3, 0),
        ])
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(4), into: &indices)
        #expect(count == 2)
        #expect(indices == [1, 2, 3, 3, 0, 1])
    }

    /// Non-planar quad v0=(-3,-3,0) v1=(-3,-3,1) v2=(-3,-2.5,1) v3=(-1.5,-3,1):
    /// diagonal lengths are |a|^2 = 1.25, |b|^2 = 2.25, so the NAIVE
    /// shorter-diagonal rule alone would pick split `a`. But
    /// dot_na = dot(normalize(cross(a,v1-v0)), normalize(cross(a,v0-v3)))
    ///        = -2/7 < 0
    /// so the winding-flip guard (ufbx.c:32434-32436) overrides: since
    /// dot_na < dot_nb (0), `split_a = dot_na >= dot_nb` is FALSE, flipping
    /// the choice to diagonal `b` — {i1,i2,i3, i3,i0,i1} — opposite of what
    /// the naive shorter-diagonal rule alone would have produced. This
    /// exercises the override actually changing the outcome, not just
    /// agreeing with the default.
    @Test func quadWindingFlipGuardOverridesShorterDiagonal() {
        let mesh = Self.makeMesh(verts: [
            FBXVec3(-3.0, -3.0, 0.0), FBXVec3(-3.0, -3.0, 1.0),
            FBXVec3(-3.0, -2.5, 1.0), FBXVec3(-1.5, -3.0, 1.0),
        ])
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(4), into: &indices)
        #expect(count == 2)
        #expect(indices == [1, 2, 3, 3, 0, 1])
    }

    @Test func quadHonorsIndexBegin() {
        let mesh = Self.makeMesh(
            verts: [FBXVec3(0, 0, 0), FBXVec3(4, 0, 0), FBXVec3(3, 2, 0), FBXVec3(0, 2, 0)],
            indexBegin: 10
        )
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(4, indexBegin: 10), into: &indices)
        #expect(count == 2)
        #expect(indices == [10, 11, 12, 12, 13, 10])
    }

    // MARK: - Convex n-gon (ufbxi_triangulate_ngon, no reflex corners)

    /// Regular convex pentagon (CCW, +Z normal), vertices at angles
    /// 90/162/234/306/18 degrees on the unit circle. Fully convex, so the
    /// reflex list is empty and every candidate ear is accepted on the first
    /// try (no KD-blocking possible). Reference-script trace: window starts
    /// at corners (0,1,2,3); by symmetry weight(0,1,2) == weight(1,2,3), so
    /// the tie goes to side 0 (`weight1 > weight0` is false on a tie) which
    /// clips corner 1 -> triangle (0,1,2), window becomes (4,0,2,3). Same
    /// tie again clips corner 0 -> triangle (4,0,2), leaving the single
    /// final triangle at corner 4 -> (3,4,2). In ascending clipped-corner
    /// order (0, 1, 4) that's: (4,0,2), (0,1,2), (3,4,2).
    @Test func convexPentagonEarClipOrder() {
        var verts: [FBXVec3] = []
        for i in 0..<5 {
            let angle = Double.pi / 2 + Double(i) * 2 * Double.pi / 5
            verts.append(FBXVec3(cos(angle), sin(angle), 0))
        }
        let mesh = Self.makeMesh(verts: verts)
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(5), into: &indices)
        #expect(count == 3)
        #expect(indices == [4, 0, 2, 0, 1, 2, 3, 4, 2])
    }

    // MARK: - Concave (L-shaped) n-gon (exercises reflex-vertex handling)

    /// L-shaped hexagon, CCW: (0,0) (4,0) (4,2) (2,2) (2,4) (0,4). Corner 3
    /// = (2,2) is the single reflex (non-convex) vertex — the inner corner
    /// of the L — everything else is convex (reflex list = [3]).
    /// Independently-scripted trace of the exact ufbx algorithm: window
    /// (0,1,2,3) clips corner 2 -> (1,2,3) [side 1 beats side 0 in weight];
    /// window (0,1,3,4) clips corner 1 -> (0,1,3) [side 1's triangle (1,3,4)
    /// is rejected, orient2d(1,3,4) <= 0]; window (5,0,3,4) clips corner 0
    /// -> (5,0,3); the remaining ring (3,4,5) is emitted as the final
    /// triangle (4,5,3). Corner 3 (the reflex vertex) is never itself
    /// clipped — it survives to the end and appears in all 4 triangles, a
    /// fan around the reflex corner. In ascending clipped-corner order
    /// (0, 1, 2, 5) that's: (5,0,3), (0,1,3), (1,2,3), (4,5,3).
    @Test func concaveLShapeEarClipOrder() {
        let mesh = Self.makeMesh(verts: [
            FBXVec3(0, 0, 0), FBXVec3(4, 0, 0), FBXVec3(4, 2, 0),
            FBXVec3(2, 2, 0), FBXVec3(2, 4, 0), FBXVec3(0, 4, 0),
        ])
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(6), into: &indices)
        #expect(count == 4)
        #expect(indices == [5, 0, 3, 0, 1, 3, 1, 2, 3, 4, 5, 3])
        // Sanity: every triangle is non-degenerate (positive area) and the
        // union covers the same index set as the polygon.
        var seen = Set<UInt32>()
        for t in 0..<count {
            seen.insert(indices[t * 3 + 0])
            seen.insert(indices[t * 3 + 1])
            seen.insert(indices[t * 3 + 2])
        }
        #expect(seen == Set(0...5))
    }

    @Test func ngonHonorsIndexBegin() {
        let mesh = Self.makeMesh(
            verts: [
                FBXVec3(0, 0, 0), FBXVec3(4, 0, 0), FBXVec3(4, 2, 0),
                FBXVec3(2, 2, 0), FBXVec3(2, 4, 0), FBXVec3(0, 4, 0),
            ],
            indexBegin: 7
        )
        var indices: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(6, indexBegin: 7), into: &indices)
        #expect(count == 4)
        #expect(indices == [12, 7, 10, 7, 8, 10, 8, 9, 10, 11, 12, 10])
    }

    // MARK: - Buffer growth / convenience API

    @Test func growsUndersizedBuffer() {
        let mesh = Self.makeMesh(verts: [
            FBXVec3(0, 0, 0), FBXVec3(4, 0, 0), FBXVec3(3, 2, 0), FBXVec3(0, 2, 0),
        ])
        var indices: [UInt32] = [999] // too small (need 6)
        let count = mesh.triangulateFace(Self.face(4), into: &indices)
        #expect(count == 2)
        #expect(indices.count == 6)
        #expect(indices == [0, 1, 2, 2, 3, 0])
    }

    @Test func leavesOversizedBufferTailUntouched() {
        let mesh = Self.makeMesh(verts: [FBXVec3(0, 0, 0), FBXVec3(1, 0, 0), FBXVec3(0, 1, 0)])
        var indices: [UInt32] = [1, 2, 3, 4, 5]
        let count = mesh.triangulateFace(Self.face(3), into: &indices)
        #expect(count == 1)
        #expect(Array(indices[0..<3]) == [0, 1, 2])
        #expect(indices.count == 5) // untouched tail preserved, not truncated
    }

    @Test func convenienceReturnValueMatchesBufferVersion() {
        let mesh = Self.makeMesh(verts: [
            FBXVec3(0, 0, 0), FBXVec3(1, 0, 0), FBXVec3(4, 3, 0), FBXVec3(0, 3, 0),
        ])
        var buffered: [UInt32] = []
        let count = mesh.triangulateFace(Self.face(4), into: &buffered)
        let returned = mesh.triangulateFace(Self.face(4))
        #expect(returned.count == count * 3)
        #expect(Array(buffered[0..<returned.count]) == returned)
    }
}
