import AppKit
import Foundation
import ServiceManagement

enum AppSection: String, CaseIterable, Identifiable {
    case discover
    case library
    case playlists
    case displays
    case settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .discover: return "safari"
        case .library: return "square.grid.2x2"
        case .playlists: return "music.note.list"
        case .displays: return "display.2"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var library: [WallpaperItem] = []
    @Published private(set) var playlists: [WallpaperPlaylist] = []
    @Published var selectedID: WallpaperItem.ID?
    @Published var selectedPlaylistID: WallpaperPlaylist.ID?
    @Published var selectedSection: AppSection? = .library
    @Published var issue: AppIssue?
    @Published private(set) var isImporting = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var activePlaylistID: UUID?
    @Published private(set) var previewCacheSize: Int64 = 0
    @Published private(set) var favoriteWorkshopIDs: Set<String> = []

    let settings: AppSettings
    let storage: WallpaperStorage
    let player: WallpaperCoordinator
    let workshop: WorkshopViewModel
    let steam: SteamCmdService

    private enum Keys {
        static let legacyLibrary = "wallpaper.library.v1"
        static let libraryMigrationComplete = "migration.library.v2.complete"
    }

    private var playlistTask: Task<Void, Never>?
    private var retryDownloadID: UUID?
    private var recoveryFileURL: URL?
    private var pendingImportCount = 0

    init(
        settings: AppSettings? = nil,
        storage: WallpaperStorage = WallpaperStorage(),
        displayManager: DisplayManager? = nil
    ) {
        let settings = settings ?? AppSettings()
        let displayManager = displayManager ?? DisplayManager()
        self.settings = settings
        self.storage = storage
        player = WallpaperCoordinator(settings: settings, displayManager: displayManager)
        workshop = WorkshopViewModel(settings: settings)
        steam = SteamCmdService(settings: settings, storage: storage)

        loadPersistedState()
        selectedID = library.first?.id
        selectedPlaylistID = playlists.first?.id
        player.applicationTerminationHandler = { [weak steam] in steam?.shutdown() }
        player.compatibilityUpdateHandler = { [weak self] id, status, notes in
            self?.updateCompatibility(id: id, status: status, notes: notes)
        }
        player.errorHandler = { [weak self] message in self?.presentRendererFailure(message) }
        player.updateLibrary(library)
        player.restoreIfNeeded(from: library)
        steam.importHandler = { [weak self] item in self?.receiveDownloadedWallpaper(item) }
        steam.failureHandler = { [weak self] download in self?.presentDownloadFailure(download) }
        refreshPreviewCacheSize()
    }

    deinit { playlistTask?.cancel() }

    var selectedItem: WallpaperItem? { library.first { $0.id == selectedID } }
    var selectedPlaylist: WallpaperPlaylist? { playlists.first { $0.id == selectedPlaylistID } }
    var recentWallpapers: [WallpaperItem] {
        library.filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "Import Wallpaper"
        panel.message = "Choose a Wallpaper Engine project folder, ZIP, scene.pkg, or supported video."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        for (index, url) in panel.urls.enumerated() {
            importWallpaper(url, playImmediately: index == panel.urls.count - 1)
        }
    }

    func importWallpaper(_ url: URL, playImmediately: Bool = true) {
        pendingImportCount += 1
        isImporting = true
        let storage = storage
        let canonicalSource = FileUtilities.canonicalURL(url)
        let preferredIdentity = library.first { item in
            FileUtilities.canonicalURL(item.sourceURL) == canonicalSource
                || item.source.originalPath.map { FileUtilities.canonicalURL(URL(fileURLWithPath: $0)) == canonicalSource } == true
        }?.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let newItem = try await Task.detached(priority: .userInitiated) {
                    try storage.importLocal(from: url, preferredIdentity: preferredIdentity)
                }.value
                let item = upsert(newItem)
                selectedID = item.id
                try saveLibrary()
                if playImmediately { play(item) }
            } catch {
                recoveryFileURL = url
                present(.importing(error))
                AppLog.library.error("Import failed: \(error.localizedDescription, privacy: .public)")
            }
            pendingImportCount = max(0, pendingImportCount - 1)
            isImporting = pendingImportCount > 0
        }
    }

    func playSelected(on displayID: String? = nil) {
        guard let selectedItem else { return }
        play(selectedItem, on: displayID)
    }

    func play(_ item: WallpaperItem, on displayID: String? = nil) {
        if activePlaylistID != nil { stopPlaylist() }
        playWallpaper(item, on: displayID)
    }

    private func playWallpaper(_ item: WallpaperItem, on displayID: String? = nil) {
        guard FileManager.default.fileExists(atPath: item.sourcePath) else {
            present(AppIssue(
                title: "Wallpaper File Missing",
                message: "The wallpaper’s main file is no longer available.",
                technicalDetails: item.sourcePath,
                recoveryAction: .openLibrary
            ))
            return
        }
        if let index = library.firstIndex(where: { $0.id == item.id }) {
            library[index].lastPlayedAt = Date()
            selectedID = item.id
            do { try saveLibrary() }
            catch { presentPersistenceError(error) }
        }
        if let displayID { player.apply(item, to: displayID) }
        else { player.play(item) }
    }

    func toggleFavorite(_ itemID: UUID) {
        guard let index = library.firstIndex(where: { $0.id == itemID }) else { return }
        library[index].isFavorite.toggle()
        if let workshopID = library[index].workshopID {
            if library[index].isFavorite { favoriteWorkshopIDs.insert(workshopID) }
            else { favoriteWorkshopIDs.remove(workshopID) }
            WorkshopFavoriteStore.save(favoriteWorkshopIDs)
        }
        do { try saveLibrary() }
        catch { presentPersistenceError(error) }
    }

    func isFavorite(_ workshopItem: WorkshopItem) -> Bool {
        localWallpaper(for: workshopItem)?.isFavorite == true
            || favoriteWorkshopIDs.contains(workshopItem.publishedFileID)
    }

    func toggleFavorite(_ workshopItem: WorkshopItem) {
        if let local = localWallpaper(for: workshopItem) {
            toggleFavorite(local.id)
            return
        }
        if favoriteWorkshopIDs.contains(workshopItem.publishedFileID) {
            favoriteWorkshopIDs.remove(workshopItem.publishedFileID)
        } else {
            favoriteWorkshopIDs.insert(workshopItem.publishedFileID)
        }
        WorkshopFavoriteStore.save(favoriteWorkshopIDs)
    }

    func remove(_ item: WallpaperItem) {
        player.stopAssignments(for: item.id)
        playlistTask?.cancel()
        if activePlaylistID != nil { activePlaylistID = nil }
        let storage = storage
        Task { [weak self] in
            guard let self else { return }
            do {
                if item.isManaged {
                    try await Task.detached(priority: .utility) {
                        try storage.removeManagedContent(for: item)
                    }.value
                }
                library.removeAll { $0.id == item.id }
                for index in playlists.indices {
                    playlists[index].wallpaperIDs.removeAll { $0 == item.id }
                }
                selectedID = library.first?.id
                try saveLibrary()
                try savePlaylists()
            } catch {
                recoveryFileURL = item.projectRootURL ?? item.sourceURL
                present(AppIssue(
                    title: "Couldn’t Remove Wallpaper",
                    message: error.localizedDescription,
                    technicalDetails: String(reflecting: error),
                    recoveryAction: .showFile
                ))
            }
        }
    }

    func removeSelected() {
        guard let selectedItem else { return }
        remove(selectedItem)
    }

    func showInFinder(_ item: WallpaperItem) {
        let url = item.projectRootURL ?? item.sourceURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showRecoveryFile() {
        guard let recoveryFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryFileURL])
    }

    func openStorageDirectory() {
        do {
            try storage.prepareDirectories()
            guard NSWorkspace.shared.open(storage.rootURL) else {
                throw WallpaperStorage.StorageError.directoryUnavailable
            }
        } catch {
            presentPersistenceError(error)
        }
    }

    func clearPreviewCache() {
        let storage = storage
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .utility) { try storage.clearPreviewCache() }.value
                LocalPreviewImageCache.clear()
                previewCacheSize = 0
            } catch {
                presentPersistenceError(error)
            }
        }
    }

    func refreshPreviewCacheSize() {
        let storage = storage
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) { storage.cacheSize }.value
            self?.previewCacheSize = size
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            present(AppIssue(
                title: "Couldn’t Change Login Setting",
                message: error.localizedDescription,
                technicalDetails: String(reflecting: error),
                recoveryAction: .openSettings
            ))
        }
    }

    func applyPlaybackSettings() { player.applyGlobalSettings() }

    func applyDefaultVolume() {
        player.updatePlaybackForAllDisplays { $0.volume = settings.globalVolume }
    }

    func applyDefaultScaling() {
        player.updatePlaybackForAllDisplays { $0.scaling = settings.defaultScaling }
    }

    func applyDefaultPlaybackRate() {
        player.updatePlaybackForAllDisplays { $0.playbackRate = settings.playbackRate }
    }

    func chooseSteamCMD() {
        let panel = NSOpenPanel()
        panel.title = "Choose SteamCMD"
        panel.message = "On macOS, select steamcmd.sh when it is available."
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            present(AppIssue(
                title: "SteamCMD Isn’t Executable",
                message: "Choose a SteamCMD executable file.",
                technicalDetails: url.path,
                recoveryAction: .locateSteamCMD
            ))
            return
        }
        settings.steamCMDPath = url.path
        steam.refreshExecutableLocation()
    }

    func download(_ item: WorkshopItem) {
        guard steam.detectedExecutableURL != nil else {
            present(AppIssue(
                title: "SteamCMD Required",
                message: SteamCMDConfigurationError.executableMissing.localizedDescription,
                recoveryAction: .locateSteamCMD
            ))
            return
        }
        guard !settings.steamUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            present(AppIssue(
                title: "Steam Sign-In Required",
                message: SteamCMDConfigurationError.invalidUsername.localizedDescription,
                recoveryAction: .openSettings
            ))
            return
        }
        _ = steam.enqueue(item)
    }

    func localWallpaper(for workshopItem: WorkshopItem) -> WallpaperItem? {
        library.first { $0.workshopID == workshopItem.publishedFileID }
    }

    func download(for workshopItem: WorkshopItem) -> WallpaperDownload? {
        steam.downloads.first { $0.workshopItem.publishedFileID == workshopItem.publishedFileID }
    }

    @discardableResult
    func createPlaylist(named proposedName: String) -> WallpaperPlaylist {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = WallpaperPlaylist(name: trimmed.isEmpty ? "New Playlist" : trimmed)
        playlists.append(playlist)
        selectedPlaylistID = playlist.id
        persistPlaylistsReportingErrors()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to proposedName: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[index].name = trimmed
        persistPlaylistsReportingErrors()
    }

    func deletePlaylist(_ id: UUID) {
        if activePlaylistID == id { stopPlaylist() }
        playlists.removeAll { $0.id == id }
        selectedPlaylistID = playlists.first?.id
        persistPlaylistsReportingErrors()
    }

    func add(_ wallpaperID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              library.contains(where: { $0.id == wallpaperID }),
              !playlists[index].wallpaperIDs.contains(wallpaperID) else { return }
        playlists[index].wallpaperIDs.append(wallpaperID)
        persistPlaylistsReportingErrors()
    }

    func remove(_ wallpaperID: UUID, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].wallpaperIDs.removeAll { $0 == wallpaperID }
        persistPlaylistsReportingErrors()
    }

    func movePlaylistItems(in playlistID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].wallpaperIDs.move(fromOffsets: offsets, toOffset: destination)
        persistPlaylistsReportingErrors()
    }

    func updatePlaylist(
        _ id: UUID,
        mode: PlaylistPlaybackMode? = nil,
        interval: TimeInterval? = nil
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        if let mode { playlists[index].playbackMode = mode }
        if let interval { playlists[index].interval = min(max(interval, 30), 86_400) }
        persistPlaylistsReportingErrors()
    }

    func startPlaylist(_ id: UUID, on displayID: String? = nil) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        let available = playlist.wallpaperIDs.compactMap { id in library.first { $0.id == id } }
        guard !available.isEmpty else {
            present(AppIssue(
                title: "Playlist Is Empty",
                message: "Add at least one downloaded wallpaper before starting this playlist."
            ))
            return
        }
        stopPlaylist()
        activePlaylistID = id
        playWallpaper(available[0], on: displayID)
        playlistTask = Task { [weak self] in
            var position = 0
            var previousID = available[0].id
            while !Task.isCancelled {
                guard let self,
                      let current = self.playlists.first(where: { $0.id == id }) else { return }
                let nanoseconds = UInt64(min(max(current.interval, 30), 86_400) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                let candidates = current.wallpaperIDs.compactMap { wallpaperID in
                    self.library.first { $0.id == wallpaperID }
                }
                guard !candidates.isEmpty else { continue }
                let next: WallpaperItem
                switch current.playbackMode {
                case .sequential:
                    position = (position + 1) % candidates.count
                    next = candidates[position]
                case .shuffle:
                    let choices = candidates.filter { candidates.count == 1 || $0.id != previousID }
                    next = choices.randomElement() ?? candidates[0]
                }
                previousID = next.id
                self.playWallpaper(next, on: displayID)
            }
        }
    }

    func stopPlaylist() {
        playlistTask?.cancel()
        playlistTask = nil
        activePlaylistID = nil
    }

    func dismissIssue() {
        issue = nil
        retryDownloadID = nil
        recoveryFileURL = nil
    }

    func retryLastIssue() {
        let downloadID = retryDownloadID
        issue = nil
        retryDownloadID = nil
        if let downloadID {
            steam.retry(downloadID)
        } else {
            do {
                try saveLibrary()
                try savePlaylists()
            } catch {
                presentPersistenceError(error)
            }
        }
    }

    func presentRendererFailure(_ message: String) {
        present(AppIssue(
            title: "Couldn’t Play Wallpaper",
            message: message,
            technicalDetails: message,
            recoveryAction: .openLibrary
        ))
    }

    private func loadPersistedState() {
        favoriteWorkshopIDs = WorkshopFavoriteStore.load()
        do {
            try storage.prepareDirectories()
            library = try storage.loadLibrary()
            playlists = try storage.loadPlaylists()
            for index in library.indices {
                if let workshopID = library[index].workshopID,
                   favoriteWorkshopIDs.contains(workshopID) {
                    library[index].isFavorite = true
                }
            }
            favoriteWorkshopIDs.formUnion(
                library.compactMap { $0.isFavorite ? $0.workshopID : nil }
            )
            WorkshopFavoriteStore.save(favoriteWorkshopIDs)
        } catch {
            presentPersistenceError(error)
        }

        guard !UserDefaults.standard.bool(forKey: Keys.libraryMigrationComplete) else { return }
        if let data = UserDefaults.standard.data(forKey: Keys.legacyLibrary),
           let legacy = try? JSONDecoder().decode([WallpaperItem].self, from: data) {
            for item in legacy { _ = upsert(item) }
        }
        do {
            try storage.saveLibrary(library)
            UserDefaults.standard.set(true, forKey: Keys.libraryMigrationComplete)
            AppLog.storage.info("Completed idempotent library metadata migration")
        } catch {
            presentPersistenceError(error)
        }
    }

    @discardableResult
    private func upsert(_ incoming: WallpaperItem) -> WallpaperItem {
        var incoming = incoming
        if let workshopID = incoming.workshopID, favoriteWorkshopIDs.contains(workshopID) {
            incoming.isFavorite = true
        }
        let existingIndex = library.firstIndex { existing in
            existing.id == incoming.id
                || (incoming.workshopID != nil && existing.workshopID == incoming.workshopID)
                || FileUtilities.canonicalURL(existing.sourceURL) == FileUtilities.canonicalURL(incoming.sourceURL)
        }
        if let existingIndex {
            var merged = incoming
            let existing = library[existingIndex]
            player.invalidatePreparedWallpaper(existing.id)
            LocalPreviewImageCache.clear()
            merged.isFavorite = existing.isFavorite
            merged.dateAdded = existing.dateAdded
            merged.lastPlayedAt = existing.lastPlayedAt
            if existing.id != merged.id {
                player.invalidatePreparedWallpaper(merged.id)
                for index in playlists.indices {
                    playlists[index].wallpaperIDs = playlists[index].wallpaperIDs.map { $0 == existing.id ? merged.id : $0 }
                }
                player.replaceWallpaperID(existing.id, with: merged.id)
                persistPlaylistsReportingErrors()
            }
            library[existingIndex] = merged
            player.updateLibrary(library)
            return merged
        }
        library.insert(incoming, at: 0)
        player.updateLibrary(library)
        return incoming
    }

    private func receiveDownloadedWallpaper(_ item: WallpaperItem) {
        let merged = upsert(item)
        selectedID = merged.id
        selectedSection = .library
        do { try saveLibrary() }
        catch { presentPersistenceError(error) }
    }

    private func updateCompatibility(id: UUID, status: CompatibilityStatus, notes: [String]) {
        guard let index = library.firstIndex(where: { $0.id == id }),
              library[index].compatibility != status || library[index].compatibilityNotes != notes else { return }
        library[index].compatibility = status
        library[index].compatibilityNotes = notes
        do { try saveLibrary() }
        catch { presentPersistenceError(error) }
    }

    private func presentDownloadFailure(_ download: WallpaperDownload) {
        retryDownloadID = download.id
        present(AppIssue(
            title: "Download Failed",
            message: download.errorMessage ?? "SteamCMD could not download this wallpaper.",
            technicalDetails: "Workshop ID: \(download.workshopItem.publishedFileID)",
            recoveryAction: steam.detectedExecutableURL == nil ? .locateSteamCMD : .retry
        ))
    }

    private func saveLibrary() throws {
        try storage.saveLibrary(library)
        player.updateLibrary(library)
    }

    private func savePlaylists() throws { try storage.savePlaylists(playlists) }

    private func persistPlaylistsReportingErrors() {
        do { try savePlaylists() }
        catch { presentPersistenceError(error) }
    }

    private func presentPersistenceError(_ error: Error) {
        retryDownloadID = nil
        present(AppIssue(
            title: "Couldn’t Save Application Data",
            message: error.localizedDescription,
            technicalDetails: String(reflecting: error),
            recoveryAction: .retry
        ))
    }

    private func present(_ issue: AppIssue) {
        if issue.recoveryAction != .retry { retryDownloadID = nil }
        if issue.recoveryAction != .showFile { recoveryFileURL = nil }
        if let technicalDetails = issue.technicalDetails {
            AppLog.app.error("\(issue.title, privacy: .public): \(technicalDetails, privacy: .private)")
        }
        self.issue = issue
    }
}
