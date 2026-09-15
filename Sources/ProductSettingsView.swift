import SwiftUI

struct ProductSettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var steam: SteamCmdService
    @State private var apiKey = ""
    @State private var apiKeyMessage: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                Toggle("Restore display assignments when the app launches", isOn: $settings.restoreOnLaunch)
            }

            Section("Playback") {
                Toggle("Pause when the display sleeps", isOn: $settings.pauseOnScreenSleep)
                Toggle("Pause when the Mac is locked", isOn: $settings.pauseOnSessionLock)
                Toggle("Pause when another app is full screen", isOn: $settings.pauseWhenFullscreen)
                Toggle("Pause in Low Power Mode", isOn: $settings.pauseInLowPowerMode)
                Toggle("Mute all wallpapers", isOn: $settings.globalMute)
                HStack {
                    Text("Default volume")
                    Slider(value: $settings.globalVolume, in: 0...1)
                }
                Picker("Default scale", selection: $settings.defaultScaling) {
                    ForEach(VideoScaling.allCases) { Text($0.title).tag($0) }
                }
                Picker("Default playback speed", selection: $settings.playbackRate) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
            }
            .onChange(of: settings.pauseOnScreenSleep) { _, _ in state.applyPlaybackSettings() }
            .onChange(of: settings.pauseOnSessionLock) { _, _ in state.applyPlaybackSettings() }
            .onChange(of: settings.pauseInLowPowerMode) { _, _ in state.applyPlaybackSettings() }
            .onChange(of: settings.pauseWhenFullscreen) { _, _ in state.applyPlaybackSettings() }
            .onChange(of: settings.globalMute) { _, _ in state.applyPlaybackSettings() }
            .onChange(of: settings.globalVolume) { _, _ in state.applyDefaultVolume() }
            .onChange(of: settings.defaultScaling) { _, _ in state.applyDefaultScaling() }
            .onChange(of: settings.playbackRate) { _, _ in state.applyDefaultPlaybackRate() }

            Section("Steam Workshop") {
                LabeledContent("SteamCMD") {
                    HStack {
                        Text(steam.detectedExecutableURL?.path ?? "Not found")
                            .foregroundStyle(steam.detectedExecutableURL == nil ? Color.red : Color.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Choose…") { state.chooseSteamCMD() }
                    }
                }
                TextField("Steam account name", text: $settings.steamUsername)
                Text("SteamCMD will request the password and Steam Guard code only when Steam needs them. The app never saves either value.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    SecureField(settings.hasSteamAPIKey ? "API key saved in Keychain" : "Steam Web API key", text: $apiKey)
                    Button("Save") { saveAPIKey() }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.hasSteamAPIKey {
                        Button("Remove", role: .destructive) { removeAPIKey() }
                    }
                }
                Text("The Web API key is used only for Workshop browsing and creator metadata. Downloads use SteamCMD.")
                    .font(.caption).foregroundStyle(.secondary)
                if let apiKeyMessage {
                    Text(apiKeyMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Storage") {
                LabeledContent("Wallpaper storage") {
                    Text(state.storage.rootURL.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Preview cache") {
                    Text(state.previewCacheSize.formattedByteCount)
                }
                HStack {
                    Button("Open Storage Folder") { state.openStorageDirectory() }
                    Button("Clear Preview Cache") { state.clearPreviewCache() }
                }
            }

            Section("Scene Compatibility") {
                Text("The current renderer supports a base image, compatible TEX images, and a limited approximation of up to three wave effects. Multiple layers, DXT textures, particles, timelines, audio-reactive scripts, camera parallax, and custom shaders remain partial or unsupported.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Application", value: ProductInfo.name)
                LabeledContent("Version", value: ProductInfo.version)
                Text("This repository is distributed under its existing MIT License.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(maxWidth: 780)
        .padding(.horizontal, 12)
    }

    private func saveAPIKey() {
        do {
            try settings.saveSteamAPIKey(apiKey)
            apiKey = ""
            apiKeyMessage = "Saved securely in Keychain."
            state.workshop.reload()
        } catch {
            apiKey = ""
            apiKeyMessage = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try settings.saveSteamAPIKey("")
            apiKey = ""
            apiKeyMessage = "Removed from Keychain."
            state.workshop.reload()
        } catch {
            apiKeyMessage = error.localizedDescription
        }
    }
}
