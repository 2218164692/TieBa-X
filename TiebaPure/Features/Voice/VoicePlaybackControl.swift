import SwiftUI

struct VoicePlaybackControlPresentation: Equatable {
    enum Action: Equatable {
        case toggle
        case retry
        case none
    }

    var title: String
    var detail: String
    var systemImage: String
    var accessibilityLabel: String
    var accessibilityValue: String
    var accessibilityHint: String
    var progress: Double?
    var action: Action
    var isFailure: Bool
}

enum VoicePlaybackControlPolicy {
    static func presentation(
        state: VoicePlaybackState,
        fallbackDurationMilliseconds: Int
    ) -> VoicePlaybackControlPresentation {
        let duration = resolvedDuration(
            state.duration,
            fallbackDurationMilliseconds: fallbackDurationMilliseconds
        )
        let durationText = clockText(duration)

        switch state.phase {
        case .idle:
            return VoicePlaybackControlPresentation(
                title: "语音",
                detail: durationText,
                systemImage: "play.fill",
                accessibilityLabel: "播放语音",
                accessibilityValue: "时长" + spokenDuration(duration),
                accessibilityHint: "双击后下载并播放",
                progress: nil,
                action: .toggle,
                isFailure: false
            )
        case .loading:
            let progress = normalizedProgress(state.loadProgress)
            return VoicePlaybackControlPresentation(
                title: progress.map { "加载中 \(percentageText($0))" } ?? "加载中",
                detail: durationText,
                systemImage: "arrow.down",
                accessibilityLabel: "正在加载语音",
                accessibilityValue: progress.map { "已加载\(percentageText($0))" } ?? "正在等待服务器响应",
                accessibilityHint: "加载完成后会自动播放",
                progress: progress,
                action: .none,
                isFailure: false
            )
        case .playing:
            return VoicePlaybackControlPresentation(
                title: "正在播放",
                detail: playbackTimeText(current: state.currentTime, duration: duration),
                systemImage: "pause.fill",
                accessibilityLabel: "暂停语音",
                accessibilityValue: spokenPlaybackTime(current: state.currentTime, duration: duration),
                accessibilityHint: "双击暂停播放",
                progress: normalizedProgress(state.playbackProgress),
                action: .toggle,
                isFailure: false
            )
        case .paused:
            return VoicePlaybackControlPresentation(
                title: "已暂停",
                detail: playbackTimeText(current: state.currentTime, duration: duration),
                systemImage: "play.fill",
                accessibilityLabel: "继续播放语音",
                accessibilityValue: spokenPlaybackTime(current: state.currentTime, duration: duration),
                accessibilityHint: "双击继续播放",
                progress: normalizedProgress(state.playbackProgress),
                action: .toggle,
                isFailure: false
            )
        case .completed:
            return VoicePlaybackControlPresentation(
                title: "播放完毕",
                detail: durationText,
                systemImage: "arrow.counterclockwise",
                accessibilityLabel: "重新播放语音",
                accessibilityValue: "时长" + spokenDuration(duration),
                accessibilityHint: "双击从头播放",
                progress: 1,
                action: .toggle,
                isFailure: false
            )
        case .failed:
            return VoicePlaybackControlPresentation(
                title: "加载失败，点击重试",
                detail: durationText,
                systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                accessibilityLabel: "重新加载语音",
                accessibilityValue: state.errorMessage ?? "加载失败",
                accessibilityHint: "双击重试",
                progress: nil,
                action: .retry,
                isFailure: true
            )
        }
    }

    static func clockText(_ duration: TimeInterval) -> String {
        let seconds = max(Int(duration.rounded(.up)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func percentageText(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }

    private static func resolvedDuration(
        _ playbackDuration: TimeInterval,
        fallbackDurationMilliseconds: Int
    ) -> TimeInterval {
        guard playbackDuration.isFinite, playbackDuration > 0 else {
            return TimeInterval(max(fallbackDurationMilliseconds, 0)) / 1_000
        }
        return playbackDuration
    }

    private static func normalizedProgress(_ progress: Double?) -> Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    private static func playbackTimeText(current: TimeInterval, duration: TimeInterval) -> String {
        "\(clockText(min(max(current, 0), duration))) / \(clockText(duration))"
    }

    private static func spokenDuration(_ duration: TimeInterval) -> String {
        "\(max(Int(duration.rounded(.up)), 0))秒"
    }

    private static func spokenPlaybackTime(current: TimeInterval, duration: TimeInterval) -> String {
        "已播放\(max(Int(min(max(current, 0), duration).rounded(.down)), 0))秒，共\(max(Int(duration.rounded(.up)), 0))秒"
    }
}

@MainActor
struct VoicePlaybackControl: View {
    let voice: VoiceContent

    @ObservedObject private var coordinator: VoicePlaybackCoordinator

    init(voice: VoiceContent) {
        self.voice = voice
        _coordinator = ObservedObject(wrappedValue: .shared)
    }

    init(voice: VoiceContent, coordinator: VoicePlaybackCoordinator) {
        self.voice = voice
        _coordinator = ObservedObject(wrappedValue: coordinator)
    }

    var body: some View {
        let isUnavailableOffline = voice.offlineOnly == true && voice.localURL == nil
        let presentation = isUnavailableOffline
            ? VoicePlaybackControlPresentation(
                title: "语音未离线保存",
                detail: VoicePlaybackControlPolicy.clockText(
                    TimeInterval(voice.durationMilliseconds) / 1_000
                ),
                systemImage: "icloud.slash",
                accessibilityLabel: "语音未离线保存",
                accessibilityValue: "",
                accessibilityHint: "更新本地保存并选择完整媒体",
                progress: nil,
                action: .none,
                isFailure: false
            )
            : VoicePlaybackControlPolicy.presentation(
                state: coordinator.state(forMD5: voice.md5),
                fallbackDurationMilliseconds: voice.durationMilliseconds
            )

        Button {
            perform(presentation.action)
        } label: {
            VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
                HStack(spacing: TiebaPureTheme.Spacing.sm) {
                    leadingIcon(presentation)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(presentation.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(presentation.isFailure ? Color.red : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(presentation.detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: TiebaPureTheme.Spacing.xs)
                }

                if let progress = presentation.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(presentation.isFailure ? .red : TiebaPureTheme.ColorToken.primaryAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, TiebaPureTheme.Spacing.sm)
            .padding(.vertical, TiebaPureTheme.Spacing.xxs)
            .frame(minWidth: 152, maxWidth: 280, minHeight: 44, alignment: .leading)
            .background(TiebaPureTheme.ColorToken.readerSecondarySurface)
            .clipShape(RoundedRectangle(cornerRadius: TiebaPureTheme.Radius.media, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation.action == .none)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .accessibilityIdentifier("voice-playback-\(voice.md5)")
    }

    @ViewBuilder
    private func leadingIcon(_ presentation: VoicePlaybackControlPresentation) -> some View {
        if presentation.action == .none, presentation.progress == nil {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        } else {
            Image(systemName: presentation.systemImage)
                .font(.system(size: TiebaPureTheme.IconSize.inline, weight: .semibold))
                .foregroundStyle(
                    presentation.isFailure
                        ? Color.red
                        : TiebaPureTheme.ColorToken.primaryAccent
                )
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
    }

    private func perform(_ action: VoicePlaybackControlPresentation.Action) {
        switch action {
        case .toggle:
            coordinator.toggle(
                md5: voice.md5,
                localURL: voice.localURL,
                offlineOnly: voice.offlineOnly == true
            )
        case .retry:
            coordinator.retry(
                md5: voice.md5,
                localURL: voice.localURL,
                offlineOnly: voice.offlineOnly == true
            )
        case .none:
            break
        }
    }
}
