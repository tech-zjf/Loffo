import Foundation

/// Shared admission policy for working files and immutable Git blobs.
public enum TextLimits {
    public static let bytes = 2 * 1024 * 1024
    public static let lines = 30_000
    public static let lineUTF16 = 20_000

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= bytes else { throw WorkspaceFailure.tooLarge }
        guard !data.contains(0) else { throw WorkspaceFailure.binary }
        guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceFailure.invalidEncoding }
        try validate(text, byteLimit: bytes, lineLimit: lines)
        return text
    }

    public static func validatePresentation(_ text: String) throws {
        // Unified output may contain both entire inputs plus synthetic final terminators.
        try validate(text, byteLimit: 2 * bytes + 2, lineLimit: 2 * lines + 1)
    }

    /// Validate the complete unified output without allocating a second full-size string.
    /// Each row is terminated exactly as it will be by UnifiedProjection.
    public static func validatePresentationRows<C: Collection>(_ rows: C) throws where C.Element == String {
        try Task.checkCancellation()
        let byteLimit = 2 * bytes + 2
        var total = 0
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let length = row.utf8.count + (row.hasSuffix("\n") ? 0 : 1)
            guard length <= byteLimit - total else { throw WorkspaceFailure.tooLarge }
            total += length
        }
        try validateCharacters(
            rows.lazy.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }, lineLimit: 2 * lines + 1)
    }

    private static func validate(_ text: String, byteLimit: Int, lineLimit: Int) throws {
        guard text.utf8.count <= byteLimit else { throw WorkspaceFailure.tooLarge }
        try validateCharacters(CollectionOfOne(text), lineLimit: lineLimit)
    }

    private static func validateCharacters<S: Sequence>(_ chunks: S, lineLimit: Int) throws
    where S.Element == String {
        var count = 1
        var width = 0
        for (index, character) in chunks.lazy.flatMap({ $0 }).enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            if character.isNewline {
                count += 1
                width = 0
            } else {
                width += character.utf16.count
            }
            guard count < lineLimit else {
                throw WorkspaceFailure.unavailable(
                    DomainStrings.text("This document exceeds the supported line count."))
            }
            guard width <= lineUTF16 else {
                throw WorkspaceFailure.unavailable(
                    DomainStrings.text("A line exceeds the 20,000 UTF-16 unit limit."))
            }
        }
    }
}
