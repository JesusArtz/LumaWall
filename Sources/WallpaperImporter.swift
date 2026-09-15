import Foundation

enum WallpaperImporter {
    private static let videoExtensions = Set(["mp4", "mov", "m4v"])
    private static let webExtensions = Set(["html", "htm"])
    private static let maximumProjectMetadataBytes = 8 * 1_024 * 1_024

    static func inspect(_ url: URL) throws -> WallpaperItem {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.missing
        }

        if isDirectory.boolValue {
            return try inspectProjectDirectory(FileUtilities.canonicalURL(url))
        }

        let fileURL = FileUtilities.canonicalURL(url)
        let ext = fileURL.pathExtension.lowercased()
        if ext == "pkg" { return try inspectScenePackage(fileURL) }
        if videoExtensions.contains(ext) {
            return WallpaperItem(
                id: StableIdentifier.uuid(namespace: "local-video", value: fileURL.path),
                name: fileURL.deletingPathExtension().lastPathComponent,
                sourceURL: fileURL,
                kind: .video,
                source: .external(path: fileURL.path),
                compatibility: .full,
                localSize: FileUtilities.allocatedSize(of: fileURL)
            )
        }
        if webExtensions.contains(ext) {
            return WallpaperItem(
                id: StableIdentifier.uuid(namespace: "local-web", value: fileURL.path),
                name: fileURL.deletingPathExtension().lastPathComponent,
                sourceURL: fileURL,
                kind: .web,
                projectRootURL: fileURL.deletingLastPathComponent(),
                source: .external(path: fileURL.path),
                compatibility: .full,
                localSize: FileUtilities.allocatedSize(of: fileURL)
            )
        }
        throw ImportError.unsupportedFile(ext.isEmpty ? "unknown" : ext)
    }

    static func inspectProjectDirectory(_ directory: URL) throws -> WallpaperItem {
        let root = FileUtilities.canonicalURL(directory)
        let project = try decodeProject(at: root.appendingPathComponent("project.json"))
        let workshopID = validatedWorkshopID(project.workshopID) ?? inferredWorkshopID(from: root)
        let previewURL = try project.preview.flatMap { try resolveOptional($0, within: root) }
        let title = project.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? root.lastPathComponent
        let id = workshopID.map { StableIdentifier.uuid(namespace: "workshop", value: $0) }
            ?? StableIdentifier.uuid(namespace: "local-project", value: root.path)
        let source = WallpaperSource.external(path: root.path, workshopID: workshopID)

        switch project.type {
        case .video:
            guard let assetPath = project.file?.nilIfEmpty else {
                throw ImportError.assetMissing("project.file")
            }
            let assetURL = try resolve(assetPath, within: root, mustExist: true)
            guard videoExtensions.contains(assetURL.pathExtension.lowercased()) else {
                throw ImportError.assetMissing(assetPath)
            }
            return WallpaperItem(
                id: id,
                name: title,
                sourceURL: assetURL,
                kind: .video,
                previewURL: previewURL,
                projectRootURL: root,
                source: source,
                summary: project.description,
                tags: project.tags,
                compatibility: .full,
                localSize: FileUtilities.allocatedSize(of: root)
            )

        case .web:
            let assetPath = project.file?.nilIfEmpty ?? "index.html"
            let assetURL = try resolve(assetPath, within: root, mustExist: true)
            guard webExtensions.contains(assetURL.pathExtension.lowercased()) else {
                throw ImportError.assetMissing(assetPath)
            }
            return WallpaperItem(
                id: id,
                name: title,
                sourceURL: assetURL,
                kind: .web,
                previewURL: previewURL,
                projectRootURL: root,
                source: source,
                summary: project.description,
                tags: project.tags,
                compatibility: .full,
                localSize: FileUtilities.allocatedSize(of: root)
            )

        case .scenePackage:
            let packagePath = project.file?.lowercased().hasSuffix(".pkg") == true
                ? project.file ?? "scene.pkg"
                : "scene.pkg"
            let packageURL = try resolve(packagePath, within: root, mustExist: true)
            let report = try SceneCompatibilityAnalyzer.inspect(packageURL: packageURL, previewURL: previewURL)
            return WallpaperItem(
                id: id,
                name: title,
                sourceURL: packageURL,
                kind: .scenePackage,
                previewURL: previewURL,
                projectRootURL: root,
                source: source,
                summary: project.description,
                tags: project.tags,
                compatibility: report.status,
                compatibilityNotes: report.notes,
                localSize: FileUtilities.allocatedSize(of: root)
            )

        case .unsupported:
            throw ImportError.unsupportedProject(project.rawType ?? "unknown")
        }
    }

    static func decodeProject(at url: URL) throws -> DecodedWallpaperProject {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumProjectMetadataBytes {
            throw ImportError.projectTooLarge
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= maximumProjectMetadataBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ImportError.invalidProject
        }

        func string(_ key: String) -> String? {
            if let value = dictionary[key] as? String { return value }
            if let number = dictionary[key] as? NSNumber { return number.stringValue }
            return nil
        }

        let rawType = string("type")
        let rawTags = dictionary["tags"] as? [Any] ?? []
        let tags = rawTags.compactMap { value -> String? in
            if let value = value as? String { return value }
            if let value = value as? [String: Any] { return value["tag"] as? String }
            return nil
        }
        return DecodedWallpaperProject(
            title: string("title"),
            type: WallpaperType.projectType(rawType),
            rawType: rawType,
            file: string("file"),
            preview: string("preview"),
            description: string("description"),
            workshopID: string("workshopid") ?? string("publishedfileid"),
            tags: tags
        )
    }

    private static func inspectScenePackage(_ packageURL: URL) throws -> WallpaperItem {
        let metadataURL = packageURL.deletingLastPathComponent().appendingPathComponent("project.json")
        let metadata = try? decodeProject(at: metadataURL)
        let previewURL: URL?
        if let preview = metadata?.preview {
            previewURL = try resolveOptional(preview, within: packageURL.deletingLastPathComponent())
        } else {
            previewURL = nil
        }
        let report = try SceneCompatibilityAnalyzer.inspect(packageURL: packageURL, previewURL: previewURL)
        let canonical = FileUtilities.canonicalURL(packageURL)
        let workshopID = validatedWorkshopID(metadata?.workshopID)
            ?? inferredWorkshopID(from: canonical.deletingLastPathComponent())
        return WallpaperItem(
            id: workshopID.map { StableIdentifier.uuid(namespace: "workshop", value: $0) }
                ?? StableIdentifier.uuid(namespace: "local-scene", value: canonical.path),
            name: metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? canonical.deletingPathExtension().lastPathComponent,
            sourceURL: canonical,
            kind: .scenePackage,
            previewURL: previewURL,
            projectRootURL: canonical.deletingLastPathComponent(),
            source: .external(path: canonical.path, workshopID: workshopID),
            summary: metadata?.description,
            tags: metadata?.tags ?? [],
            compatibility: report.status,
            compatibilityNotes: report.notes,
            localSize: FileUtilities.allocatedSize(of: canonical)
        )
    }

    private static func resolve(_ relativePath: String, within root: URL, mustExist: Bool) throws -> URL {
        let resolved = FileUtilities.canonicalURL(root.appendingPathComponent(relativePath))
        guard FileUtilities.isDescendant(resolved, of: root) else {
            throw ImportError.unsafeProjectPath(relativePath)
        }
        if mustExist && !FileManager.default.fileExists(atPath: resolved.path) {
            throw ImportError.assetMissing(relativePath)
        }
        return resolved
    }

    private static func resolveOptional(_ relativePath: String, within root: URL) throws -> URL? {
        let resolved = try resolve(relativePath, within: root, mustExist: false)
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    private static func inferredWorkshopID(from root: URL) -> String? {
        let canonical = FileUtilities.canonicalURL(root)
        let id = canonical.lastPathComponent
        guard id.isSteamPublishedFileID,
              canonical.deletingLastPathComponent().lastPathComponent == ProductInfo.wallpaperEngineAppID,
              canonical.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "content",
              canonical.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "workshop" else {
            return nil
        }
        return id
    }

    private static func validatedWorkshopID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isSteamPublishedFileID == true ? trimmed : nil
    }
}

struct DecodedWallpaperProject: Hashable, Sendable {
    let title: String?
    let type: WallpaperType
    let rawType: String?
    let file: String?
    let preview: String?
    let description: String?
    let workshopID: String?
    let tags: [String]
}

struct SceneCompatibilityReport: Hashable, Sendable {
    let status: CompatibilityStatus
    let notes: [String]
}

enum SceneCompatibilityAnalyzer {
    static func inspect(packageURL: URL, previewURL: URL?) throws -> SceneCompatibilityReport {
        let package = try ScenePackage(url: packageURL)
        let hasUsablePreview = previewURL.map(ImageFileSafety.isUsablePreview) == true
        guard package.contains("scene.json") else { throw ImportError.invalidProject }
        guard let scene = try JSONSerialization.jsonObject(
            with: package.data(for: "scene.json", maximumBytes: 8 * 1_024 * 1_024)
        ) as? [String: Any],
              let objects = scene["objects"] as? [[String: Any]] else {
            throw ImportError.invalidProject
        }

        let imageObjects = objects.filter { $0["image"] is String }
        guard !imageObjects.isEmpty else {
            if hasUsablePreview {
                return SceneCompatibilityReport(
                    status: .fallback,
                    notes: ["No renderable base image was found; the project preview will be shown."]
                )
            }
            return SceneCompatibilityReport(
                status: .unsupported,
                notes: ["The current scene renderer requires at least one image object."]
            )
        }

        var notes = ["Scene rendering currently uses the first image object as a full-screen base layer."]
        do {
            guard let modelPath = imageObjects[0]["image"] as? String,
                  let model = try jsonObject(in: package, path: modelPath),
                  let materialPath = model["material"] as? String,
                  let material = try jsonObject(in: package, path: materialPath),
                  let passes = material["passes"] as? [[String: Any]],
                  let textureName = (passes.first?["textures"] as? [String])?.first else {
                throw ImportError.unsupportedProject("scene without a compatible base material")
            }
            _ = try WETexture(data: package.data(
                for: "materials/\(textureName).tex",
                maximumBytes: WETexture.maximumInputBytes
            ))
        } catch {
            if hasUsablePreview {
                return SceneCompatibilityReport(
                    status: .fallback,
                    notes: ["The base scene texture is not supported; the project preview will be shown.", error.localizedDescription]
                )
            }
            return SceneCompatibilityReport(
                status: .unsupported,
                notes: ["The base scene texture cannot be rendered and no preview fallback is available.", error.localizedDescription]
            )
        }
        if imageObjects.count > 1 {
            notes.append("Additional image layers are not rendered.")
        }
        if objects.contains(where: { $0["particle"] != nil }) {
            notes.append("Particle systems are approximated only for recognized fog and ember resource names.")
        }
        if imageObjects.contains(where: { ($0["effects"] as? [Any])?.isEmpty == false }) {
            notes.append("Only up to three wave-like effect passes are approximated; custom shaders are not reproduced.")
        }
        if objects.count > imageObjects.count {
            notes.append("Non-image scene objects are not rendered.")
        }
        return SceneCompatibilityReport(status: .partial, notes: notes)
    }

    private static func jsonObject(in package: ScenePackage, path: String) throws -> [String: Any]? {
        let data = try package.data(for: path, maximumBytes: 8 * 1_024 * 1_024)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
