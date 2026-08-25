import Foundation

/// Product-level constants owned by TieBa-X. Keeping these values in one
/// place prevents protocol code from accidentally inheriting the identity of
/// a reference client.
enum TieBaXProduct {
    static let name = "TieBa-X"
    static let bundleIdentifier = "com.tiebax.ios"
    static let minimumOSVersion = "14.0"
    static let urlScheme = "tiebax"

    /// This is deliberately a neutral client marker. It is not the official
    /// Baidu client string and should be changed only together with protocol
    /// compatibility tests.
    static let userAgent = "TieBa-X/0.1 (iOS)"
}

enum TieBaXFeature: String, CaseIterable, Sendable {
    case homeFeed
    case forumThreads
    case threadReader
    case search
    case accountLogin
    case forumSign
    case threadFavorite
    case compose
    case messages
    case profile
    case localHistory
}

enum TieBaXFeatureAvailability {
    static func isSupported(_ feature: TieBaXFeature, on systemVersion: OperatingSystemVersion) -> Bool {
        // Every committed MVP capability is intentionally available on the
        // minimum OS. Newer-only UIKit/SwiftUI conveniences must be hidden
        // behind compatibility views instead of becoming product gates.
        _ = systemVersion
        return TieBaXFeature.allCases.contains(feature)
    }
}
