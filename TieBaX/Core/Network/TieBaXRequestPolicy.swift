import Foundation

/// Product-owned request rules. The wire values in this type are protocol
/// compatibility values, not a copy of another client's object model. Keeping
/// validation and normalization here makes every feature use the same safety
/// limits before it reaches an HTTP transport.
enum TieBaXRequestPolicy {
    // V11 protobuf endpoints (hot feed and profile) use this client line.
    static let officialClientVersion = "11.10.8.6"
    // The JSON /c/f/forum/like contract is the Android 12.41 client line.
    static let officialJSONClientVersion = "12.41.7.1"
    static let appClientVersion = "12.52.1.0"
    static let contentSubmissionClientVersion = "12.35.1.0"
    static let postingLoginClientVersion = "22.5.1.0"
    static let miniClientVersion = "7.2.0.0"
    static let socialClientVersion = "22.5.1.0"
    static let searchWebClientVersion = "99.9.101"

    static let defaultSearchPageSize = 30
    static let maximumSearchPageSize = 100
    static let maximumKeywordLength = 120
    static let maximumForumNameLength = 60

    static func signedPage(_ page: Int) throws -> Int32 {
        guard page > 0, let value = Int32(exactly: page) else {
            throw TiebaRequestValidationError.invalidPage(page)
        }
        return value
    }

    static func unsignedPage(_ page: Int) throws -> UInt32 {
        guard page > 0, let value = UInt32(exactly: page) else {
            throw TiebaRequestValidationError.invalidPage(page)
        }
        return value
    }

    static func signedIdentifier(_ identifier: UInt64) throws -> Int64 {
        guard let value = Int64(exactly: identifier) else {
            throw TiebaRequestValidationError.invalidIdentifier(identifier)
        }
        return value
    }

    static func positiveIdentifier(_ identifier: Int64) throws -> Int64 {
        guard identifier > 0 else {
            throw TiebaRequestValidationError.invalidSignedIdentifier(identifier)
        }
        return identifier
    }

    static func normalizedKeyword(_ keyword: String) -> String? {
        normalized(keyword, maximumLength: maximumKeywordLength)
    }

    static func normalizedForumName(_ forumName: String) -> String? {
        normalized(forumName, maximumLength: maximumForumNameLength)
    }

    static func searchPageSize(_ requestedSize: Int) -> Int {
        min(max(requestedSize, 1), maximumSearchPageSize)
    }

    private static func normalized(_ value: String, maximumLength: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return String(trimmed.prefix(maximumLength))
    }
}
