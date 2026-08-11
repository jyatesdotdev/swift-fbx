# swift-fbx

A pure-Swift FBX file parser, ported from [ufbx](https://github.com/ufbx/ufbx).

- Binary FBX 7100–7700 (including 64-bit and big-endian variants) and ASCII FBX 6100–7700
- Zero dependencies (pure Swift, including DEFLATE decompression)
- Scene graph: node hierarchy with the full FBX transform chain, meshes with all
  vertex attributes, materials, textures, lights, cameras, bones, skinning,
  blend shapes
- Animation: stacks, layers, curves; keyframe interpolation and transform
  evaluation at arbitrary times (including pre-7000 "Takes" animation)
- Behavioral parity with ufbx, enforced by golden-dump tests against the real C
  implementation on 44 real-world exporter files (Maya, 3ds Max, Blender)

## Usage

```swift
import SwiftFBX

let scene = try FBXScene.load(contentsOf: url)

for node in scene.nodes {
    print(node.name, node.nodeToWorld)
    if let mesh = node.mesh {
        print("  mesh:", mesh.numVertices, "vertices,", mesh.numFaces, "faces")
    }
}

// Animation
if let stack = scene.animStacks.first {
    let t = (stack.timeBegin + stack.timeEnd) / 2
    for node in scene.nodes {
        let transform = stack.anim.evaluateTransform(node: node, time: t)
        _ = transform
    }
}

// Low-level document access
let document = try FBXDocument.parse(data: data)
```

File and decoded-array memory work is bounded by default. Applications with a
known asset budget can lower the limits; every value must be positive:

```swift
let options = FBXLoadOptions(
    maximumSourceBytes: 64 * 1_024 * 1_024,
    maximumDecodedArrayBytes: 128 * 1_024 * 1_024,
    maximumDecodedArrayElements: 16 * 1_024 * 1_024
)
let scene = try FBXScene.load(contentsOf: fileURL, options: options)
```

`load(contentsOf:)` accepts file URLs and reads only one sentinel byte beyond
`maximumSourceBytes`, so an oversized file is rejected without being fully
materialized. `FBXDocument.parse(data:)` applies the same source and decoded
array limits to in-memory input.

### Add as a Swift package

Add via URL from another package:

```swift
let package = Package(
    // ...
    dependencies: [
        .package(url: "https://github.com/jyatesdotdev/swift-fbx.git", from: "0.1.2"),
    ],
    targets: [
        .target(
            name: "MyTarget",
            dependencies: [
                .product(name: "SwiftFBX", package: "swift-fbx"),
            ]
        ),
    ]
)
```

In Xcode, choose **File > Add Package Dependencies** and paste the repository URL,
then link the `SwiftFBX` library product to the target that imports it.

## Development

- `docs/DESIGN.md` — architecture and porting rules
- `docs/ufbx-notes/` — subsystem-by-subsystem port notes mapping ufbx.c internals
- `docs/DUMP_FORMAT.md` — golden dump format shared with the C reference harness
- `tools/ufbx_dump.c` + `tools/ufbx/` — vendored ufbx reference used to
  (re)generate `Tests/SwiftFBXTests/Resources/golden/`

```sh
swift build
swift test                         # includes golden parity suite
swift run fbx-dump file.fbx        # emit the golden JSON dump for a file
```

## License

SwiftFBX is available under the MIT License. The ufbx-derived portions retain
Samuli Raivio's copyright notice, and the vendored reference retains its full
license in `tools/ufbx/LICENSE`.
