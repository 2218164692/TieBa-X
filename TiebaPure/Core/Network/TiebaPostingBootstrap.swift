import CommonCrypto
import CryptoKit
import Foundation
import Security

struct TiebaPostingIdentitySeed: Codable, Equatable, Sendable {
    let androidID: String
    let uuid: String
    let aesCBCKey: Data

    init(androidID: String, uuid: String, aesCBCKey: Data) throws {
        let normalizedAndroidID = androidID.lowercased()
        guard normalizedAndroidID.utf8.count == 16,
              normalizedAndroidID.utf8.allSatisfy(Self.isLowercaseHex),
              Self.isValidUUID(uuid),
              aesCBCKey.count == kCCKeySizeAES128 else {
            throw TiebaPostingBootstrapError.invalidStoredIdentity
        }
        self.androidID = normalizedAndroidID
        self.uuid = uuid.lowercased()
        self.aesCBCKey = aesCBCKey
    }

    static func generate(randomBytes: @Sendable (Int) throws -> Data) throws -> Self {
        let bytes = try randomBytes(40)
        guard bytes.count == 40 else {
            throw TiebaPostingBootstrapError.randomGenerationFailed
        }
        let androidID = TiebaPostingCrypto.lowercaseHex(bytes.prefix(8))
        var uuidBytes = Array(bytes[8..<24])
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        let uuid = TiebaPostingCrypto.uuidString(bytes: uuidBytes)
        return try Self(
            androidID: androidID,
            uuid: uuid,
            aesCBCKey: Data(bytes[24..<40])
        )
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }

    private static func isValidUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        let bytes = Array(value.lowercased().utf8)
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == 45 else { return false }
            } else if isLowercaseHex(byte) == false {
                return false
            }
        }
        return true
    }
}

struct TiebaPostingIdentity: Equatable, Sendable {
    let androidID: String
    let uuid: String
    let cuidGalaxy2: String
    let c3AID: String
}

struct TiebaPostingBootstrapResult: Equatable, Sendable {
    let identity: TiebaPostingIdentity
    let clientID: String
    let sampleID: String
    let zID: String
}

protocol TiebaPostingBootstrapping: Sendable {
    func bootstrap(bduss: String) async throws -> TiebaPostingBootstrapResult
}

enum TiebaPostingBootstrapError: Error, Equatable, LocalizedError, Sendable {
    case invalidCredential
    case invalidStoredIdentity
    case identityPersistenceFailed
    case randomGenerationFailed
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge(limit: Int)
    case badHTTPStatus(Int)
    case server(code: Int, message: String)
    case missingField(String)
    case invalidField(String)
    case invalidBase64
    case invalidCiphertext
    case cryptoFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "登录凭证无效，无法初始化发布身份。"
        case .invalidStoredIdentity:
            return "发布身份数据已损坏。"
        case .identityPersistenceFailed:
            return "发布身份无法安全保存。"
        case .randomGenerationFailed:
            return "无法生成安全的发布身份。"
        case .invalidEndpoint:
            return "发布身份服务地址无效。"
        case .invalidResponse:
            return "发布身份服务返回了无效响应。"
        case let .responseTooLarge(limit):
            return "发布身份响应超过 \(limit) 字节上限。"
        case let .badHTTPStatus(status):
            return "发布身份服务返回 HTTP \(status)。"
        case let .server(code, message):
            return message.isEmpty ? "发布身份服务错误（\(code)）。" : message
        case let .missingField(field):
            return "发布身份响应缺少 \(field)。"
        case let .invalidField(field):
            return "发布身份响应中的 \(field) 无效。"
        case .invalidBase64:
            return "发布身份响应包含无效编码。"
        case .invalidCiphertext:
            return "发布身份响应无法解密。"
        case .cryptoFailure:
            return "发布身份加密处理失败。"
        }
    }
}

protocol TiebaPostingIdentityPersisting: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

actor KeychainTiebaPostingIdentityStore: TiebaPostingIdentityPersisting {
    private let service: String
    private let account: String

    init(
        service: String = "com.tiebax.posting-identity",
        account: String = "stable-device-v1"
    ) {
        self.service = service
        self.account = account
    }

    func load() async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count <= TiebaPostingBootstrap.maximumStoredIdentityBytes else {
            throw TiebaPostingBootstrapError.identityPersistenceFailed
        }
        return data
    }

    func save(_ data: Data) async throws {
        guard data.count <= TiebaPostingBootstrap.maximumStoredIdentityBytes else {
            throw TiebaPostingBootstrapError.identityPersistenceFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TiebaPostingBootstrapError.identityPersistenceFailed
        }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw TiebaPostingBootstrapError.identityPersistenceFailed
        }
    }
}

protocol TiebaPostingBootstrapTransport: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTiebaPostingBootstrapTransport: TiebaPostingBootstrapTransport, @unchecked Sendable {
    let session: URLSession

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard maximumBytes > 0 else { throw TiebaPostingBootstrapError.invalidResponse }
        try Task.checkCancellation()
        let dataAndResponse: (Data, URLResponse)
        if #available(iOS 15.0, *) {
            do {
                let (bytes, rawResponse) = try await session.bytes(for: request)
                if rawResponse.expectedContentLength > Int64(maximumBytes) {
                    throw TiebaPostingBootstrapError.responseTooLarge(limit: maximumBytes)
                }
                var streamedData = Data()
                if rawResponse.expectedContentLength > 0 {
                    streamedData.reserveCapacity(min(Int(rawResponse.expectedContentLength), maximumBytes))
                }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard streamedData.count < maximumBytes else {
                        throw TiebaPostingBootstrapError.responseTooLarge(limit: maximumBytes)
                    }
                    streamedData.append(byte)
                }
                dataAndResponse = (streamedData, rawResponse)
            } catch where Task.isCancelled {
                throw CancellationError()
            }
        } else {
            do {
                dataAndResponse = try await TieBaXURLSessionCompat.data(for: request, in: session)
            } catch where Task.isCancelled {
                throw CancellationError()
            }
            guard dataAndResponse.0.count <= maximumBytes else {
                throw TiebaPostingBootstrapError.responseTooLarge(limit: maximumBytes)
            }
        }
        let (data, response) = dataAndResponse
        guard let http = response as? HTTPURLResponse else {
            throw TiebaPostingBootstrapError.invalidResponse
        }
        try Task.checkCancellation()
        return (data, http)
    }
}

private final class TiebaPostingNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct TiebaPostingBootstrapEndpoints: Equatable, Sendable {
    let syncURL: URL
    let zIDBaseURL: URL

    static let production = TiebaPostingBootstrapEndpoints(
        syncURL: URL(string: "https://tiebac.baidu.com/c/s/sync")!,
        zIDBaseURL: URL(string: "https://sofire.baidu.com")!
    )
}

actor TiebaPostingBootstrap: TiebaPostingBootstrapping {
    static let maximumStoredIdentityBytes = 4 * 1_024
    // The sync payload contains a compressed server configuration whose decoded
    // JSON currently exceeds 128 KiB for real accounts. Keep a dedicated bound
    // well below the general API ceiling while allowing that valid response.
    static let maximumSyncResponseBytes = 1 * 1_024 * 1_024
    static let maximumZIDResponseBytes = 64 * 1_024

    private static let currentClientVersion = "22.5.1.0"
    private static let stableClientVersion = "12.64.1.1"
    private static let sofireAppKey = "200033"
    private static let sofireVersion = "4.4.1.3"
    private static let sofireSecret = "ea737e4f435b53786043369d2e5ace4f"
    private static let appSigningSalt = "tiebaclient!!!"

    private let store: any TiebaPostingIdentityPersisting
    private let transport: any TiebaPostingBootstrapTransport
    private let endpoints: TiebaPostingBootstrapEndpoints
    private let randomBytes: @Sendable (Int) throws -> Data
    private let now: @Sendable () -> Date

    init(
        store: any TiebaPostingIdentityPersisting,
        transport: any TiebaPostingBootstrapTransport,
        endpoints: TiebaPostingBootstrapEndpoints = .production,
        randomBytes: @escaping @Sendable (Int) throws -> Data = { count in
            try TiebaPostingBootstrap.secureRandomBytes(count: count)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.transport = transport
        self.endpoints = endpoints
        self.randomBytes = randomBytes
        self.now = now
    }

    static func live() -> TiebaPostingBootstrap {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(
            configuration: configuration,
            delegate: TiebaPostingNoRedirectDelegate(),
            delegateQueue: nil
        )
        return TiebaPostingBootstrap(
            store: KeychainTiebaPostingIdentityStore(),
            transport: URLSessionTiebaPostingBootstrapTransport(session: session)
        )
    }

    func identity() async throws -> TiebaPostingIdentity {
        try await resolvedIdentity().identity
    }

    func bootstrap(bduss: String) async throws -> TiebaPostingBootstrapResult {
        let credential = bduss.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credential.isEmpty == false,
              credential.utf8.count <= 4_096,
              credential.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value != 0x7f }) else {
            throw TiebaPostingBootstrapError.invalidCredential
        }
        try Task.checkCancellation()
        let resolved = try await resolvedIdentity()
        let timestamp = Int64(now().timeIntervalSince1970.rounded(.down))
        guard timestamp > 0 else { throw TiebaPostingBootstrapError.invalidField("timestamp") }

        async let sync = Self.fetchSync(
            bduss: credential,
            cuidGalaxy2: resolved.identity.cuidGalaxy2,
            endpoint: endpoints.syncURL,
            transport: transport
        )
        async let zID = Self.fetchZID(
            seed: resolved.seed,
            timestamp: timestamp,
            baseURL: endpoints.zIDBaseURL,
            transport: transport
        )
        let ((clientID, sampleID), fetchedZID) = try await (sync, zID)
        try Task.checkCancellation()
        return TiebaPostingBootstrapResult(
            identity: resolved.identity,
            clientID: clientID,
            sampleID: sampleID,
            zID: fetchedZID
        )
    }

    private func resolvedIdentity() async throws -> (seed: TiebaPostingIdentitySeed, identity: TiebaPostingIdentity) {
        try Task.checkCancellation()
        let seed: TiebaPostingIdentitySeed
        if let stored = try await store.load() {
            do {
                let decoded = try JSONDecoder().decode(TiebaPostingIdentitySeed.self, from: stored)
                seed = try TiebaPostingIdentitySeed(
                    androidID: decoded.androidID,
                    uuid: decoded.uuid,
                    aesCBCKey: decoded.aesCBCKey
                )
            } catch {
                throw TiebaPostingBootstrapError.invalidStoredIdentity
            }
        } else {
            seed = try TiebaPostingIdentitySeed.generate(randomBytes: randomBytes)
            let encoded: Data
            do {
                encoded = try JSONEncoder().encode(seed)
            } catch {
                throw TiebaPostingBootstrapError.identityPersistenceFailed
            }
            do {
                try await store.save(encoded)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TiebaPostingBootstrapError.identityPersistenceFailed
            }
        }
        try Task.checkCancellation()
        return (seed, try Self.deriveIdentity(from: seed))
    }

    static func deriveIdentity(from seed: TiebaPostingIdentitySeed) throws -> TiebaPostingIdentity {
        TiebaPostingIdentity(
            androidID: seed.androidID,
            uuid: seed.uuid,
            cuidGalaxy2: try TiebaPostingCrypto.cuidGalaxy2(androidID: seed.androidID),
            c3AID: try TiebaPostingCrypto.c3AID(androidID: seed.androidID, uuid: seed.uuid)
        )
    }

    private static func fetchSync(
        bduss: String,
        cuidGalaxy2: String,
        endpoint: URL,
        transport: any TiebaPostingBootstrapTransport
    ) async throws -> (String, String) {
        try validateHTTPS(endpoint, host: "tiebac.baidu.com", path: "/c/s/sync")
        var fields = [
            ("BDUSS", bduss),
            ("_client_version", currentClientVersion),
            ("cuid", cuidGalaxy2)
        ]
        fields.append(("sign", TiebaPostingCrypto.formSignature(fields: fields, salt: appSigningSalt)))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = TiebaPostingCrypto.formBody(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("TieBaX/\(currentClientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        try Task.checkCancellation()
        let (data, response) = try await transport.data(
            for: request,
            maximumBytes: maximumSyncResponseBytes
        )
        try validateHTTP(response)
        let object = try jsonObject(data)
        let code = flexibleInt(object["error_code"])
        guard let code else { throw TiebaPostingBootstrapError.missingField("error_code") }
        if code != 0 {
            throw TiebaPostingBootstrapError.server(
                code: code,
                message: flexibleString(object["error_msg"]) ?? ""
            )
        }
        guard let client = object["client"] as? [String: Any] else {
            throw TiebaPostingBootstrapError.missingField("client")
        }
        guard let config = object["wl_config"] as? [String: Any] else {
            throw TiebaPostingBootstrapError.missingField("wl_config")
        }
        let clientID = try validatedServerValue(client["client_id"], field: "client_id", maximumBytes: 512)
        let sampleID = try validatedServerValue(config["sample_id"], field: "sample_id", maximumBytes: 8_192)
        return (clientID, sampleID)
    }

    private static func fetchZID(
        seed: TiebaPostingIdentitySeed,
        timestamp: Int64,
        baseURL: URL,
        transport: any TiebaPostingBootstrapTransport
    ) async throws -> String {
        try validateHTTPS(baseURL, host: "sofire.baidu.com", path: nil)
        let xyus = TiebaPostingCrypto.uppercaseMD5Hex(Data((seed.androidID + seed.uuid).utf8)) + "|0"
        let deviceID = TiebaPostingCrypto.lowercaseMD5Hex(Data(xyus.utf8))
        let json = Data("{\"module_section\":[{\"zid\":\"\(xyus)\"}]}".utf8)
        let compressed = TiebaPostingCrypto.gzipStored(json)
        let encrypted = try TiebaPostingCrypto.aesCBCEncryptPKCS7(compressed, key: seed.aesCBCKey)
        let body = encrypted + TiebaPostingCrypto.md5(compressed)
        let wrappedKey = TiebaPostingCrypto.rc442(key: Data(deviceID.utf8), input: seed.aesCBCKey)
        let pathDigest = TiebaPostingCrypto.lowercaseMD5Hex(
            Data((sofireAppKey + String(timestamp) + sofireSecret).utf8)
        )

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TiebaPostingBootstrapError.invalidEndpoint
        }
        components.path = "/c/11/z/100/\(sofireAppKey)/\(timestamp)/\(pathDigest)"
        components.queryItems = [URLQueryItem(name: "skey", value: wrappedKey.base64EncodedString())]
        guard let url = components.url else { throw TiebaPostingBootstrapError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("x6/\(sofireAppKey)/\(stableClientVersion)/\(sofireVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("x6/\(sofireVersion)", forHTTPHeaderField: "x-plu-ver")
        request.setValue(deviceID, forHTTPHeaderField: "x-device-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        try Task.checkCancellation()
        let (data, response) = try await transport.data(
            for: request,
            maximumBytes: maximumZIDResponseBytes
        )
        try validateHTTP(response)
        let object = try jsonObject(data)
        let responseWrappedKey = try decodedBase64(object["skey"], field: "skey", maximumBytes: 64)
        guard responseWrappedKey.count == kCCKeySizeAES128 else {
            throw TiebaPostingBootstrapError.invalidField("skey")
        }
        let responseKey = TiebaPostingCrypto.rc442(key: Data(deviceID.utf8), input: responseWrappedKey)
        let ciphertext = try decodedBase64(
            object["data"],
            field: "data",
            maximumBytes: maximumZIDResponseBytes
        )
        guard ciphertext.count >= 32,
              ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw TiebaPostingBootstrapError.invalidCiphertext
        }
        let decrypted = try TiebaPostingCrypto.aesCBCDecryptRaw(ciphertext, key: responseKey)
        guard decrypted.count >= 32 else {
            throw TiebaPostingBootstrapError.invalidCiphertext
        }
        // Sofire appends an opaque 16-byte suffix. It is not a keyed MAC and
        // live responses do not consistently contain MD5(unpadded JSON).
        let paddedJSON = decrypted.dropLast(16)
        let responseJSON = try TiebaPostingCrypto.removePKCS7Padding(Data(paddedJSON))
        let responseObject = try jsonObject(responseJSON)
        return try validatedServerValue(responseObject["token"], field: "token", maximumBytes: 4_096)
    }

    private static func validateHTTPS(_ url: URL, host: String, path: String?) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.user == nil,
              url.password == nil,
              path.map({ url.path == $0 }) ?? true else {
            throw TiebaPostingBootstrapError.invalidEndpoint
        }
    }

    private static func validateHTTP(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw TiebaPostingBootstrapError.badHTTPStatus(response.statusCode)
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard data.isEmpty == false,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw TiebaPostingBootstrapError.invalidResponse
        }
        return dictionary
    }

    private static func flexibleInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func flexibleString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func validatedServerValue(
        _ value: Any?,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        guard let string = flexibleString(value)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw TiebaPostingBootstrapError.missingField(field)
        }
        guard string.isEmpty == false,
              string.utf8.count <= maximumBytes,
              string.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw TiebaPostingBootstrapError.invalidField(field)
        }
        return string
    }

    private static func decodedBase64(
        _ value: Any?,
        field: String,
        maximumBytes: Int
    ) throws -> Data {
        guard let raw = value as? String else {
            throw TiebaPostingBootstrapError.missingField(field)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= ((maximumBytes + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: trimmed),
              data.count <= maximumBytes else {
            throw TiebaPostingBootstrapError.invalidBase64
        }
        return data
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw TiebaPostingBootstrapError.randomGenerationFailed
        }
        return Data(bytes)
    }
}

enum TiebaPostingCrypto {
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func lowercaseMD5Hex(_ data: Data) -> String {
        lowercaseHex(md5(data))
    }

    static func uppercaseMD5Hex(_ data: Data) -> String {
        md5(data).map { String(format: "%02X", $0) }.joined()
    }

    static func lowercaseHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func uuidString(bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        let hex = lowercaseHex(bytes)
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    static func base32(_ data: Data) -> String {
        guard data.isEmpty == false else { return "" }
        var output = [UInt8]()
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                output.append(base32Alphabet[Int((buffer >> UInt32(bitsLeft - 5)) & 0x1f)])
                bitsLeft -= 5
            }
        }
        if bitsLeft > 0 {
            output.append(base32Alphabet[Int((buffer << UInt32(5 - bitsLeft)) & 0x1f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func cuidGalaxy2(androidID: String) throws -> String {
        guard androidID.utf8.count == 16 else {
            throw TiebaPostingBootstrapError.invalidStoredIdentity
        }
        let digest = md5(Data(("com.baidu" + androidID).utf8))
        let prefix = digest.map { String(format: "%02X", $0) }.joined()
        return prefix + "|V" + base32(heliosHash(Data(prefix.utf8)))
    }

    static func c3AID(androidID: String, uuid: String) throws -> String {
        guard androidID.utf8.count == 16, uuid.utf8.count == 36 else {
            throw TiebaPostingBootstrapError.invalidStoredIdentity
        }
        let sha1 = Data(Insecure.SHA1.hash(data: Data(("com.helios" + androidID + uuid).utf8)))
        let prefix = "A00-" + base32(sha1) + "-"
        return prefix + base32(heliosHash(Data(prefix.utf8)))
    }

    static func heliosHash(_ data: Data) -> Data {
        let first = Data(repeating: 0xff, count: 5)
        var buffer = first
        var section: UInt64 = (1 << 40) - 1

        var crc = crc32(data)
        crc = crc32(first, previous: crc)
        updateSection(&section, hash: crc, start: 8, xor: false)
        buffer.append(sectionBytes(section))

        let secondHash = xxHash32(data + buffer)
        updateSection(&section, hash: secondHash, start: 0, xor: true)
        buffer.append(sectionBytes(section))

        let thirdHash = xxHash32(data + buffer)
        updateSection(&section, hash: thirdHash, start: 1, xor: true)
        buffer.append(sectionBytes(section))

        crc = crc32(Data(buffer.dropFirst(5)), previous: crc)
        updateSection(&section, hash: crc, start: 7, xor: true)
        return sectionBytes(section)
    }

    static func rc442(key: Data, input: Data) -> Data {
        guard key.isEmpty == false else { return Data() }
        var state = Array(UInt8.min...UInt8.max)
        let keyBytes = Array(key)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(state[i]) + Int(keyBytes[i % keyBytes.count])) & 0xff
            state.swapAt(i, j)
        }
        var x = 0
        var y = 0
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        for byte in input {
            x = (x + 1) & 0xff
            let a = state[x]
            y = (y + Int(a)) & 0xff
            let b = state[y]
            state[x] = b
            state[y] = a
            output.append(byte ^ state[(Int(a) + Int(b)) & 0xff] ^ 42)
        }
        return Data(output)
    }

    static func formSignature(fields: [(String, String)], salt: String) -> String {
        let source = fields
            .sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined() + salt
        return lowercaseMD5Hex(Data(source.utf8))
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&").utf8)
    }

    static func gzipStored(_ data: Data) -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        if data.isEmpty {
            output.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
        } else {
            var offset = 0
            while offset < data.count {
                let length = min(65_535, data.count - offset)
                let isFinal = offset + length == data.count
                output.append(isFinal ? 0x01 : 0x00)
                let value = UInt16(length)
                let inverse = ~value
                output.append(UInt8(value & 0xff))
                output.append(UInt8(value >> 8))
                output.append(UInt8(inverse & 0xff))
                output.append(UInt8(inverse >> 8))
                output.append(data[offset..<(offset + length)])
                offset += length
            }
        }
        appendLittleEndian(crc32(data), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &output)
        return output
    }

    static func aesCBCEncryptPKCS7(_ data: Data, key: Data) throws -> Data {
        try crypt(data, key: key, operation: CCOperation(kCCEncrypt), options: CCOptions(kCCOptionPKCS7Padding))
    }

    static func aesCBCEncryptRaw(_ data: Data, key: Data) throws -> Data {
        guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw TiebaPostingBootstrapError.invalidCiphertext
        }
        return try crypt(data, key: key, operation: CCOperation(kCCEncrypt), options: 0)
    }

    static func aesCBCDecryptRaw(_ data: Data, key: Data) throws -> Data {
        guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw TiebaPostingBootstrapError.invalidCiphertext
        }
        return try crypt(data, key: key, operation: CCOperation(kCCDecrypt), options: 0)
    }

    static func addPKCS7Padding(_ data: Data) -> Data {
        let count = kCCBlockSizeAES128 - (data.count % kCCBlockSizeAES128)
        return data + Data(repeating: UInt8(count), count: count)
    }

    static func removePKCS7Padding(_ data: Data) throws -> Data {
        guard let last = data.last,
              last > 0,
              Int(last) <= kCCBlockSizeAES128,
              data.count >= Int(last),
              data.suffix(Int(last)).allSatisfy({ $0 == last }) else {
            throw TiebaPostingBootstrapError.invalidCiphertext
        }
        return data.dropLast(Int(last))
    }

    private static func crypt(
        _ data: Data,
        key: Data,
        operation: CCOperation,
        options: CCOptions
    ) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw TiebaPostingBootstrapError.invalidStoredIdentity
        }
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let status = key.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { inputBuffer in
                iv.withUnsafeBytes { ivBuffer in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBuffer.baseAddress,
                        key.count,
                        ivBuffer.baseAddress,
                        inputBuffer.baseAddress,
                        data.count,
                        &output,
                        output.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw TiebaPostingBootstrapError.cryptoFailure(status)
        }
        return Data(output.prefix(moved))
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }

    private static func crc32(_ data: Data, previous: UInt32 = 0) -> UInt32 {
        var crc = ~previous
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0)
            }
        }
        return ~crc
    }

    private static func xxHash32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        let bytes = Array(data)
        var index = 0
        var hash: UInt32
        if bytes.count >= 16 {
            var v1 = seed &+ 0x9e37_79b1 &+ 0x85eb_ca77
            var v2 = seed &+ 0x85eb_ca77
            var v3 = seed
            var v4 = seed &- 0x9e37_79b1
            while index <= bytes.count - 16 {
                v1 = xxRound(v1, readUInt32LE(bytes, index)); index += 4
                v2 = xxRound(v2, readUInt32LE(bytes, index)); index += 4
                v3 = xxRound(v3, readUInt32LE(bytes, index)); index += 4
                v4 = xxRound(v4, readUInt32LE(bytes, index)); index += 4
            }
            hash = rotateLeft(v1, 1) &+ rotateLeft(v2, 7) &+ rotateLeft(v3, 12) &+ rotateLeft(v4, 18)
        } else {
            hash = seed &+ 0x1656_67b1
        }
        hash &+= UInt32(truncatingIfNeeded: bytes.count)
        while index <= bytes.count - 4 {
            hash &+= readUInt32LE(bytes, index) &* 0xc2b2_ae3d
            hash = rotateLeft(hash, 17) &* 0x27d4_eb2f
            index += 4
        }
        while index < bytes.count {
            hash &+= UInt32(bytes[index]) &* 0x1656_67b1
            hash = rotateLeft(hash, 11) &* 0x9e37_79b1
            index += 1
        }
        hash ^= hash >> 15
        hash &*= 0x85eb_ca77
        hash ^= hash >> 13
        hash &*= 0xc2b2_ae3d
        hash ^= hash >> 16
        return hash
    }

    private static func xxRound(_ accumulator: UInt32, _ input: UInt32) -> UInt32 {
        rotateLeft(accumulator &+ input &* 0x85eb_ca77, 13) &* 0x9e37_79b1
    }

    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func updateSection(
        _ section: inout UInt64,
        hash: UInt32,
        start: UInt64,
        xor: Bool
    ) {
        let mask = (UInt64(1) << (start + 32)) - 1
        var value = (mask & section) >> start
        value = xor ? value ^ UInt64(hash) : value & UInt64(hash)
        let fieldMask = UInt64(UInt32.max) << start
        section = (section & ~fieldMask) | ((value & UInt64(UInt32.max)) << start)
        section &= (1 << 40) - 1
    }

    private static func sectionBytes(_ section: UInt64) -> Data {
        Data((0..<5).map { UInt8((section >> UInt64($0 * 8)) & 0xff) })
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
