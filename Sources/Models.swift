import Foundation

enum VideoScaling: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill
    case fit

    var id: String { rawValue }
    var title: String { self == .fill ? "Fill screen" : "Fit on screen" }
}

enum WallpaperType: String, Codable, CaseIterable, Identifiable, Sendable {
    case video
    case web
    case scenePackage
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Video"
        case .web: return "Web"
        case .scenePackage: return "Scene"
        case .unsupported: return "Unsupported"
        }
    }

    var symbolName: String {
        switch self {
        case .video: return "film"
        case .web: return "globe"
        case .scenePackage: return "cube.transparent"
        case .unsupported: return "exclamationmark.triangle"
        }
    }

    static func projectType(_ value: String?) -> WallpaperType {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video": return .video
        case "web": return .web
        case "scene": return .scenePackage
        default: return .unsupported
        }
    }
}

enum CompatibilityStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case partial
    case fallback
    case unsupported
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Fully supported"
        case .partial: return "Partially supported"
        case .fallback: return "Preview fallback"
        case .unsupported: return "Unsupported"
        case .unknown: return "Not yet inspected"
        }
    }
}

struct WallpaperSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case external
        case managedImport
        case workshop
    }

    var kind: Kind
    var originalPath: String?
    var workshopID: String?

    static func external(path: String, workshopID: String? = nil) -> WallpaperSource {
        WallpaperSource(kind: .external, originalPath: path, workshopID: workshopID)
    }

    static func managed(originalPath: String?) -> WallpaperSource {
        WallpaperSource(kind: .managedImport, originalPath: originalPath, workshopID: nil)
    }

    static func workshop(id: String, originalPath: String? = nil) -> WallpaperSource {
        WallpaperSource(kind: .workshop, originalPath: originalPath, workshopID: id)
    }
}

struct WallpaperItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var sourcePath: String
    var previewPath: String?
    var kind: WallpaperType
    var projectRootPath: String?
    var source: WallpaperSource
    var author: String?
    var summary: String?
    var tags: [String]
    var compatibility: CompatibilityStatus
    var compatibilityNotes: [String]
    var isFavorite: Bool
    var dateAdded: Date
    var lastPlayedAt: Date?
    var localSize: Int64?

    init(
        id: UUID = UUID(),
        name: String,
        sourceURL: URL,
        kind: WallpaperType = .video,
        previewURL: URL? = nil,
        projectRootURL: URL? = nil,
        source: WallpaperSource? = nil,
        author: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        compatibility: CompatibilityStatus? = nil,
        compatibilityNotes: [String] = [],
        isFavorite: Bool = false,
        dateAdded: Date = Date(),
        lastPlayedAt: Date? = nil,
        localSize: Int64? = nil
    ) {
        self.id = id
        self.name = name
        sourcePath = sourceURL.path
        previewPath = previewURL?.path
        self.kind = kind
        projectRootPath = projectRootURL?.path
        self.source = source ?? .external(path: sourceURL.path)
        self.author = author
        self.summary = summary
        self.tags = tags
        self.compatibility = compatibility ?? Self.defaultCompatibility(for: kind)
        self.compatibilityNotes = compatibilityNotes
        self.isFavorite = isFavorite
        self.dateAdded = dateAdded
        self.lastPlayedAt = lastPlayedAt
        self.localSize = localSize
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var previewURL: URL? { previewPath.map(URL.init(fileURLWithPath:)) }
    var projectRootURL: URL? { projectRootPath.map(URL.init(fileURLWithPath:)) }
    var workshopID: String? { source.workshopID }
    var isManaged: Bool { source.kind != .external }

    private static func defaultCompatibility(for kind: WallpaperType) -> CompatibilityStatus {
        switch kind {
        case .video, .web: return .full
        case .scenePackage: return .partial
        case .unsupported: return .unsupported
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourcePath, previewPath, kind, projectRootPath, source
        case author, summary, tags, compatibility, compatibilityNotes
        case isFavorite, dateAdded, lastPlayedAt, localSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        previewPath = try container.decodeIfPresent(String.self, forKey: .previewPath)
        kind = try container.decode(WallpaperType.self, forKey: .kind)
        projectRootPath = try container.decodeIfPresent(String.self, forKey: .projectRootPath)
        source = try container.decodeIfPresent(WallpaperSource.self, forKey: .source)
            ?? .external(path: sourcePath)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        compatibility = try container.decodeIfPresent(CompatibilityStatus.self, forKey: .compatibility)
            ?? Self.defaultCompatibility(for: kind)
        compatibilityNotes = try container.decodeIfPresent([String].self, forKey: .compatibilityNotes) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        localSize = try container.decodeIfPresent(Int64.self, forKey: .localSize)
    }
}

struct PlaybackConfiguration: Codable, Hashable, Sendable {
    var scaling: VideoScaling = .fill
    var isMuted = true
    var volume: Double = 0
    var playbackRate: Double = 1

    static let `default` = PlaybackConfiguration()
}

struct DisplayConfiguration: Codable, Hashable, Identifiable, Sendable {
    var id: String { displayID }
    var displayID: String
    var isEnabled: Bool
    var wallpaperID: UUID?
    var playback: PlaybackConfiguration

    init(
        displayID: String,
        isEnabled: Bool = true,
        wallpaperID: UUID? = nil,
        playback: PlaybackConfiguration = .default
    ) {
        self.displayID = displayID
        self.isEnabled = isEnabled
        self.wallpaperID = wallpaperID
        self.playback = playback
    }
}

enum PlaylistPlaybackMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sequential
    case shuffle

    var id: String { rawValue }
    var title: String { self == .sequential ? "Sequential" : "Shuffle" }
}

struct WallpaperPlaylist: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var wallpaperIDs: [UUID]
    var playbackMode: PlaylistPlaybackMode
    var interval: TimeInterval

    init(
        id: UUID = UUID(),
        name: String,
        wallpaperIDs: [UUID] = [],
        playbackMode: PlaylistPlaybackMode = .sequential,
        interval: TimeInterval = 300
    ) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.playbackMode = playbackMode
        self.interval = interval
    }
}

struct WorkshopItem: Hashable, Identifiable, Sendable {
    var id: String { publishedFileID }
    let publishedFileID: String
    let title: String
    let creatorSteamID: String?
    var creatorName: String?
    let summary: String?
    let previewURL: URL?
    let tags: [String]
    let type: WallpaperType
    let fileSize: Int64?
    let updatedAt: Date?
    let subscriptions: Int?
    let contentDescriptorIDs: [Int]
}

enum WorkshopSort: String, CaseIterable, Identifiable, Sendable {
    case trending
    case mostPopular
    case mostRecent
    case mostSubscribed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .mostPopular: return "Most Popular"
        case .mostRecent: return "Most Recent"
        case .mostSubscribed: return "Most Subscribed"
        }
    }

    var queryType: Int {
        switch self {
        case .trending: return 3
        case .mostPopular: return 0
        case .mostRecent: return 1
        case .mostSubscribed: return 9
        }
    }
}

enum WorkshopTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case scene
    case video
    case web

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var requiredTag: String? { self == .all ? nil : title }
}

enum WorkshopContentFilter: String, CaseIterable, Identifiable, Sendable {
    case general
    case all
    case mature

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum DownloadState: String, Codable, Sendable {
    case queued
    case authenticating
    case awaitingPassword
    case awaitingSteamGuard
    case downloading
    case validating
    case importing
    case completed
    case failed
    case cancelled

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    var canCancel: Bool {
        switch self {
        case .queued, .authenticating, .awaitingPassword, .awaitingSteamGuard, .downloading:
            return true
        case .validating, .importing, .completed, .failed, .cancelled:
            return false
        }
    }
}

struct WallpaperDownload: Identifiable, Hashable, Sendable {
    let id: UUID
    let workshopItem: WorkshopItem
    var state: DownloadState
    var progress: Double?
    var statusText: String
    var errorMessage: String?

    init(id: UUID = UUID(), workshopItem: WorkshopItem) {
        self.id = id
        self.workshopItem = workshopItem
        state = .queued
        progress = nil
        statusText = "Queued"
        errorMessage = nil
    }
}

enum ImportError: LocalizedError, Equatable {
    case missing
    case unsupportedFile(String)
    case invalidProject
    case unsupportedProject(String)
    case assetMissing(String)
    case unsafeProjectPath(String)
    case archiveExtractionFailed
    case projectTooLarge

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The selected item no longer exists."
        case .unsupportedFile(let ext):
            return "‘.\(ext)’ is not supported. Choose an MP4, MOV, M4V, ZIP, scene.pkg, or Wallpaper Engine project folder."
        case .invalidProject:
            return "The selected item does not contain a valid Wallpaper Engine project.json or scene package."
        case .unsupportedProject(let kind):
            return "This Wallpaper Engine \(kind) project is not supported."
        case .assetMissing(let path):
            return "The project’s main asset is missing or unsupported: \(path)"
        case .unsafeProjectPath(let path):
            return "The project references a file outside its folder: \(path)"
        case .archiveExtractionFailed:
            return "The ZIP archive could not be extracted safely."
        case .projectTooLarge:
            return "The project metadata exceeds the 8 MB safety limit."
        }
    }
}
