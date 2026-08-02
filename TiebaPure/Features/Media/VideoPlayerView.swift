import AVKit
import Combine
import SafariServices
import SwiftUI

enum TiebaVideoSourcePolicy {
    static func videoURL(_ url: URL?) -> URL? {
        TiebaURL.video(url?.absoluteString)
    }

    static func webpageURL(_ url: URL?) -> URL? {
        TiebaURL.webpage(url?.absoluteString)
    }
}

struct VideoPlayerView: View {
    @Environment(\.readingPreferences) private var readingPreferences

    let video: VideoContent

    @State private var showsPlayer = false
    @State private var showsSafari = false
    @State private var coverLoadState: TiebaRemoteImageLoadState = .empty
    @State private var manualCoverAuthorization: String?

    var body: some View {
        Group {
            if resolvedVideoURL != nil || resolvedWebURL != nil {
                Button {
                    if coverLoadState == .failure {
                        openVideo()
                    } else if coverLoadState == .empty,
                              isManualCoverMode {
                        manualCoverAuthorization = coverSourceIdentity
                        return
                    } else if coverLoadState == .loading,
                              ReaderMediaActivationPolicy.blocksWhileLoading(
                                requestPolicy: mediaRequestPolicy
                              ) {
                        return
                    } else {
                        openVideo()
                    }
                } label: {
                    thumbnail
                }
                .buttonStyle(.plain)
                .minTouchTarget()
                .accessibilityLabel(videoAccessibilityLabel)
                .accessibilityHint(videoAccessibilityHint)
            } else {
                thumbnail
                    .accessibilityLabel("视频不可用")
            }
        }
        .fullScreenCover(isPresented: $showsPlayer) {
            if let videoURL = resolvedVideoURL {
                FullScreenVideoPlayer(url: videoURL)
            }
        }
        .sheet(isPresented: $showsSafari) {
            if let webURL = resolvedWebURL {
                SafariView(url: webURL)
                    .ignoresSafeArea()
            }
        }
    }

    private func openVideo() {
        VoicePlaybackCoordinator.shared.handleVideoPlaybackWillStart()
        if resolvedVideoURL != nil {
            showsPlayer = true
        } else if resolvedWebURL != nil {
            showsSafari = true
        }
    }

    private var resolvedVideoURL: URL? {
        TiebaVideoSourcePolicy.videoURL(video.videoURL)
    }

    private var resolvedWebURL: URL? {
        TiebaVideoSourcePolicy.webpageURL(video.webURL)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TiebaPureTheme.Radius.media, style: .continuous)
                .fill(TiebaPureTheme.ColorToken.readerTertiarySurface)

            if let coverURL = video.coverURL {
                TiebaRemoteImage(
                    primaryURL: coverURL,
                    contentMode: .fill,
                    showsProgress: true,
                    showsRetryButton: false,
                    loadsAutomatically: mediaRequestPolicy.loadsAutomatically || isManualCoverLoadAuthorized,
                    onLoadStateChange: { coverLoadState = $0 }
                )
            } else {
                placeholderIcon
            }

            if waitsForManualCoverLoad == false || coverLoadState != .empty {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: TiebaPureTheme.IconSize.play))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .accessibilityHidden(true)
            }

            if waitsForManualCoverLoad,
               coverLoadState == .empty {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let durationText {
                Text(durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(TiebaPureTheme.Spacing.xs)
            }
        }
        .aspectRatio(inlineAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: TiebaPureTheme.Radius.media, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: TiebaPureTheme.Radius.media, style: .continuous))
    }

    private var placeholderIcon: some View {
        Image(systemName: "play.rectangle.fill")
            .font(.system(size: 30))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var inlineAspectRatio: CGFloat {
        max(0.5, min(CGFloat(video.aspectRatio), 2.0))
    }

    private var durationText: String? {
        guard video.duration > 0 else { return nil }

        let seconds = video.duration > 10_000 ? video.duration / 1_000 : video.duration
        return [
            seconds / 60,
            seconds % 60
        ]
        .map { String(format: "%02d", $0) }
        .joined(separator: ":")
    }

    private var mediaRequestPolicy: ReaderMediaRequestPolicy {
        ReaderMediaRequestPolicy.resolve(readingPreferences.mediaLoading)
    }

    private var waitsForManualCoverLoad: Bool {
        isManualCoverMode && isManualCoverLoadAuthorized == false
    }

    private var isManualCoverMode: Bool {
        video.coverURL != nil && mediaRequestPolicy.loadsAutomatically == false
    }

    private var coverSourceIdentity: String? {
        video.coverURL?.absoluteString
    }

    private var isManualCoverLoadAuthorized: Bool {
        guard let coverSourceIdentity else { return false }
        return manualCoverAuthorization == coverSourceIdentity
    }

    private var videoAccessibilityLabel: String {
        switch coverLoadState {
        case .empty where waitsForManualCoverLoad:
            return "加载视频封面"
        case .loading:
            return "正在加载视频封面"
        case .failure:
            return "播放视频，封面加载失败"
        case .empty, .success:
            return "播放视频"
        }
    }

    private var videoAccessibilityHint: String {
        switch coverLoadState {
        case .empty where waitsForManualCoverLoad:
            return "加载当前视频封面"
        case .loading:
            return "请等待视频封面加载完成"
        case .failure:
            return "封面不可用，仍可打开视频播放器"
        case .empty, .success:
            return "打开视频播放器"
        }
    }
}

struct DirectVideoPlaybackView: View {
    let video: VideoContent

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let videoURL = TiebaVideoSourcePolicy.videoURL(video.videoURL) {
                FullScreenVideoPlayer(url: videoURL)
            } else if let webURL = TiebaVideoSourcePolicy.webpageURL(video.webURL) {
                SafariView(url: webURL)
                    .ignoresSafeArea()
            } else {
                unavailableView
            }
        }
        .onAppear {
            VoicePlaybackCoordinator.shared.handleVideoPlaybackWillStart()
        }
    }

    private var unavailableView: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            Text("视频不可用")
                .font(.body.weight(.medium))
                .foregroundStyle(.white)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TiebaPureTheme.IconSize.toolbar, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("关闭视频")
            .padding(TiebaPureTheme.Spacing.md)
        }
    }
}

private struct FullScreenVideoPlayer: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button {
                player.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TiebaPureTheme.IconSize.toolbar, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("关闭视频")
            .padding(TiebaPureTheme.Spacing.md)
        }
        .onAppear {
            VoicePlaybackCoordinator.shared.handleVideoPlaybackWillStart()
            player.play()
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            guard status == .playing else { return }
            VoicePlaybackCoordinator.shared.handleVideoPlaybackWillStart()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tiebaVoicePlaybackWillStart)) { _ in
            player.pause()
        }
        .onDisappear {
            player.pause()
        }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
