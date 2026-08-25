import Foundation

struct Account: Codable, Equatable, Identifiable, Sendable {
    var uid: String
    var name: String
    var displayName: String
    var portrait: String
    var bduss: String
    var stoken: String
    var baiduID: String?
    var tbs: String

    var id: String { uid }

    var sessionIdentity: AccountSessionIdentity {
        AccountSessionIdentity(account: self)
    }

    var portraitURL: URL? {
        TiebaURL.avatar(portrait)
    }

    /// Only the three validated cookies required by the read-only web API.
    /// The app deliberately never persists a browser's complete Cookie header.
    var minimalCookieHeader: String {
        var values = ["BDUSS=\(bduss)", "STOKEN=\(stoken)"]
        if let baiduID, baiduID.isEmpty == false {
            values.append("BAIDUID=\(baiduID)")
        }
        return values.joined(separator: "; ")
    }

    static let preview = Account(
        uid: "0",
        name: "Preview",
        displayName: "Preview",
        portrait: "",
        bduss: "",
        stoken: "",
        baiduID: nil,
        tbs: ""
    )
}

/// Identifies the authenticated Baidu session without treating display
/// metadata or a refreshed TBS value as a different login.
struct AccountSessionIdentity: Hashable, Sendable {
    let accountID: String
    private let bduss: String
    private let stoken: String
    private let baiduID: String?

    init(account: Account) {
        accountID = account.id
        bduss = account.bduss
        stoken = account.stoken
        baiduID = account.baiduID
    }
}
