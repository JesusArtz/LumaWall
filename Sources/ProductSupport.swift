import Foundation
import ImageIO
import OSLog
import Security

enum ProductInfo {
    private static let fallbackName = "LumaWall"

    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? fallbackName
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    static let bundleIdentifier = "local.lumawall.app"
    static let wallpaperEngineAppID = "431960"
}

enum AppLog {
    private static let subsystem = ProductInfo.bundleIdentifier
    static let app = Logger(subsystem: subsystem, category: "App")
    static let library = Logger(subsystem: subsystem, category: "Library")
    static let workshop = Logger(subsystem: subsystem, category: "Workshop")
    static let steam = Logger(subsystem: subsystem, category: "Steam")
    static let renderer = Logger(subsystem: subsystem, category: "Renderer")
    static let video = Logger(subsystem: subsystem, category: "Video")
    static let web = Logger(subsystem: subsystem, category: "Web")
    static let scene = Logger(subsystem: subsystem, category: "Scene")
    static let display = Logger(subsystem: subsystem, category: "Display")
    static let storage = Logger(subsystem: subsystem, category: "Storage")
}

enum RecoveryAction: String, Sendable {
    case locateSteamCMD
    case retry
    case openSettings
    case showFile
    case openLibrary

    var title: String {
        switch self {
        case .locateSteamCMD: return "Locate SteamCMD"
        case .retry: return "Retry"
        case .openSettings: return "Open Settings"
        case .showFile: return "Show File"
        case .openLibrary: return "Open Library"
        }
    }
}

struct AppIssue: LocalizedError, Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let technicalDetails: String?
    let recoveryAction: RecoveryAction?

    var errorDescription: String? { message }

    init(
        title: String,
        message: String,
        technicalDetails: String? = nil,
        recoveryAction: RecoveryAction? = nil
    ) {
        self.title = title
        self.message = message
        self.technicalDetails = technicalDetails
        self.recoveryAction = recoveryAction
    }

    static func importing(_ error: Error) -> AppIssue {
        AppIssue(
            title: "Couldn’t Import Wallpaper",
            message: error.localizedDescription,
            technicalDetails: String(reflecting: error),
            recoveryAction: .showFile
        )
    }

}

enum KeychainStore {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            }
        }
    }

    static func value(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ProductInfo.bundleIdentifier,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ProductInfo.bundleIdentifier,
            kSecAttrAccount as String: account
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }

        let encodedValue = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: encodedValue] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = encodedValue
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
}

enum StableIdentifier {
    static func uuid(namespace: String, value: String) -> UUID {
        let bytes = Array("\(namespace):\(value)".utf8)
        let first = fnv1a(bytes, seed: 0xcbf29ce484222325)
        let second = fnv1a(bytes.reversed(), seed: 0x84222325cbf29ce4)
        var output: [UInt8] = []
        output.reserveCapacity(16)
        for shift in stride(from: 56, through: 0, by: -8) { output.append(UInt8((first >> UInt64(shift)) & 0xff)) }
        for shift in stride(from: 56, through: 0, by: -8) { output.append(UInt8((second >> UInt64(shift)) & 0xff)) }
        output[6] = (output[6] & 0x0f) | 0x50
        output[8] = (output[8] & 0x3f) | 0x80
        return UUID(uuid: (
            output[0], output[1], output[2], output[3],
            output[4], output[5], output[6], output[7],
            output[8], output[9], output[10], output[11],
            output[12], output[13], output[14], output[15]
        ))
    }

    private static func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        bytes.reduce(seed) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }
}

enum FileUtilities {
    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let child = canonicalURL(url).path
        let parent = canonicalURL(directory).path
        return child.hasPrefix(parent + "/")
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            let values = try? url.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            if values?.isDirectory != true {
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

enum ImageFileSafety {
    private static let maximumEncodedBytes = 128 * 1_024 * 1_024
    private static let maximumDimension = 16_384
    private static let maximumPixels = 64_000_000

    static func isUsablePreview(_ url: URL) -> Bool {
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= maximumEncodedBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        let widthValue = width.intValue
        let heightValue = height.intValue
        let (pixels, overflow) = widthValue.multipliedReportingOverflow(by: heightValue)
        return widthValue > 0 && heightValue > 0
            && widthValue <= maximumDimension && heightValue <= maximumDimension
            && !overflow && pixels <= maximumPixels
    }
}

enum WorkshopFavoriteStore {
    private static let key = "favorites.workshopIDs.v1"

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.array(forKey: key) as? [String] ?? []).filter(\.isSteamPublishedFileID))
    }

    static func save(_ ids: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(ids.sorted(), forKey: key)
    }
}

extension String {
    var isASCIIDecimal: Bool {
        !isEmpty && utf8.allSatisfy { (48...57).contains($0) }
    }

    var isSteamPublishedFileID: Bool {
        isASCIIDecimal && utf8.count <= 20 && UInt64(self) != nil
    }
}
