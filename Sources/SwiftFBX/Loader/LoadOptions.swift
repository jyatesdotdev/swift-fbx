/// Options that bound the memory work performed while loading an FBX file.
///
/// The defaults are intentionally generous enough for detailed production
/// assets while still making hostile-input behavior finite. Applications that
/// know their asset budget should lower these values.
public struct FBXLoadOptions: Sendable {
    private static let bytesPerMebibyte = 1_024 * 1_024

    /// 256 MiB keeps a single source file from consuming an application's
    /// entire address space before parsing begins.
    public static let defaultMaximumSourceBytes = 256 * bytesPerMebibyte

    /// 512 MiB allows decoded geometry to be larger than its compressed source
    /// while bounding DEFLATE amplification across the complete document.
    public static let defaultMaximumDecodedArrayBytes = 512 * bytesPerMebibyte

    /// 64 Mi elements separately bounds arrays whose element representation is
    /// small, such as visibility flags and byte content.
    public static let defaultMaximumDecodedArrayElements = 64 * 1_024 * 1_024

    /// Maximum bytes accepted from `Data` or a file URL.
    public var maximumSourceBytes: Int

    /// Maximum aggregate decoded payload bytes across all document arrays.
    /// Binary arrays use the larger of their wire and normalized storage sizes.
    public var maximumDecodedArrayBytes: Int

    /// Maximum aggregate element count across all document arrays.
    public var maximumDecodedArrayElements: Int

    public init(
        maximumSourceBytes: Int = FBXLoadOptions.defaultMaximumSourceBytes,
        maximumDecodedArrayBytes: Int = FBXLoadOptions.defaultMaximumDecodedArrayBytes,
        maximumDecodedArrayElements: Int = FBXLoadOptions.defaultMaximumDecodedArrayElements
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumDecodedArrayBytes = maximumDecodedArrayBytes
        self.maximumDecodedArrayElements = maximumDecodedArrayElements
    }

    func validate() throws {
        guard maximumSourceBytes > 0 else {
            throw FBXError(.invalidOptions, "maximumSourceBytes must be positive")
        }
        guard maximumSourceBytes < Int.max else {
            throw FBXError(.invalidOptions, "maximumSourceBytes must be less than Int.max")
        }
        guard maximumDecodedArrayBytes > 0 else {
            throw FBXError(.invalidOptions, "maximumDecodedArrayBytes must be positive")
        }
        guard maximumDecodedArrayElements > 0 else {
            throw FBXError(.invalidOptions, "maximumDecodedArrayElements must be positive")
        }
    }

    func validateSourceByteCount(_ count: Int) throws {
        try validate()
        guard count <= maximumSourceBytes else {
            throw FBXError(
                .resourceLimit,
                "source bytes \(count) exceed maximumSourceBytes \(maximumSourceBytes)"
            )
        }
    }
}

/// Tracks logical decoded array storage for one document parse.
///
/// Swift's typed conversion may briefly hold an additional same-sized buffer,
/// but every such buffer is derived from a payload claimed here. Keeping one
/// shared tracker prevents many individually-small arrays from bypassing the
/// document-wide limits.
final class FBXDecodedArrayBudget {
    private let maximumBytes: Int
    private let maximumElements: Int
    private var usedBytes = 0
    private var usedElements = 0

    init(options: FBXLoadOptions) {
        maximumBytes = options.maximumDecodedArrayBytes
        maximumElements = options.maximumDecodedArrayElements
    }

    func claim(elements: Int, bytesPerElement: Int, context: String) throws {
        guard elements >= 0, bytesPerElement > 0 else {
            throw FBXError(.corruptData, "invalid decoded array size for \(context)")
        }
        let byteCount = elements.multipliedReportingOverflow(by: bytesPerElement)
        guard !byteCount.overflow else {
            throw FBXError(.resourceLimit, "decoded array byte count overflow for \(context)")
        }
        try claim(elements: elements, bytes: byteCount.partialValue, context: context)
    }

    func claim(elements: Int, bytes: Int, context: String) throws {
        guard elements >= 0, bytes >= 0 else {
            throw FBXError(.corruptData, "invalid decoded array size for \(context)")
        }

        let nextElements = usedElements.addingReportingOverflow(elements)
        guard !nextElements.overflow, nextElements.partialValue <= maximumElements else {
            throw FBXError(
                .resourceLimit,
                "decoded array elements exceed maximumDecodedArrayElements \(maximumElements) at \(context)"
            )
        }

        let nextBytes = usedBytes.addingReportingOverflow(bytes)
        guard !nextBytes.overflow, nextBytes.partialValue <= maximumBytes else {
            throw FBXError(
                .resourceLimit,
                "decoded array bytes exceed maximumDecodedArrayBytes \(maximumBytes) at \(context)"
            )
        }

        usedElements = nextElements.partialValue
        usedBytes = nextBytes.partialValue
    }
}
