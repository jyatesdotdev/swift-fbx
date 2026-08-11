import Foundation
import Testing
@testable import SwiftFBX

@Suite struct AsciiParserTests {
    static let fbxDir = Bundle.module.url(forResource: "Resources", withExtension: nil)!
        .appendingPathComponent("fbx")

    static func load(_ name: String) throws -> FBXDocument {
        let bytes = [UInt8](try Data(contentsOf: fbxDir.appendingPathComponent("\(name).fbx")))
        return try AsciiParser.parseAsciiDocument(bytes)
    }

    // Recursively find the first descendant node with the given name.
    static func findDeep(_ node: FBXDocNode, _ name: String) -> FBXDocNode? {
        for c in node.children {
            if c.name == name { return c }
            if let found = findDeep(c, name) { return found }
        }
        return nil
    }

    // The cube's 24 vertex coordinates (identical across both files).
    static let cubeVertices: [Double] = [
        -0.5, -0.5, 0.5, 0.5, -0.5, 0.5, -0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
        -0.5, 0.5, -0.5, 0.5, 0.5, -0.5, -0.5, -0.5, -0.5, 0.5, -0.5, -0.5,
    ]

    // MARK: - Version detection (magic comment)

    @Test func detectsVersion6100() throws {
        let doc = try Self.load("maya_cube_6100_ascii")
        #expect(doc.version == 6100)
        #expect(doc.format == .ascii)
        #expect(doc.bigEndian == false)
    }

    @Test func detectsVersion7500() throws {
        let doc = try Self.load("maya_cube_7500_ascii")
        #expect(doc.version == 7500)
        #expect(doc.format == .ascii)
    }

    @Test func detectsVersion7400() throws {
        let doc = try Self.load("maya_cube_7400_ascii")
        #expect(doc.version == 7400)
    }

    // MARK: - Top-level node names

    @Test func topLevelNodeNames6100() throws {
        let doc = try Self.load("maya_cube_6100_ascii")
        let names = doc.root.children.map(\.name)
        #expect(names.contains("FBXHeaderExtension"))
        #expect(names.contains("Definitions"))
        #expect(names.contains("Objects"))
        #expect(names.contains("Connections"))
        #expect(names.contains("Takes"))
        // First top-level node is always the header extension.
        #expect(names.first == "FBXHeaderExtension")
    }

    @Test func topLevelNodeNames7500() throws {
        let doc = try Self.load("maya_cube_7500_ascii")
        let names = doc.root.children.map(\.name)
        #expect(names.contains("FBXHeaderExtension"))
        #expect(names.contains("GlobalSettings"))
        #expect(names.contains("Objects"))
        #expect(names.contains("Connections"))
        #expect(names.first == "FBXHeaderExtension")
    }

    // MARK: - FBXVersion child integer

    @Test func fbxVersionChild() throws {
        let doc = try Self.load("maya_cube_7500_ascii")
        let header = doc.root.child("FBXHeaderExtension")
        #expect(header?.child("FBXVersion")?.int32(at: 0) == 7500)
    }

    // MARK: - Vertices array (bare comma list vs *N{} syntax)

    @Test func vertices6100BareCommaList() throws {
        let doc = try Self.load("maya_cube_6100_ascii")
        let verts = try #require(Self.findDeep(doc.root, "Vertices"))
        let arr = try #require(verts.asDoubleArray())
        #expect(arr.count == 24)
        #expect(arr == Self.cubeVertices)
    }

    @Test func vertices7500StarArray() throws {
        let doc = try Self.load("maya_cube_7500_ascii")
        let verts = try #require(Self.findDeep(doc.root, "Vertices"))
        let arr = try #require(verts.asDoubleArray())
        #expect(arr.count == 24)
        #expect(arr == Self.cubeVertices)
    }

    // PolygonVertexIndex is an int32 array with negative (face-terminating) values.
    @Test func polygonVertexIndex7500() throws {
        let doc = try Self.load("maya_cube_7500_ascii")
        let poly = try #require(Self.findDeep(doc.root, "PolygonVertexIndex"))
        let arr = try #require(poly.asInt32Array())
        #expect(arr.count == 24)
        #expect(arr.prefix(4) == [0, 1, 3, -3])
    }

    // MARK: - String property

    @Test func creatorString6100() throws {
        let doc = try Self.load("maya_cube_6100_ascii")
        let header = try #require(doc.root.child("FBXHeaderExtension"))
        #expect(header.child("Creator")?.string(at: 0) == "FBX SDK/FBX Plugins version 2019.2")
    }

    @Test func creatorString7500() throws {
        let doc = try Self.load("maya_cube_7500_ascii")
        let creator = try #require(doc.root.child("FBXHeaderExtension")?.child("Creator"))
        #expect(creator.string(at: 0) == "FBX SDK/FBX Plugins version 2019.2")
    }

    // MARK: - Negative-zero scalar (ufbx.c:10466-10469)

    // A scalar `-0` integer token must preserve the sign in the real view: ufbx
    // stores i=0 AND f=-0.0, so `double(at:)` must be -0.0 while `int64(at:)` is 0.
    // (The 'f'/'d' array branches already do this; this guards the scalar branch.)
    @Test func negativeZeroScalarKeepsSignInRealView() throws {
        let src = "; FBX ASCII\nNegZero: -0, 5 {\n}\n"
        let doc = try AsciiParser.parseAsciiDocument([UInt8](src.utf8))
        let node = try #require(doc.root.child("NegZero"))

        let d = try #require(node.double(at: 0))
        #expect(d == 0.0)                       // numerically zero...
        #expect(d.sign == .minus)               // ...but negative-signed, like ufbx
        #expect(node.int64(at: 0) == 0)         // integer view stays 0

        // A plain `0` (or non-zero) keeps a positive real view.
        #expect(node.double(at: 1) == 5.0)
        #expect(node.double(at: 1)?.sign == .plus)
    }

    // Object names under Objects are stored raw (isRawString) but decode identically.
    @Test func modelNameString7500() throws {
        let doc = try Self.load("maya_cube_7500_ascii")
        let objects = try #require(doc.root.child("Objects"))
        let model = try #require(objects.child("Model"))
        // 7500: `Model: <id>, "Model::pCube1", "Mesh"` — id is value 0, name is value 1.
        #expect(model.int64(at: 0) == 1907292239120)
        let s = try #require(model.string(at: 1))
        #expect(s.contains("pCube1"))
    }
}
