// The load driver: `Data` → parsed `FBXDocument` → read → takes → link →
// finalize → `FBXScene`. Mirrors the FBX branch of `ufbxi_load_imp`
// (ufbx.c:25286-25378): parse, `ufbxi_read_root`, then the pre-finalize /
// finalize / update passes, and finally the metadata copy-out.

import Foundation

enum Loader {
    /// Small chunks avoid asking Foundation to materialize the entire file in
    /// one read while keeping syscall overhead negligible for asset files.
    private static let fileReadChunkBytes = 64 * 1_024

    /// Load from a file URL; sets `metadata.filename` to the basename.
    static func load(contentsOf url: URL, options: FBXLoadOptions = .init()) throws -> FBXScene {
        try options.validate()
        guard url.isFileURL else {
            throw FBXError(.io, "Only file URLs are supported")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FBXError(.io, "Failed to read file: \(url.lastPathComponent)")
        }
        defer { try? handle.close() }

        let readLimit = options.maximumSourceBytes + 1
        var data = Data()
        do {
            while data.count < readLimit {
                let remaining = readLimit - data.count
                let count = Swift.min(fileReadChunkBytes, remaining)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            throw FBXError(.io, "Failed to read file: \(url.lastPathComponent)")
        }
        try options.validateSourceByteCount(data.count)

        let scene = try load(data: data, options: options)
        scene.metadata.filename = url.lastPathComponent
        return scene
    }

    /// Load from an in-memory buffer. `metadata.filename` is left empty.
    static func load(data: Data, options: FBXLoadOptions = .init()) throws -> FBXScene {
        // Format/version detection + full DOM parse (DocumentParser, notes 04).
        let doc = try FBXDocument.parse(data: data, options: options)

        // Arena-first: the scene is created empty so elements can hold `unowned
        // scene`. Populate the metadata ufbx copies out at the end of the load.
        let scene = FBXScene()
        scene.metadata.version = doc.version
        scene.metadata.ascii = doc.format == .ascii
        scene.metadata.bigEndian = doc.bigEndian

        let ctx = LoadContext(doc: doc, opts: options, scene: scene)

        // Read: header, templates, objects, connections, settings (creator etc.
        // land on `scene.metadata` during this pass).
        try ElementReader.readDocument(ctx)

        // Takes: pre-7000 builds the animation; ≥7000 back-fills stack time ranges.
        try TakesReader.read(ctx)

        // Resolve connections + hierarchy, linearize nodes, wire cross-refs.
        try SceneLinker.link(ctx)

        // update_* passes: props → fields, transforms, world matrices, material
        // fetchMaps, mesh parts, video content, stack time ranges.
        try SceneFinalizer.finalize(ctx)

        // Warnings are staged on the context; publish them to the one location.
        scene.warnings = ctx.warnings

        return scene
    }
}

// NOTE: The public `FBXScene.load(contentsOf:)` / `load(data:)` entry points are
// declared in `Scene/Scene.swift` (scene-model wave) and delegate to the
// `Loader.load` methods above, so they are intentionally NOT re-declared here.
