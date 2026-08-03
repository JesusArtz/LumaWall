import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperPlayer
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.45)
            detail
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(appBackground)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: drop)
        .alert("LumaWall", isPresented: Binding(
            get: { state.alertMessage != nil || player.lastError != nil },
            set: { if !$0 { state.alertMessage = nil; player.clearError() } }
        )) {
            Button("OK", role: .cancel) { state.alertMessage = nil; player.clearError() }
        } message: {
            Text(state.alertMessage ?? player.lastError ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 35, height: 35)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("LumaWall")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("LIVE WALLPAPER STUDIO")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1.15)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 19)
            .padding(.bottom, 24)

            Text("LIBRARY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.05)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 19)
                .padding(.bottom, 8)

            if state.library.isEmpty {
                Text("Your wallpapers will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 19)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(state.library) { item in
                            WallpaperRow(
                                item: item,
                                isSelected: state.selectedID == item.id,
                                isPlaying: player.currentItem?.id == item.id && player.isPlaying
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { state.selectedID = item.id }
                            .contextMenu {
                                Button("Set as Live Wallpaper") {
                                    state.selectedID = item.id
                                    state.playSelected()
                                }
                                Divider()
                                Button("Remove from Library", role: .destructive) {
                                    state.selectedID = item.id
                                    state.removeSelected()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Spacer(minLength: 10)

            VStack(spacing: 10) {
                Button {
                    state.chooseWallpaper()
                } label: {
                    Label("Add Wallpaper", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                HStack {
                    Text("\(state.library.count) \(state.library.count == 1 ? "wallpaper" : "wallpapers")")
                    Spacer()
                    if state.selectedItem != nil {
                        Button {
                            state.removeSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove from Library")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(14)
        }
        .frame(width: 238)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var detail: some View {
        if let item = state.selectedItem {
            WallpaperDetail(item: item)
                .environmentObject(state)
                .environmentObject(player)
        } else {
            EmptyLibraryView(isDropTargeted: dropTargeted, choose: state.chooseWallpaper)
        }
    }

    private var appBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.cyan.opacity(0.09), Color.indigo.opacity(0.045), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
            let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url { Task { @MainActor in state.importWallpaper(url) } }
        }
        return true
    }
}

private struct WallpaperRow: View {
    let item: WallpaperItem
    let isSelected: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.cyan.opacity(0.28), .indigo.opacity(0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                if let previewURL = item.previewURL, let image = NSImage(contentsOf: previewURL) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind == .scenePackage ? "cube.transparent" : "film")
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(width: 48, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(item.kind == .scenePackage ? "SCENE PACKAGE" : "VIDEO")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            if isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? Color.white.opacity(0.105) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WallpaperDetail: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperPlayer
    let item: WallpaperItem

    private var isCurrent: Bool { player.currentItem?.id == item.id && player.isPlaying }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Wallpaper Preview")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("Preview and control your desktop scene")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge
                }

                preview

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .lineLimit(2)
                        Label(item.kind == .scenePackage ? "Wallpaper Engine scene.pkg" : item.sourceURL.lastPathComponent,
                              systemImage: item.kind == .scenePackage ? "cube.transparent" : "film")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    playbackControls
                }

                VStack(alignment: .leading, spacing: 11) {
                    Text("DISPLAY MODE")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)

                    Picker("Display mode", selection: Binding(
                        get: { player.scaling },
                        set: { player.scaling = $0 }
                    )) {
                        ForEach(VideoScaling.allCases) { scaling in
                            Label(scaling.title, systemImage: scaling == .fill ? "rectangle.inset.filled" : "rectangle.center.inset.filled")
                                .tag(scaling)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
                .padding(16)
                .background(Color.white.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .padding(28)
        }
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.03, green: 0.19, blue: 0.25), .indigo.opacity(0.58)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            if let previewURL = item.previewURL, let image = NSImage(contentsOf: previewURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "sparkles.tv.fill")
                    .font(.system(size: 70, weight: .light))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)

            HStack(spacing: 7) {
                Label(item.kind == .scenePackage ? "NATIVE SCENE" : "VIDEO", systemImage: "play.fill")
                Text("•")
                Text("HARDWARE ACCELERATED")
            }
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.88))
            .padding(14)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isCurrent ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(isCurrent ? (player.isPaused ? "PAUSED" : "LIVE") : "READY")
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.75)
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.07))
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.09)) }
    }

    @ViewBuilder private var playbackControls: some View {
        if isCurrent {
            HStack(spacing: 8) {
                Button {
                    player.togglePause()
                } label: {
                    Label(player.isPaused ? "Resume" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Stop Wallpaper")
            }
        } else {
            Button {
                state.playSelected()
            } label: {
                Label("Set as Wallpaper", systemImage: "play.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .controlSize(.large)
        }
    }
}

private struct EmptyLibraryView: View {
    let isDropTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.cyan.opacity(0.20), .indigo.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 94, height: 94)
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "sparkles.tv.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.cyan)
            }

            VStack(spacing: 7) {
                Text(isDropTargeted ? "Drop to import" : "Bring your desktop to life")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Add a video, scene.pkg, or Wallpaper Engine project folder.\nLumaWall will inspect it before anything runs.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            Button(action: choose) {
                Label("Choose Wallpaper…", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .controlSize(.large)

            HStack(spacing: 16) {
                Label("MP4 · MOV · M4V", systemImage: "film")
                Label("scene.pkg", systemImage: "cube.transparent")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                    .padding(20)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isDropTargeted)
    }
}
