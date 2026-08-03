import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var library: [WallpaperItem] = []
    @Published var selectedID: WallpaperItem.ID?
    @Published var alertMessage: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    let player = WallpaperPlayer()

    private let libraryKey = "wallpaper.library.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: libraryKey),
           let items = try? JSONDecoder().decode([WallpaperItem].self, from: data) {
            library = items.filter { FileManager.default.fileExists(atPath: $0.sourcePath) }
        }
        selectedID = library.first?.id
        player.restoreIfNeeded(from: library)
    }

    var selectedItem: WallpaperItem? { library.first { $0.id == selectedID } }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "Add a Live Wallpaper"
        panel.message = "Choose a video, scene.pkg, or Wallpaper Engine project folder."
        panel.prompt = "Add Wallpaper"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { importWallpaper(url) }
    }

    func importWallpaper(_ url: URL, playImmediately: Bool = true) {
        do {
            let newItem = try WallpaperImporter.inspect(url)
            if let existing = library.first(where: { $0.sourcePath == newItem.sourcePath }) {
                selectedID = existing.id
                if playImmediately { player.play(existing) }
                return
            }
            library.insert(newItem, at: 0)
            selectedID = newItem.id
            saveLibrary()
            if playImmediately { player.play(newItem) }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func playSelected() {
        guard let selectedItem else { return }
        player.play(selectedItem)
    }

    func removeSelected() {
        guard let selectedID else { return }
        if player.currentItem?.id == selectedID { player.stop() }
        library.removeAll { $0.id == selectedID }
        self.selectedID = library.first?.id
        saveLibrary()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            alertMessage = error.localizedDescription
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library) { UserDefaults.standard.set(data, forKey: libraryKey) }
    }
}
