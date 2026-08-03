import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class WallpaperPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentItem: WallpaperItem?
    @Published private(set) var lastError: String?
    @Published var scaling: VideoScaling {
        didSet {
            UserDefaults.standard.set(scaling.rawValue, forKey: Keys.scaling)
            windows.forEach {
                ($0.contentView as? VideoPlayerView)?.videoLayer.videoGravity = gravity
                ($0.contentView as? SceneMetalView)?.scaling = scaling
            }
        }
    }

    private enum Keys {
        static let scaling = "player.scaling"
        static let activeID = "player.activeID"
        static let shouldResume = "player.shouldResume"
    }

    private var player: AVPlayer?
    private var sceneResources: SceneResources?
    private var windows: [NSWindow] = []
    private var endObserver: NSObjectProtocol?
    private var pausedBySystem = false

    override init() {
        scaling = VideoScaling(rawValue: UserDefaults.standard.string(forKey: Keys.scaling) ?? "") ?? .fill
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemPaused), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemResumed), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemPaused), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemResumed), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ item: WallpaperItem) {
        stop(forget: false)
        guard FileManager.default.fileExists(atPath: item.sourcePath) else { return }

        if item.kind == .scenePackage {
            do {
                sceneResources = try SceneResources(packageURL: item.sourceURL)
                activate(item)
                rebuildWindows()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }

        let playerItem = AVPlayerItem(url: item.sourceURL)
        playerItem.preferredForwardBufferDuration = 1
        if let largest = NSScreen.screens.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            playerItem.preferredMaximumResolution = CGSize(width: largest.frame.width * largest.backingScaleFactor, height: largest.frame.height * largest.backingScaleFactor)
        }
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        activate(item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player?.play()
        }
        rebuildWindows()
        player.play()
    }

    func togglePause() {
        guard isPlaying else { return }
        isPaused.toggle()
        if isPaused { player?.pause() } else { player?.play() }
        sceneViews.forEach { $0.isPaused = isPaused }
    }

    func clearError() { lastError = nil }

    func stop(forget: Bool = true) {
        player?.pause()
        player = nil
        sceneResources = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        isPlaying = false
        isPaused = false
        pausedBySystem = false
        UserDefaults.standard.set(false, forKey: Keys.shouldResume)
        if forget {
            currentItem = nil
            UserDefaults.standard.removeObject(forKey: Keys.activeID)
        }
    }

    func restoreIfNeeded(from library: [WallpaperItem]) {
        guard UserDefaults.standard.bool(forKey: Keys.shouldResume),
              let rawID = UserDefaults.standard.string(forKey: Keys.activeID),
              let id = UUID(uuidString: rawID),
              let item = library.first(where: { $0.id == id }) else { return }
        play(item)
    }

    @objc private func screensChanged() { rebuildWindows() }
    @objc private func systemPaused() {
        guard isPlaying, !isPaused else { return }
        pausedBySystem = true
        player?.pause()
        sceneViews.forEach { $0.isPaused = true }
    }
    @objc private func systemResumed() {
        guard isPlaying, !isPaused, pausedBySystem else { return }
        pausedBySystem = false
        player?.play()
        sceneViews.forEach { $0.isPaused = false }
    }

    private var sceneViews: [SceneMetalView] { windows.compactMap { $0.contentView as? SceneMetalView } }
    private var gravity: AVLayerVideoGravity { scaling == .fill ? .resizeAspectFill : .resizeAspect }

    private func activate(_ item: WallpaperItem) {
        currentItem = item
        isPlaying = true
        isPaused = false
        lastError = nil
        UserDefaults.standard.set(item.id.uuidString, forKey: Keys.activeID)
        UserDefaults.standard.set(true, forKey: Keys.shouldResume)
    }

    private func rebuildWindows() {
        guard isPlaying else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let sceneResources {
            for screen in NSScreen.screens {
                guard let sceneView = try? SceneMetalView(frame: screen.frame, resources: sceneResources, scaling: scaling) else { continue }
                let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.configureDesktopWindow(content: sceneView, screen: screen)
                windows.append(window)
            }
        } else if let player {
            windows = NSScreen.screens.map { screen in
                let view = VideoPlayerView(player: player, gravity: gravity)
                let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.configureDesktopWindow(content: view, screen: screen)
                return window
            }
        }
        windows.forEach { $0.orderFrontRegardless() }
    }
}

private final class VideoPlayerView: NSView {
    let videoLayer = AVPlayerLayer()
    init(player: AVPlayer, gravity: AVLayerVideoGravity) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.player = player
        videoLayer.videoGravity = gravity
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

private extension NSWindow {
    func configureDesktopWindow(content: NSView, screen: NSScreen) {
        contentView = content
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: true)
    }
}
