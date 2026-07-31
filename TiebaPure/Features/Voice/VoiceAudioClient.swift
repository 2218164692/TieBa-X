import Foundation

enum VoiceAudioURLPolicy {
    static let host = "tiebac.baidu.com"
    static let path = "/c/p/voice"

    static func normalizedMD5(_ value: String) -> String? {
        guard value.utf8.count == 32,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...70, 97...102:
                      return true
                  default:
                      return false
                  }
              }) else {
            return nil
        }
        return value.lowercased()
    }

    static func url(forMD5 value: String) -> URL? {
        guard let md5 = normalizedMD5(value) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "voice_md5", value: md5),
            URLQueryItem(name: "play_from", value: "pb_voice_play")
        ]
        guard let url = components.url,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}

#if DEBUG
enum VoiceAudioFixturePolicy {
    static let successMD5 = String(repeating: "a", count: 32)
    static let failureMD5 = String(repeating: "b", count: 32)

    static func payload(forMD5 md5: String) async throws -> VoiceAudioPayload? {
        guard let normalized = VoiceAudioURLPolicy.normalizedMD5(md5) else { return nil }
        if normalized == failureMD5 {
            try await Task.sleep(nanoseconds: 80_000_000)
            throw URLError(.cannotDecodeContentData)
        }
        guard normalized == successMD5 else { return nil }
        return VoiceAudioPayload(data: syntheticWAV(), mimeType: "audio/wav")
    }

    private static func syntheticWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let durationMilliseconds: UInt32 = 2_000
        let sampleCount = sampleRate * durationMilliseconds / 1_000
        let bytesPerSample: UInt16 = 2
        let dataByteCount = sampleCount * UInt32(bytesPerSample)

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * UInt32(bytesPerSample))
        data.appendLittleEndian(bytesPerSample)
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        data.append(Data(repeating: 0, count: Int(dataByteCount)))
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
#endif

enum VoiceAudioRedirectPolicy {
    static func allows(_ url: URL?) -> Bool {
        SecureRemoteRedirectScope.baiduHTTPS.allows(url)
    }
}

enum VoiceAudioMIMEPolicy {
    static func allows(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              mimeType.isEmpty == false else {
            return false
        }
        if mimeType == "application/octet-stream" {
            return true
        }
        guard mimeType.hasPrefix("audio/") else { return false }
        return mimeType.dropFirst("audio/".count).isEmpty == false
    }
}

struct VoiceAudioPayload: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

enum VoiceAudioClientError: Error, Equatable {
    case invalidMD5
    case invalidResponse
    case badStatus(Int)
    case invalidMIMEType(String?)
    case emptyAudio
}

extension VoiceAudioClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidMD5:
            return "语音标识无效"
        case .invalidResponse:
            return "语音响应无效"
        case .badStatus:
            return "语音加载失败"
        case .invalidMIMEType:
            return "服务器返回的不是音频"
        case .emptyAudio:
            return "语音内容为空"
        }
    }
}

protocol VoiceAudioLoading: Sendable {
    func load(
        md5: String,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)?
    ) async throws -> VoiceAudioPayload
}

struct VoiceAudioClient: VoiceAudioLoading, Sendable {
    static let shared = VoiceAudioClient()
    static let maximumAudioBytes = 8 * 1_024 * 1_024

    let session: URLSession
    let maximumBytes: Int

    init(
        session: URLSession = VoiceAudioClient.makeSession(),
        maximumBytes: Int = VoiceAudioClient.maximumAudioBytes
    ) {
        precondition((1...VoiceAudioClient.maximumAudioBytes).contains(maximumBytes))
        self.session = session
        self.maximumBytes = maximumBytes
    }

    func load(
        md5: String,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)? = nil
    ) async throws -> VoiceAudioPayload {
        guard let url = VoiceAudioURLPolicy.url(forMD5: md5) else {
            throw VoiceAudioClientError.invalidMD5
        }

#if DEBUG
        if let fixture = try await VoiceAudioFixturePolicy.payload(forMD5: md5) {
            await onProgress?(.init(receivedBytes: 0, expectedBytes: fixture.data.count))
            try await Task.sleep(nanoseconds: 80_000_000)
            await onProgress?(.init(
                receivedBytes: fixture.data.count / 2,
                expectedBytes: fixture.data.count
            ))
            try await Task.sleep(nanoseconds: 80_000_000)
            await onProgress?(.init(
                receivedBytes: fixture.data.count,
                expectedBytes: fixture.data.count
            ))
            return fixture
        }
#endif

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("audio/*, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("tieba/12.52.1.0", forHTTPHeaderField: "User-Agent")

        let (data, rawResponse) = try await BoundedURLSession(session: session).data(
            for: request,
            maximumBytes: maximumBytes,
            responseValidator: { response in
                _ = try Self.validatedMIMEType(in: response)
            },
            onProgress: onProgress
        )
        let mimeType = try Self.validatedMIMEType(in: rawResponse)
        guard data.isEmpty == false else {
            throw VoiceAudioClientError.emptyAudio
        }
        return VoiceAudioPayload(
            data: data,
            mimeType: mimeType
        )
    }

    private static func validatedMIMEType(in rawResponse: URLResponse) throws -> String {
        guard let response = rawResponse as? HTTPURLResponse else {
            throw VoiceAudioClientError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw VoiceAudioClientError.badStatus(response.statusCode)
        }
        let mimeType = response.mimeType?.lowercased()
        guard VoiceAudioMIMEPolicy.allows(mimeType) else {
            throw VoiceAudioClientError.invalidMIMEType(mimeType)
        }
        return mimeType ?? "application/octet-stream"
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    static func makeSession() -> URLSession {
        SecureRemoteURLSession.make(
            configuration: makeConfiguration(),
            redirectScope: .baiduHTTPS
        )
    }
}
