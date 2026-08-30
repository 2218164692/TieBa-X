import CryptoKit
import Foundation
import SwiftProtobuf
import UIKit

struct TiebaRequestBuilder {
    static let boundary = "--------7da3d81520810*"

    var screenScale: Double
    var screenWidth: Int
    var screenHeight: Int
    var clientID: String

    static func live() -> TiebaRequestBuilder {
        let screen = UIScreen.main
        return TiebaRequestBuilder(
            screenScale: Double(screen.scale),
            screenWidth: Int(screen.bounds.width * screen.scale),
            screenHeight: Int(screen.bounds.height * screen.scale),
            clientID: installationClientID
        )
    }

    private static var installationClientID: String {
        let key = "TieBaX.installation.clientID"
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: key), stored.isEmpty == false {
            return stored
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(generated, forKey: key)
        return generated
    }

    func common(account: Account?) -> Tieba_CommonRequest {
        var request = Tieba_CommonRequest()
        request.bduss = account?.bduss ?? ""
        request.clientID = clientID
        request.clientType = 2
        request.clientVersion = TieBaXRequestPolicy.appClientVersion
        request.osVersion = UIDevice.current.systemVersion
        request.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        request.brand = "Apple"
        request.cuid = clientID
        request.cuidGalaxy2 = clientID
        request.cuidGid = ""
        request.from = "1020031h"
        request.isTeenager = 0
        request.model = UIDevice.current.model
        request.netType = 1
        request.pversion = "1.0.3"
        request.personalizedRecSwitch = 1
        request.qType = 0
        request.scrDip = screenScale
        request.scrW = Int32(screenWidth)
        request.scrH = Int32(screenHeight)
        request.stoken = account?.stoken ?? ""
        request.userAgent = "tieba/\(TieBaXRequestPolicy.appClientVersion)"
        return request
    }

    /// The hot-thread endpoint is served by Tieba's V11 protobuf contract.
    /// Keep its common payload explicit: TiebaLite sends this contract with
    /// the V11 device fields; sending the V12 profile fields here is accepted
    /// by the server but returns an empty data section.
    func v11Common(account: Account?) -> Tieba_CommonRequest {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var request = Tieba_CommonRequest()
        if let bduss = account?.bduss, bduss.isEmpty == false {
            request.bduss = bduss
        }
        request.clientID = clientID
        request.clientType = 2
        request.clientVersion = TieBaXRequestPolicy.officialClientVersion
        request.phoneImei = "000000000000000"
        request.from = "1024324o"
        request.cuid = officialCUID
        request.timestamp = timestamp
        request.model = UIDevice.current.model
        request.netType = 1
        request.pversion = "1.0.3"
        request.osVersion = UIDevice.current.systemVersion
        request.brand = "Apple"
        request.legoLibVersion = "3.0.0"
        if let stoken = account?.stoken, stoken.isEmpty == false {
            request.stoken = stoken
        }
        request.cuidGalaxy2 = officialCUID
        request.cuidGid = ""
        // TiebaLite calls this field c3_aid (not cuid_galaxy3). An opaque,
        // installation-scoped value is sufficient on iOS; no hardware ID is
        // collected or persisted by TieBa-X.
        request.c3Aid = officialAID
        request.sampleID = ""
        // Keep the protobuf message on TiebaLite's V11 contract. V12-only
        // recommendation fields (scr_*, q_type, sdk_ver, framework_ver,
        // swan_game_ver, user_agent, personalized_rec_switch) belong to the
        // V12 common request and can make hotThreadList return an empty data
        // section when sent in this V11 message.
        request.isTeenager = 0
        return request
    }

    /// URL/form fields added by TiebaLite's V11 common-parameter interceptor.
    /// They are part of the multipart envelope, separate from the protobuf
    /// CommonRequest message itself. Keep the names identical to the Android
    /// client (`timestamp` and `c3_aid` are particularly easy to confuse).
    func v11CommonFields(account: Account?) -> [String: String] {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var fields = [
            "_client_id": clientID,
            "_client_type": "2",
            "_phone_imei": "000000000000000",
            "timestamp": "\(timestamp)",
            "model": UIDevice.current.model,
            "net_type": "1",
            "cuid": officialCUID,
            "cuid_galaxy2": officialCUID,
            "cuid_gid": "",
            "from": "tieba",
            "c3_aid": officialAID,
            "oaid": ""
        ]
        if let bduss = account?.bduss, bduss.isEmpty == false {
            fields["BDUSS"] = bduss
        }

        return fields
    }
    /// Common form parameters used by TiebaLite's official JSON API. Keep
    /// these separate from the V11 protobuf envelope because the two clients
    /// use different version/device parameter sets.
    func officialJSONCommonFields(
        bduss: String? = nil,
        baiduID: String? = nil,
        clientVersion: String = TieBaXRequestPolicy.officialJSONClientVersion,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [String: String] {
        var fields = officialCommonFields(
            bduss: bduss,
            baiduID: baiduID,
            clientVersion: clientVersion,
            timestamp: timestamp
        )
        // TiebaLite's official JSON interceptor calls this header/form key
        // `c3_aid`; `cuid_galaxy3` is not a valid substitute on this route.
        fields["cuid"] = officialCUID
        fields["cuid_galaxy2"] = officialCUID
        fields["c3_aid"] = officialAID
        fields["oaid"] = ""
        // TiebaLite base64-encodes its installation-scoped Android ID. Use the same stable representation without reading hardware identifiers on iOS.
        fields["android_id"] = Data(officialIdentitySeed.androidID.utf8).base64EncodedString()
        fields["event_day"] = Self.officialEventDay()
        fields["extra"] = ""
        fields["first_install_time"] = "0"
        fields["framework_ver"] = "3340042"
        fields["last_update_time"] = "0"
        fields["pversion"] = "1.0.3"
        fields["personalized_rec_switch"] = "1"
        fields["q_type"] = "0"
        fields["sample_id"] = ""
        fields["scr_dip"] = "\(screenScale)"
        fields["scr_h"] = "\(screenHeight)"
        fields["scr_w"] = "\(screenWidth)"
        fields["sdk_ver"] = "2.34.0"
        fields["start_scheme"] = ""
        fields["start_type"] = "1"
        fields["swan_game_ver"] = "1038000"
        fields["user_agent"] = "tieba/\(clientVersion)"
        fields["z_id"] = ""
        // The official JSON client runs StParamInterceptor before signing a
        // FormBody. Use its valid no-error branch; omitting the field can make
        // /c/f/forum/like return the profile preview page only.
        fields["stErrorNums"] = "0"
        return fields
    }

    private static func officialEventDay() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMdd"
        return formatter.string(from: Date())
    }
    func miniCommonFields(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        bduss: String? = nil,
        baiduID: String? = nil
    ) -> [String: String] {
        let cuid = miniCUID
        var fields = [
            "_client_id": clientID,
            "_client_type": "2",
            "_client_version": TieBaXRequestPolicy.miniClientVersion,
            "_os_version": UIDevice.current.systemVersion,
            "_phone_imei": "000000000000000",
            "cuid": cuid,
            "cuid_galaxy2": cuid,
            "from": "1021636m",
            "model": UIDevice.current.model,
            "net_type": "1",
            "subapp_type": "mini",
            "timestamp": "\(timestamp)"
        ]
        if let bduss, bduss.isEmpty == false {
            fields["BDUSS"] = bduss
        }
        if let baiduID, baiduID.isEmpty == false {
            fields["baiduid"] = baiduID
        }
        return fields
    }

    func officialCommonFields(
        bduss: String? = nil,
        baiduID: String? = nil,
        clientVersion: String = TieBaXRequestPolicy.officialClientVersion,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [String: String] {
        let cuid = miniCUID
        var fields = [
            "_client_id": clientID,
            "_client_type": "2",
            "_client_version": clientVersion,
            "_os_version": UIDevice.current.systemVersion,
            "_phone_imei": "000000000000000",
            "active_timestamp": "\(timestamp)",
            "brand": "Apple",
            "cmode": "1",
            "cuid": cuid,
            "cuid_galaxy2": cuid,
            "cuid_gid": "",
            "from": "tieba",
            "is_teenager": "0",
            "mac": "02:00:00:00:00:00",
            "model": UIDevice.current.model,
            "net_type": "1",
            "start_scheme": "",
            "start_type": "1",
            "timestamp": "\(timestamp)"
        ]
        if let bduss, bduss.isEmpty == false {
            fields["BDUSS"] = bduss
        }
        if let baiduID, baiduID.isEmpty == false {
            fields["baiduid"] = baiduID
        }
        return fields
    }

    func officialJSONHeaders(
        baiduID: String? = nil,
        clientVersion: String = TieBaXRequestPolicy.officialJSONClientVersion,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        accountUID: String? = nil
    ) -> [String: String] {
        var cookieParts = [
            "CUID=\(officialCUID)",
            "ka=open",
            "TBBRAND=\(UIDevice.current.model)"
        ]
        if let baiduID, baiduID.isEmpty == false {
            cookieParts.append("BAIDUID=\(baiduID)")
        }
        return [
            "Charset": "UTF-8",
            "Cookie": cookieParts.joined(separator: "; "),
            "Pragma": "no-cache",
            "User-Agent": "bdtb for Android \(clientVersion)",
            "client_logid": "\(timestamp)",
            "client_type": "2",
            "client_user_token": accountUID ?? "",
            "cuid": officialCUID,
            "cuid_galaxy2": officialCUID,
            "c3_aid": officialAID,
            "cuid_gid": ""
        ]
    }

    func officialHeaders(
        baiduID: String? = nil,
        clientVersion: String = TieBaXRequestPolicy.officialClientVersion,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [String: String] {
        let cuid = miniCUID
        var cookieParts = [
            "CUID=\(cuid)",
            "ka=open",
            "TBBRAND=\(UIDevice.current.model)"
        ]
        if let baiduID, baiduID.isEmpty == false {
            cookieParts.append("BAIDUID=\(baiduID)")
        }
        return [
            "Charset": "UTF-8",
            "Cookie": cookieParts.joined(separator: "; "),
            "Pragma": "no-cache",
            "User-Agent": "bdtb for Android \(clientVersion)",
            "client_logid": "\(timestamp)",
            "client_type": "2",
            "cuid": cuid,
            "cuid_galaxy2": cuid,
            "cuid_gid": ""
        ]
    }

    /// TiebaLite derives a CUID with a versioned suffix and sends the same
    /// value in the official JSON form and headers. The Helios suffix is not
    /// a normal SHA-1/base32 digest: it is the five-byte CRC/XXHash value used
    /// by `CuidUtils.getNewCuid()`. Reuse the audited implementation from the
    /// posting bootstrap so hot-thread and profile requests have the same
    /// device identity shape as TiebaLite.
    var officialCUID: String {
        let seed = officialIdentitySeed
        return (try? TiebaPostingCrypto.cuidGalaxy2(androidID: seed.androidID))
            ?? legacyOfficialCUID
    }

    /// C3/AID follows TiebaLite's `A00-<sha1>-<helios>` contract. It is
    /// installation-scoped and contains no account credential or hardware ID.
    var officialAID: String {
        let seed = officialIdentitySeed
        return (try? TiebaPostingCrypto.c3AID(androidID: seed.androidID, uuid: seed.uuid))
            ?? legacyOfficialAID
    }

    private var officialIdentitySeed: (androidID: String, uuid: String) {
        let androidDigest = Insecure.MD5.hash(data: Data(("TieBaX.android." + clientID).utf8))
        let androidID = TiebaPostingCrypto.lowercaseHex(androidDigest.prefix(8))

        var uuidBytes = Array(Insecure.SHA1.hash(data: Data(("TieBaX.uuid." + clientID).utf8)).prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        return (androidID, TiebaPostingCrypto.uuidString(bytes: uuidBytes))
    }

    private var legacyOfficialCUID: String {
        let seed = Insecure.MD5.hash(data: Data(clientID.utf8))
            .map { String(format: "%02X", $0) }
            .joined()
        let version = TiebaPostingCrypto.base32(Data(Insecure.SHA1.hash(data: Data(seed.utf8))))
        return "\(seed)|V\(version)"
    }

    private var legacyOfficialAID: String {
        let digest = Insecure.SHA1.hash(data: Data(("com.tieba" + clientID).utf8))
        let raw = "A00-\(TiebaPostingCrypto.base32(Data(digest)))-"
        let signature = TiebaPostingCrypto.base32(Data(Insecure.SHA1.hash(data: Data(raw.utf8))))
        return raw + signature
    }

    var miniCUID: String {
        "\(clientID.uppercased())|000000000000000"
    }

    func multipart<Message: SwiftProtobuf.Message>(
        protobuf: Message,
        account: Account?,
        includeSToken: Bool,
        clientVersion: String? = nil,
        additionalFields: [String: String] = [:],
        signingSecret: String? = nil,
        fileContentType: String? = "application/octet-stream"
    ) throws -> (body: Data, contentType: String) {
        let form = MultipartFormData(boundary: Self.boundary)
        var fields: [String: String] = [:]
        if let clientVersion, clientVersion.isEmpty == false {
            fields["_client_version"] = clientVersion
        }
        if includeSToken, let stoken = account?.stoken {
            fields["stoken"] = stoken
        }
        additionalFields.forEach { name, value in
            fields[name] = value
        }
        if let signingSecret {
            fields["sign"] = TiebaFormSigner.sign(fields: fields, secret: signingSecret)
        }
        fields
            .sorted { $0.key < $1.key }
            .forEach { name, value in
                form.addField(name: name, value: value)
            }
        form.addFile(
            name: "data",
            filename: "file",
            contentType: fileContentType,
            data: try protobuf.serializedData()
        )
        return (form.finalize(), "multipart/form-data; boundary=\(Self.boundary)")
    }
}
