import Foundation

enum WallpaperImporter {
    private struct Project: Decodable {
        let title: String?
        let type: String?
        let file: String?
        let preview: String?
    }

    private static let supportedExtensions = Set(["mp4", "mov", "m4v"])

    static func inspect(_ url: URL) throws -> WallpaperItem {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.missing
        }

        if !isDirectory.boolValue {
            let ext = url.pathExtension.lowercased()
            if ext == "pkg" {
                let package = try ScenePackage(url: url)
                guard package.contains("scene.json") else { throw ImportError.invalidProject }
                let metadata = metadataBeside(package: url)
                return WallpaperItem(
                    name: metadata?.title?.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent,
                    sourceURL: url,
                    kind: .scenePackage,
                    previewURL: metadata?.preview.map { url.deletingLastPathComponent().appendingPathComponent($0) }
                )
            }
            guard supportedExtensions.contains(ext) else { throw ImportError.unsupportedFile(ext.isEmpty ? "unknown" : ext) }
            return WallpaperItem(name: url.deletingPathExtension().lastPathComponent, sourceURL: url)
        }

        let metadataURL = url.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let project = try? JSONDecoder().decode(Project.self, from: data) else {
            throw ImportError.invalidProject
        }

        let kind = project.type?.lowercased() ?? "unknown"
        if kind == "scene" {
            let packageURL = url.appendingPathComponent("scene.pkg")
            let package = try ScenePackage(url: packageURL)
            guard package.contains("scene.json") else { throw ImportError.invalidProject }
            let previewURL = project.preview.map { url.appendingPathComponent($0) }
            return WallpaperItem(
                name: project.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.lastPathComponent,
                sourceURL: packageURL,
                kind: .scenePackage,
                previewURL: previewURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            )
        }
        guard kind == "video" else { throw ImportError.unsupportedProject(kind) }
        guard let relativePath = project.file else { throw ImportError.videoMissing }
        let videoURL = url.appendingPathComponent(relativePath).standardizedFileURL
        guard videoURL.path.hasPrefix(url.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: videoURL.path),
              supportedExtensions.contains(videoURL.pathExtension.lowercased()) else {
            throw ImportError.videoMissing
        }

        let previewURL = project.preview.map { url.appendingPathComponent($0) }
        let name = project.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WallpaperItem(
            name: name?.isEmpty == false ? name! : url.lastPathComponent,
            sourceURL: videoURL,
            previewURL: previewURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        )
    }

    private static func metadataBeside(package: URL) -> Project? {
        let metadataURL = package.deletingLastPathComponent().appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(Project.self, from: data)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
