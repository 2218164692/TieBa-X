import Foundation

enum SafariActionPayload {
    static let deepLinkKey = "deepLink"
    static let errorMessageKey = "errorMessage"

    static func result(from item: NSSecureCoding?) -> [String: String] {
        guard let webURL = webURL(from: item),
              let deepLink = ExternalRoute.importURL(forWebURL: webURL) else {
            return [errorMessageKey: "当前页面不是支持的贴吧帖子或贴吧页面。"]
        }
        return [deepLinkKey: deepLink.absoluteString]
    }

    private static func webURL(from item: NSSecureCoding?) -> URL? {
        guard let dictionary = item as? NSDictionary,
              let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary,
              let value = results["url"] as? String else {
            return nil
        }
        return URL(string: value)
    }
}
