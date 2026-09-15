import AppKit
import SwiftUI

struct LocalWallpaperArtwork: View {
    let item: WallpaperItem
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let previewURL = item.previewURL, let image = LocalPreviewImageCache.image(at: previewURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.quaternary)
        }
    }
}

@MainActor
enum LocalPreviewImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path):\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard ImageFileSafety.isUsablePreview(url), let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func clear() { cache.removeAllObjects() }
}

struct RemoteWallpaperArtwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .failure: placeholder
            case .empty: placeholder.overlay { ProgressView().controlSize(.small) }
            @unknown default: placeholder
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.quaternary)
        }
    }

    private var placeholder: some View {
        Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
    }
}

struct CompatibilityBadge: View {
    let status: CompatibilityStatus

    var body: some View {
        Label(status.title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .full: return .green
        case .partial, .fallback: return .orange
        case .unsupported: return .red
        case .unknown: return .secondary
        }
    }

    private var symbol: String {
        switch status {
        case .full: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .fallback: return "photo.circle.fill"
        case .unsupported: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension Int64 {
    var formattedByteCount: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
