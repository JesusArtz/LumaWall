import SwiftUI

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case video
    case web
    case scene

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyPlayed
    case recentlyAdded
    case name
    case size

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recentlyPlayed: return "Recently Played"
        case .recentlyAdded: return "Recently Added"
        case .name: return "Name"
        case .size: return "Size"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperCoordinator
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .recentlyAdded
    @State private var gridLayout = true
    @State private var detailItem: WallpaperItem?
    @State private var pendingRemoval: WallpaperItem?

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 310), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Library")
        .sheet(item: $detailItem) { item in
            LibraryItemDetailView(itemID: item.id)
                .environmentObject(state)
                .frame(minWidth: 780, minHeight: 650)
        }
        .confirmationDialog(
            "Remove this wallpaper?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { item in
            Button(item.isManaged ? "Remove from Library and Delete Files" : "Remove from Library", role: .destructive) {
                state.remove(item)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { item in
            Text(item.isManaged
                 ? "The app will delete only this wallpaper’s managed storage folder."
                 : "The original files will remain where they are.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your Wallpapers").font(.title2.weight(.semibold))
                Text("\(state.library.count) item\(state.library.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Filter", selection: $filter) {
                ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 120)
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 155)
            Picker("Layout", selection: $gridLayout) {
                Image(systemName: "square.grid.2x2").tag(true)
                Image(systemName: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 72)
            Button {
                state.chooseWallpaper()
            } label: {
                Label(state.isImporting ? "Importing…" : "Import", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isImporting)
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        if filteredItems.isEmpty {
            ContentUnavailableView {
                Label(state.library.isEmpty ? "No Wallpapers Yet" : "No Matching Wallpapers", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(state.library.isEmpty
                     ? "Import a Wallpaper Engine project, ZIP, scene.pkg, or supported video."
                     : "Change the search or filter to see more of your Library.")
            } actions: {
                if state.library.isEmpty {
                    Button("Import Wallpaper…") { state.chooseWallpaper() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if gridLayout {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(filteredItems) { item in
                        LibraryCard(item: item)
                            .environmentObject(state)
                            .onTapGesture { detailItem = item }
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(20)
            }
        } else {
            List(filteredItems) { item in
                LibraryRow(item: item)
                    .environmentObject(state)
                    .contentShape(Rectangle())
                    .onTapGesture { detailItem = item }
                    .contextMenu { contextMenu(for: item) }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder private func contextMenu(for item: WallpaperItem) -> some View {
        Button("Apply to All Displays") { state.play(item) }
            .disabled(item.compatibility == .unsupported)
        Button(item.isFavorite ? "Remove Favorite" : "Favorite") { state.toggleFavorite(item.id) }
        if !state.playlists.isEmpty {
            Menu("Add to Playlist") {
                ForEach(state.playlists) { playlist in
                    Button(playlist.name) { state.add(item.id, to: playlist.id) }
                }
            }
        }
        Button("Show in Finder") { state.showInFinder(item) }
        Divider()
        Button("Remove…", role: .destructive) { pendingRemoval = item }
    }

    private var filteredItems: [WallpaperItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = state.library.filter { item in
            let matchesText = query.isEmpty
                || item.name.localizedCaseInsensitiveContains(query)
                || item.author?.localizedCaseInsensitiveContains(query) == true
                || item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .favorites: matchesFilter = item.isFavorite
            case .video: matchesFilter = item.kind == .video
            case .web: matchesFilter = item.kind == .web
            case .scene: matchesFilter = item.kind == .scenePackage
            }
            return matchesText && matchesFilter
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .recentlyPlayed:
                return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
            case .recentlyAdded: return lhs.dateAdded > rhs.dateAdded
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size: return (lhs.localSize ?? 0) > (rhs.localSize ?? 0)
            }
        }
    }
}

private struct LibraryCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperCoordinator
    let item: WallpaperItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LocalWallpaperArtwork(item: item)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.white, .pink)
                            .padding(7)
                            .background(.regularMaterial, in: Circle())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if player.isWallpaperActive(item.id) {
                        Label("Active", systemImage: "waveform")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
            Text(item.name).font(.headline).lineLimit(1)
            HStack {
                Label(item.kind.title, systemImage: item.kind.symbolName)
                Spacer()
                CompatibilityBadge(status: item.compatibility)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: WallpaperCoordinator
    let item: WallpaperItem

    var body: some View {
        HStack(spacing: 14) {
            LocalWallpaperArtwork(item: item, cornerRadius: 7)
                .frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name).font(.headline)
                    if item.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                }
                HStack(spacing: 12) {
                    Label(item.kind.title, systemImage: item.kind.symbolName)
                    CompatibilityBadge(status: item.compatibility)
                    if let size = item.localSize { Text(size.formattedByteCount) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if player.isWallpaperActive(item.id) {
                Label("Active", systemImage: "waveform").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 5)
    }
}

struct LibraryItemDetailView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: WallpaperCoordinator
    @EnvironmentObject private var displayManager: DisplayManager
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @State private var selectedDisplayID: String?
    @State private var confirmsRemoval = false

    private var item: WallpaperItem? { state.library.first { $0.id == itemID } }
    private var displayID: String? { selectedDisplayID ?? displayManager.displays.first?.id }
    private var configuration: PlaybackConfiguration {
        guard let displayID else { return settings.globalPlayback }
        return player.configuration(for: displayID).playback
    }

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            WallpaperPreview(item: item, configuration: configuration)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .background(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(item.name).font(.largeTitle.weight(.bold))
                                    if let author = item.author {
                                        Label(author, systemImage: "person.crop.circle").foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 16) {
                                        Label(item.kind.title, systemImage: item.kind.symbolName)
                                        CompatibilityBadge(status: item.compatibility)
                                        if let size = item.localSize { Text(size.formattedByteCount).foregroundStyle(.secondary) }
                                    }
                                }
                                Spacer()
                                Button {
                                    state.toggleFavorite(item.id)
                                } label: {
                                    Label(item.isFavorite ? "Favorited" : "Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart")
                                }
                            }

                            if let summary = item.summary, !summary.isEmpty {
                                Text(summary).foregroundStyle(.secondary).textSelection(.enabled)
                            }

                            if !item.compatibilityNotes.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Compatibility").font(.headline)
                                    ForEach(item.compatibilityNotes, id: \.self) { note in
                                        Label(note, systemImage: "info.circle")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(14)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }

                            playbackControls(for: item)
                        }
                        .padding(24)
                    }
                    Divider()
                    HStack {
                        Button("Show in Finder") { state.showInFinder(item) }
                        Button("Remove…", role: .destructive) { confirmsRemoval = true }
                        if !state.playlists.isEmpty {
                            Menu("Add to Playlist") {
                                ForEach(state.playlists) { playlist in
                                    Button(playlist.name) { state.add(item.id, to: playlist.id) }
                                }
                            }
                        }
                        Spacer()
                        Button("Close") { dismiss() }
                        Button("Apply") {
                            state.play(item, on: displayID)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(item.compatibility == .unsupported || displayID == nil)
                    }
                    .padding(16)
                }
                .confirmationDialog("Remove \(item.name)?", isPresented: $confirmsRemoval) {
                    Button(item.isManaged ? "Remove and Delete Managed Files" : "Remove from Library", role: .destructive) {
                        state.remove(item)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(item.isManaged
                         ? "Only this wallpaper’s folder inside application storage will be deleted."
                         : "The original files will not be deleted.")
                }
            } else {
                ContentUnavailableView("Wallpaper Removed", systemImage: "trash")
            }
        }
        .onAppear { selectedDisplayID = displayManager.displays.first?.id }
    }

    private func playbackControls(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Playback and Display").font(.headline)
            if displayManager.displays.count > 1 {
                Picker("Target display", selection: $selectedDisplayID) {
                    ForEach(displayManager.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
            }
            if let displayID {
                Picker("Scale", selection: Binding(
                    get: { player.configuration(for: displayID).playback.scaling },
                    set: { value in player.updatePlayback(for: displayID) { $0.scaling = value } }
                )) {
                    ForEach(VideoScaling.allCases) { Text($0.title).tag($0) }
                }
                .disabled(item.kind == .web)

                if item.kind == .video || item.kind == .web {
                    Toggle("Mute", isOn: Binding(
                        get: { player.configuration(for: displayID).playback.isMuted },
                        set: { value in player.updatePlayback(for: displayID) { $0.isMuted = value } }
                    ))
                    HStack {
                        Text("Volume")
                        Slider(value: Binding(
                            get: { player.configuration(for: displayID).playback.volume },
                            set: { value in player.updatePlayback(for: displayID) { $0.volume = value } }
                        ), in: 0...1)
                    }
                    Picker("Playback speed", selection: Binding(
                        get: { player.configuration(for: displayID).playback.playbackRate },
                        set: { value in player.updatePlayback(for: displayID) { $0.playbackRate = value } }
                    )) {
                        Text("0.5×").tag(0.5)
                        Text("1×").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
