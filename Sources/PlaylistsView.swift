import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showsNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var showsRename = false
    @State private var renameValue = ""
    @State private var confirmsDelete = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $state.selectedPlaylistID) {
                    ForEach(state.playlists) { playlist in
                        HStack {
                            Label(playlist.name, systemImage: "music.note.list")
                            Spacer()
                            Text(playlist.wallpaperIDs.count.formatted())
                                .foregroundStyle(.secondary)
                        }
                        .tag(playlist.id)
                    }
                }
                Divider()
                HStack {
                    Button {
                        newPlaylistName = ""
                        showsNewPlaylist = true
                    } label: { Image(systemName: "plus") }
                    .help("New Playlist")
                    Button {
                        renameValue = state.selectedPlaylist?.name ?? ""
                        showsRename = true
                    } label: { Image(systemName: "pencil") }
                    .disabled(state.selectedPlaylist == nil)
                    .help("Rename Playlist")
                    Spacer()
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: { Image(systemName: "trash") }
                    .disabled(state.selectedPlaylist == nil)
                    .help("Delete Playlist")
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
            .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)

            if let playlist = state.selectedPlaylist {
                PlaylistDetail(playlist: playlist)
                    .environmentObject(state)
            } else {
                ContentUnavailableView {
                    Label("No Playlist Selected", systemImage: "music.note.list")
                } description: {
                    Text("Create a playlist to rotate wallpapers sequentially or in a shuffled order.")
                } actions: {
                    Button("New Playlist") { showsNewPlaylist = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Playlists")
        .alert("New Playlist", isPresented: $showsNewPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Create") { _ = state.createPlaylist(named: newPlaylistName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: $showsRename) {
            TextField("Playlist name", text: $renameValue)
            Button("Rename") {
                if let id = state.selectedPlaylistID { state.renamePlaylist(id, to: renameValue) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this playlist?", isPresented: $confirmsDelete) {
            Button("Delete Playlist", role: .destructive) {
                if let id = state.selectedPlaylistID { state.deletePlaylist(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded wallpapers will remain in the Library.")
        }
    }
}
private struct PlaylistDetail: View {
    @EnvironmentObject private var state: AppState
    let playlist: WallpaperPlaylist

    private var items: [WallpaperItem] {
        playlist.wallpaperIDs.compactMap { id in state.library.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name).font(.title2.weight(.semibold))
                    Text("\(items.count) wallpaper\(items.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(state.library.filter { !playlist.wallpaperIDs.contains($0.id) }) { item in
                        Button(item.name) { state.add(item.id, to: playlist.id) }
                    }
                } label: {
                    Label("Add Wallpaper", systemImage: "plus")
                }
                .disabled(state.library.allSatisfy { playlist.wallpaperIDs.contains($0.id) })
                if state.activePlaylistID == playlist.id {
                    Button("Stop", systemImage: "stop.fill") { state.stopPlaylist() }
                } else {
                    Button("Play", systemImage: "play.fill") { state.startPlaylist(playlist.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(items.isEmpty)
                }
            }
            .padding(20)

            HStack(spacing: 18) {
                Picker("Order", selection: Binding(
                    get: { playlist.playbackMode },
                    set: { state.updatePlaylist(playlist.id, mode: $0) }
                )) {
                    ForEach(PlaylistPlaybackMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Switch every", selection: Binding(
                    get: { playlist.interval },
                    set: { state.updatePlaylist(playlist.id, interval: $0) }
                )) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1_800.0)
                    Text("1 hour").tag(3_600.0)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            Divider()

            if items.isEmpty {
                ContentUnavailableView {
                    Label("Empty Playlist", systemImage: "music.note.list")
                } description: {
                    Text("Add wallpapers from your local Library.")
                }
            } else {
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            LocalWallpaperArtwork(item: item, cornerRadius: 6)
                                .frame(width: 96, height: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.headline)
                                Label(item.kind.title, systemImage: item.kind.symbolName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                state.movePlaylistItems(
                                    in: playlist.id,
                                    from: IndexSet(integer: index),
                                    to: index - 1
                                )
                            } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help("Move Up")
                            Button {
                                state.movePlaylistItems(
                                    in: playlist.id,
                                    from: IndexSet(integer: index),
                                    to: index + 2
                                )
                            } label: { Image(systemName: "chevron.down") }
                            .disabled(index == items.count - 1)
                            .help("Move Down")
                            Button(role: .destructive) {
                                state.remove(item.id, from: playlist.id)
                            } label: { Image(systemName: "minus.circle") }
                            .help("Remove from Playlist")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}
