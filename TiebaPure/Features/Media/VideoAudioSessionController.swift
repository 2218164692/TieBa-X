import AVFoundation

struct MediaAudioSessionConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions

    static let moviePlayback = MediaAudioSessionConfiguration(
        category: .playback,
        mode: .moviePlayback,
        options: []
    )

    static let voicePlayback = MediaAudioSessionConfiguration(
        category: .playback,
        mode: .spokenAudio,
        options: []
    )
}

enum MediaAudioSessionOwner: Equatable {
    case video
    case voice
}

struct MediaAudioSessionLease: Equatable {
    fileprivate let token: UUID
    let owner: MediaAudioSessionOwner
}

@MainActor
protocol MediaAudioSessionBackend: AnyObject {
    var configuration: MediaAudioSessionConfiguration { get }

    func setConfiguration(_ configuration: MediaAudioSessionConfiguration) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SystemMediaAudioSessionBackend: MediaAudioSessionBackend {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    var configuration: MediaAudioSessionConfiguration {
        MediaAudioSessionConfiguration(
            category: session.category,
            mode: session.mode,
            options: session.categoryOptions
        )
    }

    func setConfiguration(_ configuration: MediaAudioSessionConfiguration) throws {
        try session.setCategory(
            configuration.category,
            mode: configuration.mode,
            options: configuration.options
        )
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try session.setActive(active, options: options)
    }
}

@MainActor
protocol MediaAudioSessionCoordinating: AnyObject {
    func acquire(
        owner: MediaAudioSessionOwner,
        configuration: MediaAudioSessionConfiguration
    ) throws -> MediaAudioSessionLease
    func release(_ lease: MediaAudioSessionLease) -> Bool
    func isCurrent(_ lease: MediaAudioSessionLease) -> Bool
}

@MainActor
final class MediaAudioSessionCoordinator: MediaAudioSessionCoordinating {
    static let shared = MediaAudioSessionCoordinator()

    private let backend: any MediaAudioSessionBackend
    private let releaseRetryDelays: [UInt64]
    private var baselineConfiguration: MediaAudioSessionConfiguration?
    private var currentLease: MediaAudioSessionLease?
    private var currentConfiguration: MediaAudioSessionConfiguration?
    private var releaseRetryTask: Task<Void, Never>?

    init(
        backend: (any MediaAudioSessionBackend)? = nil,
        releaseRetryDelays: [UInt64] = [100_000_000, 300_000_000, 900_000_000]
    ) {
        self.backend = backend ?? SystemMediaAudioSessionBackend()
        self.releaseRetryDelays = releaseRetryDelays
    }

    func acquire(
        owner: MediaAudioSessionOwner,
        configuration: MediaAudioSessionConfiguration
    ) throws -> MediaAudioSessionLease {
        cancelReleaseRetry()
        let nextLease = MediaAudioSessionLease(token: UUID(), owner: owner)

        if let currentLease,
           currentLease.owner == owner,
           currentConfiguration == configuration {
            do {
                try backend.setConfiguration(configuration)
                try backend.setActive(true, options: [])
                self.currentLease = nextLease
                return nextLease
            } catch {
                scheduleReleaseRetry(for: currentLease)
                throw error
            }
        }

        if baselineConfiguration == nil {
            baselineConfiguration = backend.configuration
        }

        if let previousLease = currentLease,
           let previousConfiguration = currentConfiguration {
            do {
                try backend.setActive(false, options: .notifyOthersOnDeactivation)
                try backend.setConfiguration(configuration)
                try backend.setActive(true, options: [])
                currentLease = nextLease
                currentConfiguration = configuration
                return nextLease
            } catch {
                let handoffError = error
                var restoredPreviousOwner = true
                do {
                    try backend.setConfiguration(previousConfiguration)
                } catch {
                    restoredPreviousOwner = false
                }
                do {
                    try backend.setActive(true, options: [])
                } catch {
                    restoredPreviousOwner = false
                }
                if restoredPreviousOwner == false {
                    scheduleReleaseRetry(for: previousLease)
                }
                throw handoffError
            }
        }

        do {
            try backend.setConfiguration(configuration)
            try backend.setActive(true, options: [])
            currentLease = nextLease
            currentConfiguration = configuration
            return nextLease
        } catch {
            let activationError = error
            currentLease = nextLease
            currentConfiguration = configuration
            if restoreBaseline(for: nextLease) == false {
                scheduleReleaseRetry(for: nextLease)
            }
            throw activationError
        }
    }

    func release(_ lease: MediaAudioSessionLease) -> Bool {
        guard isCurrent(lease) else { return true }
        cancelReleaseRetry()
        guard restoreBaseline(for: lease) else {
            scheduleReleaseRetry(for: lease)
            return false
        }
        return true
    }

    func isCurrent(_ lease: MediaAudioSessionLease) -> Bool {
        currentLease == lease
    }

    private func restoreBaseline(for lease: MediaAudioSessionLease) -> Bool {
        guard isCurrent(lease), let baselineConfiguration else { return true }
        do {
            try backend.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }
        do {
            try backend.setConfiguration(baselineConfiguration)
        } catch {
            return false
        }
        currentLease = nil
        currentConfiguration = nil
        self.baselineConfiguration = nil
        return true
    }

    private func scheduleReleaseRetry(for lease: MediaAudioSessionLease) {
        guard isCurrent(lease),
              releaseRetryTask == nil,
              releaseRetryDelays.isEmpty == false else {
            return
        }
        releaseRetryTask = Task { @MainActor [self] in
            for delay in releaseRetryDelays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    releaseRetryTask = nil
                    return
                }
                guard isCurrent(lease) else {
                    releaseRetryTask = nil
                    return
                }
                if restoreBaseline(for: lease) {
                    releaseRetryTask = nil
                    return
                }
            }
            releaseRetryTask = nil
        }
    }

    private func cancelReleaseRetry() {
        releaseRetryTask?.cancel()
        releaseRetryTask = nil
    }
}

@MainActor
final class VideoAudioSessionLifecycle {
    private let coordinator: any MediaAudioSessionCoordinating
    private var lease: MediaAudioSessionLease?

    private(set) var hasActiveLease = false

    init(coordinator: (any MediaAudioSessionCoordinating)? = nil) {
        self.coordinator = coordinator ?? MediaAudioSessionCoordinator.shared
    }

    func activate() throws {
        guard hasActiveLease == false else { return }
        let lease = try coordinator.acquire(
            owner: .video,
            configuration: .moviePlayback
        )
        self.lease = lease
        hasActiveLease = true
    }

    func deactivate() {
        hasActiveLease = false
        guard let lease else { return }
        if coordinator.release(lease) {
            self.lease = nil
        }
    }

    @discardableResult
    func relinquishForExternalPlayback() -> Bool {
        hasActiveLease = false
        guard let lease else { return true }
        let didRelease = coordinator.release(lease)
        if didRelease {
            self.lease = nil
        }
        return didRelease
    }
}

enum VideoAudioSessionPlaybackPolicy {
    static func requiresActiveSession(for status: AVPlayer.TimeControlStatus) -> Bool {
        switch status {
        case .playing, .waitingToPlayAtSpecifiedRate:
            return true
        case .paused:
            return false
        @unknown default:
            return false
        }
    }

    static func shouldPauseForRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        reason == .oldDeviceUnavailable
    }
}
