import AVFoundation
import XCTest
@testable import TieBaX

@MainActor
final class VideoAudioSessionTests: XCTestCase {
    private let hostConfiguration = MediaAudioSessionConfiguration(
        category: .ambient,
        mode: .default,
        options: [.mixWithOthers]
    )

    func testMoviePlaybackIgnoresSilentSwitchAndRestoresHostConfiguration() throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(backend: backend)
        let lifecycle = VideoAudioSessionLifecycle(coordinator: coordinator)

        try lifecycle.activate()

        XCTAssertTrue(lifecycle.hasActiveLease)
        XCTAssertEqual(backend.configuration, .moviePlayback)
        XCTAssertEqual(backend.activeCalls.map(\.active), [true])

        lifecycle.deactivate()

        XCTAssertFalse(lifecycle.hasActiveLease)
        XCTAssertEqual(backend.configuration, hostConfiguration)
        XCTAssertEqual(backend.activeCalls.map(\.active), [true, false])
        XCTAssertTrue(backend.activeCalls[1].options.contains(.notifyOthersOnDeactivation))
    }

    func testActivationFailureRollsBackHostConfigurationBeforeRetry() throws {
        let backend = FakeMediaAudioSessionBackend(
            configuration: hostConfiguration,
            activationFailuresRemaining: 1
        )
        let coordinator = MediaAudioSessionCoordinator(backend: backend)
        let lifecycle = VideoAudioSessionLifecycle(coordinator: coordinator)

        XCTAssertThrowsError(try lifecycle.activate())
        XCTAssertFalse(lifecycle.hasActiveLease)
        XCTAssertEqual(backend.configuration, hostConfiguration)
        XCTAssertEqual(backend.activeCalls.map(\.active), [true, false])

        try lifecycle.activate()
        XCTAssertTrue(lifecycle.hasActiveLease)
        XCTAssertEqual(backend.configuration, .moviePlayback)
    }

    func testLifecycleActivationAndExitReleaseAreIdempotent() throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(backend: backend)
        let lifecycle = VideoAudioSessionLifecycle(coordinator: coordinator)

        try lifecycle.activate()
        try lifecycle.activate()
        XCTAssertEqual(backend.activeCalls.map(\.active), [true])

        lifecycle.deactivate()
        lifecycle.deactivate()
        XCTAssertEqual(backend.activeCalls.map(\.active), [true, false])
        XCTAssertEqual(backend.configuration, hostConfiguration)
    }

    func testBackgroundStyleReleaseRetriesTransientDeactivationFailure() async throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(
            backend: backend,
            releaseRetryDelays: [1_000_000]
        )
        let lifecycle = VideoAudioSessionLifecycle(coordinator: coordinator)
        try lifecycle.activate()
        backend.failNextDeactivations(1)

        lifecycle.deactivate()

        XCTAssertFalse(lifecycle.hasActiveLease)
        try await waitUntil {
            backend.configuration == self.hostConfiguration
                && backend.activeCalls.filter { $0.active == false }.count == 2
        }
        XCTAssertEqual(backend.configurationCalls.filter { $0 == hostConfiguration }.count, 1)
    }

    func testStaleVideoLeaseCannotDeactivateNewVoiceOwner() throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(backend: backend)
        let videoLease = try coordinator.acquire(
            owner: .video,
            configuration: .moviePlayback
        )
        let voiceLease = try coordinator.acquire(
            owner: .voice,
            configuration: .voicePlayback
        )
        let callsBeforeStaleRelease = backend.activeCalls.count

        XCTAssertTrue(coordinator.release(videoLease))

        XCTAssertEqual(backend.activeCalls.count, callsBeforeStaleRelease)
        XCTAssertTrue(coordinator.isCurrent(voiceLease))
        XCTAssertEqual(backend.configuration, .voicePlayback)

        XCTAssertTrue(coordinator.release(voiceLease))
        XCTAssertEqual(backend.configuration, hostConfiguration)
        XCTAssertEqual(backend.configurationCalls.filter { $0 == hostConfiguration }.count, 1)
    }

    func testSameOwnerReacquisitionIssuesNewTokenAndMakesOldVideoLeaseStale() throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(backend: backend)
        let firstLease = try coordinator.acquire(
            owner: .video,
            configuration: .moviePlayback
        )
        let secondLease = try coordinator.acquire(
            owner: .video,
            configuration: .moviePlayback
        )
        let callsBeforeStaleRelease = backend.activeCalls.count

        XCTAssertNotEqual(firstLease, secondLease)
        XCTAssertTrue(coordinator.release(firstLease))
        XCTAssertEqual(backend.activeCalls.count, callsBeforeStaleRelease)
        XCTAssertTrue(coordinator.isCurrent(secondLease))
        XCTAssertEqual(backend.configuration, .moviePlayback)

        XCTAssertTrue(coordinator.release(secondLease))
        XCTAssertEqual(backend.configuration, hostConfiguration)
    }

    func testFailedOwnerHandoffKeepsPreviousLeaseCurrentUntilReleaseSucceeds() throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(
            backend: backend,
            releaseRetryDelays: []
        )
        let videoLease = try coordinator.acquire(
            owner: .video,
            configuration: .moviePlayback
        )
        backend.failNextDeactivations(1)

        XCTAssertThrowsError(try coordinator.acquire(
            owner: .voice,
            configuration: .voicePlayback
        ))

        XCTAssertTrue(coordinator.isCurrent(videoLease))
        XCTAssertEqual(backend.configuration, .moviePlayback)
        XCTAssertTrue(coordinator.release(videoLease))
        XCTAssertEqual(backend.configuration, hostConfiguration)
    }

    func testRecoveredOwnerHandoffFailureDoesNotLaterReleasePreviousLease() async throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(
            backend: backend,
            releaseRetryDelays: [5_000_000]
        )
        let videoLease = try coordinator.acquire(
            owner: .video,
            configuration: .moviePlayback
        )
        backend.failNextDeactivations(1)

        XCTAssertThrowsError(try coordinator.acquire(
            owner: .voice,
            configuration: .voicePlayback
        ))
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(coordinator.isCurrent(videoLease))
        XCTAssertEqual(backend.configuration, .moviePlayback)
        XCTAssertEqual(backend.activeCalls.filter { $0.active == false }.count, 1)

        XCTAssertTrue(coordinator.release(videoLease))
        XCTAssertEqual(backend.configuration, hostConfiguration)
    }

    func testVideoAndVoiceControllersShareTokenizedProcessCoordinator() throws {
        let backend = FakeMediaAudioSessionBackend(configuration: hostConfiguration)
        let coordinator = MediaAudioSessionCoordinator(backend: backend)
        let video = VideoAudioSessionLifecycle(coordinator: coordinator)
        let voice = SystemVoiceAudioSessionController(coordinator: coordinator)

        try video.activate()
        try voice.activate()
        XCTAssertEqual(backend.configuration, .voicePlayback)

        video.deactivate()
        XCTAssertEqual(backend.configuration, .voicePlayback)

        try voice.deactivate()
        XCTAssertEqual(backend.configuration, hostConfiguration)

        try voice.activate()
        try video.activate()
        XCTAssertEqual(backend.configuration, .moviePlayback)

        XCTAssertNoThrow(try voice.deactivate())
        XCTAssertEqual(backend.configuration, .moviePlayback)
        video.deactivate()
        XCTAssertEqual(backend.configuration, hostConfiguration)
    }

    func testWaitingAndPlayingRequireSessionButPausedDoesNotReleaseByStatusAlone() {
        XCTAssertTrue(VideoAudioSessionPlaybackPolicy.requiresActiveSession(for: .playing))
        XCTAssertTrue(VideoAudioSessionPlaybackPolicy.requiresActiveSession(
            for: .waitingToPlayAtSpecifiedRate
        ))
        XCTAssertFalse(VideoAudioSessionPlaybackPolicy.requiresActiveSession(for: .paused))
    }

    func testOnlyHeadphoneStyleRouteLossRequiresProtectivePause() {
        XCTAssertTrue(VideoAudioSessionPlaybackPolicy.shouldPauseForRouteChange(
            .oldDeviceUnavailable
        ))
        XCTAssertFalse(VideoAudioSessionPlaybackPolicy.shouldPauseForRouteChange(.newDeviceAvailable))
        XCTAssertFalse(VideoAudioSessionPlaybackPolicy.shouldPauseForRouteChange(.categoryChange))
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while condition() == false {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return XCTFail("Timed out waiting for audio session state")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private final class FakeMediaAudioSessionBackend: MediaAudioSessionBackend {
    struct ActiveCall {
        let active: Bool
        let options: AVAudioSession.SetActiveOptions
    }

    var configuration: MediaAudioSessionConfiguration
    private(set) var configurationCalls: [MediaAudioSessionConfiguration] = []
    private(set) var activeCalls: [ActiveCall] = []
    private var activationFailuresRemaining: Int
    private var deactivationFailuresRemaining = 0

    init(
        configuration: MediaAudioSessionConfiguration,
        activationFailuresRemaining: Int = 0
    ) {
        self.configuration = configuration
        self.activationFailuresRemaining = activationFailuresRemaining
    }

    func failNextDeactivations(_ count: Int) {
        deactivationFailuresRemaining = count
    }

    func setConfiguration(_ configuration: MediaAudioSessionConfiguration) throws {
        configurationCalls.append(configuration)
        self.configuration = configuration
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activeCalls.append(ActiveCall(active: active, options: options))
        if active, activationFailuresRemaining > 0 {
            activationFailuresRemaining -= 1
            throw FakeMediaAudioSessionError.activationFailed
        }
        if active == false, deactivationFailuresRemaining > 0 {
            deactivationFailuresRemaining -= 1
            throw FakeMediaAudioSessionError.deactivationFailed
        }
    }
}

private enum FakeMediaAudioSessionError: Error {
    case activationFailed
    case deactivationFailed
}
