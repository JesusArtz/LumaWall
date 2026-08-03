import AppKit
import SwiftUI

@main
struct LumaWallApp: App {
    @StateObject private var state: AppState
    @StateObject private var player: WallpaperPlayer

    init() {
        let appState = AppState()
        _state = StateObject(wrappedValue: appState)
        _player = StateObject(wrappedValue: appState.player)
    }

    var body: some Scene {
        Window("LumaWall", id: "library") {
            LibraryView().environmentObject(state).environmentObject(player)
        }
        .defaultSize(width: 920, height: 610)

        MenuBarExtra("LumaWall", systemImage: player.isPlaying ? "sparkles.tv.fill" : "sparkles.tv") {
            StatusMenu().environmentObject(state).environmentObject(player)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environmentObject(state).environmentObject(player)
        }
    }
}

private struct StatusMenu: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperPlayer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let item = player.currentItem, player.isPlaying {
            Label(item.name, systemImage: "waveform")
            Button(player.isPaused ? "Resume Wallpaper" : "Pause Wallpaper") { player.togglePause() }
            Button("Stop Wallpaper") { player.stop() }
            Divider()
        }
        Button("Add Wallpaper…") { state.chooseWallpaper() }
        Button("Open LumaWall…") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit LumaWall") { NSApp.terminate(nil) }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperPlayer

    var body: some View {
        TabView {
            Form {
                Section("Startup") {
                    Toggle("Launch LumaWall at login", isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                }

                Section("Playback") {
                    Picker("Default scaling", selection: Binding(
                        get: { player.scaling },
                        set: { player.scaling = $0 }
                    )) {
                        ForEach(VideoScaling.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Playback is muted and automatically pauses while the display or user session sleeps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 82, height: 82)
                Text("LumaWall")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Version 0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("A lightweight, native live wallpaper engine for macOS.")
                    .foregroundStyle(.secondary)
                Text("Open source under the MIT License")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(12)
        .frame(width: 480, height: 310)
    }
}
