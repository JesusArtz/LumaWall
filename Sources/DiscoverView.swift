import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var workshop: WorkshopViewModel
    @EnvironmentObject private var steam: SteamCmdService
    @State private var selectedItem: WorkshopItem?
    @State private var showsDownloads = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Discover")
        .searchable(text: $workshop.searchText, placement: .toolbar, prompt: "Search Workshop")
        .onSubmit(of: .search) { workshop.reload() }
        .onChange(of: workshop.sort) { _, _ in workshop.reload() }
        .onChange(of: workshop.typeFilter) { _, _ in workshop.reload() }
        .onChange(of: workshop.tagFilter) { _, _ in workshop.reload() }
        .onChange(of: workshop.contentFilter) { _, _ in workshop.reload() }
        .onAppear {
            if workshop.items.isEmpty, workshop.errorMessage == nil { workshop.reload() }
        }
        .sheet(item: $selectedItem) { item in
            WorkshopDetailView(item: item)
                .environmentObject(state)
                .frame(minWidth: 760, minHeight: 640)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Wallpaper Engine Workshop")
                    .font(.title2.weight(.semibold))
                Text("Browse projects published for Wallpaper Engine on Steam.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Type", selection: $workshop.typeFilter) {
                ForEach(WorkshopTypeFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 120)
            Picker("Rating", selection: $workshop.contentFilter) {
                ForEach(WorkshopContentFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 120)
            if !workshop.availableTags.isEmpty {
                Picker("Tag", selection: $workshop.tagFilter) {
                    Text("All Tags").tag(Optional<String>.none)
                    ForEach(workshop.availableTags, id: \.self) { tag in
                        Text(tag).tag(Optional(tag))
                    }
                }
                .frame(width: 130)
            }
            Picker("Sort", selection: $workshop.sort) {
                ForEach(WorkshopSort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 155)
            Button {
                workshop.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Workshop")
            if !steam.downloads.isEmpty {
                Button {
                    showsDownloads.toggle()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                        .overlay(alignment: .topTrailing) {
                            if activeDownloadCount > 0 {
                                Text(activeDownloadCount.formatted())
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(3)
                                    .background(.blue, in: Circle())
                                    .foregroundStyle(.white)
                                    .offset(x: 5, y: -5)
                            }
                        }
                }
                .help("Download Activity")
                .popover(isPresented: $showsDownloads, arrowEdge: .bottom) {
                    DownloadActivityView()
                        .environmentObject(steam)
                        .frame(width: 390, height: 300)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        if !settings.hasSteamAPIKey {
            ContentUnavailableView {
                Label("Steam Web API Setup Required", systemImage: "key")
            } description: {
                Text("Add a Steam Web API key in Settings to browse public Workshop metadata. Downloads still use SteamCMD and a legitimate Steam account.")
            } actions: {
                Button("Open Settings") { state.selectedSection = .settings }
                    .buttonStyle(.borderedProminent)
            }
        } else if let error = workshop.errorMessage, workshop.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Workshop", systemImage: "exclamationmark.icloud")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { workshop.retry() }
                    .buttonStyle(.borderedProminent)
            }
        } else if workshop.items.isEmpty, workshop.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading Workshop…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workshop.items.isEmpty {
            ContentUnavailableView {
                Label("No Workshop Results", systemImage: "magnifyingglass")
            } description: {
                Text("No items in the loaded results match these search and content filters.")
            } actions: {
                if workshop.canLoadMore {
                    Button("Search More Results") { workshop.loadMore() }
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(workshop.items) { item in
                        WorkshopCard(item: item)
                            .environmentObject(state)
                            .onTapGesture { selectedItem = item }
                            .onAppear { workshop.loadMoreIfNeeded(after: item) }
                    }
                }
                .padding(20)

                if workshop.isLoading {
                    ProgressView().padding(.vertical, 20)
                }
            }
        }
    }

    private var activeDownloadCount: Int {
        steam.downloads.filter { !$0.state.isTerminal }.count
    }
}

private struct WorkshopCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var steam: SteamCmdService
    let item: WorkshopItem

    private var download: WallpaperDownload? {
        steam.downloads.first { $0.workshopItem.publishedFileID == item.publishedFileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteWallpaperArtwork(url: item.previewURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    typeBadge.padding(8)
                }
                .overlay(alignment: .topLeading) {
                    if state.isFavorite(item) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.white, .pink)
                            .padding(7)
                            .background(.regularMaterial, in: Circle())
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let creator = item.creatorName {
                    Text(creator)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if state.localWallpaper(for: item) != nil {
                        Label("In Library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let download {
                        Label(download.statusText, systemImage: download.state == .failed ? "exclamationmark.circle" : "arrow.down.circle")
                            .foregroundStyle(download.state == .failed ? Color.red : Color.secondary)
                    } else if let count = item.subscriptions {
                        Label(count.formatted(), systemImage: "person.2")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let size = item.fileSize { Text(size.formattedByteCount).foregroundStyle(.secondary) }
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var typeBadge: some View {
        Label(item.type.title, systemImage: item.type.symbolName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct WorkshopDetailView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: WallpaperCoordinator
    @EnvironmentObject private var displayManager: DisplayManager
    @EnvironmentObject private var steam: SteamCmdService
    @Environment(\.dismiss) private var dismiss
    let item: WorkshopItem
    @State private var selectedDisplayID: String?
    @State private var confirmsRemoval = false

    private var localItem: WallpaperItem? { state.localWallpaper(for: item) }
    private var download: WallpaperDownload? {
        steam.downloads.first { $0.workshopItem.publishedFileID == item.publishedFileID }
    }
    private var compatibility: CompatibilityStatus {
        switch item.type {
        case .video, .web: return .full
        case .scenePackage: return .partial
        case .unsupported: return .unsupported
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    preview
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.largeTitle.weight(.bold))
                            if let creator = item.creatorName {
                                Label(creator, systemImage: "person.crop.circle")
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                Label(item.type.title, systemImage: item.type.symbolName)
                                CompatibilityBadge(status: compatibility)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 10) {
                            Button {
                                state.toggleFavorite(item)
                            } label: {
                                Label(
                                    state.isFavorite(item) ? "Favorited" : "Favorite",
                                    systemImage: state.isFavorite(item) ? "heart.fill" : "heart"
                                )
                            }
                            actionArea
                        }
                    }

                    if let summary = item.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("About").font(.headline)
                            Text(summary).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }

                    metadata

                    if !item.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tags").font(.headline)
                            FlowLayout(spacing: 6) {
                                ForEach(item.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }

                    if item.type == .scenePackage {
                        Label(
                            "Scene projects use the current partial Metal renderer. The downloaded project is inspected again and falls back to its preview when possible.",
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if let localItem {
                    if displayManager.displays.count > 1 {
                        Picker("Display", selection: $selectedDisplayID) {
                            ForEach(displayManager.displays) { display in
                                Text(display.name).tag(Optional(display.id))
                            }
                        }
                        .frame(width: 190)
                    }
                    Button("Apply") {
                        state.play(localItem, on: selectedDisplayID)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(localItem.compatibility == .unsupported)
                } else if download == nil || download?.state.isTerminal == true {
                    Button("Download") { state.download(item) }
                        .buttonStyle(.borderedProminent)
                        .disabled(item.type == .unsupported)
                }
            }
            .padding(16)
        }
        .onAppear { selectedDisplayID = displayManager.displays.first?.id }
        .confirmationDialog(
            "Remove \(item.title) from the Library?",
            isPresented: $confirmsRemoval
        ) {
            Button("Remove Downloaded Files", role: .destructive) {
                if let localItem { state.remove(localItem) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only files in the application’s managed wallpaper storage will be deleted.")
        }
    }

    @ViewBuilder private var preview: some View {
        if let localItem {
            WallpaperPreview(item: localItem, configuration: settings.globalPlayback)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RemoteWallpaperArtwork(url: item.previewURL, cornerRadius: 14)
                .aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    @ViewBuilder private var actionArea: some View {
        if let localItem {
            VStack(alignment: .trailing, spacing: 8) {
                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let size = localItem.localSize { Text(size.formattedByteCount).font(.caption).foregroundStyle(.secondary) }
                Button("Remove…", role: .destructive) { confirmsRemoval = true }
            }
        } else if let download {
            VStack(alignment: .trailing, spacing: 8) {
                Text(download.statusText).font(.callout.weight(.medium))
                if let progress = download.progress {
                    ProgressView(value: progress).frame(width: 160)
                } else if !download.state.isTerminal {
                    ProgressView().controlSize(.small)
                }
                if download.state == .failed {
                    Text(download.errorMessage ?? "Download failed")
                        .font(.caption).foregroundStyle(.red).frame(maxWidth: 260, alignment: .trailing)
                    Button("Retry") { steam.retry(download.id) }
                } else if download.state.canCancel {
                    Button("Cancel") { steam.cancel(download.id) }
                }
            }
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
            GridRow { Text("Workshop ID").foregroundStyle(.secondary); Text(item.publishedFileID).textSelection(.enabled) }
            if let size = item.fileSize {
                GridRow { Text("Download size").foregroundStyle(.secondary); Text(size.formattedByteCount) }
            }
            if let updated = item.updatedAt {
                GridRow { Text("Updated").foregroundStyle(.secondary); Text(updated.formatted(date: .abbreviated, time: .omitted)) }
            }
            if let subscriptions = item.subscriptions {
                GridRow { Text("Subscriptions").foregroundStyle(.secondary); Text(subscriptions.formatted()) }
            }
        }
        .font(.callout)
    }
}

private struct DownloadActivityView: View {
    @EnvironmentObject private var steam: SteamCmdService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Download Activity")
                .font(.headline)
                .padding(14)
            Divider()
            if steam.downloads.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            } else {
                List(steam.downloads) { download in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(download.workshopItem.title).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            if download.state.canCancel {
                                Button { steam.cancel(download.id) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless)
                            } else if download.state == .failed {
                                Button("Retry") { steam.retry(download.id) }.buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            Text(download.statusText).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let progress = download.progress { Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption) }
                        }
                        if let progress = download.progress, !download.state.isTerminal {
                            ProgressView(value: progress)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var cursor = CGPoint.zero
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > width {
                cursor.x = 0
                cursor.y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(cursor)
            cursor.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, cursor.x - spacing)
        }
        return (CGSize(width: min(usedWidth, width), height: cursor.y + lineHeight), points)
    }
}
