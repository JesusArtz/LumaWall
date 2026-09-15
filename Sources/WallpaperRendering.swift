import AppKit
import AVFoundation
import QuartzCore
import SwiftUI
import WebKit

struct RendererCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let scaling = RendererCapabilities(rawValue: 1 << 0)
    static let audio = RendererCapabilities(rawValue: 1 << 1)
    static let playbackRate = RendererCapabilities(rawValue: 1 << 2)
    static let mouseInput = RendererCapabilities(rawValue: 1 << 3)
}

@MainActor
protocol WallpaperRenderer: AnyObject {
    var view: NSView { get }
    var capabilities: RendererCapabilities { get }
    var failureHandler: (@MainActor (Error) -> Void)? { get set }
    func play()
    func pause()
    func stop()
    func apply(_ configuration: PlaybackConfiguration)
    func resize(to size: CGSize)
}

/// Injection point for a future, versioned Wallpaper Engine web bridge. The
/// default renderer deliberately installs no emulated API surface.
@MainActor
protocol WebWallpaperExtension: AnyObject {
    var userScripts: [WKUserScript] { get }
    func documentDidLoad(in webView: WKWebView)
}

extension WebWallpaperExtension {
    var userScripts: [WKUserScript] { [] }
    func documentDidLoad(in webView: WKWebView) {}
}

enum WallpaperRendererError: LocalizedError {
    case missingAsset
    case unplayableVideo
    case invalidWebRoot
    case webProcessTerminated
    case unsupported

    var errorDescription: String? {
        switch self {
        case .missingAsset: return "The wallpaper asset is missing."
        case .unplayableVideo: return "macOS cannot play this video file."
        case .invalidWebRoot: return "The web wallpaper is outside its project directory."
        case .webProcessTerminated: return "The web wallpaper process stopped unexpectedly."
        case .unsupported: return "This wallpaper type is not supported by the current renderer."
        }
    }
}

enum PreparedWallpaper: @unchecked Sendable {
    case video(URL)
    case web(fileURL: URL, readAccessURL: URL)
    case scene(SceneResources)
    case image(URL, fallbackReason: String?)
}

enum WallpaperRendererFactory {
    static func prepare(_ item: WallpaperItem) async throws -> PreparedWallpaper {
        guard FileManager.default.fileExists(atPath: item.sourcePath) else {
            throw WallpaperRendererError.missingAsset
        }

        switch item.kind {
        case .video:
            let url = item.sourceURL
            let playable = try await AVURLAsset(url: url).load(.isPlayable)
            guard playable else { throw WallpaperRendererError.unplayableVideo }
            return .video(url)

        case .web:
            let fileURL = FileUtilities.canonicalURL(item.sourceURL)
            let root = FileUtilities.canonicalURL(item.projectRootURL ?? fileURL.deletingLastPathComponent())
            guard FileUtilities.isDescendant(fileURL, of: root) else {
                throw WallpaperRendererError.invalidWebRoot
            }
            return .web(fileURL: fileURL, readAccessURL: root)

        case .scenePackage:
            if item.compatibility == .fallback,
               let previewURL = item.previewURL,
               ImageFileSafety.isUsablePreview(previewURL) {
                return .image(previewURL, fallbackReason: nil)
            }
            guard item.compatibility != .unsupported else { throw WallpaperRendererError.unsupported }
            do {
                let resources = try await Task.detached(priority: .userInitiated) {
                    try SceneResources(packageURL: item.sourceURL)
                }.value
                return .scene(resources)
            } catch {
                if let previewURL = item.previewURL,
                   ImageFileSafety.isUsablePreview(previewURL) {
                    AppLog.scene.notice("Using preview fallback for \(item.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return .image(previewURL, fallbackReason: error.localizedDescription)
                }
                throw error
            }

        case .unsupported:
            throw WallpaperRendererError.unsupported
        }
    }

    @MainActor
    static func makeRenderer(
        from prepared: PreparedWallpaper,
        configuration: PlaybackConfiguration,
        pixelSize: CGSize
    ) throws -> any WallpaperRenderer {
        let renderer: any WallpaperRenderer
        switch prepared {
        case .video(let url):
            renderer = VideoWallpaperRenderer(url: url, maximumResolution: pixelSize)
        case .web(let fileURL, let readAccessURL):
            renderer = WebWallpaperRenderer(fileURL: fileURL, readAccessURL: readAccessURL)
        case .scene(let resources):
            renderer = try SceneWallpaperRenderer(resources: resources, scaling: configuration.scaling)
        case .image(let url, _):
            guard ImageFileSafety.isUsablePreview(url), let image = NSImage(contentsOf: url) else {
                throw WallpaperRendererError.missingAsset
            }
            renderer = ImageWallpaperRenderer(image: image)
        }
        renderer.apply(configuration)
        return renderer
    }
}

@MainActor
final class VideoWallpaperRenderer: WallpaperRenderer {
    let view: NSView
    let capabilities: RendererCapabilities = [.scaling, .audio, .playbackRate]
    var failureHandler: (@MainActor (Error) -> Void)?

    private let queuePlayer: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let templateItem: AVPlayerItem
    private let playerView: VideoPlayerView
    private var configuration = PlaybackConfiguration.default
    private var playing = false
    private var failureObserver: NSObjectProtocol?

    init(url: URL, maximumResolution: CGSize) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        if maximumResolution.width > 0, maximumResolution.height > 0 {
            item.preferredMaximumResolution = maximumResolution
        }
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        queuePlayer = player
        templateItem = item
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerView = VideoPlayerView(player: player)
        view = playerView
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      let failedItem = notification.object as? AVPlayerItem,
                      self.queuePlayer.items().contains(where: { $0 === failedItem }) else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    ?? WallpaperRendererError.unplayableVideo
                self.failureHandler?(error)
            }
        }
    }

    func play() {
        playing = true
        queuePlayer.playImmediately(atRate: Float(configuration.playbackRate))
    }

    func pause() {
        playing = false
        queuePlayer.pause()
    }

    func stop() {
        playing = false
        queuePlayer.pause()
        looper.disableLooping()
        queuePlayer.removeAllItems()
        playerView.videoLayer.player = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
    }

    func apply(_ configuration: PlaybackConfiguration) {
        self.configuration = configuration.normalized
        queuePlayer.isMuted = self.configuration.isMuted
        queuePlayer.volume = Float(self.configuration.volume)
        playerView.videoLayer.videoGravity = self.configuration.scaling == .fill ? .resizeAspectFill : .resizeAspect
        if playing {
            queuePlayer.rate = Float(self.configuration.playbackRate)
        }
    }

    func resize(to size: CGSize) {
        playerView.frame.size = size
        playerView.needsLayout = true
        let scale = playerView.window?.backingScaleFactor ?? 1
        let resolution = CGSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        templateItem.preferredMaximumResolution = resolution
        for item in queuePlayer.items() { item.preferredMaximumResolution = resolution }
    }
}

@MainActor
final class WebWallpaperRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate {
    let view: NSView
    let capabilities: RendererCapabilities = [.audio, .playbackRate, .mouseInput]
    var failureHandler: (@MainActor (Error) -> Void)?

    private let webView: WKWebView
    private let fileURL: URL
    private let readAccessURL: URL
    private let extensions: [any WebWallpaperExtension]
    private var configuration = PlaybackConfiguration.default
    private var loadStarted = false
    private var paused = false

    init(fileURL: URL, readAccessURL: URL, extensions: [any WebWallpaperExtension] = []) {
        self.fileURL = fileURL
        self.readAccessURL = readAccessURL
        self.extensions = extensions
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.mediaTypesRequiringUserActionForPlayback = []
        webConfiguration.allowsAirPlayForMediaPlayback = false
        for webExtension in extensions {
            for script in webExtension.userScripts {
                webConfiguration.userContentController.addUserScript(script)
            }
        }

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.underPageBackgroundColor = .black
        self.webView = webView
        view = webView
        super.init()
        webView.navigationDelegate = self
    }

    func play() {
        paused = false
        if !loadStarted {
            loadStarted = true
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }
        Task { await webView.setAllMediaPlaybackSuspended(false) }
        evaluatePlaybackScript(paused: false)
    }

    func pause() {
        paused = true
        Task { await webView.setAllMediaPlaybackSuspended(true) }
        evaluatePlaybackScript(paused: true)
    }

    func stop() {
        paused = true
        webView.stopLoading()
        Task { await webView.setAllMediaPlaybackSuspended(true) }
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    func apply(_ configuration: PlaybackConfiguration) {
        self.configuration = configuration.normalized
        evaluatePlaybackScript(paused: nil)
    }

    func resize(to size: CGSize) {
        webView.frame.size = size
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        for webExtension in extensions { webExtension.documentDidLoad(in: webView) }
        Task { await webView.setAllMediaPlaybackSuspended(paused) }
        evaluatePlaybackScript(paused: paused)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failureHandler?(WallpaperRendererError.webProcessTerminated)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let allowed = (url.isFileURL && FileUtilities.isDescendant(url, of: readAccessURL))
            || url.absoluteString == "about:blank"
        if !allowed {
            AppLog.web.notice("Blocked web wallpaper navigation to \(url.scheme ?? "unknown", privacy: .public)")
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    private func reportNavigationFailure(_ error: Error) {
        let cocoaError = error as NSError
        guard !(cocoaError.domain == NSURLErrorDomain && cocoaError.code == NSURLErrorCancelled) else { return }
        failureHandler?(error)
    }

    private func evaluatePlaybackScript(paused: Bool?) {
        let muted = configuration.isMuted ? "true" : "false"
        let volume = configuration.volume
        let rate = configuration.playbackRate
        let pauseStatement: String
        switch paused {
        case true?: pauseStatement = "element.pause();"
        case false?: pauseStatement = "element.play().catch(function() {});"
        case nil: pauseStatement = ""
        }
        let animationStatement: String
        if let paused {
            animationStatement = "element.style.animationPlayState = '\(paused ? "paused" : "running")';"
        } else {
            animationStatement = ""
        }
        let script = """
        (function() {
          document.querySelectorAll('video,audio').forEach(function(element) {
            element.muted = \(muted);
            element.volume = \(volume);
            element.playbackRate = \(rate);
            \(pauseStatement)
          });
          document.querySelectorAll('*').forEach(function(element) {
            \(animationStatement)
          });
          \(paused.map { "window.dispatchEvent(new Event('\($0 ? "blur" : "focus")'));" } ?? "")
        })();
        """
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                AppLog.web.debug("Web lifecycle script was not applied: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

@MainActor
final class SceneWallpaperRenderer: WallpaperRenderer {
    let view: NSView
    let capabilities: RendererCapabilities = [.scaling]
    var failureHandler: (@MainActor (Error) -> Void)?
    private let sceneView: SceneMetalView

    init(resources: SceneResources, scaling: VideoScaling) throws {
        let sceneView = try SceneMetalView(frame: .zero, resources: resources, scaling: scaling)
        self.sceneView = sceneView
        view = sceneView
    }

    func play() { sceneView.isPaused = false }
    func pause() { sceneView.isPaused = true }
    func stop() { sceneView.isPaused = true }
    func apply(_ configuration: PlaybackConfiguration) { sceneView.scaling = configuration.scaling }
    func resize(to size: CGSize) { sceneView.frame.size = size }
}

@MainActor
final class ImageWallpaperRenderer: WallpaperRenderer {
    let view: NSView
    let capabilities: RendererCapabilities = [.scaling]
    var failureHandler: (@MainActor (Error) -> Void)?
    private let imageView: FallbackImageView

    init(image: NSImage) {
        let imageView = FallbackImageView(image: image)
        self.imageView = imageView
        view = imageView
    }

    func play() {}
    func pause() {}
    func stop() { imageView.wallpaperImage = nil }
    func apply(_ configuration: PlaybackConfiguration) {
        imageView.scaling = configuration.scaling
    }
    func resize(to size: CGSize) { imageView.frame.size = size }
}

@MainActor
private final class FallbackImageView: NSView {
    var wallpaperImage: NSImage? {
        didSet { layer?.contents = wallpaperImage }
    }
    var scaling: VideoScaling = .fill {
        didSet { layer?.contentsGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect }
    }

    init(image: NSImage) {
        wallpaperImage = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class VideoPlayerView: NSView {
    let videoLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.player = player
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

@MainActor
private final class RendererHostView: NSView {
    var renderer: (any WallpaperRenderer)? {
        didSet {
            subviews.forEach { $0.removeFromSuperview() }
            guard let renderer else { return }
            addSubview(renderer.view)
            renderer.view.frame = bounds
            renderer.view.autoresizingMask = [.width, .height]
        }
    }

    func showLoading() {
        renderer = nil
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.startAnimation(nil)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func showError(_ message: String) {
        renderer = nil
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    override func layout() {
        super.layout()
        renderer?.view.frame = bounds
        renderer?.resize(to: bounds.size)
    }
}

struct WallpaperPreview: NSViewRepresentable {
    let item: WallpaperItem
    var configuration: PlaybackConfiguration

    func makeCoordinator() -> PreviewCoordinator { PreviewCoordinator() }

    func makeNSView(context: Context) -> NSView {
        let host = RendererHostView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.showLoading()
        context.coordinator.load(item: item, configuration: configuration, into: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? RendererHostView else { return }
        if context.coordinator.itemID != item.id {
            context.coordinator.load(item: item, configuration: configuration, into: host)
        } else {
            context.coordinator.update(configuration: configuration)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: PreviewCoordinator) {
        coordinator.stop()
        (nsView as? RendererHostView)?.renderer = nil
    }

    @MainActor
    final class PreviewCoordinator {
        fileprivate var itemID: UUID?
        fileprivate var renderer: (any WallpaperRenderer)?
        private var task: Task<Void, Never>?
        private var configuration = PlaybackConfiguration.default

        fileprivate func load(item: WallpaperItem, configuration: PlaybackConfiguration, into host: RendererHostView) {
            stop()
            itemID = item.id
            self.configuration = configuration
            host.showLoading()
            task = Task { [weak self, weak host] in
                do {
                    let prepared = try await WallpaperRendererFactory.prepare(item)
                    guard !Task.isCancelled, let self, let host, self.itemID == item.id else { return }
                    let scale = host.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                    let size = CGSize(width: max(host.bounds.width * scale, 1), height: max(host.bounds.height * scale, 1))
                    let renderer = try WallpaperRendererFactory.makeRenderer(
                        from: prepared,
                        configuration: self.configuration,
                        pixelSize: size
                    )
                    self.renderer = renderer
                    host.renderer = renderer
                    renderer.play()
                } catch {
                    guard !Task.isCancelled, let self, self.itemID == item.id else { return }
                    AppLog.renderer.error("Preview failed: \(error.localizedDescription, privacy: .public)")
                    host?.showError(error.localizedDescription)
                }
            }
        }

        fileprivate func update(configuration: PlaybackConfiguration) {
            self.configuration = configuration
            renderer?.apply(configuration)
        }

        fileprivate func stop() {
            task?.cancel()
            task = nil
            renderer?.stop()
            renderer = nil
        }
    }
}

private extension PlaybackConfiguration {
    var normalized: PlaybackConfiguration {
        var value = self
        value.volume = min(max(value.volume, 0), 1)
        value.playbackRate = min(max(value.playbackRate, 0.25), 2)
        return value
    }
}
