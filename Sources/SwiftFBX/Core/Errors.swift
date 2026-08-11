import Foundation

/// Error thrown by SwiftFBX loading/parsing. Mirrors the relevant subset of
/// `ufbx_error_type`.
public struct FBXError: Error, Sendable, CustomStringConvertible {
    public enum Code: Sendable, Equatable {
        case io
        case fileNotFound
        case truncatedFile
        case unrecognizedFileFormat
        case unsupportedVersion
        case corruptData          // malformed records/values
        case badDeflate           // DEFLATE stream errors
        case asciiSyntax          // ASCII tokenizer/parser errors
        case badIndex
        case nodeDepthLimit
        case invalidOptions       // non-positive or otherwise unsafe limits
        case resourceLimit        // configured source/decoded-array budget
        case unknown
    }

    public var code: Code
    public var info: String

    public init(_ code: Code, _ info: String = "") {
        self.code = code
        self.info = info
    }

    public var description: String {
        info.isEmpty ? "FBXError.\(code)" : "FBXError.\(code): \(info)"
    }
}

/// Top-level error-code name contracted by DESIGN.md (`error.code: FBXErrorCode`).
/// The implementation nests it as `FBXError.Code`; this alias keeps both spellings
/// valid so code/docs written to the spec continue to compile.
public typealias FBXErrorCode = FBXError.Code

/// Non-fatal issue collected during load. Mirrors `ufbx_warning`.
public struct FBXWarning: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case missingExternalFile
        case truncatedArray
        case missingGeometryData
        case duplicateConnection
        case badVertexWAttribute
        case missingPolygonMapping
        case unsupportedVersion
        case indexClamped
        case badUnicode
        case badBase64Content
        case badElementConnectedToRoot
        case duplicateObjectID
        case emptyFaceRemoved
        case unknown
    }

    public var kind: Kind
    public var info: String
    /// Number of times this (deduplicated) warning occurred.
    public var count: Int
    /// element_id of the related element, -1 if none.
    public var elementID: Int32

    public init(kind: Kind, info: String, count: Int = 1, elementID: Int32 = -1) {
        self.kind = kind
        self.info = info
        self.count = count
        self.elementID = elementID
    }
}
