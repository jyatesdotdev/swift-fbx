import Foundation
import Testing
@testable import SwiftFBX

/// Crash-safety contract for the loader: malformed/corrupt/truncated input must
/// always fail cleanly, never trap, hang, or corrupt memory.
///
/// Every file under `Resources/malformed/` is a known crasher (byte-flipped
/// real FBX files that previously triggered fatal-error traps — chiefly the
/// integer-width conversion trap in `BinaryParser` on oversized `values_len` /
/// array-size / node-offset fields). Each must now load successfully OR throw an
/// `FBXError`. Any other outcome — a Swift runtime trap ("Fatal error: …"), an
/// uncaught non-`FBXError`, an out-of-bounds subscript, or a hang — aborts the
/// test process and fails this suite, which is exactly the regression we guard.
///
/// The suite also feeds every valid `Resources/fbx` file through the loader
/// truncated at many lengths, so the "truncated file" reject path stays covered
/// even as new sample files are added.
@Suite struct MalformedInputTests {
    static let resourceRoot = Bundle.module.url(forResource: "Resources", withExtension: nil)!

    static var malformedFiles: [String] {
        let dir = resourceRoot.appendingPathComponent("malformed")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".fbx") }.sorted()
    }

    static var validFiles: [String] {
        let dir = resourceRoot.appendingPathComponent("fbx")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".fbx") }.sorted()
    }

    /// Load a blob and assert the outcome is "clean": either a scene or an
    /// `FBXError`. Returns nothing; a trap/OOB inside `load` crashes the process
    /// (the failure we are testing against), and any non-`FBXError` throw is a
    /// contract violation we surface explicitly.
    private func expectCleanLoad(_ data: Data, _ label: String) {
        do {
            _ = try FBXScene.load(data: data)
            // Loaded successfully — acceptable.
        } catch let error as FBXError {
            // Rejected cleanly — acceptable. Touch the fields so the payload is
            // exercised (and to keep the binding from being optimised away).
            #expect(!"\(error.code)".isEmpty, "\(label)")
        } catch {
            Issue.record("\(label): threw non-FBXError \(type(of: error)): \(error)")
        }
    }

    /// Every known crasher input must load or throw `FBXError`, never trap.
    @Test(arguments: malformedFiles)
    func malformedFileNeverCrashes(name: String) throws {
        let url = Self.resourceRoot.appendingPathComponent("malformed/\(name)")
        let data = try Data(contentsOf: url)
        expectCleanLoad(data, "malformed/\(name)")
    }

    /// Truncating each valid file at many offsets must never trap — it either
    /// loads (rare, for benign tail truncations) or throws `FBXError`.
    @Test(arguments: validFiles)
    func truncationsNeverCrash(name: String) throws {
        let url = Self.resourceRoot.appendingPathComponent("fbx/\(name)")
        let full = try Data(contentsOf: url)
        guard !full.isEmpty else { return }
        // ~24 cut points spread across the file, plus header-boundary sizes that
        // stress the binary/ascii sniff and the record-header readers.
        var cuts = Set<Int>([0, 1, 2, 13, 26, 27, 28, 40, 64, 128])
        let step = max(1, full.count / 24)
        cuts.formUnion(stride(from: 0, to: full.count, by: step))
        for cut in cuts.sorted() where cut <= full.count {
            expectCleanLoad(full.prefix(cut), "trunc:\(name)@\(cut)")
        }
    }

    /// A hostile hand-built binary node whose declared `values_len` field is the
    /// maximum u64 must be rejected as truncated/corrupt, not trap on the
    /// value-skip integer conversion (the original BinaryParser:157 crash).
    @Test func hugeValuesLenDoesNotTrap() throws {
        var bytes = [UInt8]()
        bytes.append(contentsOf: Array("Kaydara FBX Binary  ".utf8))
        bytes.append(contentsOf: [0x00, 0x1a])       // magic terminator
        bytes.append(0x00)                            // endianness (little)
        bytes.append(contentsOf: [0x5c, 0x1d, 0x00, 0x00]) // version 7500
        // One >= 7500 node header (25 bytes): end_offset, num_values, values_len,
        // name_len. Set values_len = UINT64_MAX and a 1-byte name.
        bytes.append(contentsOf: [UInt8](repeating: 0x00, count: 8))  // end_offset = 0
        bytes.append(contentsOf: [UInt8](repeating: 0x00, count: 8))  // num_values = 0
        bytes.append(contentsOf: [UInt8](repeating: 0xff, count: 8))  // values_len = UINT64_MAX
        bytes.append(0x01)                                            // name_len = 1
        bytes.append(UInt8(ascii: "X"))                               // name

        do {
            _ = try FBXScene.load(data: Data(bytes))
        } catch is FBXError {
            // Expected: clean rejection.
        } catch {
            Issue.record("hugeValuesLen: threw non-FBXError \(error)")
        }
    }
}
