import Foundation

struct WallpaperStorage: Sendable {
    private static let managedMutationLock = NSLock()

    enum StorageError: LocalizedError {
        case directoryUnavailable
        case unsafeArchive
        case archiveTooLarge
        case noWallpaperProject
        case multipleWallpaperProjects
        case invalidManagedPath
        case persistenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryUnavailable:
                return "The application storage directory is unavailable."
            case .unsafeArchive:
                return "The archive contains links or an unsafe directory structure."
            case .archiveTooLarge:
                return "The archive expands beyond the 20 GB safety limit."
            case .noWallpaperProject:
                return "No Wallpaper Engine project or supported wallpaper was found."
            case .multipleWallpaperProjects:
                return "The selected archive contains more than one wallpaper project. Import a single project at a time."
            case .invalidManagedPath:
                return "The requested storage operation is outside the application’s managed library."
            case .persistenceFailed(let detail):
                return "The library could not be saved: \(detail)"
            }
        }
    }

    static let maximumArchiveBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumInstalledBytes: Int64 = 20 * 1_024 * 1_024 * 1_024
    static let maximumInstalledFiles = 100_000

    let rootURL: URL
    let wallpapersURL: URL
    let cacheURL: URL
    let stagingURL: URL
    let steamDataURL: URL
    let libraryFileURL: URL
    let playlistsFileURL: URL

    init(rootURL: URL = WallpaperStorage.defaultRootURL()) {
        self.rootURL = rootURL
        wallpapersURL = rootURL.appendingPathComponent("Wallpapers", isDirectory: true)
        cacheURL = rootURL.appendingPathComponent("Preview Cache", isDirectory: true)
        stagingURL = rootURL.appendingPathComponent("Staging", isDirectory: true)
        steamDataURL = rootURL.appendingPathComponent("SteamCMD", isDirectory: true)
        libraryFileURL = rootURL.appendingPathComponent("Library.json")
        playlistsFileURL = rootURL.appendingPathComponent("Playlists.json")
    }

    static func defaultRootURL() -> URL {
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport.appendingPathComponent(ProductInfo.bundleIdentifier, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(ProductInfo.bundleIdentifier, isDirectory: true)
    }

    func prepareDirectories() throws {
        for directory in [rootURL, wallpapersURL, cacheURL, stagingURL, steamDataURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func loadLibrary() throws -> [WallpaperItem] {
        guard FileManager.default.fileExists(atPath: libraryFileURL.path) else { return [] }
        do {
            return try JSONDecoder.wallpaperDecoder.decode([WallpaperItem].self, from: Data(contentsOf: libraryFileURL))
        } catch {
            throw StorageError.persistenceFailed(error.localizedDescription)
        }
    }

    func saveLibrary(_ items: [WallpaperItem]) throws {
        try prepareDirectories()
        do {
            let data = try JSONEncoder.wallpaperEncoder.encode(items)
            try data.write(to: libraryFileURL, options: .atomic)
        } catch {
            throw StorageError.persistenceFailed(error.localizedDescription)
        }
    }

    func loadPlaylists() throws -> [WallpaperPlaylist] {
        guard FileManager.default.fileExists(atPath: playlistsFileURL.path) else { return [] }
        do {
            return try JSONDecoder.wallpaperDecoder.decode([WallpaperPlaylist].self, from: Data(contentsOf: playlistsFileURL))
        } catch {
            throw StorageError.persistenceFailed(error.localizedDescription)
        }
    }

    func savePlaylists(_ playlists: [WallpaperPlaylist]) throws {
        try prepareDirectories()
        do {
            let data = try JSONEncoder.wallpaperEncoder.encode(playlists)
            try data.write(to: playlistsFileURL, options: .atomic)
        } catch {
            throw StorageError.persistenceFailed(error.localizedDescription)
        }
    }

    func importLocal(from sourceURL: URL, preferredIdentity: UUID? = nil) throws -> WallpaperItem {
        Self.managedMutationLock.lock()
        defer { Self.managedMutationLock.unlock() }
        try prepareDirectories()
        let canonicalSource = FileUtilities.canonicalURL(sourceURL)
        if canonicalSource.pathExtension.lowercased() == "zip" {
            return try importArchive(canonicalSource, preferredIdentity: preferredIdentity)
        }
        let inspected = try WallpaperImporter.inspect(canonicalSource)
        let provenance = inspected.workshopID.map {
            WallpaperSource.workshop(id: $0, originalPath: canonicalSource.path)
        } ?? .managed(originalPath: canonicalSource.path)
        return try install(
            sourceURL: canonicalSource,
            inspectionURL: canonicalSource,
            identity: inspected.workshopID == nil ? (preferredIdentity ?? inspected.id) : inspected.id,
            provenance: provenance,
            metadata: nil
        )
    }

    func installWorkshopProject(from sourceDirectory: URL, metadata: WorkshopItem) throws -> WallpaperItem {
        Self.managedMutationLock.lock()
        defer { Self.managedMutationLock.unlock() }
        try prepareDirectories()
        let projectRoot = try locateWallpaper(in: sourceDirectory)
        let identity = StableIdentifier.uuid(namespace: "workshop", value: metadata.publishedFileID)
        return try install(
            sourceURL: projectRoot,
            inspectionURL: projectRoot,
            identity: identity,
            provenance: .workshop(id: metadata.publishedFileID),
            metadata: metadata
        )
    }

    func removeManagedContent(for item: WallpaperItem) throws {
        Self.managedMutationLock.lock()
        defer { Self.managedMutationLock.unlock() }
        guard item.isManaged, let managedRoot = item.projectRootURL else { return }
        let expected = wallpapersURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
        guard FileUtilities.canonicalURL(managedRoot) == FileUtilities.canonicalURL(expected),
              FileUtilities.isDescendant(expected, of: wallpapersURL) else {
            throw StorageError.invalidManagedPath
        }
        if FileManager.default.fileExists(atPath: expected.path) {
            try FileManager.default.removeItem(at: expected)
            AppLog.storage.info("Removed managed wallpaper \(item.id.uuidString, privacy: .public)")
        }
    }

    func clearPreviewCache() throws {
        guard FileUtilities.canonicalURL(cacheURL).deletingLastPathComponent() == FileUtilities.canonicalURL(rootURL) else {
            throw StorageError.invalidManagedPath
        }
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    }

    var cacheSize: Int64 { FileUtilities.allocatedSize(of: cacheURL) }

    private func importArchive(_ archiveURL: URL, preferredIdentity: UUID?) throws -> WallpaperItem {
        if let size = try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > Self.maximumArchiveBytes {
            throw StorageError.archiveTooLarge
        }
        let extractionURL = stagingURL.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractionURL) }

        try validateArchiveDirectory(archiveURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, extractionURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ImportError.archiveExtractionFailed
        }
        guard process.terminationStatus == 0 else { throw ImportError.archiveExtractionFailed }
        try validateExtractedTree(extractionURL)

        let candidate = try locateWallpaper(in: extractionURL)
        let inspected = try WallpaperImporter.inspect(candidate)
        let identity = inspected.workshopID.map { StableIdentifier.uuid(namespace: "workshop", value: $0) }
            ?? preferredIdentity
            ?? StableIdentifier.uuid(namespace: "local-archive", value: archiveURL.path)
        let provenance = inspected.workshopID.map {
            WallpaperSource.workshop(id: $0, originalPath: archiveURL.path)
        } ?? .managed(originalPath: archiveURL.path)
        return try install(
            sourceURL: candidate,
            inspectionURL: candidate,
            identity: identity,
            provenance: provenance,
            metadata: nil
        )
    }

    private func install(
        sourceURL: URL,
        inspectionURL: URL,
        identity: UUID,
        provenance: WallpaperSource,
        metadata: WorkshopItem?
    ) throws -> WallpaperItem {
        let stage = stagingURL.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        let destination = wallpapersURL.appendingPathComponent(identity.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let stagedInspectionURL: URL
        var sourceIsDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory)
        if sourceIsDirectory.boolValue {
            try validateExtractedTree(sourceURL)
        } else {
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw StorageError.unsafeArchive }
            if let size = values.fileSize, Int64(size) > Self.maximumInstalledBytes {
                throw StorageError.archiveTooLarge
            }
        }
        if sourceIsDirectory.boolValue {
            try copyDirectoryContents(from: sourceURL, to: stage)
            let relative = relativePath(of: inspectionURL, from: sourceURL)
            stagedInspectionURL = relative.isEmpty ? stage : stage.appendingPathComponent(relative)
        } else {
            let stagedFile = stage.appendingPathComponent(sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: stagedFile)
            try copySceneSidecarsIfNeeded(for: sourceURL, to: stage)
            stagedInspectionURL = stagedFile
        }
        try validateExtractedTree(stage)
        _ = try WallpaperImporter.inspect(stagedInspectionURL)

        try replaceManagedDirectory(destination, with: stage)
        let installedInspectionURL: URL
        if sourceIsDirectory.boolValue {
            let relative = relativePath(of: inspectionURL, from: sourceURL)
            installedInspectionURL = relative.isEmpty ? destination : destination.appendingPathComponent(relative)
        } else {
            installedInspectionURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
        }
        let installed = try WallpaperImporter.inspect(installedInspectionURL)
        return WallpaperItem(
            id: identity,
            name: metadata?.title ?? installed.name,
            sourceURL: installed.sourceURL,
            kind: installed.kind,
            previewURL: installed.previewURL,
            projectRootURL: destination,
            source: provenance,
            author: metadata?.creatorName ?? installed.author,
            summary: metadata?.summary ?? installed.summary,
            tags: metadata?.tags ?? installed.tags,
            compatibility: installed.compatibility,
            compatibilityNotes: installed.compatibilityNotes,
            localSize: FileUtilities.allocatedSize(of: destination)
        )
    }

    private func replaceManagedDirectory(_ destination: URL, with stage: URL) throws {
        guard FileUtilities.isDescendant(destination, of: wallpapersURL),
              FileUtilities.isDescendant(stage, of: stagingURL) else {
            throw StorageError.invalidManagedPath
        }
        let backup = stagingURL.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let hadExisting = FileManager.default.fileExists(atPath: destination.path)
        if hadExisting { try FileManager.default.moveItem(at: destination, to: backup) }
        do {
            try FileManager.default.moveItem(at: stage, to: destination)
            if hadExisting { try? FileManager.default.removeItem(at: backup) }
        } catch {
            if hadExisting, !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children {
            try FileManager.default.copyItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
    }

    private func copySceneSidecarsIfNeeded(for source: URL, to destination: URL) throws {
        guard source.pathExtension.lowercased() == "pkg" else { return }
        let parent = source.deletingLastPathComponent()
        let metadataURL = parent.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }
        try FileManager.default.copyItem(at: metadataURL, to: destination.appendingPathComponent("project.json"))
        guard let project = try? WallpaperImporter.decodeProject(at: metadataURL),
              let preview = project.preview else { return }
        let sourcePreview = FileUtilities.canonicalURL(parent.appendingPathComponent(preview))
        guard FileUtilities.isDescendant(sourcePreview, of: parent),
              FileManager.default.fileExists(atPath: sourcePreview.path) else { return }
        let destinationPreview = destination.appendingPathComponent(preview)
        try FileManager.default.createDirectory(at: destinationPreview.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourcePreview, to: destinationPreview)
    }

    private func locateWallpaper(in root: URL) throws -> URL {
        let directProject = root.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: directProject.path) { return root }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw StorageError.noWallpaperProject }

        var projectCandidates: [URL] = []
        var standaloneCandidates: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw StorageError.unsafeArchive }
            if url.lastPathComponent == "project.json" { projectCandidates.append(url.deletingLastPathComponent()) }
            if values.isDirectory != true,
               ["mp4", "mov", "m4v", "pkg", "html", "htm"].contains(url.pathExtension.lowercased()) {
                standaloneCandidates.append(url)
            }
        }
        let uniqueProjects = Array(Set(projectCandidates.map { FileUtilities.canonicalURL($0) })).sorted { $0.path < $1.path }
        if uniqueProjects.count > 1 { throw StorageError.multipleWallpaperProjects }
        if let project = uniqueProjects.first { return project }
        let sortedStandalone = standaloneCandidates.sorted { $0.path < $1.path }
        guard sortedStandalone.count == 1, let candidate = sortedStandalone.first else {
            throw StorageError.noWallpaperProject
        }
        return candidate
    }

    private func validateExtractedTree(_ root: URL) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { throw StorageError.unsafeArchive }
        var count = 0
        var total: Int64 = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= Self.maximumInstalledFiles else { throw StorageError.archiveTooLarge }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, FileUtilities.isDescendant(url, of: root) else {
                throw StorageError.unsafeArchive
            }
            if values.isDirectory != true {
                guard values.isRegularFile == true else { throw StorageError.unsafeArchive }
                let addition = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                let (newTotal, overflow) = total.addingReportingOverflow(addition)
                guard !overflow, newTotal <= Self.maximumInstalledBytes else { throw StorageError.archiveTooLarge }
                total = newTotal
            }
        }
    }

    private func validateArchiveDirectory(_ archiveURL: URL) throws {
        let text = try archiveListing(arguments: ["-Z1", "--", archiveURL.path])
        let verbose = try archiveListing(arguments: ["-Z", "-l", "--", archiveURL.path])
        var declaredBytes: Int64 = 0
        for line in verbose.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 9, whereSeparator: \.isWhitespace)
            guard fields.count == 10 else { continue }
            let permissions = fields[0]
            guard permissions.first == "-" || permissions.first == "d" || permissions.first == "l" else { continue }
            guard permissions.first != "l", let size = Int64(fields[3]), size >= 0 else {
                throw StorageError.unsafeArchive
            }
            let (newTotal, overflow) = declaredBytes.addingReportingOverflow(size)
            guard !overflow, newTotal <= Self.maximumInstalledBytes else { throw StorageError.archiveTooLarge }
            declaredBytes = newTotal
        }
        if let available = try? stagingURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           available > 0,
           declaredBytes > max(available - 512 * 1_024 * 1_024, 0) {
            throw StorageError.archiveTooLarge
        }

        let entries = text.split(whereSeparator: \.isNewline)
        guard entries.count <= Self.maximumInstalledFiles else { throw StorageError.archiveTooLarge }
        for entrySubstring in entries {
            let entry = String(entrySubstring).replacingOccurrences(of: "\\", with: "/")
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.hasPrefix("/"),
                  !entry.contains("\0"),
                  !components.contains("..") else {
                throw StorageError.unsafeArchive
            }
        }
    }

    private func archiveListing(arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ImportError.archiveExtractionFailed }

        var listing = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                listing.append(chunk)
                if listing.count > 64 * 1_024 * 1_024 {
                    process.terminate()
                    throw StorageError.unsafeArchive
                }
            }
        } catch {
            process.terminate()
            throw StorageError.unsafeArchive
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: listing, encoding: .utf8) else {
            throw ImportError.archiveExtractionFailed
        }
        return text
    }

    private func relativePath(of child: URL, from parent: URL) -> String {
        let parentPath = FileUtilities.canonicalURL(parent).path
        let childPath = FileUtilities.canonicalURL(child).path
        guard childPath.hasPrefix(parentPath + "/") else { return "" }
        return String(childPath.dropFirst(parentPath.count + 1))
    }
}

private extension JSONEncoder {
    static var wallpaperEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var wallpaperDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
