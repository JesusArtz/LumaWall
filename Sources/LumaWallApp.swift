import AppKit
import SwiftUI

@main
struct LumaWallApp: App {
    @StateObject private var state: AppState
    @StateObject private var player: WallpaperCoordinator
    @StateObject private var settings: AppSettings
    @StateObject private var workshop: WorkshopViewModel
    @StateObject private var steam: SteamCmdService

    init() {
        let appState = AppState()
        _state = StateObject(wrappedValue: appState)
        _player = StateObject(wrappedValue: appState.player)
        _settings = StateObject(wrappedValue: appState.settings)
        _workshop = StateObject(wrappedValue: appState.workshop)
        _steam = StateObject(wrappedValue: appState.steam)
    }

    var body: some Scene {
        Window(ProductInfo.name, id: "main") {
            ApplicationRootView()
                .environmentObject(state)
                .environmentObject(player)
                .environmentObject(player.displayManager)
                .environmentObject(settings)
                .environmentObject(workshop)
                .environmentObject(steam)
        }
        .defaultSize(width: 1_120, height: 740)

        MenuBarExtra(ProductInfo.name, systemImage: player.isPlaying ? "sparkles.tv.fill" : "sparkles.tv") {
            StatusMenu()
                .environmentObject(state)
                .environmentObject(player)
                .environmentObject(player.displayManager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            ProductSettingsView()
                .environmentObject(state)
                .environmentObject(settings)
                .environmentObject(steam)
                .frame(width: 620, height: 650)
        }
    }
}

private struct StatusMenu: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperCoordinator
    @EnvironmentObject private var displayManager: DisplayManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if player.isPlaying {
            Button(player.isPaused ? "Resume All" : "Pause All") {
                player.togglePause()
            }
            Button("Stop All Wallpapers") { player.stop() }
            Divider()
        }

        if !state.recentWallpapers.isEmpty {
            Menu("Recent Wallpapers") {
                ForEach(state.recentWallpapers.prefix(8)) { item in
                    Button(item.name) { state.play(item) }
                }
            }
        }

        Menu("Displays") {
            ForEach(displayManager.displays) { display in
                let configuration = player.configuration(for: display.id)
                Button {
                    openMain(section: .displays)
                } label: {
                    Label(display.name, systemImage: configuration.isEnabled ? "display" : "display.slash")
                }
            }
        }

        Button("Import Wallpaper…") { state.chooseWallpaper() }
        Button("Open \(ProductInfo.name)…") { openMain(section: state.selectedSection ?? .library) }
        Button("Settings…") { openMain(section: .settings) }
        Divider()
        Button("Quit \(ProductInfo.name)") { NSApp.terminate(nil) }
    }

    private func openMain(section: AppSection) {
        state.selectedSection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
