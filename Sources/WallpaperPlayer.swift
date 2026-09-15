import AppKit
import CoreGraphics
import Foundation

@MainActor
struct ConnectedDisplay: Identifiable {
    let id: String
    let name: String
    let frame: CGRect
    let pixelSize: CGSize
    let isMain: Bool
    let screen: NSScreen
}

@MainActor
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [ConnectedDisplay] = []

    init() { refresh() }

    func refresh() {
        displays = NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            let stableID: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(number) {
                stableID = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
            } else {
                stableID = "display-\(number)"
            }
            return ConnectedDisplay(
                id: stableID,
                name: screen.localizedName,
                frame: screen.frame,
                pixelSize: CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor
                ),
                isMain: screen == NSScreen.main,
                screen: screen
            )
        }
        .sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.frame.minX < rhs.frame.minX
        }
    }
}

@MainActor
final class WallpaperCoordinator: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentItem: WallpaperItem?
    @Published private(set) var lastError: String?
    @Published private(set) var configurations: [DisplayConfiguration] = []

    let displayManager: DisplayManager
    let settings: AppSettings
    var applicationTerminationHandler: (() -> Void)?
    var compatibilityUpdateHandler: ((UUID, CompatibilityStatus, [String]) -> Void)?
    var errorHandler: ((String) -> Void)?

    var scaling: VideoScaling {
        get { settings.defaultScaling }
        set {
            settings.defaultScaling = newValue
            for display in displayManager.displays {
                updatePlayback(for: display.id) { $0.scaling = newValue }
            }
        }
    }

    func clearError() { lastError = nil }

    private enum Keys {
        static let configurations = "display.configurations.v2"
        static let activeID = "player.activeID"
        static let shouldResume = "player.shouldResume"
    }

    private enum SuspensionReason: Hashable {
        case displaySleep
        case sessionLock
        case systemSleep
        case lowPower
        case fullscreen
    }

    @MainActor
    private final class DesktopSession {
        let displayID: String
        let wallpaperID: UUID
        let renderer: any WallpaperRenderer
        let window: NSWindow

        init(displayID: String, wallpaperID: UUID, renderer: any WallpaperRenderer, window: NSWindow) {
            self.displayID = displayID
            self.wallpaperID = wallpaperID
            self.renderer = renderer
            self.window = window
        }

        func stop() {
            renderer.stop()
            window.orderOut(nil)
            window.close()
        }
    }

    private var sessions: [String: DesktopSession] = [:]
    private var preparationTasks: [String: Task<Void, Never>] = [:]
    private var preparationTokens: [String: UUID] = [:]
    private var sharedPreparations: [UUID: Task<PreparedWallpaper, Error>] = [:]
    private var preparedWallpapers: [UUID: PreparedWallpaper] = [:]
    private var libraryByID: [UUID: WallpaperItem] = [:]
    private var suspensionReasons = Set<SuspensionReason>()
    private var manuallyPaused = false
    private var reconnectAssignments = false

    override convenience init() {
        self.init(settings: AppSettings(), displayManager: DisplayManager())
    }

    init(settings: AppSettings, displayManager: DisplayManager) {
        self.settings = settings
        self.displayManager = displayManager
        super.init()
        configurations = Self.loadConfigurations()
        reconcileConfigurationList()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionLocked), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionUnlocked), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(activeSpaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        updatePowerState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func updateLibrary(_ library: [WallpaperItem]) {
        libraryByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        preparedWallpapers = preparedWallpapers.filter { libraryByID[$0.key] != nil }
        for displayID in Array(sessions.keys) {
            if let wallpaperID = sessions[displayID]?.wallpaperID, libraryByID[wallpaperID] == nil {
                sessions.removeValue(forKey: displayID)?.stop()
                if let replacementID = configuration(for: displayID).wallpaperID,
                   let replacement = libraryByID[replacementID],
                   configuration(for: displayID).isEnabled {
                    apply(replacement, to: displayID)
                } else {
                    mutateConfiguration(for: displayID) { $0.wallpaperID = nil }
                }
            }
        }
    }

    func replaceWallpaperID(_ oldID: UUID, with newID: UUID) {
        guard oldID != newID else { return }
        var changed = false
        for index in configurations.indices where configurations[index].wallpaperID == oldID {
            configurations[index].wallpaperID = newID
            changed = true
        }
        if changed { persistConfigurations() }
    }

    func invalidatePreparedWallpaper(_ wallpaperID: UUID) {
        sharedPreparations[wallpaperID]?.cancel()
        sharedPreparations[wallpaperID] = nil
        preparedWallpapers[wallpaperID] = nil
    }

    func play(_ item: WallpaperItem) {
        reconnectAssignments = true
        currentItem = item
        let targets = displayManager.displays.filter { configuration(for: $0.id).isEnabled }
        for display in targets { apply(item, to: display.id) }
        if targets.isEmpty, let first = displayManager.displays.first {
            apply(item, to: first.id)
        }
    }

    func apply(_ item: WallpaperItem, to displayID: String) {
        reconnectAssignments = true
        guard displayManager.displays.contains(where: { $0.id == displayID }) else {
            reportError("The selected display is not connected.")
            return
        }
        mutateConfiguration(for: displayID) {
            $0.isEnabled = true
            $0.wallpaperID = item.id
        }
        currentItem = item
        lastError = nil
        preparationTasks[displayID]?.cancel()
        let expectedWallpaperID = item.id
        let preparationToken = UUID()
        preparationTokens[displayID] = preparationToken
        preparationTasks[displayID] = Task { [weak self] in
            defer {
                if self?.preparationTokens[displayID] == preparationToken {
                    self?.preparationTasks[displayID] = nil
                    self?.preparationTokens[displayID] = nil
                }
            }
            do {
                let prepared = try await self?.preparedWallpaper(for: item)
                try Task.checkCancellation()
                guard let self, let prepared,
                      self.configuration(for: displayID).wallpaperID == expectedWallpaperID,
                      self.configuration(for: displayID).isEnabled,
                      let latestDisplay = self.displayManager.displays.first(where: { $0.id == displayID }) else { return }
                try self.install(prepared, item: item, display: latestDisplay)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if self.configuration(for: displayID).wallpaperID == expectedWallpaperID {
                    let visibleWallpaperID = self.sessions[displayID]?.wallpaperID
                    self.mutateConfiguration(for: displayID) { $0.wallpaperID = visibleWallpaperID }
                }
                self.updatePublishedPlaybackState()
                self.reportError(error.localizedDescription)
                AppLog.renderer.error("Wallpaper preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func restoreIfNeeded(from library: [WallpaperItem]) {
        updateLibrary(library)
        guard settings.restoreOnLaunch else { return }
        reconnectAssignments = true

        let hasModernAssignments = configurations.contains { $0.wallpaperID != nil }
        if !hasModernAssignments,
           UserDefaults.standard.bool(forKey: Keys.shouldResume),
           let rawID = UserDefaults.standard.string(forKey: Keys.activeID),
           let id = UUID(uuidString: rawID) {
            for display in displayManager.displays {
                mutateConfiguration(for: display.id) { $0.wallpaperID = id }
            }
        }

        for display in displayManager.displays {
            let config = configuration(for: display.id)
            guard config.isEnabled, let wallpaperID = config.wallpaperID,
                  let item = libraryByID[wallpaperID] else { continue }
            apply(item, to: display.id)
        }
    }

    func togglePause() { isPaused ? resumeAll() : pauseAll() }

    func pauseAll() {
        manuallyPaused = true
        applyOperationalState()
    }

    func resumeAll() {
        manuallyPaused = false
        applyOperationalState()
    }

    func stop(forget: Bool = true) {
        for task in preparationTasks.values { task.cancel() }
        preparationTasks.removeAll()
        preparationTokens.removeAll()
        for task in sharedPreparations.values { task.cancel() }
        sharedPreparations.removeAll()
        preparedWallpapers.removeAll()
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        isPlaying = false
        isPaused = false
        manuallyPaused = false
        currentItem = nil
        if forget {
            for index in configurations.indices { configurations[index].wallpaperID = nil }
            persistConfigurations()
            UserDefaults.standard.removeObject(forKey: Keys.activeID)
            UserDefaults.standard.set(false, forKey: Keys.shouldResume)
        }
    }

    func stop(displayID: String, forget: Bool = true) {
        preparationTasks[displayID]?.cancel()
        preparationTasks[displayID] = nil
        preparationTokens[displayID] = nil
        sessions.removeValue(forKey: displayID)?.stop()
        if forget { mutateConfiguration(for: displayID) { $0.wallpaperID = nil } }
        prunePreparedWallpapers()
        updatePublishedPlaybackState()
    }

    func stopAssignments(for wallpaperID: UUID) {
        for displayID in configurations.filter({ $0.wallpaperID == wallpaperID }).map(\.displayID) {
            stop(displayID: displayID, forget: true)
        }
    }

    func isWallpaperActive(_ wallpaperID: UUID) -> Bool {
        sessions.values.contains { $0.wallpaperID == wallpaperID }
    }

    func applyGlobalSettings() {
        if !settings.pauseOnScreenSleep { suspensionReasons.remove(.displaySleep) }
        if !settings.pauseOnSessionLock { suspensionReasons.remove(.sessionLock) }
        for (displayID, session) in sessions {
            session.renderer.apply(effectivePlayback(for: configuration(for: displayID)))
        }
        updatePowerState()
        activeSpaceChanged()
    }

    func updatePlaybackForAllDisplays(mutation: (inout PlaybackConfiguration) -> Void) {
        for index in configurations.indices {
            mutation(&configurations[index].playback)
            configurations[index].playback.volume = min(max(configurations[index].playback.volume, 0), 1)
            configurations[index].playback.playbackRate = min(max(configurations[index].playback.playbackRate, 0.25), 2)
        }
        persistConfigurations()
        for (displayID, session) in sessions {
            session.renderer.apply(effectivePlayback(for: configuration(for: displayID)))
        }
    }

    func setEnabled(_ enabled: Bool, for displayID: String) {
        if enabled { reconnectAssignments = true }
        let wasEnabled = configuration(for: displayID).isEnabled
        mutateConfiguration(for: displayID) { $0.isEnabled = enabled }
        if !enabled {
            preparationTasks[displayID]?.cancel()
            preparationTasks[displayID] = nil
            preparationTokens[displayID] = nil
            sessions.removeValue(forKey: displayID)?.stop()
            prunePreparedWallpapers()
            updatePublishedPlaybackState()
        } else if !wasEnabled,
                  let id = configuration(for: displayID).wallpaperID,
                  let item = libraryByID[id] {
            apply(item, to: displayID)
        }
    }

    func updatePlayback(for displayID: String, mutation: (inout PlaybackConfiguration) -> Void) {
        mutateConfiguration(for: displayID) { configuration in
            mutation(&configuration.playback)
            configuration.playback.volume = min(max(configuration.playback.volume, 0), 1)
            configuration.playback.playbackRate = min(max(configuration.playback.playbackRate, 0.25), 2)
        }
        if let session = sessions[displayID] {
            session.renderer.apply(effectivePlayback(for: configuration(for: displayID)))
        }
    }

    func configuration(for displayID: String) -> DisplayConfiguration {
        configurations.first(where: { $0.displayID == displayID })
            ?? DisplayConfiguration(displayID: displayID, playback: settings.defaultDisplayPlayback)
    }

    private func install(_ prepared: PreparedWallpaper, item: WallpaperItem, display: ConnectedDisplay) throws {
        let config = configuration(for: display.id)
        let renderer = try WallpaperRendererFactory.makeRenderer(
            from: prepared,
            configuration: effectivePlayback(for: config),
            pixelSize: display.pixelSize
        )
        renderer.failureHandler = { [weak self] error in
            self?.reportError(error.localizedDescription)
            AppLog.renderer.error("Renderer failed during playback: \(error.localizedDescription, privacy: .public)")
        }
        let window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.configureDesktopWindow(content: renderer.view, display: display)
        let replacement = DesktopSession(displayID: display.id, wallpaperID: item.id, renderer: renderer, window: window)
        sessions.removeValue(forKey: display.id)?.stop()
        sessions[display.id] = replacement
        window.orderFrontRegardless()
        if shouldRender { renderer.play() } else { renderer.pause() }
        UserDefaults.standard.set(item.id.uuidString, forKey: Keys.activeID)
        UserDefaults.standard.set(true, forKey: Keys.shouldResume)
        updatePublishedPlaybackState()
        AppLog.display.info("Applied wallpaper \(item.id.uuidString, privacy: .public) to display \(display.id, privacy: .public)")
    }

    private func preparedWallpaper(for item: WallpaperItem) async throws -> PreparedWallpaper {
        if let prepared = preparedWallpapers[item.id] { return prepared }
        let task: Task<PreparedWallpaper, Error>
        if let existing = sharedPreparations[item.id] {
            task = existing
        } else {
            let created = Task { try await WallpaperRendererFactory.prepare(item) }
            sharedPreparations[item.id] = created
            task = created
        }
        do {
            let prepared = try await task.value
            if case .image(_, let fallbackReason) = prepared, let fallbackReason {
                compatibilityUpdateHandler?(
                    item.id,
                    .fallback,
                    ["The scene renderer failed at runtime; the project preview is being shown.", fallbackReason]
                )
            }
            preparedWallpapers[item.id] = prepared
            sharedPreparations[item.id] = nil
            prunePreparedWallpapers(keeping: item.id)
            return prepared
        } catch {
            sharedPreparations[item.id] = nil
            throw error
        }
    }

    private func prunePreparedWallpapers(keeping additionalID: UUID? = nil) {
        var activeIDs = Set(sessions.values.map(\.wallpaperID))
        if let additionalID { activeIDs.insert(additionalID) }
        for id in Array(preparedWallpapers.keys) where !activeIDs.contains(id) {
            preparedWallpapers[id] = nil
        }
    }

    private func effectivePlayback(for configuration: DisplayConfiguration) -> PlaybackConfiguration {
        var playback = configuration.playback
        if settings.globalMute { playback.isMuted = true }
        playback.volume = min(max(playback.volume, 0), 1)
        playback.playbackRate = min(max(playback.playbackRate, 0.25), 2)
        return playback
    }

    private var shouldRender: Bool { !manuallyPaused && suspensionReasons.isEmpty }

    private func applyOperationalState() {
        if shouldRender {
            sessions.values.forEach { $0.renderer.play() }
        } else {
            sessions.values.forEach { $0.renderer.pause() }
        }
        isPaused = isPlaying && !shouldRender
    }

    private func updatePublishedPlaybackState() {
        isPlaying = !sessions.isEmpty
        isPaused = isPlaying && !shouldRender
        if let mainID = displayManager.displays.first(where: { $0.isMain })?.id,
           let wallpaperID = sessions[mainID]?.wallpaperID {
            currentItem = libraryByID[wallpaperID] ?? currentItem
        } else if let wallpaperID = sessions.values.first?.wallpaperID {
            currentItem = libraryByID[wallpaperID] ?? currentItem
        } else {
            currentItem = nil
        }
    }

    private func mutateConfiguration(for displayID: String, mutation: (inout DisplayConfiguration) -> Void) {
        if let index = configurations.firstIndex(where: { $0.displayID == displayID }) {
            mutation(&configurations[index])
        } else {
            var config = DisplayConfiguration(displayID: displayID, playback: settings.defaultDisplayPlayback)
            mutation(&config)
            configurations.append(config)
        }
        persistConfigurations()
    }

    private func reconcileConfigurationList() {
        for display in displayManager.displays where !configurations.contains(where: { $0.displayID == display.id }) {
            configurations.append(DisplayConfiguration(displayID: display.id, playback: settings.defaultDisplayPlayback))
        }
        persistConfigurations()
    }

    private static func loadConfigurations() -> [DisplayConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: Keys.configurations),
              let decoded = try? JSONDecoder().decode([DisplayConfiguration].self, from: data) else { return [] }
        return decoded
    }

    private func persistConfigurations() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: Keys.configurations)
    }

    private func reportError(_ message: String) {
        lastError = message
        errorHandler?(message)
    }

    @objc private func screensChanged() {
        displayManager.refresh()
        reconcileConfigurationList()
        let connected = Set(displayManager.displays.map(\.id))
        for id in Array(sessions.keys) where !connected.contains(id) {
            sessions.removeValue(forKey: id)?.stop()
        }
        for id in Array(preparationTasks.keys) where !connected.contains(id) {
            preparationTasks[id]?.cancel()
            preparationTasks[id] = nil
            preparationTokens[id] = nil
        }
        for display in displayManager.displays {
            if let session = sessions[display.id] {
                session.window.setFrame(display.frame, display: true)
                session.renderer.resize(to: display.frame.size)
            } else if reconnectAssignments {
                let config = configuration(for: display.id)
                if config.isEnabled, let id = config.wallpaperID, let item = libraryByID[id] {
                    apply(item, to: display.id)
                }
            }
        }
        prunePreparedWallpapers()
        updatePublishedPlaybackState()
    }

    @objc private func screensDidSleep() {
        if settings.pauseOnScreenSleep { suspensionReasons.insert(.displaySleep) }
        applyOperationalState()
    }

    @objc private func screensDidWake() {
        suspensionReasons.remove(.displaySleep)
        applyOperationalState()
    }

    @objc private func systemWillSleep() {
        suspensionReasons.insert(.systemSleep)
        applyOperationalState()
    }

    @objc private func systemDidWake() {
        suspensionReasons.remove(.systemSleep)
        applyOperationalState()
    }

    @objc private func sessionLocked() {
        if settings.pauseOnSessionLock { suspensionReasons.insert(.sessionLock) }
        applyOperationalState()
    }

    @objc private func sessionUnlocked() {
        suspensionReasons.remove(.sessionLock)
        applyOperationalState()
    }

    @objc private func powerStateChanged() { updatePowerState() }

    @objc private func applicationWillTerminate() {
        applicationTerminationHandler?()
        stop(forget: false)
    }

    private func updatePowerState() {
        if settings.pauseInLowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled {
            suspensionReasons.insert(.lowPower)
        } else {
            suspensionReasons.remove(.lowPower)
        }
        applyOperationalState()
    }

    @objc private func activeSpaceChanged() {
        guard settings.pauseWhenFullscreen else {
            suspensionReasons.remove(.fullscreen)
            applyOperationalState()
            return
        }
        if Self.frontmostApplicationIsFullscreen(on: displayManager.displays) {
            suspensionReasons.insert(.fullscreen)
        } else {
            suspensionReasons.remove(.fullscreen)
        }
        applyOperationalState()
    }

    private static func frontmostApplicationIsFullscreen(on displays: [ConnectedDisplay]) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != NSRunningApplication.current.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            if displays.contains(where: { abs($0.frame.width - bounds.width) < 2 && abs($0.frame.height - bounds.height) < 2 }) {
                return true
            }
        }
        return false
    }
}

typealias WallpaperPlayer = WallpaperCoordinator

@MainActor
private extension NSWindow {
    func configureDesktopWindow(content: NSView, display: ConnectedDisplay) {
        contentView = content
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        setFrame(display.frame, display: true)
    }
}
