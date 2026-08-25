import Foundation
import XCTest
@testable import TieBaX

final class TieBaXHTTPClientContractTests: XCTestCase {
    override func tearDown() {
        TieBaXHTTPClientURLProtocol.handler = nil
        TieBaXHTTPClientURLProtocol.statusCode = 200
        TieBaXHTTPClientURLProtocol.contentType = "application/json"
        super.tearDown()
    }

    func testGetJSONBuildsEndpointAndDecodesSuccessfulResponse() async throws {
        TieBaXHTTPClientURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "tieba/12.52.1.0 skin/default")
            let components = try XCTUnwrap(request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            })
            XCTAssertEqual(components.path, "/mo/q/search/thread")
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "word" })?.value,
                "TieBa-X + iOS"
            )
            return Data(#"{"value":42}"#.utf8)
        }

        let client = TiebaHTTPClient(session: makeSession())
        let payload = try await client.getJSON(
            .searchThread,
            queryItems: [.init(name: "word", value: "TieBa-X + iOS")],
            as: ContractPayload.self
        )

        XCTAssertEqual(payload, ContractPayload(value: 42))
    }

    func testSignedFormSortsFieldsAndUsesProductAwareDefaultHeaders() async throws {
        TieBaXHTTPClientURLProtocol.contentType = "application/octet-stream"
        TieBaXHTTPClientURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "bdtb for iPhone 12.52.1.0"
            )
            let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
            let parts = body.split(separator: "&").map(String.init)
            XCTAssertEqual(
                parts.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) },
                ["a", "b", "sign"]
            )
            XCTAssertTrue(body.contains("a=one%2Btwo"))
            XCTAssertTrue(body.contains("b=two+words"))
            let expectedSign = TiebaFormSigner.sign(
                fields: ["a": "one+two", "b": "two words"],
                secret: "secret"
            )
            XCTAssertTrue(body.contains("sign=\(expectedSign)"))
            return Data("ok".utf8)
        }

        let client = TiebaHTTPClient(session: makeSession())
        let data = try await client.postFormData(
            .login,
            fields: ["b": "two words", "a": "one+two"],
            signingSecret: "secret"
        )

        XCTAssertEqual(data, Data("ok".utf8))
    }

    func testProtobufRequestUsesExplicitContentTypeAndTieBaXVersion() async throws {
        TieBaXHTTPClientURLProtocol.contentType = "application/octet-stream"
        TieBaXHTTPClientURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/octet-stream"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "tieba/12.52.1.0"
            )
            return Data()
        }

        let client = TiebaHTTPClient(session: makeSession())
        let response = try await client.postProtobuf(
            .pbPage,
            body: Data([0x0A, 0x00]),
            contentType: "application/octet-stream",
            as: Tieba_Error.self
        )

        XCTAssertEqual(response.errorCode, 0)
    }

    func testNonSuccessHTTPStatusPreservesResponseBody() async throws {
        TieBaXHTTPClientURLProtocol.statusCode = 503
        TieBaXHTTPClientURLProtocol.contentType = "text/plain"
        TieBaXHTTPClientURLProtocol.handler = { _ in Data("upstream unavailable".utf8) }

        let client = TiebaHTTPClient(session: makeSession())
        do {
            _ = try await client.getJSON(
                .searchThread,
                queryItems: [],
                as: ContractPayload.self
            )
            XCTFail("Expected HTTP status validation failure")
        } catch let error as TiebaHTTPError {
            XCTAssertEqual(error, .badStatus(code: 503, body: Data("upstream unavailable".utf8)))
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TieBaXHTTPClientURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct ContractPayload: Decodable, Equatable {
    let value: Int
}

private enum TieBaXHTTPClientURLProtocolError: Error {
    case handlerUnavailable
}

private final class TieBaXHTTPClientURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    static var statusCode = 200
    static var contentType = "application/json"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw TieBaXHTTPClientURLProtocolError.handlerUnavailable
            }
            let data = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": Self.contentType,
                    "Content-Length": "\(data.count)"
                ]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
