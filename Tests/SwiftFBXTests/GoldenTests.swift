import Foundation
import Testing
import FBXDumpCore
@testable import SwiftFBX

/// Compares every FBX file in Resources/fbx against the ufbx-generated golden dump
/// in Resources/golden (see docs/DUMP_FORMAT.md). This is the primary acceptance
/// suite: SwiftFBX must reproduce ufbx's output for all of them.
@Suite struct GoldenTests {
    static let resourceRoot = Bundle.module.url(forResource: "Resources", withExtension: nil)!

    static var fbxFiles: [String] {
        let dir = resourceRoot.appendingPathComponent("fbx")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".fbx") }.map { String($0.dropLast(4)) }.sorted()
    }

    @Test(arguments: fbxFiles)
    func golden(name: String) throws {
        let fbxURL = Self.resourceRoot.appendingPathComponent("fbx/\(name).fbx")
        let goldenURL = Self.resourceRoot.appendingPathComponent("golden/\(name).json")

        let scene = try FBXScene.load(contentsOf: fbxURL)
        let actual = SceneDump.build(scene: scene, filename: "\(name).fbx")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL))

        let diffs = JSONCompare.diff(expected: expected, actual: actual)
        #expect(diffs.isEmpty, "\(name): \(diffs.count) divergences (showing up to 25):\n\(diffs.joined(separator: "\n"))")
    }
}
