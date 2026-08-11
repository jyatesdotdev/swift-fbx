import Foundation
import Testing
@testable import SwiftFBX

@Suite struct ResourceLimitTests {
    private struct BinaryNode {
        var name: String
        var numberOfValues: UInt32 = 0
        var values: [UInt8] = []
        var children: [BinaryNode] = []
    }

    private static let asciiDocument = Data("""
        ; FBX 7.4.0 project file
        Objects: {
            Geometry: 1, "Geometry::Budget", "Mesh" {
                Vertices: *3 { a: 0,1,2 }
                Vertices: *3 { a: 3,4,5 }
            }
        }
        """.utf8)

    @Test func exactSourceAndDecodedBoundariesAreAccepted() throws {
        let options = FBXLoadOptions(
            maximumSourceBytes: Self.asciiDocument.count,
            maximumDecodedArrayBytes: 6 * MemoryLayout<Double>.size,
            maximumDecodedArrayElements: 6
        )

        let document = try FBXDocument.parse(data: Self.asciiDocument, options: options)
        #expect(document.format == .ascii)
    }

    @Test func sourceByteOverLimitIsRejected() {
        let options = FBXLoadOptions(
            maximumSourceBytes: Self.asciiDocument.count - 1,
            maximumDecodedArrayBytes: FBXLoadOptions.defaultMaximumDecodedArrayBytes,
            maximumDecodedArrayElements: FBXLoadOptions.defaultMaximumDecodedArrayElements
        )

        expectError(.resourceLimit) {
            _ = try FBXDocument.parse(data: Self.asciiDocument, options: options)
        }
    }

    @Test func aggregateDecodedByteOverLimitIsRejected() {
        let options = FBXLoadOptions(
            maximumSourceBytes: Self.asciiDocument.count,
            maximumDecodedArrayBytes: 6 * MemoryLayout<Double>.size - 1,
            maximumDecodedArrayElements: 6
        )

        expectError(.resourceLimit) {
            _ = try FBXDocument.parse(data: Self.asciiDocument, options: options)
        }
    }

    @Test func aggregateDecodedElementOverLimitIsRejected() {
        let options = FBXLoadOptions(
            maximumSourceBytes: Self.asciiDocument.count,
            maximumDecodedArrayBytes: 6 * MemoryLayout<Double>.size,
            maximumDecodedArrayElements: 5
        )

        expectError(.resourceLimit) {
            _ = try FBXDocument.parse(data: Self.asciiDocument, options: options)
        }
    }

    @Test func invalidOptionsAreRejected() {
        let invalidOptions = [
            FBXLoadOptions(
                maximumSourceBytes: 0,
                maximumDecodedArrayBytes: 1,
                maximumDecodedArrayElements: 1
            ),
            FBXLoadOptions(
                maximumSourceBytes: 1,
                maximumDecodedArrayBytes: 0,
                maximumDecodedArrayElements: 1
            ),
            FBXLoadOptions(
                maximumSourceBytes: 1,
                maximumDecodedArrayBytes: 1,
                maximumDecodedArrayElements: 0
            ),
            FBXLoadOptions(
                maximumSourceBytes: Int.max,
                maximumDecodedArrayBytes: 1,
                maximumDecodedArrayElements: 1
            ),
        ]

        for options in invalidOptions {
            expectError(.invalidOptions) {
                _ = try FBXDocument.parse(data: Data([0]), options: options)
            }
        }
    }

    @Test func compressedArrayDeclarationCannotAmplifyPastBudget() {
        let data = Self.compressedArrayDocument(declaredDoubleCount: 1_024)
        let options = FBXLoadOptions(
            maximumSourceBytes: data.count,
            maximumDecodedArrayBytes: 64,
            maximumDecodedArrayElements: 1_024
        )

        expectError(.resourceLimit) {
            _ = try FBXDocument.parse(data: data, options: options)
        }
    }

    @Test func hugeScalarValueCountUsesSourceBoundedReserve() {
        let node = BinaryNode(name: "Unknown", numberOfValues: UInt32.max)
        let data = Self.binaryDocument(root: node)

        expectError(.corruptData) {
            _ = try FBXDocument.parse(data: data)
        }
    }

    @Test func fileURLReadStopsAtSourceLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-fbx-resource-limit-\(UUID().uuidString).fbx")
        try Data([0, 1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let options = FBXLoadOptions(
            maximumSourceBytes: 4,
            maximumDecodedArrayBytes: 1,
            maximumDecodedArrayElements: 1
        )
        expectError(.resourceLimit) {
            _ = try FBXScene.load(contentsOf: url, options: options)
        }
    }

    private func expectError(_ expectedCode: FBXError.Code, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected FBXError.\(expectedCode)")
        } catch let error as FBXError {
            #expect(error.code == expectedCode)
        } catch {
            Issue.record("Expected FBXError, got \(error)")
        }
    }

    private static func compressedArrayDocument(declaredDoubleCount: UInt32) -> Data {
        // Valid zlib stream for an empty payload. The resource budget rejects
        // the declared 8 KiB output before this compact payload is inflated.
        let emptyZlib: [UInt8] = [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
        var arrayValue: [UInt8] = [0x64] // 'd'
        appendUInt32(declaredDoubleCount, to: &arrayValue)
        appendUInt32(1, to: &arrayValue)
        appendUInt32(UInt32(emptyZlib.count), to: &arrayValue)
        arrayValue.append(contentsOf: emptyZlib)

        let vertices = BinaryNode(name: "Vertices", numberOfValues: 1, values: arrayValue)
        let geometry = BinaryNode(name: "Geometry", children: [vertices])
        let objects = BinaryNode(name: "Objects", children: [geometry])

        return binaryDocument(root: objects)
    }

    private static func binaryDocument(root: BinaryNode) -> Data {
        var bytes = BinaryParser.binaryMagic
        bytes.append(0) // little-endian
        appendUInt32(7_400, to: &bytes)
        appendNode(root, to: &bytes)
        bytes.append(contentsOf: repeatElement(0, count: 13))
        return Data(bytes)
    }

    private static func appendNode(_ node: BinaryNode, to bytes: inout [UInt8]) {
        let headerOffset = bytes.count
        bytes.append(contentsOf: repeatElement(0, count: 13))
        bytes.append(contentsOf: node.name.utf8)
        bytes.append(contentsOf: node.values)
        for child in node.children {
            appendNode(child, to: &bytes)
        }
        if !node.children.isEmpty {
            bytes.append(contentsOf: repeatElement(0, count: 13))
        }

        writeUInt32(UInt32(bytes.count), at: headerOffset, in: &bytes)
        writeUInt32(node.numberOfValues, at: headerOffset + 4, in: &bytes)
        writeUInt32(UInt32(node.values.count), at: headerOffset + 8, in: &bytes)
        bytes[headerOffset + 12] = UInt8(node.name.utf8.count)
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func writeUInt32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset + 0] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
