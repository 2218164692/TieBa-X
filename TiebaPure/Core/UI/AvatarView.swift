import SwiftUI
import UIKit
import ImageIO

enum TiebaImageRequestPolicy {
    static let maximumRetryCount = 2

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        request.setValue("tieba/12.52.1.0 skin/default", forHTTPHeaderField: "User-Agent")
        request.setValue("https://tieba.baidu.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    static func shouldRetry(statusCode: Int, attempt: Int) -> Bool {
        guard attempt < maximumRetryCount else { return false }
        return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    static func shouldRetry(error: Error, attempt: Int) -> Bool {
        guard attempt < maximumRetryCount else { return false }
        let code = (error as? URLError)?.code
        return code == .timedOut
            || code == .networkConnectionLost
            || code == .notConnectedToInternet
            || code == .cannotConnectToHost
            || code == .cannotFindHost
    }

    static func retryDelayNanoseconds(after attempt: Int) -> UInt64 {
        UInt64(250_000_000 * max(attempt + 1, 1))
    }
}

enum TiebaImageSourcePolicy {
    private static let syntheticFailureHost = "fixture.invalid"
#if DEBUG
    private static let syntheticSuccessHost = "fixture-success.invalid"
    static let syntheticOriginalByteCount = 3_670_016
#endif

    static func urls(primary: URL?, fallback: URL? = nil) -> [URL] {
        var result: [URL] = []
        for candidate in [primary, fallback].compactMap({ $0 }) {
            guard let safeURL = TiebaURL.image(candidate.absoluteString),
                  result.contains(safeURL) == false else {
                continue
            }
            result.append(safeURL)
        }
        return result
    }

    /// UI-test fixtures use this reserved host to exercise the accessible
    /// failure and retry states without consulting DNS or the network stack.
    static func isSyntheticFailureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == syntheticFailureHost
    }

#if DEBUG
    /// Deterministic UI-test images are generated in memory and never consult
    /// DNS or the network stack.
    static func isSyntheticSuccessURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == syntheticSuccessHost
    }
#endif
}

enum TiebaImageDecodePolicy {
    static let maximumSourceDimension = 32_768
    static let maximumSourcePixels = 100_000_000
    static let maximumDecodedPixelSize = 4_096

    static func allows(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumSourceDimension,
              height <= maximumSourceDimension else {
            return false
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow == false && pixels <= maximumSourcePixels
    }

    /// Decode targets are a downscale hint only: they never raise the global
    /// pixel ceiling, and non-positive requests fall back to it.
    static func decodeTargetPixelSize(_ requested: Int) -> Int {
        guard requested > 0 else { return maximumDecodedPixelSize }
        return min(requested, maximumDecodedPixelSize)
    }
}

private enum TiebaImagePipelineError: Error {
    case invalidURL
    case invalidResponse
    case badStatus(Int)
    case invalidImageData
    case noSource
}

actor TiebaImagePipeline {
    static let shared = TiebaImagePipeline()
    static let maximumImageBytes = 30 * 1_024 * 1_024

    private struct DecodeRequest: Hashable {
        let url: URL
        let targetPixelSize: Int

        var cacheKey: NSString {
            "\(targetPixelSize)|\(url.absoluteString)" as NSString
        }
    }

    private let memoryCache = NSCache<NSString, UIImage>()
    private let urlCache: URLCache
    private let session: URLSession
    private var inFlight: [DecodeRequest: Task<UIImage, Error>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        let urlCache = URLCache(
            memoryCapacity: 64 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024,
            diskPath: "TiebaPureImages"
        )
        configuration.urlCache = urlCache
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        self.urlCache = urlCache
        session = SecureRemoteURLSession.make(configuration: configuration, redirectScope: .publicHTTPS)
        memoryCache.totalCostLimit = 96 * 1_024 * 1_024
        memoryCache.countLimit = 300
    }

    func clearCaches() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        memoryCache.removeAllObjects()
        urlCache.removeAllCachedResponses()
    }

    /// `targetPixelSize` caps the decoded bitmap's longest edge. Distinct
    /// targets cache independently, so a screen-sized decode and the
    /// full-resolution tier of the same URL can coexist.
    func image(
        from urls: [URL],
        targetPixelSize: Int = TiebaImageDecodePolicy.maximumDecodedPixelSize,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)? = nil
    ) async throws -> UIImage {
        guard urls.isEmpty == false else { throw TiebaImagePipelineError.noSource }

        var latestError: Error = TiebaImagePipelineError.noSource
        for url in urls {
            try Task.checkCancellation()
            do {
                return try await image(
                    from: url,
                    targetPixelSize: targetPixelSize,
                    onProgress: onProgress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                latestError = error
            }
        }
        throw latestError
    }

    private func image(
        from url: URL,
        targetPixelSize: Int,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)?
    ) async throws -> UIImage {
        // Download the validated URL, not the caller's: validation may have
        // upgraded a legacy http source to https.
        guard let safeURL = TiebaURL.image(url.absoluteString) else {
            throw TiebaImagePipelineError.invalidURL
        }
        guard TiebaImageSourcePolicy.isSyntheticFailureURL(url) == false else {
            throw TiebaImagePipelineError.invalidImageData
        }
        let request = DecodeRequest(
            url: safeURL,
            targetPixelSize: TiebaImageDecodePolicy.decodeTargetPixelSize(targetPixelSize)
        )
        if let cached = memoryCache.object(forKey: request.cacheKey) {
            await onProgress?(BoundedURLSessionProgress(receivedBytes: 1, expectedBytes: 1))
            return cached
        }
#if DEBUG
        if TiebaImageSourcePolicy.isSyntheticSuccessURL(url) {
            await onProgress?(BoundedURLSessionProgress(
                receivedBytes: 0,
                expectedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount
            ))
            if ProcessInfo.processInfo.arguments.contains("UITEST_IMAGE_PROGRESS_DELAY") {
                // Drive a deterministic, visibly filling progress surface.
                // Production requests continue to report real streamed bytes.
                for step in 1...5 {
                    try await Task.sleep(nanoseconds: 400_000_000)
                    await onProgress?(BoundedURLSessionProgress(
                        receivedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount * step / 5,
                        expectedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount
                    ))
                }
            } else {
                await Task.yield()
                await onProgress?(BoundedURLSessionProgress(
                    receivedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount,
                    expectedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount
                ))
            }
            let image = Self.syntheticFixtureImage(for: url)
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memoryCache.setObject(image, forKey: request.cacheKey, cost: cost)
            return image
        }
#endif
        if let onProgress {
            let image = try await Self.download(
                request: request,
                session: session,
                onProgress: onProgress
            )
            try Task.checkCancellation()
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memoryCache.setObject(image, forKey: request.cacheKey, cost: cost)
            return image
        }
        if let task = inFlight[request] {
            let image = try await task.value
            try Task.checkCancellation()
            await onProgress?(BoundedURLSessionProgress(receivedBytes: 1, expectedBytes: 1))
            return image
        }

        let session = session
        let task = Task<UIImage, Error> {
            try await Self.download(
                request: request,
                session: session,
                onProgress: nil
            )
        }
        inFlight[request] = task

        do {
            let image = try await task.value
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memoryCache.setObject(image, forKey: request.cacheKey, cost: cost)
            inFlight[request] = nil
            return image
        } catch {
            inFlight[request] = nil
            throw error
        }
    }

    private static func download(
        request: DecodeRequest,
        session: URLSession,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)?
    ) async throws -> UIImage {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await BoundedURLSession(session: session).data(
                    for: TiebaImageRequestPolicy.request(for: request.url),
                    maximumBytes: maximumImageBytes,
                    requiredMIMEPrefix: "image/",
                    onProgress: onProgress
                )
                guard let response = response as? HTTPURLResponse else {
                    throw TiebaImagePipelineError.invalidResponse
                }
                guard (200...299).contains(response.statusCode) else {
                    if TiebaImageRequestPolicy.shouldRetry(statusCode: response.statusCode, attempt: attempt) {
                        try await Task.sleep(
                            nanoseconds: TiebaImageRequestPolicy.retryDelayNanoseconds(after: attempt)
                        )
                        attempt += 1
                        continue
                    }
                    throw TiebaImagePipelineError.badStatus(response.statusCode)
                }
                guard let image = decodedImage(
                    from: data,
                    targetPixelSize: request.targetPixelSize
                ) else {
                    throw TiebaImagePipelineError.invalidImageData
                }
                return image
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard TiebaImageRequestPolicy.shouldRetry(error: error, attempt: attempt) else {
                    throw error
                }
                try await Task.sleep(
                    nanoseconds: TiebaImageRequestPolicy.retryDelayNanoseconds(after: attempt)
                )
                attempt += 1
            }
        }
    }

#if DEBUG
    private static func syntheticFixtureImage(for url: URL) -> UIImage {
        let size = CGSize(width: 120, height: 480)
        // Thumbnail/original fixture URLs represent the same underlying
        // picture. Seeding them independently made the hero animation morph
        // between unrelated colors and could either mimic or conceal a real
        // transition drift in pixel tests.
        let fixtureIdentity = url.absoluteString
            .replacingOccurrences(of: "-thumbnail.", with: ".")
            .replacingOccurrences(of: "-original.", with: ".")
        let seed = fixtureIdentity.utf8.reduce(UInt32(2_166_136_261)) { partial, byte in
            (partial ^ UInt32(byte)) &* 16_777_619
        }
        let hue = CGFloat(seed % 360) / 360
        let accentHue = CGFloat((seed / 360 + 113) % 360) / 360
        return UIGraphicsImageRenderer(size: size).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.cgContext.setFillColor(UIColor(
                hue: hue,
                saturation: 0.72,
                brightness: 0.82,
                alpha: 1
            ).cgColor)
            context.cgContext.fill(bounds)
            context.cgContext.setFillColor(UIColor(
                hue: accentHue,
                saturation: 0.78,
                brightness: 0.96,
                alpha: 0.82
            ).cgColor)
            context.cgContext.fill(CGRect(x: 0, y: size.height * 0.45, width: size.width, height: size.height * 0.55))

            let stripeWidth = CGFloat(12 + Int(seed % 20))
            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.72).cgColor)
            context.cgContext.fill(CGRect(
                x: CGFloat(Int(seed / 7) % 72),
                y: 0,
                width: stripeWidth,
                height: size.height
            ))
        }
    }
#endif

    private static func decodedImage(from data: Data, targetPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              TiebaImageDecodePolicy.allows(width: width, height: height) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: TiebaImageDecodePolicy.decodeTargetPixelSize(targetPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

@MainActor
private final class TiebaRemoteImageModel: ObservableObject {
    enum Phase {
        case empty
        case loading
        case success(UIImage)
        case failure
    }

    @Published private(set) var phase: Phase = .empty
    private var sourceKey = ""
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func load(urls: [URL], force: Bool = false) {
        let key = urls.map(\.absoluteString).joined(separator: "|")
        let sourceChanged = key != sourceKey
        guard force || sourceChanged || isEmpty || isFailed else { return }
        sourceKey = key
        task?.cancel()

        guard urls.isEmpty == false else {
            phase = .failure
            return
        }

        phase = .loading
        let requestKey = key
        task = Task {
            do {
                let image = try await TiebaImagePipeline.shared.image(from: urls)
                guard Task.isCancelled == false, sourceKey == requestKey else { return }
                phase = .success(image)
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false, sourceKey == requestKey else { return }
                phase = .failure
            }
        }
    }

    func suspendAutomaticLoad(urls: [URL]) {
        let key = urls.map(\.absoluteString).joined(separator: "|")
        if sourceKey != key {
            task?.cancel()
            sourceKey = key
            phase = .empty
            return
        }
        guard case .loading = phase else { return }
        task?.cancel()
        phase = .empty
    }

    func represents(urls: [URL]) -> Bool {
        sourceKey == urls.map(\.absoluteString).joined(separator: "|")
    }

    private var isFailed: Bool {
        if case .failure = phase { return true }
        return false
    }

    private var isEmpty: Bool {
        if case .empty = phase { return true }
        return false
    }

    var loadState: TiebaRemoteImageLoadState {
        switch phase {
        case .empty:
            return .empty
        case .loading:
            return .loading
        case .success:
            return .success
        case .failure:
            return .failure
        }
    }
}

enum TiebaRemoteImageLoadState: Equatable, Sendable {
    case empty
    case loading
    case success
    case failure
}

struct TiebaRemoteImage: View {
    let urls: [URL]
    var contentMode: ContentMode = .fill
    var showsProgress = false
    var retryTrigger = 0
    var showsRetryButton = true
    var showsResolvedImage = true
    var loadsAutomatically = true
    var onLoadStateChange: ((TiebaRemoteImageLoadState) -> Void)?
    var onImageResolved: ((UIImage) -> Void)?
    var onImageLayoutResolved: ((UIImage, CGRect) -> Void)?
    var onDebugImageObserverResolved: ((UIView, UIImage) -> Void)?

    @StateObject private var model = TiebaRemoteImageModel()

    init(
        primaryURL: URL?,
        fallbackURL: URL? = nil,
        contentMode: ContentMode = .fill,
        showsProgress: Bool = false,
        retryTrigger: Int = 0,
        showsRetryButton: Bool = true,
        showsResolvedImage: Bool = true,
        loadsAutomatically: Bool = true,
        onLoadStateChange: ((TiebaRemoteImageLoadState) -> Void)? = nil,
        onImageResolved: ((UIImage) -> Void)? = nil,
        onImageLayoutResolved: ((UIImage, CGRect) -> Void)? = nil,
        onDebugImageObserverResolved: ((UIView, UIImage) -> Void)? = nil
    ) {
        urls = TiebaImageSourcePolicy.urls(primary: primaryURL, fallback: fallbackURL)
        self.contentMode = contentMode
        self.showsProgress = showsProgress
        self.retryTrigger = retryTrigger
        self.showsRetryButton = showsRetryButton
        self.showsResolvedImage = showsResolvedImage
        self.loadsAutomatically = loadsAutomatically
        self.onLoadStateChange = onLoadStateChange
        self.onImageResolved = onImageResolved
        self.onImageLayoutResolved = onImageLayoutResolved
        self.onDebugImageObserverResolved = onDebugImageObserverResolved
    }

    var body: some View {
        Group {
            switch model.phase {
            case let .success(image):
                if model.represents(urls: urls) {
                    if showsResolvedImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .background {
                                if onImageLayoutResolved != nil || activeDebugImageObserver != nil {
                                    TiebaResolvedImageFrameReader(
                                        image: image,
                                        onLayout: onImageLayoutResolved,
                                        onObserver: activeDebugImageObserver
                                    )
                                }
                            }
                    } else {
                        // Transition thumbnails are rendered by their registered
                        // UIKit source view. Keep this loader in the hierarchy so
                        // it can resolve/retry the image without drawing a second
                        // bitmap underneath the native zoom source.
                        Color.clear
                    }
                } else if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Color.clear
                }
            case .empty:
                if showsProgress, loadsAutomatically {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Color.clear
                }
            case .loading:
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Color.clear
                }
            case .failure:
                if showsRetryButton {
                    Button {
                        model.load(urls: urls, force: true)
                    } label: {
                        retryLabel
                    }
                    .accessibilityLabel("图片加载失败")
                    .accessibilityHint("点按重新加载图片")
                } else {
                    retryLabel
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(urls.map(\.absoluteString).joined(separator: "|"))#\(retryTrigger)#\(loadsAutomatically)") {
            guard loadsAutomatically else {
                model.suspendAutomaticLoad(urls: urls)
                return
            }
            model.load(urls: urls, force: retryTrigger > 0)
        }
        .onReceive(model.$phase) { phase in
            guard case let .success(image) = phase,
                  model.represents(urls: urls) else {
                return
            }
            onImageResolved?(image)
        }
        .onChange(of: model.loadState) { state in
            onLoadStateChange?(state)
        }
        .onAppear {
            onLoadStateChange?(model.loadState)
        }
    }

    private var retryLabel: some View {
        Label("图片加载失败，点按重试", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
            .minTouchTarget()
            .contentShape(Rectangle())
    }

    private var activeDebugImageObserver: ((UIView, UIImage) -> Void)? {
#if DEBUG
        onDebugImageObserverResolved
#else
        nil
#endif
    }
}

#if DEBUG
struct RemoteImageReuseUITestHost: View {
    @State private var selectedSource = "A"
    @State private var resolvedSource = ""
    @State private var manualAuthorization: String?

    private var usesManualLoading: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_REMOTE_IMAGE_REUSE_MANUAL")
    }

    private var sourceURL: URL? {
        URL(string: selectedSource == "A"
            ? "https://fixture-success.invalid/reuse-a.png"
            : "https://fixture-success.invalid/reuse-b.png")
    }

    private var sourceIdentity: String {
        sourceURL?.absoluteString ?? selectedSource
    }

    private var allowsLoading: Bool {
        usesManualLoading == false || manualAuthorization == sourceIdentity
    }

    var body: some View {
        VStack(spacing: 20) {
            TiebaRemoteImage(
                primaryURL: sourceURL,
                contentMode: .fill,
                showsProgress: true,
                loadsAutomatically: allowsLoading,
                onLoadStateChange: { state in
                    if state == .success {
                        resolvedSource = selectedSource
                    }
                }
            )
            .frame(width: 160, height: 260)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("remote-image-reuse-surface")
            .accessibilityLabel("复用图片 \(selectedSource)")

            Text(stateText)
                .accessibilityIdentifier("remote-image-reuse-state")

            if usesManualLoading {
                Button("加载当前图片") {
                    manualAuthorization = sourceIdentity
                }
                .disabled(resolvedSource == selectedSource)
                .accessibilityIdentifier("remote-image-reuse-load")
            }

            Button("切换到图片 B") {
                selectedSource = "B"
                resolvedSource = ""
            }
            .disabled(selectedSource == "B")
            .accessibilityIdentifier("remote-image-reuse-switch")
        }
        .padding()
    }

    private var stateText: String {
        if resolvedSource.isEmpty == false {
            return "已加载 \(resolvedSource)"
        }
        return allowsLoading ? "正在加载" : "等待加载 \(selectedSource)"
    }
}
#endif

private struct TiebaResolvedImageFrameReader: UIViewRepresentable {
    let image: UIImage
    let onLayout: ((UIImage, CGRect) -> Void)?
    let onObserver: ((UIView, UIImage) -> Void)?

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.configure(image: image, onLayout: onLayout, onObserver: onObserver)
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.configure(image: image, onLayout: onLayout, onObserver: onObserver)
        uiView.reportFrameIfPossible(force: true)
    }

    final class ObserverView: UIView {
        private var image: UIImage?
        private var onLayout: ((UIImage, CGRect) -> Void)?
        private var onObserver: ((UIView, UIImage) -> Void)?
        private var lastReportedFrame: CGRect?

        func configure(
            image: UIImage,
            onLayout: ((UIImage, CGRect) -> Void)?,
            onObserver: ((UIView, UIImage) -> Void)?
        ) {
            if self.image !== image {
                lastReportedFrame = nil
            }
            self.image = image
            self.onLayout = onLayout
            self.onObserver = onObserver
            onObserver?(self, image)
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFrameIfPossible(force: true)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFrameIfPossible()
        }

        func reportFrameIfPossible(force: Bool = false) {
            guard let image,
                  let window,
                  bounds.width >= 2,
                  bounds.height >= 2 else {
                return
            }
            let frameInWindow = convert(bounds, to: window)
            guard frameInWindow.minX.isFinite,
                  frameInWindow.minY.isFinite,
                  frameInWindow.width.isFinite,
                  frameInWindow.height.isFinite else {
                return
            }
            if force == false,
               let lastReportedFrame,
               Self.framesMatch(lastReportedFrame, frameInWindow) {
                return
            }
            lastReportedFrame = frameInWindow
            onLayout?(image, frameInWindow)
        }

        private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            let tolerance: CGFloat = 0.25
            return abs(lhs.minX - rhs.minX) <= tolerance
                && abs(lhs.minY - rhs.minY) <= tolerance
                && abs(lhs.width - rhs.width) <= tolerance
                && abs(lhs.height - rhs.height) <= tolerance
        }
    }
}

struct AvatarView: View {
    let url: URL?
    let title: String?
    let size: CGFloat

    init(url: URL?, title: String? = nil, size: CGFloat = TiebaPureTheme.AvatarSize.medium) {
        self.url = url
        self.title = title
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(TiebaPureTheme.ColorToken.readerTertiarySurface)

            if let url {
                TiebaRemoteImage(
                    primaryURL: url,
                    contentMode: .fill,
                    showsProgress: true,
                    showsRetryButton: false
                )
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(title.map { "\($0)头像" } ?? "头像")
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(.system(size: max(13, size * 0.42), weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
