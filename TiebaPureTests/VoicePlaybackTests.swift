import AVFoundation
import UIKit
import XCTest
@testable import TiebaPure

final class VoiceAudioClientTests: XCTestCase {
    private let md5 = String(repeating: "c", count: 32)

    override func setUp() {
        super.setUp()
        VoiceAudioURLProtocol.reset()
    }

    override func tearDown() {
        VoiceAudioURLProtocol.reset()
        super.tearDown()
    }

    func testURLPolicyNormalizesHexAndBuildsOnlyFixedEndpoint() throws {
        let uppercase = "0123456789ABCDEF0123456789ABCDEF"
        let expected = "0123456789abcdef0123456789abcdef"

        XCTAssertEqual(VoiceAudioURLPolicy.normalizedMD5(uppercase), expected)
        let url = try XCTUnwrap(VoiceAudioURLPolicy.url(forMD5: uppercase))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "tiebac.baidu.com")
        XCTAssertEqual(components.path, "/c/p/voice")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "voice_md5", value: expected),
            URLQueryItem(name: "play_from", value: "pb_voice_play")
        ])
    }

    func testURLPolicyRejectsNonCanonicalAndInjectedValues() {
        let candidates = [
            String(repeating: "a", count: 31),
            String(repeating: "a", count: 33),
            String(repeating: "g", count: 32),
            String(repeating: "a", count: 31) + "&",
            String(repeating: "a", count: 32) + "&play_from=attacker",
            String(repeating: "a", count: 31) + "?",
            " " + String(repeating: "a", count: 32),
            String(repeating: "a", count: 31) + "é"
        ]

        for candidate in candidates {
            XCTAssertNil(VoiceAudioURLPolicy.normalizedMD5(candidate), candidate)
            XCTAssertNil(VoiceAudioURLPolicy.url(forMD5: candidate), candidate)
        }
    }

    func testRedirectPolicyAllowsOnlyPublicBaiduHTTPS() {
        XCTAssertTrue(VoiceAudioRedirectPolicy.allows(
            URL(string: "https://tiebac.baidu.com/c/p/voice")
        ))
        XCTAssertTrue(VoiceAudioRedirectPolicy.allows(
            URL(string: "https://c.tieba.baidu.com/c/p/voice")
        ))
        XCTAssertFalse(VoiceAudioRedirectPolicy.allows(
            URL(string: "http://tiebac.baidu.com/c/p/voice")
        ))
        XCTAssertFalse(VoiceAudioRedirectPolicy.allows(
            URL(string: "https://baidu.com.attacker.example/voice")
        ))
        XCTAssertFalse(VoiceAudioRedirectPolicy.allows(
            URL(string: "https://127.0.0.1/voice")
        ))
    }

    func testSessionConfigurationDoesNotPersistCookiesCacheOrCredentials() {
        let configuration = VoiceAudioClient.makeConfiguration()

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testClientAcceptsAudioAndOctetStreamMIMETypes() async throws {
        for mimeType in ["audio/mpeg", "audio/amr", "application/octet-stream"] {
            VoiceAudioURLProtocol.mimeType = mimeType
            VoiceAudioURLProtocol.payload = Data([0x01, 0x02, 0x03])
            let payload = try await makeClient().load(md5: md5, onProgress: nil)

            XCTAssertEqual(payload.data, VoiceAudioURLProtocol.payload)
            XCTAssertEqual(payload.mimeType, mimeType)
            XCTAssertEqual(VoiceAudioURLProtocol.lastRequest?.url?.host, "tiebac.baidu.com")
            XCTAssertEqual(
                VoiceAudioURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept"),
                "audio/*, application/octet-stream"
            )
        }
    }

    func testClientRejectsInvalidMD5BeforeStartingNetworkRequest() async throws {
        do {
            _ = try await makeClient().load(
                md5: String(repeating: "c", count: 31) + "&",
                onProgress: nil
            )
            XCTFail("Expected invalid MD5")
        } catch {
            XCTAssertEqual(error as? VoiceAudioClientError, .invalidMD5)
        }
        XCTAssertNil(VoiceAudioURLProtocol.lastRequest)
    }

    func testClientRejectsHTMLAndMissingMIMEType() async throws {
        let progressRecorder = VoiceProgressRecorder()
        for mimeType in ["text/html", "application/json", "audio/", ""] {
            VoiceAudioURLProtocol.mimeType = mimeType
            VoiceAudioURLProtocol.payload = Data("not audio".utf8)
            do {
                _ = try await makeClient().load(md5: md5) { _ in
                    await progressRecorder.record()
                }
                XCTFail("Expected MIME rejection for \(mimeType)")
            } catch {
                guard let clientError = error as? VoiceAudioClientError,
                      case .invalidMIMEType = clientError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        let progressCount = await progressRecorder.count()
        XCTAssertEqual(progressCount, 0, "响应头无效时不得开始流式读取")
    }

    func testClientRejectsDeclaredAndStreamedOverflow() async throws {
        VoiceAudioURLProtocol.mimeType = "audio/mpeg"
        VoiceAudioURLProtocol.payload = Data(repeating: 0x01, count: 9)
        VoiceAudioURLProtocol.declaredContentLength = 9
        do {
            _ = try await makeClient(maximumBytes: 8).load(md5: md5, onProgress: nil)
            XCTFail("Expected declared response limit")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: 8))
        }

        VoiceAudioURLProtocol.declaredContentLength = nil
        do {
            _ = try await makeClient(maximumBytes: 8).load(md5: md5, onProgress: nil)
            XCTFail("Expected streamed response limit")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: 8))
        }
    }

    func testClientRejectsBadStatusAndEmptyAudio() async throws {
        let progressRecorder = VoiceProgressRecorder()
        VoiceAudioURLProtocol.statusCode = 503
        VoiceAudioURLProtocol.mimeType = "audio/mpeg"
        VoiceAudioURLProtocol.payload = Data([0x01])
        do {
            _ = try await makeClient().load(md5: md5) { _ in
                await progressRecorder.record()
            }
            XCTFail("Expected status failure")
        } catch {
            XCTAssertEqual(error as? VoiceAudioClientError, .badStatus(503))
        }
        let rejectedProgressCount = await progressRecorder.count()
        XCTAssertEqual(rejectedProgressCount, 0, "错误状态码不得开始流式读取")

        VoiceAudioURLProtocol.statusCode = 200
        VoiceAudioURLProtocol.payload = Data()
        do {
            _ = try await makeClient().load(md5: md5, onProgress: nil)
            XCTFail("Expected empty response failure")
        } catch {
            XCTAssertEqual(error as? VoiceAudioClientError, .emptyAudio)
        }
    }

    private func makeClient(maximumBytes: Int = VoiceAudioClient.maximumAudioBytes) -> VoiceAudioClient {
        let configuration = VoiceAudioClient.makeConfiguration()
        configuration.protocolClasses = [VoiceAudioURLProtocol.self]
        return VoiceAudioClient(
            session: URLSession(configuration: configuration),
            maximumBytes: maximumBytes
        )
    }
}

@MainActor
final class VoicePlaybackCoordinatorTests: XCTestCase {
    private let firstMD5 = String(repeating: "c", count: 32)
    private let secondMD5 = String(repeating: "d", count: 32)

#if DEBUG
    func testDebugFixtureWAVIsDecodableAndLongEnoughForUITestInteraction() async throws {
        let fixture = try await VoiceAudioFixturePolicy.payload(
            forMD5: VoiceAudioFixturePolicy.successMD5
        )
        let payload = try XCTUnwrap(fixture)
        let player = try SystemVoiceAudioPlayerFactory().makePlayer(data: payload.data)

        XCTAssertGreaterThanOrEqual(player.duration, 1.9)
        XCTAssertLessThanOrEqual(player.duration, 2.1)
        player.stop()
    }
#endif

    func testCoordinatorDoesNotLoadBeforeUserAction() async {
        let loader = ControlledVoiceAudioLoader()
        _ = makeCoordinator(loader: loader)

        await Task.yield()
        let requestedKeys = await loader.requestedKeys()
        XCTAssertEqual(requestedKeys, [])
    }

    func testBackgroundCancelsLoadingAndLateResponseCannotStartPlayback() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        coordinator.handleApplicationDidEnterBackground()
        XCTAssertEqual(coordinator.state, .idle)

        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(playerFactory.players.isEmpty)
        XCTAssertEqual(audioSession.activationCount, 0)
        XCTAssertEqual(audioSession.deactivationCount, 0)
    }

    func testBackgroundNotificationSynchronouslyCancelsLoading() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let notificationCenter = NotificationCenter()
        let coordinator = VoicePlaybackCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession,
            notificationCenter: notificationCenter,
            observesSystemEvents: true
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        notificationCenter.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        XCTAssertEqual(coordinator.state, .idle)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(playerFactory.players.isEmpty)
        XCTAssertEqual(audioSession.activationCount, 0)
    }

    func testInterruptionCancelsLoadingAndLateResponseCannotStartPlayback() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        coordinator.handleInterruptionBegan()
        XCTAssertEqual(coordinator.state, .idle)

        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(playerFactory.players.isEmpty)
        XCTAssertEqual(audioSession.activationCount, 0)
        XCTAssertEqual(audioSession.deactivationCount, 0)
    }

    func testMissingInterruptionEndAfterLoadingCanRetryUntilActivationSucceeds() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        coordinator.handleInterruptionBegan()
        XCTAssertEqual(coordinator.state, .idle)

        audioSession.failNextActivation()
        coordinator.toggle(md5: secondMD5)
        try await waitForRequest(secondMD5, count: 1, loader: loader)
        await loader.succeed(md5: secondMD5, data: Data([0x01]))
        try await waitForPhase(.failed, key: secondMD5, coordinator: coordinator)

        coordinator.retry(md5: secondMD5)
        try await waitForRequest(secondMD5, count: 2, loader: loader)
        await loader.succeed(md5: secondMD5, data: Data([0x02]))
        try await waitForPhase(.playing, key: secondMD5, coordinator: coordinator)

        coordinator.toggle(md5: secondMD5)
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(audioSession.activationCount, 2)
    }

    func testHeadphoneRemovalCancelsLoadingAndLateResponseCannotStartPlayback() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        coordinator.handleRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertEqual(coordinator.state, .idle)

        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(playerFactory.players.isEmpty)
        XCTAssertEqual(audioSession.activationCount, 0)
        XCTAssertEqual(audioSession.deactivationCount, 0)
    }

    func testHeadphoneRemovalDuringInterruptionPreventsSpeakerResume() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )
        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)
        let player = try XCTUnwrap(playerFactory.players.first)

        coordinator.handleInterruptionBegan()
        XCTAssertEqual(coordinator.state.phase, .paused)
        coordinator.handleRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertEqual(audioSession.deactivationCount, 1)

        coordinator.handleInterruptionEnded(shouldResume: true)
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(audioSession.activationCount, 1)
        XCTAssertEqual(audioSession.deactivationCount, 1)
    }

    func testVideoPlaybackStartCancelsLoadingAndLateResponseCannotStartVoice() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        coordinator.handleVideoPlaybackWillStart()
        XCTAssertEqual(coordinator.state, .idle)

        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(playerFactory.players.isEmpty)
        XCTAssertEqual(audioSession.activationCount, 0)
        XCTAssertEqual(audioSession.deactivationCount, 0)
    }

    func testVideoTakeoverWaitsForFailedVoiceReleaseBeforeRelinquishingLease() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController(
            deactivationFailuresRemaining: 2
        )
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.toggle(md5: firstMD5)
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(audioSession.deactivationCount, 1)

        XCTAssertFalse(coordinator.handleVideoPlaybackWillStart())
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(audioSession.deactivationCount, 2)
        XCTAssertEqual(audioSession.relinquishCount, 0)

        try await waitUntil {
            audioSession.deactivationCount == 3
        }
        XCTAssertTrue(coordinator.handleVideoPlaybackWillStart())
        XCTAssertEqual(audioSession.deactivationCount, 3)
        XCTAssertEqual(audioSession.relinquishCount, 1)
    }

    func testLoadingAndDownloadFailureDoNotDeactivateUnownedAudioSession() async throws {
        let loader = ControlledVoiceAudioLoader()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(loader: loader, audioSession: audioSession)

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        XCTAssertEqual(audioSession.deactivationCount, 0)

        await loader.fail(md5: firstMD5, error: VoiceAudioClientError.invalidResponse)
        try await waitForPhase(.failed, key: firstMD5, coordinator: coordinator)
        XCTAssertEqual(audioSession.activationCount, 0)
        XCTAssertEqual(audioSession.deactivationCount, 0)
    }

    func testDeactivationFailureRetainsOwnershipAndCancelRetries() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController(
            deactivationFailuresRemaining: 1
        )
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.toggle(md5: firstMD5)
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(audioSession.deactivationCount, 1)

        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(audioSession.deactivationCount, 2)
    }

    func testDeactivationFailureRetriesWithoutFurtherUserAction() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController(
            deactivationFailuresRemaining: 2
        )
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(audioSession.deactivationCount, 1)

        try await waitUntil {
            audioSession.deactivationCount == 3
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(audioSession.deactivationCount, 3)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testActivationFailureIsCleanedUpBeforeRetry() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController(
            activationFailuresRemaining: 1
        )
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.failed, key: firstMD5, coordinator: coordinator)

        XCTAssertEqual(audioSession.activationCount, 1)
        XCTAssertEqual(audioSession.deactivationCount, 1)

        coordinator.retry(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 2, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x02]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        XCTAssertEqual(audioSession.activationCount, 2)
        XCTAssertEqual(audioSession.deactivationCount, 1)
    }

    func testBackgroundRetriesReleaseAfterCancelFailure() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController(
            deactivationFailuresRemaining: 1
        )
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(audioSession.deactivationCount, 1)

        coordinator.handleApplicationDidEnterBackground()
        XCTAssertEqual(audioSession.deactivationCount, 2)
    }

    func testLateFirstResponseCannotReplaceSecondVoice() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let coordinator = makeCoordinator(loader: loader, playerFactory: playerFactory)

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        coordinator.toggle(md5: secondMD5)
        try await waitForRequest(secondMD5, count: 1, loader: loader)

        await loader.succeed(md5: secondMD5, data: Data([0x02]))
        try await waitForPhase(.playing, key: secondMD5, coordinator: coordinator)
        XCTAssertEqual(playerFactory.players.last?.sourceData, Data([0x02]))

        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.state.key, secondMD5)
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(playerFactory.players.count, 1)
    }

    func testTogglePausesResumesAndCompletionCanReplay() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)
        let player = try XCTUnwrap(playerFactory.players.first)

        player.currentTime = 3
        coordinator.toggle(md5: firstMD5)
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(coordinator.state.currentTime, 3)
        XCTAssertFalse(player.isPlaying)

        coordinator.toggle(md5: firstMD5)
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertTrue(player.isPlaying)

        player.finish()
        XCTAssertEqual(coordinator.state.phase, .completed)
        XCTAssertEqual(coordinator.state.currentTime, player.duration)

        coordinator.toggle(md5: firstMD5)
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(player.currentTime, 0)
        let requestCount = await loader.requestCount(for: firstMD5)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(audioSession.activationCount, 3)
    }

    func testFailureCanRetryAndSwitchStopsExistingPlayer() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let coordinator = makeCoordinator(loader: loader, playerFactory: playerFactory)

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.fail(md5: firstMD5, error: VoiceAudioClientError.invalidResponse)
        try await waitForPhase(.failed, key: firstMD5, coordinator: coordinator)

        coordinator.retry(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 2, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)
        let firstPlayer = try XCTUnwrap(playerFactory.players.first)

        coordinator.toggle(md5: secondMD5)
        XCTAssertTrue(firstPlayer.didStop)
        XCTAssertEqual(coordinator.state.phase, .loading)
        XCTAssertEqual(coordinator.state.key, secondMD5)
        try await waitForRequest(secondMD5, count: 1, loader: loader)
        await loader.succeed(md5: secondMD5, data: Data([0x02]))
        try await waitForPhase(.playing, key: secondMD5, coordinator: coordinator)
    }

    func testUnsuccessfulPlayerCompletionBecomesFailure() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let coordinator = makeCoordinator(loader: loader, playerFactory: playerFactory)

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)
        let player = try XCTUnwrap(playerFactory.players.first)

        player.finish(successfully: false)

        XCTAssertEqual(coordinator.state.phase, .failed)
        XCTAssertEqual(coordinator.state.key, firstMD5)
        XCTAssertNotNil(coordinator.state.errorMessage)
    }

    func testProgressIsPublishedOnlyForCurrentVoice() async throws {
        let loader = ControlledVoiceAudioLoader()
        let coordinator = makeCoordinator(loader: loader)

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.reportProgress(md5: firstMD5, received: 25, expected: 100)
        try await waitUntil { coordinator.state.loadProgress == 0.25 }

        coordinator.toggle(md5: secondMD5)
        try await waitForRequest(secondMD5, count: 1, loader: loader)
        await loader.reportProgress(md5: firstMD5, received: 100, expected: 100)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(coordinator.state.key, secondMD5)
        XCTAssertNil(coordinator.state.loadProgress)
        await loader.fail(md5: firstMD5, error: CancellationError())
        await loader.fail(md5: secondMD5, error: CancellationError())
    }

    func testInterruptionRouteChangeAndBackgroundPausePlayback() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let coordinator = makeCoordinator(loader: loader, playerFactory: playerFactory)
        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.handleInterruptionBegan()
        XCTAssertEqual(coordinator.state.phase, .paused)
        coordinator.handleInterruptionEnded(shouldResume: true)
        XCTAssertEqual(coordinator.state.phase, .playing)

        coordinator.handleRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertEqual(coordinator.state.phase, .paused)
        coordinator.toggle(md5: firstMD5)
        XCTAssertEqual(coordinator.state.phase, .playing)

        coordinator.handleApplicationDidEnterBackground()
        XCTAssertEqual(coordinator.state.phase, .paused)
    }

    func testUserCannotResumeRetryOrSwitchVoicesDuringInterruption() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.handleInterruptionBegan()
        XCTAssertEqual(coordinator.state.phase, .paused)

        audioSession.failNextActivation()
        coordinator.toggle(md5: firstMD5)
        coordinator.toggle(md5: secondMD5)
        coordinator.retry(md5: secondMD5)

        XCTAssertEqual(coordinator.state.key, firstMD5)
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(audioSession.activationCount, 2)
        let secondRequestCount = await loader.requestCount(for: secondMD5)
        XCTAssertEqual(secondRequestCount, 0)

        coordinator.handleInterruptionEnded(shouldResume: true)
        XCTAssertEqual(coordinator.state.key, firstMD5)
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(audioSession.activationCount, 3)
    }

    func testMissingInterruptionEndCanRecoverAfterReturningToForeground() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.handleInterruptionBegan()
        coordinator.handleApplicationDidEnterBackground()
        coordinator.handleApplicationWillEnterForeground()
        coordinator.toggle(md5: firstMD5)

        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(audioSession.activationCount, 2)
    }

    func testDelayedInterruptionAfterForegroundCanRecoverByExplicitActivation() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        coordinator.handleApplicationDidEnterBackground()
        coordinator.handleApplicationWillEnterForeground()
        coordinator.handleInterruptionBegan()
        coordinator.toggle(md5: firstMD5)

        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(audioSession.activationCount, 2)
    }

    func testFailedExplicitInterruptionRecoveryPreservesPausedPlayerAndProgress() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)
        let player = try XCTUnwrap(playerFactory.players.first)
        player.currentTime = 4

        coordinator.handleInterruptionBegan()
        audioSession.failNextActivation()
        coordinator.toggle(md5: firstMD5)

        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(coordinator.state.currentTime, 4)
        XCTAssertTrue(playerFactory.players.first === player)
        XCTAssertEqual(audioSession.activationCount, 2)

        coordinator.handleInterruptionEnded(shouldResume: true)
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(audioSession.activationCount, 3)
    }

    func testRouteDisconnectedInterruptionNotificationDoesNotResumeOnSpeaker() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let notificationCenter = NotificationCenter()
        let coordinator = VoicePlaybackCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession,
            notificationCenter: notificationCenter,
            observesSystemEvents: true
        )

        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)

        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(
                    value: AVAudioSession.InterruptionType.began.rawValue
                ),
                AVAudioSessionInterruptionReasonKey: NSNumber(
                    value: AVAudioSession.InterruptionReason.routeDisconnected.rawValue
                )
            ]
        )
        XCTAssertEqual(coordinator.state.phase, .paused)
        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(
                    value: AVAudioSession.InterruptionType.ended.rawValue
                ),
                AVAudioSessionInterruptionOptionKey: NSNumber(
                    value: AVAudioSession.InterruptionOptions.shouldResume.rawValue
                )
            ]
        )

        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(audioSession.activationCount, 1)
        XCTAssertEqual(audioSession.deactivationCount, 1)
    }

    func testBackgroundDuringInterruptionPreventsResumeAndReleasesAudioSession() async throws {
        let loader = ControlledVoiceAudioLoader()
        let playerFactory = FakeVoiceAudioPlayerFactory()
        let audioSession = FakeVoiceAudioSessionController()
        let coordinator = makeCoordinator(
            loader: loader,
            playerFactory: playerFactory,
            audioSession: audioSession
        )
        coordinator.toggle(md5: firstMD5)
        try await waitForRequest(firstMD5, count: 1, loader: loader)
        await loader.succeed(md5: firstMD5, data: Data([0x01]))
        try await waitForPhase(.playing, key: firstMD5, coordinator: coordinator)
        let player = try XCTUnwrap(playerFactory.players.first)

        coordinator.handleInterruptionBegan()
        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertEqual(audioSession.deactivationCount, 0)

        coordinator.handleApplicationDidEnterBackground()
        XCTAssertEqual(audioSession.deactivationCount, 1)
        coordinator.handleInterruptionEnded(shouldResume: true)

        XCTAssertEqual(coordinator.state.phase, .paused)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(audioSession.activationCount, 1)
        XCTAssertEqual(audioSession.deactivationCount, 1)

        coordinator.handleApplicationWillEnterForeground()
        coordinator.toggle(md5: firstMD5)
        XCTAssertEqual(coordinator.state.phase, .playing)
        XCTAssertEqual(audioSession.activationCount, 2)
    }

    private func makeCoordinator(
        loader: ControlledVoiceAudioLoader,
        playerFactory: FakeVoiceAudioPlayerFactory? = nil,
        audioSession: FakeVoiceAudioSessionController? = nil
    ) -> VoicePlaybackCoordinator {
        VoicePlaybackCoordinator(
            loader: loader,
            playerFactory: playerFactory ?? FakeVoiceAudioPlayerFactory(),
            audioSession: audioSession ?? FakeVoiceAudioSessionController(),
            observesSystemEvents: false
        )
    }

    private func waitForRequest(
        _ md5: String,
        count: Int,
        loader: ControlledVoiceAudioLoader
    ) async throws {
        try await waitUntil {
            await loader.requestCount(for: md5) >= count
        }
    }

    private func waitForPhase(
        _ phase: VoicePlaybackPhase,
        key: String,
        coordinator: VoicePlaybackCoordinator
    ) async throws {
        try await waitUntil {
            coordinator.state.phase == phase && coordinator.state.key == key
        }
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private final class VoiceAudioURLProtocol: URLProtocol {
    static var payload = Data()
    static var mimeType = "audio/mpeg"
    static var statusCode = 200
    static var declaredContentLength: Int?
    static var lastRequest: URLRequest?

    static func reset() {
        payload = Data()
        mimeType = "audio/mpeg"
        statusCode = 200
        declaredContentLength = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let url = request.url else { return }
        var headers: [String: String] = [:]
        if Self.mimeType.isEmpty == false {
            headers["Content-Type"] = Self.mimeType
        }
        if let declaredContentLength = Self.declaredContentLength {
            headers["Content-Length"] = "\(declaredContentLength)"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.payload.isEmpty == false {
            client?.urlProtocol(self, didLoad: Self.payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor VoiceProgressRecorder {
    private var recordedCount = 0

    func record() {
        recordedCount += 1
    }

    func count() -> Int {
        recordedCount
    }
}

private actor ControlledVoiceAudioLoader: VoiceAudioLoading {
    private struct Pending {
        let continuation: CheckedContinuation<VoiceAudioPayload, Error>
        let onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)?
    }

    private var pending: [String: [Pending]] = [:]
    private var requests: [String] = []

    func load(
        md5: String,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)?
    ) async throws -> VoiceAudioPayload {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(md5)
            pending[md5, default: []].append(Pending(
                continuation: continuation,
                onProgress: onProgress
            ))
        }
    }

    func requestedKeys() -> [String] {
        requests
    }

    func requestCount(for md5: String) -> Int {
        requests.filter { $0 == md5 }.count
    }

    func reportProgress(md5: String, received: Int, expected: Int?) async {
        guard let request = pending[md5]?.first else { return }
        await request.onProgress?(.init(receivedBytes: received, expectedBytes: expected))
    }

    func succeed(md5: String, data: Data) {
        resumeFirst(
            md5: md5,
            result: .success(VoiceAudioPayload(data: data, mimeType: "audio/wav"))
        )
    }

    func fail(md5: String, error: Error) {
        resumeFirst(md5: md5, result: .failure(error))
    }

    private func resumeFirst(
        md5: String,
        result: Result<VoiceAudioPayload, Error>
    ) {
        guard var requests = pending[md5], requests.isEmpty == false else { return }
        let request = requests.removeFirst()
        pending[md5] = requests
        request.continuation.resume(with: result)
    }
}

@MainActor
private final class FakeVoiceAudioPlayerFactory: VoiceAudioPlayerCreating {
    private(set) var players: [FakeVoiceAudioPlayer] = []

    func makePlayer(data: Data) throws -> any VoiceAudioPlayer {
        let player = FakeVoiceAudioPlayer(sourceData: data)
        players.append(player)
        return player
    }
}

@MainActor
private final class FakeVoiceAudioPlayer: VoiceAudioPlayer {
    let sourceData: Data
    var currentTime: TimeInterval = 0
    let duration: TimeInterval = 12
    private(set) var isPlaying = false
    private(set) var didStop = false
    var onCompletion: ((Bool) -> Void)?

    init(sourceData: Data) {
        self.sourceData = sourceData
    }

    func play() -> Bool {
        isPlaying = true
        return true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        didStop = true
    }

    func finish(successfully: Bool = true) {
        currentTime = duration
        isPlaying = false
        onCompletion?(successfully)
    }
}

@MainActor
private final class FakeVoiceAudioSessionController: VoiceAudioSessionControlling {
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0
    private(set) var relinquishCount = 0
    private var activationFailuresRemaining: Int
    private var deactivationFailuresRemaining: Int

    init(
        activationFailuresRemaining: Int = 0,
        deactivationFailuresRemaining: Int = 0
    ) {
        self.activationFailuresRemaining = activationFailuresRemaining
        self.deactivationFailuresRemaining = deactivationFailuresRemaining
    }

    func activate() throws {
        activationCount += 1
        if activationFailuresRemaining > 0 {
            activationFailuresRemaining -= 1
            throw FakeVoiceAudioSessionError.activationFailed
        }
    }

    func deactivate() throws {
        deactivationCount += 1
        if deactivationFailuresRemaining > 0 {
            deactivationFailuresRemaining -= 1
            throw FakeVoiceAudioSessionError.deactivationFailed
        }
    }

    func relinquish() {
        relinquishCount += 1
    }

    func failNextActivation() {
        activationFailuresRemaining += 1
    }
}

private enum FakeVoiceAudioSessionError: Error {
    case activationFailed
    case deactivationFailed
}
