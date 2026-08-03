import Foundation

enum VideoScaling: String, CaseIterable, Identifiable {
    case fill
    case fit

    var id: String { rawValue }
    var title: String { self == .fill ? "Fill screen" : "Fit on screen" }
}

struct WallpaperItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case video, scenePackage }

    let id: UUID
    var name: String
    var sourcePath: String
    var previewPath: String?
    var kind: Kind

    init(name: String, sourceURL: URL, kind: Kind = .video, previewURL: URL? = nil) {
        id = UUID()
        self.name = name
        sourcePath = sourceURL.path
        previewPath = previewURL?.path
        self.kind = kind
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var previewURL: URL? { previewPath.map(URL.init(fileURLWithPath:)) }
}

enum ImportError: LocalizedError, Equatable {
    case missing
    case unsupportedFile(String)
    case invalidProject
    case unsupportedProject(String)
    case videoMissing

    var errorDescription: String? {
        switch self {
        case .missing: return "The selected item no longer exists."
        case .unsupportedFile(let ext):
            return "‘.\(ext)’ is not supported. Choose an MP4, MOV, M4V, scene.pkg, or Wallpaper Engine project folder."
        case .invalidProject: return "This folder is not a supported Wallpaper Engine video project."
        case .unsupportedProject(let kind): return "This Wallpaper Engine \(kind) project uses features LumaWall cannot render yet."
        case .videoMissing: return "The project describes a video wallpaper, but its video file is missing."
        }
    }
}
