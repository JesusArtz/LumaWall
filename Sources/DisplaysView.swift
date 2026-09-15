import SwiftUI

struct DisplaysView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperCoordinator
    @EnvironmentObject private var displayManager: DisplayManager

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 20)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected Displays").font(.title2.weight(.semibold))
                    Text("Assignments are saved by the display’s Core Graphics UUID.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if player.isPlaying {
                    Button(player.isPaused ? "Resume All" : "Pause All", systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                        player.togglePause()
                    }
                    Button("Stop All", systemImage: "stop.fill") { player.stop() }
                }
            }
            .padding(20)
            Divider()

            if displayManager.displays.isEmpty {
                ContentUnavailableView("No Displays Detected", systemImage: "display.trianglebadge.exclamationmark")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(displayManager.displays) { display in
                            DisplayCard(display: display)
                                .environmentObject(state)
                                .environmentObject(player)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Displays")
    }
}
private struct DisplayCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperCoordinator
    @EnvironmentObject private var settings: AppSettings
    let display: ConnectedDisplay

    private var configuration: DisplayConfiguration { player.configuration(for: display.id) }
    private var currentItem: WallpaperItem? {
        configuration.wallpaperID.flatMap { id in state.library.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(display.name).font(.headline)
                        if display.isMain { Text("Main").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { configuration.isEnabled },
                    set: { player.setEnabled($0, for: display.id) }
                ))
                .toggleStyle(.switch)
            }

            Group {
                if let currentItem {
                    LocalWallpaperArtwork(item: currentItem)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "display").font(.largeTitle).foregroundStyle(.tertiary) }
                }
            }
            .aspectRatio(max(display.frame.width / max(display.frame.height, 1), 1.2), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Picker("Wallpaper", selection: Binding(
                get: { configuration.wallpaperID },
                set: { id in
                    if let id, let item = state.library.first(where: { $0.id == id }) {
                        state.play(item, on: display.id)
                    } else {
                        player.stop(displayID: display.id)
                    }
                }
            )) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(state.library.filter { $0.compatibility != .unsupported }) { item in
                    Text(item.name).tag(Optional(item.id))
                }
            }
            .disabled(!configuration.isEnabled)

            Picker("Scale", selection: Binding(
                get: { configuration.playback.scaling },
                set: { value in player.updatePlayback(for: display.id) { $0.scaling = value } }
            )) {
                ForEach(VideoScaling.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!configuration.isEnabled || currentItem?.kind == .web)

            if currentItem?.kind == .video || currentItem?.kind == .web {
                HStack {
                    Toggle("Mute", isOn: Binding(
                        get: { configuration.playback.isMuted },
                        set: { value in player.updatePlayback(for: display.id) { $0.isMuted = value } }
                    ))
                    Spacer()
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { configuration.playback.volume },
                        set: { value in player.updatePlayback(for: display.id) { $0.volume = value } }
                    ), in: 0...1)
                    .frame(maxWidth: 150)
                    .disabled(configuration.playback.isMuted || settings.globalMute)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
        .opacity(configuration.isEnabled ? 1 : 0.68)
    }
}
