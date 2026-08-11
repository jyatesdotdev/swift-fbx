// CLI wrapper: loads an FBX file and prints its DUMP_FORMAT JSON to stdout.
// Mirrors `tools/ufbx_dump.c`'s `main` (usage/exit-code conventions).

import FBXDumpCore
import Foundation
import SwiftFBX

let arguments = CommandLine.arguments

guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: fbx-dump file.fbx\n".utf8))
    exit(2)
}

let path = arguments[1]

do {
    let scene = try FBXScene.load(contentsOf: URL(fileURLWithPath: path))
    let dump = SceneDump.build(scene: scene, filename: path)
    let data = try JSONSerialization.data(withJSONObject: dump, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("load failed: \(error)\n".utf8))
    exit(1)
}
