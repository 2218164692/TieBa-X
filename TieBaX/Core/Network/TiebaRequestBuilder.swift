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
            clientID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        )
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
    /// Keep its common payload explicit: the endpoint otherwise accepts the
    /// request but returns an empty data section when sent the V12 profile.
    func v11Common(account: Account?) -> Tieba_CommonRequest {
        var request = Tieba_CommonRequest()
        request.bduss = account?.bduss ?? ""
        request.clientID = clientID
        request.clientType = 2
        request.clientVersion = TieBaXRequestPolicy.officialClientVersion
        request.phoneImei = "000000000000000"
        request.from = "1024324o"
        request.cuid = clientID
        request.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        request.model = UIDevice.current.model
        request.netType = 1
        request.pversion = "1.0.3"
        request.osVersion = UIDevice.current.systemVersion
        request.brand = "Apple"
        request.legoLibVersion = "3.0.0"
        request.stoken = account?.stoken ?? ""
        request.cuidGalaxy2 = clientID
        request.cuidGid = ""
        request.c3Aid = ""
        request.sampleID = ""
        request.isTeenager = 0
        return request
    }
    /// URL/form fields added by TiebaLite's V11 common-parameter interceptor.
    /// They are part of the multipart envelope, separate from the protobuf
    /// CommonRequest message itself.
    func v11CommonFields(account: Account?) -> [String: String] {
        var fields = [
            "_client_id": clientID,
            "_client_type": "2",
            "_phone_imei": "000000000000000",
            "_timestamp": "\(Int64(Date().timeIntervalSince1970 * 1000))",
            "model": UIDevice.current.model,
            "net_type": "1",
            "cuid": clientID,
            "cuid_galaxy2": clientID,
            "cuid_galaxy3": "",
            "oaid": "",
            "cuid_gid": "",
            "from": "tieba"
        ]
        if let bduss = account?.bduss, bduss.isEmpty == false {
            fields["BDUSS"] = bduss
        }
        return fields
    }
    func miniCommonFields(timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [String: String] {
        let cuid = miniCUID
        return [
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

    func officialHeaders(
        baiduID: String? = nil,
        clientVersion: String = TieBaXRequestPolicy.officialClientVersion,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [String: String] {
        let cuid = miniCUID
        var cookieParts = [
            "CUID=\(cuid)",
            "ka=open",
            "TBBRAND=Apple"
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
