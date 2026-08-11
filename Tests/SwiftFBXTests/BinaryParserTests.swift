import Foundation
import Testing
@testable import SwiftFBX

/// Exercises the binary FBX record reader against real Maya-exported cubes:
/// a 64-bit (7500) file, a legacy 32-bit multivalue (6100) file, and the
/// big-endian 7500 variant. Ground-truth values were cross-checked against the
/// golden ufbx dumps in Resources/golden.
@Suite struct BinaryParserTests {
    static let fbxDir = Bundle.module.url(forResource: "Resources", withExtension: nil)!
        .appendingPathComponent("fbx")

    static let creator = "FBX SDK/FBX Plugins version 2019.2 build=71e69bd5d"
    // First two vertices (x,y,z, x,y,z) of the raw Vertices array.
    static let firstVertices: [Double] = [-0.5, -0.5, 0.5, 0.5, -0.5, 0.5]

    private func load(_ name: String) throws -> FBXDocument {
        let url = Self.fbxDir.appendingPathComponent("\(name).fbx")
        let bytes = [UInt8](try Data(contentsOf: url))
        let doc = try BinaryParser.parseBinaryDocument(bytes)
        return try #require(doc)
    }

    private func approxEqual(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where abs(x - y) > 1e-9 { return false }
        return true
    }

    // MARK: - Header / version detection

    @Test func detectVersion7500() throws {
        let doc = try load("maya_cube_7500_binary")
        #expect(doc.version == 7500)
        #expect(doc.format == .binary)
        #expect(doc.bigEndian == false)
    }

    @Test func detectVersion6100() throws {
        let doc = try load("maya_cube_6100_binary")
        #expect(doc.version == 6100)
        #expect(doc.bigEndian == false)
    }

    @Test func detectVersionBigEndian() throws {
        let doc = try load("maya_cube_big_endian_7500_binary")
        #expect(doc.version == 7500)
        #expect(doc.bigEndian == true)
    }

    @Test func nonBinaryReturnsNil() throws {
        // An ASCII/garbage buffer must not be mistaken for binary.
        let bytes = [UInt8]("; FBX 7.4.0 project file\n".utf8)
        var reader = DataReader(bytes)
        #expect(try BinaryParser.detectHeader(&reader) == nil)
        #expect(reader.position == 0)
    }

    // MARK: - Top-level node names

    @Test func topLevelNames7500() throws {
        let doc = try load("maya_cube_7500_binary")
        let names = doc.root.children.map(\.name)
        #expect(names == ["FBXHeaderExtension", "FileId", "CreationTime", "Creator",
                          "GlobalSettings", "Documents", "References", "Definitions",
                          "Objects", "Connections", "Takes"])
    }

    @Test func topLevelNames6100() throws {
        let doc = try load("maya_cube_6100_binary")
        let names = doc.root.children.map(\.name)
        #expect(names == ["FBXHeaderExtension", "FileId", "CreationTime", "Creator",
                          "Document", "References", "Definitions", "Objects",
                          "Connections", "Takes", "Version5"])
    }

    // MARK: - String property values

    @Test func creatorString7500() throws {
        let doc = try load("maya_cube_7500_binary")
        #expect(doc.root.child("Creator")?.string(at: 0) == Self.creator)
    }

    @Test func creatorString6100() throws {
        let doc = try load("maya_cube_6100_binary")
        #expect(doc.root.child("Creator")?.string(at: 0) == Self.creator)
    }

    @Test func creatorStringBigEndian() throws {
        let doc = try load("maya_cube_big_endian_7500_binary")
        #expect(doc.root.child("Creator")?.string(at: 0) == Self.creator)
    }

    // MARK: - Vertex arrays (typed deflate array vs multivalue)

    @Test func vertices7500() throws {
        // 7500: Objects/Geometry/Vertices is a typed (possibly deflated) 'd' array.
        let doc = try load("maya_cube_7500_binary")
        let geometry = try #require(doc.root.child("Objects")?.child("Geometry"))
        let vertices = try #require(geometry.child("Vertices")?.asDoubleArray())
        #expect(vertices.count == 24) // 8 unique vertices * 3
        #expect(approxEqual(Array(vertices.prefix(6)), Self.firstVertices))
    }

    @Test func verticesBigEndian() throws {
        // Big-endian 7500: array payload elements are byte-swapped.
        let doc = try load("maya_cube_big_endian_7500_binary")
        let geometry = try #require(doc.root.child("Objects")?.child("Geometry"))
        let vertices = try #require(geometry.child("Vertices")?.asDoubleArray())
        #expect(vertices.count == 24)
        #expect(approxEqual(Array(vertices.prefix(6)), Self.firstVertices))
    }

    @Test func vertices6100Multivalue() throws {
        // 6100: Objects/Model/Vertices is a pre-7000 concatenated-scalar array.
        let doc = try load("maya_cube_6100_binary")
        let model = try #require(doc.root.child("Objects")?.child("Model"))
        let vertices = try #require(model.child("Vertices")?.asDoubleArray())
        #expect(vertices.count == 24)
        #expect(approxEqual(Array(vertices.prefix(6)), Self.firstVertices))
    }

    // MARK: - Nested structure / integer index arrays

    @Test func polygonIndices7500() throws {
        let doc = try load("maya_cube_7500_binary")
        let geometry = try #require(doc.root.child("Objects")?.child("Geometry"))
        let indices = try #require(geometry.child("PolygonVertexIndex")?.asInt32Array())
        // Maya cube: 6 quads = 24 polygon-vertex indices (last of each face negative).
        #expect(indices.count == 24)
        #expect(indices.contains { $0 < 0 })
    }
}
