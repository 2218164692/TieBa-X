import Foundation

/// Backports the path-appending behavior used by TieBa-X without calling
/// Foundation's iOS 16-only `URL.appending(path:)` API. URLComponents keeps
/// slash separators intact while still escaping other characters correctly.
extension URL {
    func tieBaAppendingPath(_ path: String) -> URL {
        guard var components = URLComponents(
            url: self,
            resolvingAgainstBaseURL: false
        ) else {
            return self
        }

        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path == "/"
            ? ""
            : components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedSuffix = String(suffix.drop(while: { $0 == "/" }))
        components.path = "/" + ([basePath, normalizedSuffix]
            .filter { $0.isEmpty == false }
            .joined(separator: "/"))
        return components.url ?? self
    }

    func tieBaAppendingQueryItems(_ queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(
            url: self,
            resolvingAgainstBaseURL: false
        ) else {
            return self
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
