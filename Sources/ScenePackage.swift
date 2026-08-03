import Foundation

struct ScenePackageEntry: Equatable {
    let path: String
    let offset: Int
    let length: Int
}

enum ScenePackageError: LocalizedError, Equatable {
    case unreadable
    case invalidHeader
    case invalidDirectory
    case unsafePath(String)
    case missingEntry(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The scene package could not be read."
        case .invalidHeader: return "This is not a supported Wallpaper Engine scene package."
        case .invalidDirectory: return "The scene package directory is damaged or incomplete."
        case .unsafePath(let path): return "The package contains an unsafe path: \(path)"
        case .missingEntry(let path): return "The package does not contain \(path)."
        }
    }
}

/// A bounds-checked reader for Wallpaper Engine PKGV packages.
/// Entry offsets are relative to the byte immediately following the directory.
struct ScenePackage {
    let version: String
    let entries: [ScenePackageEntry]

    private let data: Data
    private let payloadOffset: Int

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { throw ScenePackageError.unreadable }
        try self.init(data: data)
    }

    init(data: Data) throws {
        var cursor = 0
        let version = try Self.readString(data, cursor: &cursor)
        guard version.hasPrefix("PKGV") else { throw ScenePackageError.invalidHeader }
        let count = try Self.readUInt32(data, cursor: &cursor)
        guard count <= 100_000 else { throw ScenePackageError.invalidDirectory }

        var entries: [ScenePackageEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            let path = try Self.readString(data, cursor: &cursor)
            try Self.validate(path: path)
            let offset = Int(try Self.readUInt32(data, cursor: &cursor))
            let length = Int(try Self.readUInt32(data, cursor: &cursor))
            entries.append(ScenePackageEntry(path: path, offset: offset, length: length))
        }

        let payloadOffset = cursor
        for entry in entries {
            guard entry.offset >= 0, entry.length >= 0,
                  entry.offset <= data.count - payloadOffset,
                  entry.length <= data.count - payloadOffset - entry.offset else {
                throw ScenePackageError.invalidDirectory
            }
        }

        self.version = version
        self.entries = entries
        self.data = data
        self.payloadOffset = payloadOffset
    }

    func contains(_ path: String) -> Bool { entries.contains { $0.path == path } }

    func data(for path: String) throws -> Data {
        guard let entry = entries.first(where: { $0.path == path }) else { throw ScenePackageError.missingEntry(path) }
        let start = payloadOffset + entry.offset
        return data.subdata(in: start..<(start + entry.length))
    }

    func extract(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            let output = destination.appendingPathComponent(entry.path).standardizedFileURL
            guard output.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw ScenePackageError.unsafePath(entry.path)
            }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data(for: entry.path).write(to: output, options: .atomic)
        }
    }

    private static func readUInt32(_ data: Data, cursor: inout Int) throws -> UInt32 {
        guard cursor <= data.count - 4 else { throw ScenePackageError.invalidDirectory }
        let value = data[cursor..<(cursor + 4)].enumerated().reduce(UInt32(0)) { result, pair in
            result | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
        cursor += 4
        return value
    }

    private static func readString(_ data: Data, cursor: inout Int) throws -> String {
        let length = Int(try readUInt32(data, cursor: &cursor))
        guard length >= 0, length <= 1_048_576, cursor <= data.count - length,
              let value = String(data: data[cursor..<(cursor + length)], encoding: .utf8) else {
            throw ScenePackageError.invalidDirectory
        }
        cursor += length
        return value
    }

    private static func validate(path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains("..") else {
            throw ScenePackageError.unsafePath(path)
        }
    }
}
